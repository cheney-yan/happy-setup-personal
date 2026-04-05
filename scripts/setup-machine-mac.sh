#!/bin/bash
# Happy CLI Machine Setup Script
# Sets up nvm, Node 24, builds happy-cli, and installs the daemon
# Safe to run multiple times (idempotent)

set -e

# Pass as env var or you'll be prompted: HAPPY_SERVER_URL=https://your-host.ts.net bash setup-machine-mac.sh
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
npm install -g yarn 2>/dev/null || true
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

# ── 6. Install launchd daemon ─────────────────────────────────────────────────
log "Step 6/6 — Installing daemon as launchd service..."

mkdir -p "$HAPPY_HOME/logs"

PLIST_PATH="$HOME/Library/LaunchAgents/com.local.happy-cli-daemon.plist"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.happy-cli-daemon</string>

    <key>ProgramArguments</key>
    <array>
        <string>$NODE_BIN</string>
        <string>$REPO_DIR/packages/happy-cli/bin/happy.mjs</string>
        <string>daemon</string>
        <string>start-sync</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HAPPY_SERVER_URL</key>
        <string>$HAPPY_SERVER_URL</string>
        <key>HAPPY_HOME_DIR</key>
        <string>$HAPPY_HOME</string>
    </dict>

    <key>StandardOutPath</key>
    <string>$HAPPY_HOME/logs/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$HAPPY_HOME/logs/launchd-stderr.log</string>
</dict>
</plist>
EOF

# Unload if already loaded
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

sleep 3

if launchctl list | grep -q "com.local.happy-cli-daemon"; then
    log "Daemon loaded successfully ✓"
else
    die "Daemon failed to load. Check: $HAPPY_HOME/logs/"
fi

echo ""
echo -e "${GREEN}✓ Setup complete!${NC}"
echo "  Server:  $HAPPY_SERVER_URL"
echo "  Data:    $HAPPY_HOME"
echo "  Logs:    $HAPPY_HOME/logs/"
echo ""
echo "  To check daemon: launchctl list | grep happy"
echo "  To run claude:   HAPPY_SERVER_URL=$HAPPY_SERVER_URL happy claude"
