#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "${PROJECT_DIR}/build"
xcrun clang -O1 -g -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  "${PROJECT_DIR}/tests/gestures.m" \
  -framework Cocoa -framework ApplicationServices -framework CoreFoundation \
  -o "${PROJECT_DIR}/build/gesture-tests"
"${PROJECT_DIR}/build/gesture-tests"
