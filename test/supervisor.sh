#!/bin/bash
# Checks how entrypoint.sh supervises t3 serve, the factory loop and the factory waker, with stubs:
#   1. a stop mid-tick lets the tick finish, keeps T3 up until then, and exits 0
#   2. a T3 crash stops the loop (its tick finishes) and exits with T3's status
#   3. with FACTORY_TICK_ENABLED unset, T3 runs alone and a stop exits 0
#   4. a FACTORY_SECRET_* variable reaches the secrets file and not T3's or the tick's environment
#   5. a stop that lands in the last sleep of the loop's wait starts no further tick
#   6. the waker starts only with FACTORY_WAKER_ENABLED=1, and a stop mid-tick stops it at once,
#      before the tick finishes, with the secrets out of its environment
#   7. a waker that exits is started again, and a stop ends the supervisor with exit 0
#   8. a missing checkout is cloned before the waker starts
#   9. a waker that fails gets the newest main before it starts again
#  10. every waker start gets the newest main first
#  11. the waker's npm dependencies are installed before it starts, once per lockfile
# Case 1 exists because the first draft started the loop through a shell function, which
# left a subshell in between, and the stop signal never reached the loop.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/workspace" "$T/home/factory/scripts" "$T/home/workspace/software-factory/orchestrator" "$T/clone-src/orchestrator"

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
# A stand-in waker. WAKER_EXIT_AFTER=1 makes it exit by itself after a second; otherwise it runs
# until SIGTERM, which it answers with exit 0 as the real one does.
cat > "$T/home/workspace/software-factory/orchestrator/waker.mjs" <<'EOF'
process.on("SIGTERM", () => { console.log("waker: stopped"); process.exit(0); });
console.log("waker running; secrets in env: " + Object.keys(process.env).filter(k => k.startsWith("FACTORY_SECRET_")).length +
  "; secrets file set: " + Boolean(process.env.FACTORY_SECRETS_FILE) + "; factory home: " + process.env.FACTORY_HOME);
if (process.env.WAKER_EXIT_AFTER) setTimeout(() => process.exit(3), 1000);
setInterval(() => {}, 1000);
EOF
git -C "$T/home/workspace/software-factory" init -q
# `gh repo clone <repo> <dir>` for case 8: copies a prepared checkout.
cp "$T/home/workspace/software-factory/orchestrator/waker.mjs" "$T/clone-src/orchestrator/waker.mjs"
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
[ "$1 $2" = "repo clone" ] || exit 1
echo "gh: cloning $3"
mkdir -p "$4" && cp -R "$GH_CLONE_SRC/." "$4/" && git -C "$4" init -q
EOF
chmod +x "$T/bin/gh"

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
  sed -n '/^# supervisor: start/,$p' entrypoint.sh | sed -e "s#/opt/factory-loop.sh#$ROOT/factory-loop.sh#" -e "s#/opt/factory-waker.sh#$ROOT/factory-waker.sh#"
} > "$T/tail.sh"

