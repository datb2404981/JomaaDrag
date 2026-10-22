#!/bin/bash
set -euo pipefail

# Directory locations
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
APP_NAME="JomaaDrag.app"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}"

echo "=========================================="
echo "🔨 Building JomaaDrag for macOS..."
echo "=========================================="

mkdir -p "${BUILD_DIR}"
rm -rf "${APP_BUNDLE}"

# Create .app bundle structure
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy Info.plist and AppIcon
cp "${PROJECT_DIR}/resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
if [ -f "${PROJECT_DIR}/resources/AppIcon.icns" ]; then
    cp "${PROJECT_DIR}/resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

# Compile Objective-C source
echo "📦 Compiling binary with Clang..."
clang -O2 -fobjc-arc -mmacosx-version-min=12.0 \
  -Wall -Wextra -Wno-unused-parameter -Werror "${PROJECT_DIR}/src/main.m" \
  -framework Cocoa \
  -framework ApplicationServices \
  -framework CoreFoundation \
  -F/System/Library/PrivateFrameworks \
  -o "${APP_BUNDLE}/Contents/MacOS/JomaaDrag"

# Code sign with designated requirement to preserve Accessibility permissions
echo "🔏 Signing application bundle..."
codesign -s - -r='designated => identifier "com.jomaa.drag"' --force --deep "${APP_BUNDLE}"

echo "=========================================="
echo "✅ Build completed: ${APP_BUNDLE}"
echo "=========================================="
