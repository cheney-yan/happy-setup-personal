#!/bin/bash
# Happy Server Setup Script — Linux (systemd)
# Sets up Node 24, builds happy-server, installs daemon, configures Tailscale HTTPS, and runs auth.
# Idempotent: safe to re-run; skips steps already completed.
#
# Run:
#   bash <(curl -fsSL https://raw.githubusercontent.com/cheney-yan/happy-setup-personal/main/scripts/setup-server-linux.sh)

set -e

NODE_VERSION="24"
REPO_DIR="$HOME/code/ai/happy"
SERVER_DIR="$REPO_DIR/happy/packages/happy-server"
SERVICE_PATH="$HOME/.config/systemd/user/happy-server.service"
HAPPY_HOME="$HOME/.happy"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[setup]${NC} $1"; }
warn() { echo -e "${YELLOW}[setup]${NC} $1"; }
die()  { echo -e "${RED}[setup] ERROR:${NC} $1"; exit 1; }

# ── 0. Prereqs ────────────────────────────────────────────────────────────────
command -v curl >/dev/null 2>&1 || die "curl required: apt install curl"
command -v git  >/dev/null 2>&1 || die "git required: apt install git"
if ! command -v tailscale >/dev/null 2>&1; then
    warn "Tailscale CLI not found. Install it from https://tailscale.com/download"
    warn "After installing, run: sudo tailscale up && tailscale set --accept-dns=true"
    warn "Continuing without Tailscale — you will need to configure HTTPS manually."
    SKIP_TAILSCALE=true
fi

# ── 0b. Migration: detect old repo layout ────────────────────────────────────
if [ -d "$REPO_DIR/.git" ] && [ ! -d "$REPO_DIR/happy" ]; then
    warn "Detected old repo layout (pre-submodule restructure)."
    BACKUP_DIR="${REPO_DIR}.bak.$(date +%Y%m%d%H%M%S)"
    warn "Backing up old repo → $BACKUP_DIR"
    mv "$REPO_DIR" "$BACKUP_DIR"
    log "Backup complete. Will re-clone personal fork with submodule."
fi

# ── 1. Node version manager ───────────────────────────────────────────────────
log "Step 1/9 — Node version manager..."

USE_FNM=false
for fnm_bin in \
    "$(command -v fnm 2>/dev/null)" \
    "$HOME/.local/share/fnm/fnm"
do
    if [ -x "$fnm_bin" ]; then
        eval "$("$fnm_bin" env --shell bash 2>/dev/null)" 2>/dev/null || true
        USE_FNM=true
        log "Using fnm ($fnm_bin)"
        break
    fi
done

if [ "$USE_FNM" = "false" ]; then
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
    if ! command -v nvm >/dev/null 2>&1; then
        log "Installing nvm..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
        [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
    else
        warn "nvm already installed."
    fi
    command -v nvm >/dev/null 2>&1 || die "Neither fnm nor nvm could be loaded."
fi

# ── 2. Node 24 + stable binary path ──────────────────────────────────────────
log "Step 2/9 — Node $NODE_VERSION..."

if [ "$USE_FNM" = "true" ]; then
    fnm install $NODE_VERSION
    fnm use $NODE_VERSION
    INSTALLED_VER="$(fnm current 2>/dev/null | tr -d '[:space:]')"
    NODE_BIN=""
    for fnm_data in "$HOME/.local/share/fnm" "${FNM_DIR:-}"; do
        candidate="$fnm_data/node-versions/$INSTALLED_VER/installation/bin/node"
        if [ -x "$candidate" ]; then
            NODE_BIN="$candidate"
            FNM_DATA_DIR="$fnm_data"
            break
        fi
    done
    [ -n "$NODE_BIN" ] || die "Could not find fnm node binary for $INSTALLED_VER."

    FNM_ALIAS="$FNM_DATA_DIR/aliases/ai"
    if [ ! -e "$FNM_ALIAS" ]; then
        fnm alias ai "$INSTALLED_VER" 2>/dev/null || \
        fnm alias "$INSTALLED_VER" ai 2>/dev/null || \
        warn "Could not create fnm alias 'ai' — continuing."
    else
        warn "fnm alias 'ai' already exists, skipping."
    fi
else
    nvm install $NODE_VERSION
    ACTUAL_VER="$(nvm version $NODE_VERSION)"
    FAKE_VER="v1.1.1"
    if [ ! -d "$NVM_DIR/versions/node/$FAKE_VER" ]; then
        log "Copying $ACTUAL_VER → $FAKE_VER (isolation layer)..."
        cp -r "$NVM_DIR/versions/node/$ACTUAL_VER" "$NVM_DIR/versions/node/$FAKE_VER"
    else
        warn "Isolated env $FAKE_VER already exists, skipping copy."
    fi
    nvm use $FAKE_VER
    nvm alias ai $FAKE_VER 2>/dev/null || warn "nvm alias 'ai' already set."
    NODE_BIN="$(nvm which $FAKE_VER)"
fi

[ -x "$NODE_BIN" ] || die "Node binary not executable: $NODE_BIN"
log "Node binary: $NODE_BIN ($("$NODE_BIN" --version))"

# ── 3. Clone / update repo ────────────────────────────────────────────────────
log "Step 3/9 — Repo..."
if [ ! -d "$REPO_DIR/.git" ]; then
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone https://github.com/cheney-yan/happy-setup-personal.git "$REPO_DIR"
    git -C "$REPO_DIR" submodule update --init
else
    warn "Repo already exists, pulling latest..."
    git -C "$REPO_DIR" pull || warn "git pull failed (local changes?), continuing."
    git -C "$REPO_DIR" submodule update --init
fi

# ── 4. Install dependencies ───────────────────────────────────────────────────
log "Step 4/9 — Dependencies..."
cd "$REPO_DIR/happy"
corepack enable
yarn install

# ── 5. Server .env.dev ────────────────────────────────────────────────────────
log "Step 5/9 — Server environment..."
ENV_FILE="$SERVER_DIR/.env.dev"
if [ -f "$ENV_FILE" ]; then
    warn ".env.dev already exists, skipping generation."
else
    SECRET=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48)
    cat > "$ENV_FILE" <<ENV
