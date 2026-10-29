#!/bin/bash
set -e
: "${T3_SETUP_PASSWORD:?T3_SETUP_PASSWORD is required - it gates the pairing page}"

# /home/t3 is the Railway volume: empty (bar lost+found) and root-owned on first boot.
H=/home/t3
[ -f "$H/.bashrc" ] || cp -an /etc/skel/. "$H/"
mkdir -p "$H/workspace"
[ "$(stat -c %u "$H")" = 1000 ] && [ "$(stat -c %u "$H/workspace")" = 1000 ] || chown -R t3:t3 "$H"

# T3 names a Linux environment after PRETTY_HOSTNAME, else the container hostname, which changes on every deploy.
[ -n "${T3_ENVIRONMENT_LABEL:-}" ] && printf 'PRETTY_HOSTNAME="%s"\n' "$T3_ENVIRONMENT_LABEL" > /etc/machine-info

as_t3() { setpriv --reuid=1000 --regid=1000 --init-groups env HOME="$H" USER=t3 LOGNAME=t3 SHELL=/bin/bash "$@"; }

# Optional keys, applied once so a login done in the app is never overwritten.
if [ -n "${OPENAI_API_KEY:-}" ] && [ ! -f "$H/.codex/auth.json" ]; then
  printenv OPENAI_API_KEY | as_t3 codex login --with-api-key >/dev/null 2>&1 || echo "codex: API-key login failed"
fi
[ -n "${GH_TOKEN:-}" ] && { as_t3 gh auth setup-git >/dev/null 2>&1 || true; }

# nginx on $PORT. /railway-pair (password page) mints pairing links; everything else
# is the T3 server, which authenticates every API call, WebSocket and terminal itself.
cat > /etc/nginx/conf.d/t3.conf <<CFG
server {
  listen ${PORT} default_server;
  listen [::]:${PORT} default_server;
  client_max_body_size 200m;
  location = /healthcheck { proxy_pass http://127.0.0.1:3773/.well-known/t3/environment; }
  location = /railway-pair { proxy_pass http://127.0.0.1:3774; proxy_set_header Host \$http_host; }
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

echo "== T3 Code $(t3 --version 2>/dev/null) on :${PORT}. Pair a device at https://<your-domain>/railway-pair"
cd "$H/workspace"
# 0.0.0.0 = T3's "remote-reachable" policy (it is, via the domain); nginx still fronts it.
# `t3 serve` prints a one-time admin pairing token + QR at boot; keep it out of the logs.
exec setpriv --reuid=1000 --regid=1000 --init-groups env HOME="$H" USER=t3 LOGNAME=t3 SHELL=/bin/bash \
  t3 serve --host 0.0.0.0 --port 3773 "$H/workspace" \
  > >(sed -u -e '/^Token: /d' -e 's/token=[^ "&]*/token=<redacted>/g' -e '/^[ █▀▄]*$/d') 2>&1
