#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-auto}"

if [[ "$TARGET" == "auto" ]]; then
  case "$(uname -s)" in
    Darwin*) TARGET="mac" ;;
    Linux*)  TARGET="linux" ;;
    *)       TARGET="win" ;;
  esac
fi

case "$TARGET" in
  mac|macos)
    echo "==> Building Native macOS App & DMG (ConverMac)..."
    cd "$ROOT_DIR/ConverMac"
    chmod +x package.sh
    ./package.sh
    echo "==> Done! Output: ConverMac/dist/Conver.app & ConverMac/dist/Conver.dmg"
    ;;
  linux)
    echo "==> Building Linux AppImage & .deb (conver)..."
    cd "$ROOT_DIR/conver"
    npm install
    npm run dist:linux
    echo "==> Done! Output in: conver/dist/"
    ;;
  win|windows)
    echo "==> Building Windows Installer & Portable .exe (conver)..."
    cd "$ROOT_DIR/conver"
    npm install
    npm run dist:win
    echo "==> Done! Output in: conver/dist/"
    ;;
  *)
    echo "Usage: ./build.sh [mac|linux|windows]"
    exit 1
    ;;
esac
