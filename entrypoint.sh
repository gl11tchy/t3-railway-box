#!/bin/bash
set -e
: "${T3_SETUP_PASSWORD:?T3_SETUP_PASSWORD is required - it gates the pairing page}"

# /home/t3 is the Railway volume: empty (bar lost+found) and root-owned on first boot.
H=/home/t3
[ -f "$H/.bashrc" ] || cp -an /etc/skel/. "$H/"
mkdir -p "$H/workspace"
[ "$(stat -c %u "$H")" = 1000 ] && [ "$(stat -c %u "$H/workspace")" = 1000 ] || chown -R t3:t3 "$H"

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

# Optional tailnet. The container has no TUN device, so tailscaled runs in userspace mode.
# State lives on the volume, so the node keeps its name and identity across redeploys.
if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
  TS="$H/.tailscale"
  install -d -m 700 -o root -g root "$TS" || true
  mkdir -p /run/tailscale
  ts_state() { tailscale status --json 2>/dev/null | jq -r '.BackendState // empty'; }
  # env -u keeps the key out of the daemon's environment.
  env -u TAILSCALE_AUTHKEY tailscaled --tun=userspace-networking --state="$TS/tailscaled.state" \
    --socket=/run/tailscale/tailscaled.sock >> "$TS/tailscaled.log" 2>&1 &
  # A saved node passes through Starting before Running; waiting avoids a needless re-login.
  for _ in $(seq 20); do
    case "$(ts_state)" in Running|NeedsLogin) break ;; esac
    sleep 0.5
  done
  if [ "$(ts_state)" != Running ]; then
    ts_key="$TAILSCALE_AUTHKEY"; ts_tags=()
    # An OAuth client secret needs the tag its key was issued for; a plain auth key joins as its owner.
    case "$ts_key" in tskey-client-*)
      ts_key="$ts_key?ephemeral=false&preauthorized=true"
      ts_tags=(--advertise-tags="${TAILSCALE_TAGS:-tag:claude-cloud}") ;;
    esac
    printf '%s' "$ts_key" | timeout 2m tailscale up --auth-key=file:/dev/stdin --operator=t3 \
      --hostname="${TAILSCALE_HOSTNAME:-t3-railway}" "${ts_tags[@]}" >/dev/null || echo "tailscale: login failed"
    unset ts_key ts_tags
  fi
  if [ "$(ts_state)" = Running ]; then
    timeout 30 tailscale serve --bg --https=443 "http://127.0.0.1:${PORT}" >/dev/null \
      || echo "tailscale: serve failed (are HTTPS certificates on for the tailnet?)"
    cat > /etc/ssh/ssh_config.d/tailnet.conf <<'SSH'
Host 100.* *.ts.net
  ProxyCommand tailscale nc %h %p
SSH
    echo "tailscale: $(tailscale status --json | jq -r '.Self.DNSName // empty | sub("\\.$"; "")')"
  else
    echo "tailscale: not connected, see $TS/tailscaled.log"
  fi
fi
# Before the pairing page and T3 start, so nothing agents run can inherit the key.
unset TAILSCALE_AUTHKEY

as_t3 node /opt/railway-pair.mjs &
unset T3_SETUP_PASSWORD

# Railway counts the kernel cache of files this container touched as its memory and
# never frees it without pressure (one npm install = hundreds of MB). Drop it every 15 min.
( while sleep 900; do nice -n 19 drop-file-cache "$H" /tmp || true; done ) &

echo "== T3 Code $(t3 --version 2>/dev/null) on :${PORT}. Pair a device at https://<your-domain>/railway-pair"
cd "$H/workspace"
# 0.0.0.0 = T3's "remote-reachable" policy (it is, via the domain); nginx still fronts it.
# `t3 serve` prints a one-time admin pairing token + QR at boot; keep it out of the logs.
exec setpriv --reuid=1000 --regid=1000 --init-groups env HOME="$H" USER=t3 LOGNAME=t3 SHELL=/bin/bash \
  t3 serve --host 0.0.0.0 --port 3773 "$H/workspace" \
  > >(sed -u -e '/^Token: /d' -e 's/token=[^ "&]*/token=<redacted>/g' -e '/^[ █▀▄]*$/d') 2>&1
