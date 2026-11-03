#!/bin/bash
set -e
: "${T3_SETUP_PASSWORD:?T3_SETUP_PASSWORD is required - it gates the pairing page}"

# /home/t3 is the Railway volume: empty (bar lost+found) and root-owned on first boot.
H=/home/t3
[ -f "$H/.bashrc" ] || cp -an /etc/skel/. "$H/"
mkdir -p "$H/workspace"
[ "$(stat -c %u "$H")" = 1000 ] && [ "$(stat -c %u "$H/workspace")" = 1000 ] || chown -R t3:t3 "$H"

# factory-secrets: start (test/supervisor.sh runs this block, then the supervisor below)
# The software factory's secrets arrive as sealed service variables FACTORY_SECRET_*. They go to
# a file only t3 can read, in memory and not on the volume, and out of the environment, before
# any process starts (nginx, the pairing page and the cache loop included; test/supervisor.sh
# pins that order). So neither T3 (its terminal and the agents RG runs in it) nor the factory's
# loop, tick and agents carry a secret in their environment, and /proc/<pid>/environ of none of
# them shows one. The factory's scripts read the file on demand (gl11tchy/software-factory,
# docs/railway.md). The box has one user with sudo, so this keeps secrets out of sight and out
# of accidental reach, as the Mac's Keychain does, not out of the reach of a process that looks.
SECRETS_DIR="${FACTORY_SECRETS_DIR:-/run/factory}"
SECRETS_FILE="$SECRETS_DIR/secrets.env"
mkdir -p "$SECRETS_DIR"
: > "$SECRETS_FILE"
if [ "$(id -u)" = 0 ]; then chown t3:t3 "$SECRETS_DIR" "$SECRETS_FILE"; fi
chmod 700 "$SECRETS_DIR" && chmod 600 "$SECRETS_FILE"
moved=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  # One NAME=value line per secret, so a value with a newline cannot be stored. It is dropped
  # with a note (the name only), never written broken.
  case "${!name}" in
    *$'\n'*) echo "== factory secrets: $name holds a newline and was not written"; unset "$name"; continue ;;
  esac
  printf '%s=%s\n' "$name" "${!name}" >> "$SECRETS_FILE"
  unset "$name"
  moved=$((moved + 1))
done < <(compgen -e | grep '^FACTORY_SECRET_' || true)
echo "== factory secrets: $moved moved to $SECRETS_FILE"
export FACTORY_SECRETS_FILE="$SECRETS_FILE"
# factory-secrets: end

as_t3() { setpriv --reuid=1000 --regid=1000 --init-groups env HOME="$H" USER=t3 LOGNAME=t3 SHELL=/bin/bash "$@"; }

# Optional keys, applied once so a login done in the app is never overwritten.
if [ -n "${OPENAI_API_KEY:-}" ] && [ ! -f "$H/.codex/auth.json" ]; then
  printenv OPENAI_API_KEY | as_t3 codex login --with-api-key >/dev/null 2>&1 || echo "codex: API-key login failed"
fi
[ -n "${GH_TOKEN:-}" ] && { as_t3 gh auth setup-git >/dev/null 2>&1 || true; }

