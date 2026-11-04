FROM ubuntu:24.04

# Bump here. T3: version + sha256 of t3-<v>-linux-x64.tar.gz from the release's SHA256SUMS.
# `# upgrade:` lines tell dispatched.zaur.app where to look for newer releases.
# upgrade: github pingdotgg/t3code
ARG T3_VERSION=0.1.7
ARG T3_SHA256=c089892bf7922e2e73c6f44a5d1ea125c99f70e378c18361cbbed2fba1920e6c
# upgrade: npm @anthropic-ai/claude-code
ARG CLAUDE_CODE_VERSION=2.1.317
# upgrade: npm @openai/codex
ARG CODEX_VERSION=0.163.0
# OpenCode 2 (@opencode/cli); T3 gives OpenCode 1.x only limited support.
# upgrade: npm @opencode/cli
ARG OPENCODE_VERSION=2.1.3
# The software factory's release stage (gl11tchy/software-factory, docs/release.md) deploys
# products with the Vercel CLI and backs each product's database up with pg_dump.
# Vercel is pinned to the version the factory's release script was proven with on the Mac.
# upgrade: npm vercel
ARG VERCEL_VERSION=56.4.1

# Global npm installs go to /opt/npm, owned by the t3 user, so T3's "Update" button for
# Claude/Codex works without root (until the next redeploy restores the pinned versions).
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 PORT=8080 \
    NPM_CONFIG_PREFIX=/opt/npm PATH=/opt/npm/bin:$PATH \
    OPENCODE_DISABLE_AUTOUPDATE=1 DISABLE_AUTOUPDATER=1

# Toolbox the agents work with: git, gh, Node 22, Python 3 + uv, build tools, ripgrep.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg git openssh-client nginx-light sudo tmux \
      vim nano less htop ripgrep fd-find jq unzip zip tree procps locales qrencode tini \
      python3 python3-pip python3-venv build-essential libatomic1 \
  && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
  # pg_dump 18 from PostgreSQL's own repository: product databases live in the factory's
  # Railway Postgres, which runs 18, and an older pg_dump refuses to dump a newer server.
  && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/keyrings/pgdg.asc \
  && echo "deb [signed-by=/usr/share/keyrings/pgdg.asc] https://apt.postgresql.org/pub/repos/apt noble-pgdg main" \
       > /etc/apt/sources.list.d/pgdg.list \
  && apt-get update && apt-get install -y --no-install-recommends nodejs gh postgresql-client-18 \
  && curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh \
  && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" "@openai/codex@${CODEX_VERSION}" \
       "@opencode/cli@${OPENCODE_VERSION}" "vercel@${VERCEL_VERSION}" \
  && npm cache clean --force && claude --version && codex --version && opencode --version && vercel --version \
  && pg_dump --version \
  && curl -fsSL -o /tmp/t3.tgz "https://github.com/pingdotgg/t3code/releases/download/v${T3_VERSION}/t3-${T3_VERSION}-linux-x64.tar.gz" \
  && echo "${T3_SHA256}  /tmp/t3.tgz" | sha256sum -c - \
  && mkdir -p /opt/t3 && tar xzf /tmp/t3.tgz -C /opt/t3 --strip-components=1 && rm /tmp/t3.tgz \
  && ln -s /opt/t3/t3 /usr/local/bin/t3 && t3 --version \
  && ln -s /usr/bin/fdfind /usr/local/bin/fd \
  # nginx `auto` sizes from the host's cores on Railway, not the container's limit.
  && sed -i 's/^worker_processes .*/worker_processes 2;/' /etc/nginx/nginx.conf \
  && rm -f /etc/nginx/sites-enabled/default \
  # Agents run as a normal user (Claude Code refuses its skip-permissions mode as root),
  # with passwordless sudo so they can still apt-get what a repo needs.
  && userdel -r ubuntu \
  && useradd -m -u 1000 -s /bin/bash t3 \
  && chown -R t3:t3 /opt/npm \
  && echo 't3 ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/t3 && chmod 440 /etc/sudoers.d/t3 \
  && echo 'export PATH="$HOME/.local/bin:/opt/npm/bin:$PATH"' > /etc/profile.d/local-bin.sh \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY railway-pair.mjs /opt/railway-pair.mjs
COPY entrypoint.sh /entrypoint.sh
COPY factory-loop.sh /opt/factory-loop.sh
COPY factory-waker.sh /opt/factory-waker.sh
COPY drop-file-cache /usr/local/bin/drop-file-cache

# `fo` talks to the Factory orchestrator from any shell on the box, for every user. The
# checkout it runs is the one the waker clones.
RUN printf '%s\n' '#!/bin/sh' 'exec node /home/t3/workspace/software-factory/orchestrator/bin/fo.mjs "$@"' \
      > /usr/local/bin/fo \
  && chmod 755 /usr/local/bin/fo

EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
