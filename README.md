# happy-setup-personal

Personal self-hosted setup for [Happy](https://github.com/slopus/happy) — a mobile/web client for Claude Code and Codex with end-to-end encryption.

Upstream Happy code lives in the `happy/` submodule. Personal configuration, provisioning scripts, and daemon setup live at the repo root.

## What is Happy?

Happy lets you run `happy claude` on your desktop and control it from your phone. It wraps Claude Code/Codex so you get push notifications and can switch between devices instantly. All session content is end-to-end encrypted.

## Setup

### Step 1 — Set up the server (once, on your main machine)

The server relays encrypted messages between your machines and the mobile app. It needs to be reachable over HTTPS — this setup uses Tailscale for that.

**Prerequisites:**
- [Tailscale](https://tailscale.com/download) installed and logged in
- MagicDNS enabled in the Tailscale admin console (required for iOS App Transport Security)

```bash
# macOS
bash <(curl -fsSL https://raw.githubusercontent.com/cheney-yan/happy-setup-personal/main/scripts/setup-server-mac.sh)

# Linux
bash <(curl -fsSL https://raw.githubusercontent.com/cheney-yan/happy-setup-personal/main/scripts/setup-server-linux.sh)
```

The script handles everything: Node 24, dependencies, `.env.dev` with a generated secret, launchd/systemd daemon, Tailscale Serve HTTPS, and auth login via the mobile app.

At the end it prints the command to connect additional machines.

### Step 2 — Connect additional machines

Run this on each machine you want to use Happy from:

```bash
# macOS
HAPPY_SERVER_URL=https://<your-server>.ts.net \
  bash <(curl -fsSL https://raw.githubusercontent.com/cheney-yan/happy-setup-personal/main/scripts/setup-machine-mac.sh)

# Linux
HAPPY_SERVER_URL=https://<your-server>.ts.net \
  bash <(curl -fsSL https://raw.githubusercontent.com/cheney-yan/happy-setup-personal/main/scripts/setup-machine-linux.sh)
```

### Step 3 — Use Happy

After setup, use `happy claude` or `happy codex` instead of `claude` or `codex`:

```bash
happy claude    # Claude Code via Happy
happy codex     # Codex via Happy
```

Control sessions from the mobile app ([iOS](https://apps.apple.com/us/app/happy-claude-code-client/id6748571505) / [Android](https://play.google.com/store/apps/details?id=com.ex3ndr.happy)).

---

## For Claude Code users

Open this repo in Claude Code — `CLAUDE.md` has the full picture: architecture, debugging, auth flow, environment variables, and how to fix things when they break.

```bash
cd ~/code/ai/happy
claude   # or: happy claude
```

Claude Code can re-run any setup step, diagnose daemon issues, and update configurations.