HANDY_MASTER_SECRET=$SECRET
PORT=3005
DB_PROVIDER=pglite
DANGEROUSLY_LOG_TO_SERVER_FOR_AI_AUTO_DEBUGGING=true
ENV
    log "Created .env.dev with generated secret."
fi
SERVER_PORT=$(grep '^PORT=' "$ENV_FILE" | cut -d= -f2 | tr -d '[:space:]')
SERVER_PORT="${SERVER_PORT:-3005}"
log "Server port: $SERVER_PORT"

# ── 6. systemd user service ───────────────────────────────────────────────────
log "Step 6/9 — Installing daemon (systemd)..."
mkdir -p "$HOME/.config/systemd/user"
mkdir -p "$SERVER_DIR/.logs"
TSX_BIN="$REPO_DIR/happy/node_modules/tsx/dist/cli.mjs"

cat > "$SERVICE_PATH" <<SERVICE
[Unit]
Description=Happy Server
After=network.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=$SERVER_DIR
ExecStartPre=$NODE_BIN $TSX_BIN --env-file=.env.dev ./sources/standalone.ts migrate
ExecStart=$NODE_BIN $TSX_BIN --env-file=.env.dev ./sources/standalone.ts serve
Restart=on-failure
RestartSec=10
StandardOutput=append:$SERVER_DIR/.logs/systemd-stdout.log
StandardError=append:$SERVER_DIR/.logs/systemd-stderr.log

[Install]
WantedBy=default.target
SERVICE

loginctl enable-linger "$USER" 2>/dev/null || warn "Could not enable linger — service may stop on logout."

systemctl --user daemon-reload
systemctl --user enable happy-server
systemctl --user restart happy-server

log "Waiting for server to start..."
for i in $(seq 1 20); do
    if curl -sf http://localhost:$SERVER_PORT/health >/dev/null 2>&1; then
        log "Server is up ✓"
        break
    fi
    sleep 1
    [ "$i" = "20" ] && die "Server did not start. Check logs: $SERVER_DIR/.logs/"
done

# ── 7. Tailscale HTTPS ────────────────────────────────────────────────────────
log "Step 7/9 — Tailscale HTTPS..."
if [ "${SKIP_TAILSCALE:-false}" = "true" ]; then
    warn "Tailscale not installed — skipping. Set HAPPY_SERVER_URL manually."
    HAPPY_SERVER_URL=""
    read -rp "Enter server URL (or leave blank to set later): " HAPPY_SERVER_URL
