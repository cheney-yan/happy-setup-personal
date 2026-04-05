#!/bin/bash
# Happy CLI Machine Setup Script — Linux (systemd)
# Sets up fnm/nvm, Node 24, builds happy-cli, and installs the daemon.
# Idempotent: safe to re-run; skips steps already completed.

set -e

# Pass as env var or you'll be prompted:
#   HAPPY_SERVER_URL=https://your-host.ts.net bash setup-machine-linux.sh
HAPPY_SERVER_URL="${HAPPY_SERVER_URL:-}"
if [ -z "$HAPPY_SERVER_URL" ]; then
    read -rp "Enter your Happy Server URL (e.g. https://ms.yourtailnet.ts.net): " HAPPY_SERVER_URL
fi
NODE_VERSION="24"
REPO_DIR="$HOME/code/ai/happy"
HAPPY_HOME="$HOME/.happy"
SERVICE_PATH="$HOME/.config/systemd/user/happy-cli-daemon.service"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[setup]${NC} $1"; }
warn() { echo -e "${YELLOW}[setup]${NC} $1"; }
die()  { echo -e "${RED}[setup] ERROR:${NC} $1"; exit 1; }

# ── 0. Prereqs ────────────────────────────────────────────────────────────────
command -v curl >/dev/null 2>&1 || die "curl required: apt install curl"
command -v git  >/dev/null 2>&1 || die "git required: apt install git"

# ── 0b. Migration: detect old repo layout ────────────────────────────────────
# Old layout: $REPO_DIR was a direct clone of slopus/happy (no happy/ subdir).
# New layout: $REPO_DIR is the personal fork; slopus/happy lives in happy/.
if [ -d "$REPO_DIR/.git" ] && [ ! -d "$REPO_DIR/happy" ]; then
    warn "Detected old repo layout (pre-submodule restructure)."
    BACKUP_DIR="${REPO_DIR}.bak.$(date +%Y%m%d%H%M%S)"
    warn "Backing up old repo → $BACKUP_DIR"
    mv "$REPO_DIR" "$BACKUP_DIR"
    log "Backup complete. Will re-clone personal fork with submodule."
fi

# Migrate old service file path if it references the pre-submodule path
if [ -f "$SERVICE_PATH" ] && grep -q "$REPO_DIR/packages/happy-cli" "$SERVICE_PATH" 2>/dev/null; then
    warn "Detected old service path (pre-submodule). Will be updated in Step 6."
fi

# ── 1. Node version manager ───────────────────────────────────────────────────
log "Step 1/7 — Node version manager..."

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
log "Step 2/7 — Node $NODE_VERSION..."

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
        log "Created fnm alias 'ai' → $INSTALLED_VER"
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
log "Step 3/7 — Repo..."
if [ ! -d "$REPO_DIR/.git" ]; then
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone https://github.com/cheney-yan/happy-setup-personal.git "$REPO_DIR"
    git -C "$REPO_DIR" submodule update --init
else
    warn "Repo already exists, pulling latest..."
    git -C "$REPO_DIR" pull || warn "git pull failed (local changes?), continuing."
    git -C "$REPO_DIR" submodule update --init
fi
cd "$REPO_DIR/happy"

# ── 4. Install dependencies & build ──────────────────────────────────────────
log "Step 4/7 — Dependencies & build..."
corepack enable
yarn install
yarn workspace happy build

# ── 5. Auth ───────────────────────────────────────────────────────────────────
log "Step 5/7 — Authentication..."

do_auth_login() {
    echo ""
    echo "  Run this in a new terminal:"
    echo ""
    echo -e "  ${YELLOW}HAPPY_SERVER_URL=$HAPPY_SERVER_URL \\"
    echo "  HAPPY_HOME_DIR=$HAPPY_HOME \\"
    echo -e "  node $REPO_DIR/happy/packages/happy-cli/bin/happy.mjs auth login${NC}"
    echo ""
    echo "  In the Happy mobile app:"
    echo "    1. Settings → Server URL → $HAPPY_SERVER_URL"
    echo "    2. Scan the QR code with the in-app scanner (not system camera)"
    echo "    3. Choose 'Mobile'"
    echo ""
    read -rp "  Press ENTER once the QR code is scanned and the terminal shows success..."

    local status
    status=$(HAPPY_SERVER_URL=$HAPPY_SERVER_URL HAPPY_HOME_DIR=$HAPPY_HOME \
        "$NODE_BIN" "$REPO_DIR/happy/packages/happy-cli/bin/happy.mjs" auth status 2>&1 || true)
    echo "$status" | grep -q "Authenticated" || \
        die "Auth not complete. Re-run this script to retry from step 5."
}

AUTH_STATUS=$(HAPPY_SERVER_URL=$HAPPY_SERVER_URL HAPPY_HOME_DIR=$HAPPY_HOME \
    "$NODE_BIN" "$REPO_DIR/happy/packages/happy-cli/bin/happy.mjs" auth status 2>&1 || true)

