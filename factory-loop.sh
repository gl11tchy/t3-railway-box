#!/bin/bash
# Runs the software factory's orchestrator tick every 30 minutes, as user t3.
# entrypoint.sh starts this when FACTORY_TICK_ENABLED=1, with HOME=/home/t3 and
# FACTORY_HOME=/home/t3/.factory (both on the volume). The tick itself fast-forwards
# the checkout on main and reruns on new code, so this loop never pulls.
#
# One tick at a time: the loop is sequential, and the tick's own lock holds too.
# SIGTERM (a redeploy or a stop) lets the running tick finish, then exits; Railway's
# RAILWAY_DEPLOYMENT_DRAINING_SECONDS decides how long it may take.
set -uo pipefail

DIR="$HOME/factory"
FACTORY_HOME="${FACTORY_HOME:-$HOME/.factory}"
export FACTORY_HOME
LOG="$FACTORY_HOME/logs/tick.log"
INTERVAL="${FACTORY_TICK_INTERVAL:-1800}"
REPO="gl11tchy/software-factory"

mkdir -p "$FACTORY_HOME/logs"
say() { echo "[factory-loop] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"; }

# A tick killed with its container (a run longer than the drain) leaves tick.lock on the
# volume with a process id from that container. In this one the id means nothing, and a
# reused id would make every tick think one is still running. This loop starts once per
# boot and a Railway service with a volume never runs two containers at once, so no live
# tick can hold the lock now.
if [ -f "$FACTORY_HOME/tick.lock" ]; then
  rm -f "$FACTORY_HOME/tick.lock" && say "removed a tick.lock left by a previous container"
fi

stopping=0
on_term() { [ "$stopping" = 1 ] && return; stopping=1; say "stop requested; a running tick finishes first"; }
trap on_term TERM INT

# `wait` returns early when a signal arrives; keep waiting until the child is gone.
wait_for() {
  local pid=$1 status=0
  while :; do
    wait "$pid"
    status=$?
    kill -0 "$pid" 2>/dev/null || break
  done
  return "$status"
}

clone_if_missing() {
  [ -d "$DIR/.git" ] && return 0
  say "cloning $REPO into $DIR"
  gh repo clone "$REPO" "$DIR" 2>&1 | tee -a "$LOG"
  [ -d "$DIR/.git" ]
}

# npm ci only when the lockfile changed since the last install. The repository has no
# dependencies today and no lockfile, so this says so and does nothing.
install_if_needed() {
  local lock="$DIR/package-lock.json" stamp="$FACTORY_HOME/.package-lock.sha256" sum
  if [ ! -f "$lock" ]; then
    say "no package-lock.json, nothing to install"
    return 0
  fi
  sum=$(sha256sum "$lock" | cut -d' ' -f1)
  [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$sum" ] && return 0
  say "package-lock.json changed; running npm ci"
  if (cd "$DIR" && npm ci --no-audit --no-fund) 2>&1 | tee -a "$LOG"; then
    echo "$sum" > "$stamp"
  else
    say "npm ci failed; the tick runs with what is installed"
  fi
}

say "started; a tick every $INTERVAL seconds; log $LOG"
while :; do
  if clone_if_missing; then
    install_if_needed
    say "tick starting"
    (cd "$DIR" && exec node scripts/factory-tick.mjs) 2>&1 | tee -a "$LOG" &
    wait_for $!
    say "tick ended (exit $?)"
  else
    say "no checkout yet; trying again next round"
  fi
  [ "$stopping" = 1 ] && { say "stopped"; exit 0; }
  for ((slept = 0; slept < INTERVAL; slept += 5)); do
    [ "$stopping" = 1 ] && { say "stopped"; exit 0; }
    sleep 5
  done
done
