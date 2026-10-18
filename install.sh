#!/usr/bin/env bash
set -euo pipefail

# Conver Terminal Installer for macOS & Linux
REPO="${CONVER_REPO:-kushagrmishra/conver}"
RELEASE_BASE="https://github.com/${REPO}/releases/latest/download"
OS="$(uname -s)"

echo "=========================================="
echo "  ⚡ Conver Installer (${OS})"
echo "=========================================="

case "$OS" in
  Darwin*)
    TMP_DMG="/tmp/Conver.dmg"
    MOUNT_DIR="/Volumes/Conver"
    echo "==> Downloading Conver.dmg for macOS..."
    curl -fL "${RELEASE_BASE}/Conver.dmg" -o "$TMP_DMG"

    echo "==> Mounting disk image..."
    hdiutil attach "$TMP_DMG" -nobrowse -quiet -mountpoint "$MOUNT_DIR"

    echo "==> Installing Conver.app to /Applications..."
    rm -rf "/Applications/Conver.app"
    cp -R "$MOUNT_DIR/Conver.app" "/Applications/Conver.app"
    xattr -cr "/Applications/Conver.app" 2>/dev/null || true

    echo "==> Cleaning up..."
    hdiutil detach "$MOUNT_DIR" -quiet || true
    rm -f "$TMP_DMG"

    echo "==> Launching Conver..."
    open "/Applications/Conver.app"
    echo "✅ Conver is installed! Press Shift + Z anytime to open the Drop Wheel."
    ;;

  Linux*)
    INSTALL_DIR="${HOME}/.local/bin"
    APP_PATH="${INSTALL_DIR}/conver"
    mkdir -p "$INSTALL_DIR"

    echo "==> Downloading Conver.AppImage for Linux..."
    curl -fL "${RELEASE_BASE}/Conver.AppImage" -o "$APP_PATH"
    chmod +x "$APP_PATH"

    echo "==> Launching Conver..."
    nohup "$APP_PATH" >/dev/null 2>&1 &
    echo "✅ Conver installed to ${APP_PATH}! Press Shift + Z anytime to open the Drop Wheel."
    ;;

  *)
    echo "Unsupported OS: ${OS}. For Windows, run install.ps1 in PowerShell."
    exit 1
    ;;
esac
