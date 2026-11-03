#!/bin/bash
# Checks how entrypoint.sh supervises t3 serve and the factory loop, with stubs:
#   1. a stop mid-tick lets the tick finish, keeps T3 up until then, and exits 0
#   2. a T3 crash stops the loop (its tick finishes) and exits with T3's status
#   3. with FACTORY_TICK_ENABLED unset, T3 runs alone and a stop exits 0
#   4. a FACTORY_SECRET_* variable reaches the secrets file and not T3's or the tick's environment
#   5. a stop that lands in the last sleep of the loop's wait starts no further tick
# Case 1 exists because the first draft started the loop through a shell function, which
# left a subshell in between, and the stop signal never reached the loop.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/workspace" "$T/home/factory/scripts"

cat > "$T/bin/setpriv" <<'EOF'
#!/bin/bash
while [[ $1 == --* ]]; do shift; done
exec "$@"
EOF
cat > "$T/bin/t3" <<'EOF'
#!/bin/bash
[ "$1" = --version ] && { echo 0.0.0-stub; exit 0; }
if [ "${T3_CRASH:-0}" = 1 ]; then echo "t3 serving"; sleep 1; echo "t3 crashing"; exit 7; fi
trap 'echo "t3: stopped"; exit 0' TERM
echo "t3 serving; secrets in env: $(env | grep -c '^FACTORY_SECRET_')"
while :; do sleep 1; done
EOF
chmod +x "$T/bin"/*
# A stand-in tick: three seconds of work, so a stop arrives while it runs.
echo 'console.log("tick working; secrets in env: " + Object.keys(process.env).filter(k => k.startsWith("FACTORY_SECRET_")).length); await new Promise(r => setTimeout(r, 3000)); console.log("tick done")' \
  > "$T/home/factory/scripts/factory-tick.mjs"
git -C "$T/home/factory" init -q

# The secrets block must run before any process starts, or that process keeps every secret in
# its environment for life (the pairing page runs as t3 and answers the internet).
secrets_at=$(grep -n '^# factory-secrets: start' entrypoint.sh | cut -d: -f1)
first_process=$(grep -nE '^nginx$|railway-pair|drop-file-cache|codex login|gh auth' entrypoint.sh | head -1 | cut -d: -f1)
if [ -z "$secrets_at" ] || [ -z "$first_process" ] || [ "$secrets_at" -ge "$first_process" ]; then
  echo "FAIL: the factory-secrets block (line ${secrets_at:-?}) must come before the first process (line ${first_process:-?})"
  exit 1
fi

# The secrets block and the supervising tail of the entrypoint, with the image paths pointed
# at this checkout.
{
  echo "H=$T/home; as_t3() { env HOME=\"\$H\" \"\$@\"; }"
  sed -n '/^# factory-secrets: start/,/^# factory-secrets: end/p' entrypoint.sh
  sed -n '/^# supervisor: start/,$p' entrypoint.sh | sed "s#/opt/factory-loop.sh#$ROOT/factory-loop.sh#"
} > "$T/tail.sh"

run_case() { # name, seconds before SIGTERM (0 = never), extra env...
  local name=$1 after=$2; shift 2
  ( env PATH="$T/bin:$PATH" PORT=8080 FACTORY_TICK_INTERVAL=60 FACTORY_SECRETS_DIR="$T/run" "$@" bash "$T/tail.sh" > "$T/$name.out" 2>&1
    echo "exit $?" >> "$T/$name.out" ) &
  local sup=$!
  if [ "$after" != 0 ]; then
    sleep "$after"
    pkill -TERM -f "bash $T/tail.sh"
  fi
  wait "$sup"
  sed "s/^/  [$name] /" "$T/$name.out"
}
expect() { # name, pattern
  grep -q -- "$2" "$T/$1.out" && return 0
  echo "FAIL: $1 lacks: $2"; failed=1
}
order() { # name, earlier pattern, later pattern
  local a b
  a=$(grep -n -- "$2" "$T/$1.out" | head -1 | cut -d: -f1)
  b=$(grep -n -- "$3" "$T/$1.out" | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && return 0
  echo "FAIL: $1: '$2' must come before '$3'"; failed=1
}
failed=0

echo "case 1: stop mid-tick (with a secret among the service variables)"
run_case stop 1.5 FACTORY_TICK_ENABLED=1 FACTORY_SECRET_DEMO=hunter2
expect stop "factory loop: on"
echo "case 4: the secret went to the file and nowhere else"
expect stop "factory secrets: 1 moved to"
expect stop "t3 serving; secrets in env: 0"
expect stop "tick working; secrets in env: 0"
if ! grep -q '^FACTORY_SECRET_DEMO=hunter2$' "$T/run/secrets.env"; then echo "FAIL: secrets file lacks the secret"; failed=1; fi
# GNU stat (Linux) takes -c; BSD stat (macOS) takes -f. Try GNU first: BSD's `-f` is also a GNU
# flag (file-system stat), which succeeds with the wrong output.
mode=$(stat -c '%a' "$T/run/secrets.env" 2>/dev/null || stat -f '%Lp' "$T/run/secrets.env")
if [ "$mode" != 600 ]; then echo "FAIL: secrets file mode is $mode, not 600"; failed=1; fi
if grep -q hunter2 "$T/stop.out"; then echo "FAIL: the secret was printed"; failed=1; fi
expect stop "stop requested; a running tick finishes first"
order stop "tick done" "t3: stopped"
order stop " stopped$" "^exit 0"
expect stop "^exit 0"

echo "case 2: T3 crash"
rm -rf "$T/home/.factory"
run_case crash 0 FACTORY_TICK_ENABLED=1 T3_CRASH=1
order crash "t3 crashing" "tick done"
expect crash "^exit 7"

echo "case 3: loop off"
run_case off 1
expect off "factory loop: off (FACTORY_TICK_ENABLED is not 1)"
expect off "t3: stopped"
expect off "^exit 0"
if grep -q "factory-loop" "$T/off.out"; then echo "FAIL: off case started the loop"; failed=1; fi

# Case 5 pins a failure seen on the box: with a 5-second interval the wait is one sleep, so a
# stop at 6 seconds (the 3-second tick is over) lands in its last sleep. Before the fix the loop
# started a second tick on the way out.
echo "case 5: stop in the last sleep of the wait"
rm -rf "$T/home/.factory"
run_case lastsleep 6 FACTORY_TICK_ENABLED=1 FACTORY_TICK_INTERVAL=5
order lastsleep "tick ended" "stop requested"
ticks=$(grep -c 'tick starting' "$T/lastsleep.out")
if [ "$ticks" != 1 ]; then echo "FAIL: lastsleep started $ticks ticks, not 1"; failed=1; fi
expect lastsleep " stopped$"
expect lastsleep "^exit 0"

if [ "$failed" = 0 ]; then echo "supervisor: all five cases pass"; else echo "supervisor: FAILED"; exit 1; fi
