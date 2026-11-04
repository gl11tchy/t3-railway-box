#!/bin/bash
# Keeps the software factory's waker running, as user t3.
# entrypoint.sh starts this when FACTORY_WAKER_ENABLED=1, with HOME=/home/t3,
# FACTORY_HOME=/home/t3/.factory (both on the volume) and FACTORY_SECRETS_FILE set. The waker
# (gl11tchy/software-factory, docs/factory-v2.md) wakes the Factory orchestrator chat when
# Linear events arrive, or every 15 minutes while work is open.
#
# The waker holds no work, so SIGTERM (a redeploy or a stop) stops it at once: the signal goes
# to the waker, which exits 0, and this script exits 0 with it. If the waker exits on its own,
# it starts again after FACTORY_WAKER_RESTART_DELAY seconds (10 unless a test sets it).
set -uo pipefail

DIR="$HOME/workspace/software-factory"
FACTORY_HOME="${FACTORY_HOME:-$HOME/.factory}"
export FACTORY_HOME
LOG="$FACTORY_HOME/logs/waker.log"
DELAY="${FACTORY_WAKER_RESTART_DELAY:-10}"
REPO="gl11tchy/software-factory"

mkdir -p "$FACTORY_HOME/logs" "$HOME/workspace"
say() { echo "[factory-waker] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"; }

stopping=0 waker_pid=""
on_term() {
  stopping=1
  [ -n "$waker_pid" ] && kill -TERM "$waker_pid" 2>/dev/null
}
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

say "started; log $LOG"
while :; do
  [ "$stopping" = 1 ] && { say "stopped"; exit 0; }
  if clone_if_missing; then
    # A stop that landed during the clone (where bash runs the trap only once it ends) must not
    # start the waker.
    [ "$stopping" = 1 ] && { say "stopped"; exit 0; }
    say "waker starting"
    # exec, so the process id is the waker's own and a stop signal reaches it. The output goes to
    # Railway's log and to the log file on the volume.
    (cd "$DIR" && exec node orchestrator/waker.mjs) > >(tee -a "$LOG") 2>&1 &
    waker_pid=$!
    # A stop that landed before the process id was known.
    [ "$stopping" = 1 ] && kill -TERM "$waker_pid" 2>/dev/null
    wait_for "$waker_pid"
    status=$?
    waker_pid=""
    say "waker ended (exit $status)"
  else
    say "no checkout yet; trying again in $DELAY seconds"
  fi
  for ((slept = 0; slept < DELAY; slept++)); do
    [ "$stopping" = 1 ] && break
    sleep 1
  done
done