else
    echo ""
    echo -e "${YELLOW}  WARNING: 'tailscale serve --bg' OVERWRITES any existing Tailscale Serve config.${NC}"
    echo ""
    EXISTING=$(tailscale serve status 2>/dev/null || echo "")
    if [ -n "$EXISTING" ]; then
        echo "  Current Tailscale Serve config:"
        echo "$EXISTING" | sed 's/^/    /'
        echo ""
        if echo "$EXISTING" | grep -q "http://localhost:$SERVER_PORT\|http://127.0.0.1:$SERVER_PORT"; then
            warn "Port $SERVER_PORT already configured — skipping Tailscale Serve setup."
        else
            read -rp "  Existing config found. Add happy-server alongside it? (y/N): " CONFIRM
            [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] || die "Aborted. Configure Tailscale manually."
            tailscale serve --bg http://localhost:$SERVER_PORT
        fi
    else
        tailscale serve --bg http://localhost:$SERVER_PORT
        log "Tailscale Serve configured."
    fi

    HAPPY_SERVER_URL=$(tailscale serve status 2>/dev/null | grep -Eo 'https://[^[:space:]]+' | head -1 | sed 's|/$||')
    if [ -z "$HAPPY_SERVER_URL" ]; then
        HAPPY_SERVER_URL=$(tailscale status --json 2>/dev/null | \
            python3 -c "import json,sys; d=json.load(sys.stdin); print('https://'+d.get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || echo "")
    fi
    [ -n "$HAPPY_SERVER_URL" ] || die "Could not detect Tailscale HTTPS URL. Check: tailscale serve status"
    log "Server URL: $HAPPY_SERVER_URL"
fi

# ── 8. Auth login ─────────────────────────────────────────────────────────────
log "Step 8/9 — Authentication..."
if [ -z "$HAPPY_SERVER_URL" ]; then
    warn "No server URL — skipping auth. Run auth login manually once URL is known."
else
    AUTH_STATUS=$(HAPPY_SERVER_URL=$HAPPY_SERVER_URL HAPPY_HOME_DIR=$HAPPY_HOME \
        "$NODE_BIN" "$REPO_DIR/happy/packages/happy-cli/bin/happy.mjs" auth status 2>&1 || true)

    if echo "$AUTH_STATUS" | grep -q "Authenticated"; then
        warn "Already authenticated, skipping auth login."
    else
        echo ""
        echo "  Open a new terminal and run:"
        echo ""
        echo -e "  ${YELLOW}HAPPY_SERVER_URL=$HAPPY_SERVER_URL \\"
        echo "  HAPPY_HOME_DIR=$HAPPY_HOME \\"
        echo -e "  node $REPO_DIR/happy/packages/happy-cli/bin/happy.mjs auth login${NC}"
        echo ""
        echo "  In the Happy mobile app:"
        echo "    1. Settings → set Server URL to: $HAPPY_SERVER_URL"
        echo "    2. Use the in-app QR scanner (not system camera)"
        echo "    3. Choose 'Mobile' mode"
        echo ""
        read -rp "Press ENTER once auth is complete..."

        AUTH_STATUS=$(HAPPY_SERVER_URL=$HAPPY_SERVER_URL HAPPY_HOME_DIR=$HAPPY_HOME \
            "$NODE_BIN" "$REPO_DIR/happy/packages/happy-cli/bin/happy.mjs" auth status 2>&1 || true)
        echo "$AUTH_STATUS" | grep -q "Authenticated" || \
            die "Auth not complete. Re-run this script to retry from step 8."
    fi
    log "Auth verified ✓"
fi

# ── 9. Shell environment ──────────────────────────────────────────────────────
log "Step 9/9 — Shell environment..."
if [ -n "$ZSH_VERSION" ] || [ "$(basename "$SHELL")" = "zsh" ]; then
    RC_FILE="$HOME/.zshrc"
else
    RC_FILE="$HOME/.bashrc"
fi

if [ -n "$HAPPY_SERVER_URL" ]; then
    HAPPY_ENV_BLOCK="# Happy
export HAPPY_SERVER_URL=\"$HAPPY_SERVER_URL\"
export HAPPY_HOME_DIR=\"$HAPPY_HOME\""

    if grep -q "HAPPY_SERVER_URL" "$RC_FILE" 2>/dev/null; then
        warn "HAPPY_SERVER_URL already in $RC_FILE, skipping."
    else
        echo "" >> "$RC_FILE"
        echo "$HAPPY_ENV_BLOCK" >> "$RC_FILE"
        log "Added Happy env vars to $RC_FILE"
    fi
fi

echo ""
echo -e "${GREEN}✓ Server setup complete!${NC}"
[ -n "$HAPPY_SERVER_URL" ] && echo "  Server URL:  $HAPPY_SERVER_URL"
echo "  Logs:        $SERVER_DIR/.logs/"
echo "  Status:      systemctl --user status happy-server"
echo "  Logs live:   journalctl --user -u happy-server -f"
echo ""
if [ -n "$HAPPY_SERVER_URL" ]; then
    echo "  To connect another machine, run on that machine:"
    echo ""
    echo -e "  ${YELLOW}HAPPY_SERVER_URL=$HAPPY_SERVER_URL \\"
    echo -e "  bash <(curl -fsSL https://raw.githubusercontent.com/cheney-yan/happy-setup-personal/main/scripts/setup-machine-linux.sh)${NC}"
    echo ""
fi
echo "  Reload your shell: source $RC_FILE"
