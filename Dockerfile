FROM ubuntu:24.04

# Bump here. T3: version + sha256 of t3-<v>-linux-x64.tar.gz from the release's SHA256SUMS.
# `# upgrade:` lines tell dispatched.zaur.app where to look for newer releases.
# upgrade: github pingdotgg/t3code
ARG T3_VERSION=0.1.5
ARG T3_SHA256=21d50dcc9c634221b11b58d6a94350d2c6ee36905737b054b11fa4eba295a98b
# upgrade: npm @anthropic-ai/claude-code
ARG CLAUDE_CODE_VERSION=2.1.309
# upgrade: npm @openai/codex
ARG CODEX_VERSION=0.163.0
# OpenCode 2 (@opencode/cli); T3 gives OpenCode 1.x only limited support.
# upgrade: npm @opencode/cli
ARG OPENCODE_VERSION=2.1.3

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
  && apt-get update && apt-get install -y --no-install-recommends nodejs gh \
  && curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh \
  && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" "@openai/codex@${CODEX_VERSION}" \
       "@opencode/cli@${OPENCODE_VERSION}" \
  && npm cache clean --force && claude --version && codex --version && opencode --version \
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
COPY drop-file-cache /usr/local/bin/drop-file-cache

EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
