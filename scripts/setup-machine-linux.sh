#!/bin/bash
# Happy CLI Machine Setup Script — Linux (systemd)
# Sets up nvm, Node 24, builds happy-cli, and installs the daemon
# Safe to run multiple times (idempotent)

set -e

# Pass as env var or you'll be prompted: HAPPY_SERVER_URL=https://your-host.ts.net bash setup-machine-linux.sh
HAPPY_SERVER_URL="${HAPPY_SERVER_URL:-}"
if [ -z "$HAPPY_SERVER_URL" ]; then
    read -rp "Enter your Happy Server URL (e.g. https://ms.yourtailnet.ts.net): " HAPPY_SERVER_URL
fi
NODE_VERSION="24"
REPO_DIR="$HOME/code/ai/happy"
HAPPY_HOME="$HOME/.happy"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[setup]${NC} $1"; }
warn() { echo -e "${YELLOW}[setup]${NC} $1"; }
die()  { echo -e "${RED}[setup] ERROR:${NC} $1"; exit 1; }

# ── 0. Prereqs ────────────────────────────────────────────────────────────────
command -v curl >/dev/null 2>&1 || die "curl is required. Install with: apt install curl / yum install curl"
command -v git  >/dev/null 2>&1 || die "git is required. Install with: apt install git / yum install git"

# ── 1. Node version manager (fnm preferred, fallback to nvm) ──────────────────
log "Step 1/6 — Setting up Node version manager..."

# Load fnm if available
export FNM_DIR="${FNM_DIR:-$HOME/.local/share/fnm}"
if command -v fnm >/dev/null 2>&1; then
    warn "fnm already available, using it."
    USE_FNM=true
elif [ -d "$FNM_DIR" ]; then
    export PATH="$FNM_DIR:$PATH"
    eval "$(fnm env 2>/dev/null)" 2>/dev/null || true
    command -v fnm >/dev/null 2>&1 && USE_FNM=true
fi

if [ "${USE_FNM:-false}" = "true" ]; then
    log "Using fnm"
else
    # Load nvm if available, else install it
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
    if ! command -v nvm >/dev/null 2>&1; then
        log "Installing nvm..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
        [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
    else
        warn "nvm already installed, using it."
    fi
    command -v nvm >/dev/null 2>&1 || die "Neither fnm nor nvm could be loaded."
    USE_FNM=false
fi

# ── 2. Node 24 ────────────────────────────────────────────────────────────────
log "Step 2/6 — Installing Node $NODE_VERSION..."
if [ "$USE_FNM" = "true" ]; then
    fnm install $NODE_VERSION
    fnm use $NODE_VERSION
    NODE_BIN="$(fnm which)"
else
    nvm install $NODE_VERSION
    nvm use $NODE_VERSION
    NODE_BIN="$(nvm which $NODE_VERSION)"
fi

log "Node binary: $NODE_BIN ($(node --version))"

# ── 3. Clone / update repo ────────────────────────────────────────────────────
log "Step 3/6 — Cloning happy repo..."
if [ ! -d "$REPO_DIR/.git" ]; then
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone https://github.com/slopus/happy.git "$REPO_DIR"
else
    warn "Repo already exists, pulling latest..."
    git -C "$REPO_DIR" pull
fi

cd "$REPO_DIR"

# ── 4. Install dependencies & build ──────────────────────────────────────────
log "Step 4/6 — Installing dependencies..."
corepack enable
yarn install

log "Building happy-cli..."
yarn workspace happy build

# ── 5. Auth (interactive) ─────────────────────────────────────────────────────
log "Step 5/6 — Authentication"
echo ""
echo "  Run the following command, choose 'Mobile', and scan the QR"
echo "  code with your Happy App (make sure App uses server: $HAPPY_SERVER_URL)"
echo ""
echo -e "  ${YELLOW}HAPPY_SERVER_URL=$HAPPY_SERVER_URL \\"
echo "  HAPPY_HOME_DIR=$HAPPY_HOME \\"
echo -e "  node $REPO_DIR/packages/happy-cli/bin/happy.mjs auth login${NC}"
echo ""
read -rp "Press ENTER once auth is complete..."

# Verify auth succeeded
AUTH_STATUS=$(HAPPY_SERVER_URL=$HAPPY_SERVER_URL HAPPY_HOME_DIR=$HAPPY_HOME \
    node "$REPO_DIR/packages/happy-cli/bin/happy.mjs" auth status 2>&1)
if echo "$AUTH_STATUS" | grep -q "✓ Authenticated"; then
    log "Auth verified ✓"
else
    die "Auth not complete. Please run 'auth login' first, then re-run this script."
fi

# ── 6. Install systemd user service ──────────────────────────────────────────
log "Step 6/6 — Installing daemon as systemd user service..."

mkdir -p "$HAPPY_HOME/logs"
mkdir -p "$HOME/.config/systemd/user"

SERVICE_PATH="$HOME/.config/systemd/user/happy-cli-daemon.service"

cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Happy CLI Daemon
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=$NODE_BIN $REPO_DIR/packages/happy-cli/bin/happy.mjs daemon start-sync
Restart=on-failure
RestartSec=10
Environment=HAPPY_SERVER_URL=$HAPPY_SERVER_URL
Environment=HAPPY_HOME_DIR=$HAPPY_HOME
StandardOutput=append:$HAPPY_HOME/logs/systemd-stdout.log
StandardError=append:$HAPPY_HOME/logs/systemd-stderr.log

[Install]
WantedBy=default.target
EOF

# Enable lingering so service starts without login (run as user, survives logout)
loginctl enable-linger "$USER" 2>/dev/null || warn "Could not enable linger (may need sudo). Service will only run while logged in."

systemctl --user daemon-reload
systemctl --user enable happy-cli-daemon
systemctl --user restart happy-cli-daemon

sleep 3

if systemctl --user is-active --quiet happy-cli-daemon; then
    log "Daemon running ✓"
else
    warn "Daemon may not be running. Check: systemctl --user status happy-cli-daemon"
fi

echo ""
echo -e "${GREEN}✓ Setup complete!${NC}"
echo "  Server:  $HAPPY_SERVER_URL"
echo "  Data:    $HAPPY_HOME"
echo "  Logs:    $HAPPY_HOME/logs/"
echo ""
echo "  Status:  systemctl --user status happy-cli-daemon"
echo "  Logs:    journalctl --user -u happy-cli-daemon -f"
echo "  To run:  HAPPY_SERVER_URL=$HAPPY_SERVER_URL happy claude"
