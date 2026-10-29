# Deploy and Host T3 Code on Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template/t3-code-cloud?referralCode=sLjDXb&utm_medium=integration&utm_source=button&utm_campaign=t3-code-cloud)

[T3 Code](https://github.com/pingdotgg/t3code) is the open-source "agent harness control surface": a server that runs coding agents (Claude Code, Codex, OpenCode and more) on a machine, and web, desktop and mobile apps that drive them from anywhere. This template makes that machine a Railway service: an always-on cloud agent box with Claude Code, Codex and OpenCode preinstalled, so your agents keep working with the laptop closed and you check in from your phone.

## About Hosting T3 Code

One service, one volume. The pinned `t3` server (v0.1.5, checksum-verified at build) runs behind nginx on your Railway domain. It serves the T3 web app and the API that the [iOS](https://apps.apple.com/us/app/t3-code-remote-claude-more/id6787819824) and [Android](https://play.google.com/store/apps/details?id=com.t3tools.t3code) apps, the desktop app and [app.t3.codes](https://app.t3.codes) connect to.

- **Locked by default, with T3's own auth.** Every API call, WebSocket and terminal needs a T3 session, and a device only gets one by pairing with a one-time link. Nothing is open to whoever finds the URL. The mobile apps, the desktop app and app.t3.codes connect through this same lock. A basic-auth gateway in front would have blocked them.
- **A pairing page instead of digging through logs.** Open `https://<your-domain>/railway-pair` and sign in with the generated `T3_SETUP_PASSWORD`. The page mints a one-time pairing link that lasts 15 minutes, with a QR code for the phone app. The one-time admin token `t3 serve` prints at boot is redacted from the logs.
- **T3 Code 0.1 (Orchestrator V2), the first stable release.** Agents can hand work to child agents on any provider (`delegate_task`: Claude plans, Codex implements), fork threads, and queue messages on the server. Interrupted threads continue after a redeploy.
- **Agents preinstalled and pinned:** Claude Code 2.1.309, Codex 0.163.0 and OpenCode 2.1.3, next to `git`, `gh`, Node 22, Python 3 + `uv`, `build-essential`, `ripgrep`, `jq` and `tmux`.
- **A normal user with sudo.** Agents run as user `t3`, so Claude Code's full-access mode works (it refuses that mode as root). Passwordless `sudo` is there for `apt-get`.
- **Everything persists.** `/home/t3` is the volume: agent logins (`~/.claude`, `~/.codex`), T3 state and threads (`~/.t3`), repos in `~/workspace`, dotfiles.

## Common Use Cases

- Start a long Claude Code or Codex task, close the laptop, and review the diff from your phone
- One persistent cloud workspace that your phone, iPad, laptop and the T3 desktop app all drive
- Use your Claude or ChatGPT subscription from devices where you can't install the CLIs
- Run several agents in parallel in worktrees, on a box sized for it
- Combine harnesses: have Claude plan and hand the implementation to Codex or a free OpenCode model

## Dependencies for T3 Code Hosting

- None. Single service, no database. You bring an agent login: a Claude or ChatGPT subscription, an API key, or OpenCode's free models.

### Deployment Dependencies

- [T3 Code](https://github.com/pingdotgg/t3code) (MIT) and its [remote access docs](https://github.com/pingdotgg/t3code/blob/main/docs/user/remote-access.md)
- [Claude Code](https://claude.com/product/claude-code), [Codex CLI](https://developers.openai.com/codex/cli), [OpenCode](https://opencode.ai)
- [GitHub CLI](https://cli.github.com/)

### Implementation Details

**1. Pair your first device.** Copy `T3_SETUP_PASSWORD` from the service's Variables tab, open `https://<your-domain>/railway-pair` (any username, that password), and click **Pair this browser**. Each reload of the page gives a fresh link, and each link works for one device:

- **Phone:** in the T3 Code app go to Settings → Environments → Add, then scan the QR code.
- **Desktop app or app.t3.codes:** go to Settings → Connections → Add environment and paste the link.

Paired devices stay paired across redeploys. The phone and desktop apps must be T3 Code 2.0 / 0.1 or newer; older apps refuse to connect to this server. You can see and revoke them in the T3 terminal with `t3 auth session list` and `t3 auth session revoke <id>`.

**2. Log an agent in.** Open a terminal in T3 (the terminal button above the composer). It runs on the box as `t3`.

- **Claude:** run `claude auth login`, open the URL it prints, then paste the code back. Or set `ANTHROPIC_API_KEY`, or `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`. Leave both empty if you use the subscription login.
- **Codex:** choose **Continue with ChatGPT** in T3's onboarding or in Settings → Providers. You can also run `codex login --device-auth` in the terminal. `OPENAI_API_KEY` logs Codex in with a key on first boot. To change that key later, run `codex logout` and redeploy.
- **OpenCode (free models, no key):** in Settings → Providers, choose **Add provider** → OpenCode, then pick a model marked Free. Once you use it, T3 keeps an `opencode serve` process running, which adds about 375 MB of RAM.

**3. Add a project.** Use **Add project** → Git URL to clone a repo, or Local folder → `~/workspace/<dir>`. Set `GH_TOKEN` and private clones, `git push` and `gh pr create` work without a login (the box runs `gh auth setup-git` at boot). Set your commit identity once with `git config --global user.name/user.email`.

**Upgrading:** the T3, Claude Code, Codex and OpenCode versions are pinned in the Dockerfile, so every deploy is the tested build. Redeploying picks up bumps from this repo. T3's in-app **Update** button for Claude and Codex works, but a redeploy resets them to the pinned versions. Your data on the volume is never touched.

**Upgrading a deploy from T3 0.0.x:** redeploy the service. On first boot T3 0.1 copies your threads into its new database (one-way; the old copy stays on the volume) and OpenCode 2 converts OpenCode's database. Devices paired under 0.0.x keep their session but with the old, narrower permissions, so open `/railway-pair` and pair them again.

Notes and limits:

- **RAM:** about 300 MB idle on Railway (the T3 server, the pairing page and nginx). OpenCode's `opencode serve` adds about 375 MB once you use it, and every running agent session adds roughly 0.3 to 1 GB (a single OpenCode task peaked at about 1.7 GB in our test). Builds and tests need more. Use the Hobby plan or higher; the Trial plan's 512 MB will not run an agent.
- The image is about 2.7 GB, so the first build takes a few minutes.
- **T3 Code moves fast.** It went stable at v0.1.0, but expect breaking changes between versions.
- **This server runs arbitrary commands.** Agents and the T3 terminal have a shell with passwordless sudo on this box. The T3 pairing lock and `T3_SETUP_PASSWORD` are all that protect it: keep the password secret and treat pairing links like passwords.
- Anything installed outside `/home/t3` is lost on redeploy. Put tools in `~/.local/bin`.
- There is no Docker daemon in the box. T3's in-app browser tabs need `sudo t3 browser setup` first; this template does not test them.

## Why Deploy T3 Code on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will host your infrastructure so you don't have to deal with configuration, while allowing you to vertically and horizontally scale it.

By deploying T3 Code on Railway, you are one step closer to supporting a complete full-stack application with minimal burden. Host your servers, databases, AI agents, and more on Railway.