# nginx on $PORT. /railway-pair (password page) mints pairing links; everything else
# is the T3 server, which authenticates every API call, WebSocket and terminal itself.
# Railway's proxy hides client IPs, so the limit is one shared bucket: 10 password
# tries a minute in total, which makes online guessing hopeless whatever the hardware.
cat > /etc/nginx/conf.d/t3.conf <<CFG
limit_req_zone \$host zone=pair:1m rate=10r/m;
limit_req_status 429;
server {
  listen ${PORT} default_server;
  listen [::]:${PORT} default_server;
  client_max_body_size 200m;
  location = /healthcheck { proxy_pass http://127.0.0.1:3773/.well-known/t3/environment; }
  location = /railway-pair { limit_req zone=pair burst=5 nodelay; proxy_pass http://127.0.0.1:3774; proxy_set_header Host \$http_host; }
  location / {
    proxy_pass http://127.0.0.1:3773;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$http_connection;
    proxy_set_header Host \$http_host;
    proxy_buffering off;
    proxy_read_timeout 1d;
    proxy_send_timeout 1d;
  }
}
CFG
nginx

as_t3 node /opt/railway-pair.mjs &
unset T3_SETUP_PASSWORD

# Railway counts the kernel cache of files this container touched as its memory and
# never frees it without pressure (one npm install = hundreds of MB). Drop it every 15 min.
( while sleep 900; do nice -n 19 drop-file-cache "$H" /tmp || true; done ) &

# supervisor: start (test/supervisor.sh runs the script from this line, after the secrets block)
echo "== T3 Code $(t3 --version 2>/dev/null) on :${PORT}. Pair a device at https://<your-domain>/railway-pair"
cd "$H/workspace"

# From here on, this script supervises two children and must outlive a failing one long
# enough to stop the other, so errors no longer end it.
set +e
t3_pid="" loop_pid="" stopping=0 t3_told=0
# `wait` returns early when a trapped signal arrives; keep waiting until the child is gone.
wait_for() {
  local pid=$1 status=0
  while :; do
    wait "$pid"
    status=$?
    kill -0 "$pid" 2>/dev/null || break
  done
  return "$status"
}
loop_running() { [ -n "$loop_pid" ] && kill -0 "$loop_pid" 2>/dev/null; }
stop_t3() { [ "$t3_told" = 1 ] && return; t3_told=1; [ -n "$t3_pid" ] && kill -TERM "$t3_pid" 2>/dev/null; }
# A stop (a redeploy, a variable change): the loop goes first and finishes the tick it is
# in, T3 keeps serving meanwhile, and T3 is stopped once the loop is gone. Railway's
# RAILWAY_DEPLOYMENT_DRAINING_SECONDS bounds the whole wait.
# shellcheck disable=SC2329  # invoked by the trap below
on_term() {
  stopping=1
  if loop_running; then kill -TERM "$loop_pid" 2>/dev/null; else stop_t3; fi
}
trap on_term TERM INT

# The software factory's orchestrator (gl11tchy/software-factory, docs/railway.md) runs a
# tick every 30 minutes as t3, with its state on the volume, only when the service variable
# FACTORY_TICK_ENABLED is 1. Exactly one machine may run it: switch it off here before
# switching it on anywhere else. Set RAILWAY_DEPLOYMENT_DRAINING_SECONDS (3600 is safe) or
# Railway kills a running tick at once on a redeploy.
if [ "${FACTORY_TICK_ENABLED:-0}" = 1 ]; then
  echo "== factory loop: on (every 30 min)"
  # A plain command, not the as_t3 function: backgrounding a function leaves a subshell
  # between this script and the loop, and a stop signal sent to that subshell never arrives.
  setpriv --reuid=1000 --regid=1000 --init-groups env HOME="$H" USER=t3 LOGNAME=t3 SHELL=/bin/bash \
    FACTORY_HOME="$H/.factory" bash /opt/factory-loop.sh &
  loop_pid=$!
else
  echo "== factory loop: off (FACTORY_TICK_ENABLED is not 1)"
fi

# 0.0.0.0 = T3's "remote-reachable" policy (it is, via the domain); nginx still fronts it.
# `t3 serve` prints a one-time admin pairing token + QR at boot; keep it out of the logs.
setpriv --reuid=1000 --regid=1000 --init-groups env HOME="$H" USER=t3 LOGNAME=t3 SHELL=/bin/bash \
  t3 serve --host 0.0.0.0 --port 3773 "$H/workspace" \
  > >(sed -u -e '/^Token: /d' -e 's/token=[^ "&]*/token=<redacted>/g' -e '/^[ █▀▄]*$/d') 2>&1 &
t3_pid=$!

while kill -0 "$t3_pid" 2>/dev/null; do
  [ "$stopping" = 1 ] && ! loop_running && stop_t3
  sleep 1
done
wait "$t3_pid"
t3_status=$?

# T3 is gone. On a stop that is the planned order. Otherwise T3 crashed and the container
# restarts: stop the loop too, and give a tick in flight the time to finish.
if loop_running; then
  kill -TERM "$loop_pid" 2>/dev/null
  wait_for "$loop_pid"
fi
[ "$stopping" = 1 ] && exit 0
exit "$t3_status"