NEEDS_AUTH=true
if echo "$AUTH_STATUS" | grep -q "Authenticated"; then
    echo ""
    echo "  Existing authentication found in $HAPPY_HOME."
    echo "  If the server database was reset, this token is stale and must be cleared."
    read -rp "  Clear local state and re-authenticate? (y/N): " RESET_AUTH
    if [ "$RESET_AUTH" = "y" ] || [ "$RESET_AUTH" = "Y" ]; then
        warn "Clearing local auth state: $HAPPY_HOME"
        rm -rf "$HAPPY_HOME"
        mkdir -p "$HAPPY_HOME/logs"
    else
        warn "Keeping existing auth."
        NEEDS_AUTH=false
    fi
fi

if [ "$NEEDS_AUTH" = "true" ]; then
    do_auth_login
fi
log "Auth verified ✓"

# ── 6. systemd user service ───────────────────────────────────────────────────
log "Step 6/7 — Installing daemon (systemd)..."
mkdir -p "$HAPPY_HOME/logs"
mkdir -p "$HOME/.config/systemd/user"

cat > "$SERVICE_PATH" <<SERVICE
[Unit]
Description=Happy CLI Daemon
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=$NODE_BIN $REPO_DIR/happy/packages/happy-cli/bin/happy.mjs daemon start-sync
Restart=on-failure
RestartSec=10
Environment=HAPPY_SERVER_URL=$HAPPY_SERVER_URL
Environment=HAPPY_HOME_DIR=$HAPPY_HOME
Environment=PATH=$HOME/.local/bin:$(dirname "$NODE_BIN"):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
StandardOutput=append:$HAPPY_HOME/logs/systemd-stdout.log
StandardError=append:$HAPPY_HOME/logs/systemd-stderr.log

[Install]
WantedBy=default.target
SERVICE

loginctl enable-linger "$USER" 2>/dev/null || warn "Could not enable linger — service may stop on logout."

systemctl --user daemon-reload
systemctl --user enable happy-cli-daemon
systemctl --user restart happy-cli-daemon
sleep 3

if systemctl --user is-active --quiet happy-cli-daemon; then
    log "Daemon running ✓"
else
    warn "Daemon may not be running. Check: systemctl --user status happy-cli-daemon"
fi

# ── 7. Shell environment ──────────────────────────────────────────────────────
log "Step 7/7 — Shell environment..."

if [ -n "$ZSH_VERSION" ] || [ "$(basename "$SHELL")" = "zsh" ]; then
    RC_FILE="$HOME/.zshrc"
else
    RC_FILE="$HOME/.bashrc"
fi

HAPPY_ENV_BLOCK="# Happy CLI
export HAPPY_SERVER_URL=\"$HAPPY_SERVER_URL\"
export HAPPY_HOME_DIR=\"$HAPPY_HOME\""

if grep -q "HAPPY_SERVER_URL" "$RC_FILE" 2>/dev/null; then
    warn "HAPPY_SERVER_URL already in $RC_FILE, skipping."
else
    echo "" >> "$RC_FILE"
    echo "$HAPPY_ENV_BLOCK" >> "$RC_FILE"
    log "Added Happy env vars to $RC_FILE"
fi

# Create happy wrapper script so 'happy' works from any shell
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/happy" <<WRAPPER
#!/bin/bash
exec "$NODE_BIN" "$REPO_DIR/happy/packages/happy-cli/bin/happy.mjs" "\$@"
WRAPPER
chmod +x "$HOME/.local/bin/happy"
log "Created happy wrapper at ~/.local/bin/happy"

# Add ~/.local/bin to PATH if not already there
if ! grep -q '\.local/bin' "$RC_FILE" 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$RC_FILE"
    log "Added ~/.local/bin to PATH in $RC_FILE"
else
    warn "~/.local/bin already in $RC_FILE, skipping."
fi

# Check that our wrapper wins in the current PATH
HAPPY_IN_PATH="$(command -v happy 2>/dev/null || true)"
if [ "$HAPPY_IN_PATH" != "$HOME/.local/bin/happy" ] && [ -n "$HAPPY_IN_PATH" ]; then
    echo ""
    warn "⚠️  A conflicting 'happy' binary was found at: $HAPPY_IN_PATH"
    warn "   This will shadow the local build until it is removed."
    warn "   Please uninstall it manually, for example:"
    warn "     npm uninstall -g happy"
    warn "     npm uninstall -g happy-coder"
    warn "   Then re-run this script to finish setup."
    exit 1
fi

echo ""
echo -e "${GREEN}✓ Setup complete!${NC}"
echo "  Server:  $HAPPY_SERVER_URL"
echo "  Data:    $HAPPY_HOME"
echo "  Logs:    $HAPPY_HOME/logs/"
echo "  Status:  systemctl --user status happy-cli-daemon"
echo "  Logs:    journalctl --user -u happy-cli-daemon -f"
echo ""
echo -e "  ${YELLOW}Important:${NC} Run 'happy claude' at least once to make this machine"
echo "  visible in the mobile app. It won't appear until a session is started."
echo ""
echo "  If you are still in this terminal session, run:"
echo -e "    ${YELLOW}source $RC_FILE && happy claude${NC}"
