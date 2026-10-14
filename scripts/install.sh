#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="/Applications/JomaaDrag.app"
LAUNCH_AGENT="${HOME}/Library/LaunchAgents/com.jomaa.drag.plist"

# 1. Build first
"${PROJECT_DIR}/scripts/build.sh"

echo "=========================================="
echo "🚀 Installing JomaaDrag to /Applications..."
echo "=========================================="

# Unload existing launch agent and terminate old process
launchctl unload "${LAUNCH_AGENT}" 2>/dev/null || true
killall JomaaDrag 2>/dev/null || true
sleep 0.5

# Install app bundle
rm -rf "${APP_PATH}"
cp -R "${PROJECT_DIR}/build/JomaaDrag.app" "${APP_PATH}"

# Install launch agent
mkdir -p "${HOME}/Library/LaunchAgents"
cp "${PROJECT_DIR}/resources/com.jomaa.drag.plist" "${LAUNCH_AGENT}"

# Start daemon
launchctl load "${LAUNCH_AGENT}"

echo "=========================================="
echo "✅ JomaaDrag installed and launched successfully!"
echo "ℹ️  Remember to grant Accessibility permission in:"
echo "   System Settings > Privacy & Security > Accessibility"
echo "=========================================="