run_case() { # name, seconds before SIGTERM (0 = never), extra env...
  local name=$1 after=$2; shift 2
  ( env PATH="$T/bin:$PATH" PORT=8080 FACTORY_TICK_INTERVAL=60 FACTORY_WAKER_RESTART_DELAY=1 GH_CLONE_SRC="$T/clone-src" FACTORY_SECRETS_DIR="$T/run" "$@" bash "$T/tail.sh" > "$T/$name.out" 2>&1
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
expect off "factory waker: off (FACTORY_WAKER_ENABLED is not 1)"
if grep -q "factory-waker\|waker running" "$T/off.out"; then echo "FAIL: off case started the waker"; failed=1; fi

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

# The tick works for three seconds; a stop at 1.5 seconds must end the waker at once, long
# before the tick, and T3 still waits for the tick as in case 1.
echo "case 6: waker on, stop mid-tick"
rm -rf "$T/home/.factory"
run_case wakerstop 1.5 FACTORY_TICK_ENABLED=1 FACTORY_WAKER_ENABLED=1 FACTORY_SECRET_DEMO=hunter2
expect wakerstop "factory waker: on"
expect wakerstop "waker running; secrets in env: 0; secrets file set: true; factory home: $T/home/.factory"
order wakerstop "waker: stopped" "tick done"
order wakerstop "tick done" "t3: stopped"
expect wakerstop "^exit 0"
if [ ! -s "$T/home/.factory/logs/waker.log" ]; then echo "FAIL: waker.log is empty"; failed=1; fi

echo "case 7: waker that exits is started again"
rm -rf "$T/home/.factory"
run_case wakerrestart 4.5 FACTORY_WAKER_ENABLED=1 WAKER_EXIT_AFTER=1
starts=$(grep -c 'waker running' "$T/wakerrestart.out")
if [ "$starts" -lt 2 ]; then echo "FAIL: wakerrestart started the waker $starts time(s), not 2 or more"; failed=1; fi
expect wakerrestart "waker ended (exit 3)"
expect wakerrestart "t3: stopped"
expect wakerrestart "^exit 0"
if grep -q "factory loop: on" "$T/wakerrestart.out"; then echo "FAIL: wakerrestart started the loop"; failed=1; fi

echo "case 8: waker clones a missing checkout"
rm -rf "$T/home/.factory" "$T/home/workspace/software-factory"
run_case wakerclone 3 FACTORY_WAKER_ENABLED=1
order wakerclone "gh: cloning gl11tchy/software-factory" "waker running"
expect wakerclone "^exit 0"

# Case 9: a merge to main that breaks the waker at start, then the fix merged after it. The
# waker cannot pull the fix itself, so the supervisor must, or the factory never wakes again.
# The broken v1 merges the v2 fix upstream itself before it exits, so the fix lands after the
# update before the first start, and only the update before the restart can bring it.
echo "case 9: a failing waker gets the newest main"
G="git -c user.name=test -c user.email=test@example.invalid"
V2='process.on("SIGTERM", () => process.exit(0)); console.log("waker v2 running"); setInterval(() => {}, 1000)'
rm -rf "$T/home/.factory" "$T/home/workspace/software-factory" "$T/upstream"
mkdir -p "$T/upstream/orchestrator"
$G init -q -b main "$T/upstream"
cat > "$T/merge-fix.sh" <<FIX
printf '%s\n' '$V2' > "$T/upstream/orchestrator/waker.mjs"
$G -C "$T/upstream" commit -qam v2
FIX
printf '%s\n' "import { execFileSync } from \"node:child_process\"; console.log(\"waker v1 broken\"); execFileSync(\"bash\", [\"$T/merge-fix.sh\"]); process.exit(3)" \
  > "$T/upstream/orchestrator/waker.mjs"
$G -C "$T/upstream" add -A && $G -C "$T/upstream" commit -qm v1
git clone -q "$T/upstream" "$T/home/workspace/software-factory"
run_case wakerupdate 5 FACTORY_WAKER_ENABLED=1
order wakerupdate "waker v1 broken" "waker ended (exit 3)"
order wakerupdate "waker ended (exit 3)" "Fast-forward"
order wakerupdate "Fast-forward" "waker v2 running"
expect wakerupdate "^exit 0"

# Case 10: a redeploy onto a checkout behind main. The waker loads its code once, at start, so
# the supervisor fast-forwards before every start, not only after a failure.
echo "case 10: every waker start gets the newest main first"
rm -rf "$T/home/.factory" "$T/home/workspace/software-factory" "$T/upstream"
mkdir -p "$T/upstream/orchestrator"
$G init -q -b main "$T/upstream"
printf '%s\n' "${V2/v2/v1}" > "$T/upstream/orchestrator/waker.mjs"
$G -C "$T/upstream" add -A && $G -C "$T/upstream" commit -qm v1
git clone -q "$T/upstream" "$T/home/workspace/software-factory"
printf '%s\n' "$V2" > "$T/upstream/orchestrator/waker.mjs"
$G -C "$T/upstream" commit -qam v2
run_case wakerfresh 3 FACTORY_WAKER_ENABLED=1
order wakerfresh "Fast-forward" "waker v2 running"
if grep -q "waker v1 running" "$T/wakerfresh.out"; then echo "FAIL: wakerfresh: the checkout behind main ran"; failed=1; fi
expect wakerfresh "^exit 0"

# Case 11: the waker's checkout has a lockfile. On 2026-11-05 the box's waker checkout had no
# node_modules at all, so the run-history sync could not load the Postgres driver. The
# supervisor installs before the start, and only once per lockfile.
echo "case 11: the waker's dependencies are installed before it starts"
printf '#!/bin/bash\necho "npm $*"\n' > "$T/bin/npm" && chmod +x "$T/bin/npm"
echo '{"lockfileVersion": 3}' > "$T/upstream/package-lock.json"
$G -C "$T/upstream" add -A && $G -C "$T/upstream" commit -qm lock
run_case wakerdeps 3 FACTORY_WAKER_ENABLED=1
order wakerdeps "npm ci --no-audit --no-fund" "waker v2 running"
run_case wakerdeps2 3 FACTORY_WAKER_ENABLED=1
if grep -q "npm ci" "$T/wakerdeps2.out"; then echo "FAIL: wakerdeps2: npm ci ran again for the same lockfile"; failed=1; fi
expect wakerdeps2 "waker v2 running"

if [ "$failed" = 0 ]; then echo "supervisor: all eleven cases pass"; else echo "supervisor: FAILED"; exit 1; fi
