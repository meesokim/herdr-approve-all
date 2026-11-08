#!/usr/bin/env bash
# All-in-one setup script for Linux/macOS (mirrors herdr-approve-all-setup.exe on Windows).
# Internally detects OS, ensures Herdr is installed, copies/links local plugin source
# without requiring remote git clone, and enables unified auto-on mode.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ID="renkoya1.approve-all"
SKIP_HERDR_UPDATE=0
for arg in "$@"; do
  if [ "$arg" = "--skip-herdr-update" ]; then
    SKIP_HERDR_UPDATE=1
  fi
done

export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:$PATH"

echo "================================================================"
echo " Herdr + herdr-approve-all All-in-One Setup (Linux/macOS)"
echo "================================================================"

if ! command -v herdr >/dev/null 2>&1; then
  echo "[1/4] Herdr not found. Installing latest Herdr..."
  curl -fsSL https://herdr.dev/install.sh | sh
else
  HERDR_BIN="$(command -v herdr)"
  echo "[1/4] Existing Herdr found: $HERDR_BIN"
  if [ "$SKIP_HERDR_UPDATE" -eq 0 ]; then
    herdr update >/dev/null 2>&1 || true
  fi
fi

HERDR_BIN="$(command -v herdr)"
echo "[OK] Herdr binary: $HERDR_BIN"

echo "[2/4] Copying packaged plugin files to local plugin directory..."
TARGET_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/herdr/plugins-local/$PLUGIN_ID"
mkdir -p "$TARGET_DIR/scripts"
cp -f "$REPO_DIR/herdr-plugin.toml" "$TARGET_DIR/herdr-plugin.toml"
cp -f "$REPO_DIR/README.md" "$TARGET_DIR/README.md"
cp -f "$REPO_DIR/scripts/dispatch" "$TARGET_DIR/scripts/dispatch"
cp -f "$REPO_DIR/scripts/dispatch.cmd" "$TARGET_DIR/scripts/dispatch.cmd"
cp -f "$REPO_DIR/scripts/lib.sh" "$TARGET_DIR/scripts/lib.sh"
cp -f "$REPO_DIR/scripts/approve-blocked.sh" "$TARGET_DIR/scripts/approve-blocked.sh"
cp -f "$REPO_DIR/scripts/auto-toggle.sh" "$TARGET_DIR/scripts/auto-toggle.sh"
cp -f "$REPO_DIR/scripts/on-status-changed.sh" "$TARGET_DIR/scripts/on-status-changed.sh"
cp -f "$REPO_DIR/scripts/approve-windows.ps1" "$TARGET_DIR/scripts/approve-windows.ps1"
chmod +x "$TARGET_DIR/scripts/dispatch" "$TARGET_DIR/scripts/approve-blocked.sh" "$TARGET_DIR/scripts/auto-toggle.sh" "$TARGET_DIR/scripts/on-status-changed.sh"
echo "[OK] Local plugin directory prepared: $TARGET_DIR"

echo "[3/4] Registering local directory as Herdr plugin ($PLUGIN_ID)..."
herdr plugin uninstall "$PLUGIN_ID" >/dev/null 2>&1 || herdr plugin unlink "$PLUGIN_ID" >/dev/null 2>&1 || true
herdr plugin link "$TARGET_DIR"
herdr plugin enable "$PLUGIN_ID"

echo "[4/4] Turning ON auto-on and starting background monitor..."
herdr plugin action invoke "$PLUGIN_ID.auto-on"
sleep 0.5
echo "================================================================"
echo " Setup Completed Successfully! (auto-on is ACTIVE)"
echo "================================================================"
