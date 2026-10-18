# JomaaDrag 🖐️

> **Native Apple Trackpad & Mos-style smooth scrolling + 3-finger dragging for Jomaa external trackpads on macOS.**

[![macOS](https://img.shields.io/badge/macOS-12.0%2B-blue.svg)](https://apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Architecture](https://img.shields.io/badge/Arch-Apple%20Silicon%20%7C%20Intel-success.svg)](#)

---

## 🌟 Overview

**JomaaDrag** is a lightweight, high-performance macOS menu bar utility and driver designed specifically for external multi-touch trackpads (such as the **Jomaa KB96 trackpad**).

It bridges the gap between third-party USB multi-touch hardware and macOS, providing the exact same **fluid subpixel inertial scrolling** (inspired by [Mos](https://github.com/Caldis/Mos) and Apple Magic Trackpad) alongside **native 3-finger window dragging** without cursor jitter or lag.

---

## ✨ Features

- **⚡ 120Hz 2D Mos-Style Momentum Interpolation (Horizontal & Vertical)**:
  Decouples raw USB input polling from display rendering across both vertical (`Axis 1`) and horizontal (`Axis 2`) axes. Smoothly discharges scroll velocity using a subpixel floating-point spring accumulator and gesture-intent stabilization matching MacBook ProMotion displays.

- **🚀 Mos-Style `Option (⌥)` Dash / Turbo Scroll**:
  Hold the `Option (⌥)` key while scrolling (up/down or left/right) to boost scroll speed by **3.2×** with extended momentum glide—automatically stripping the `Alternate` flag from synthesized scroll events so browsers, Figma, and VS Code don't accidentally trigger zoom shortcuts.

- **🎯 Per-Finger ID Tracking (Zero-Stutter)**:
  Tracks individual finger deltas using hardware touch `identifier`s instead of naive centroid averaging. Prevents phantom jumps and coordinate spikes when fingers touch down or lift asynchronously.

- **🖐️ Native 3-Finger Dragging with Instant 1-Finger Handover**:
  Enables full 1:1 window dragging and text selection. Releasing 3 fingers to a single finger instantly hands over cursor control within 25ms, avoiding macOS WindowServer mouse lockup.

- **🛡️ Hardware USB Wheel Suppressor**:
  Automatically intercepts and discards coarse, jagged non-continuous scroll packets from external USB mouse chips during touch gestures.

- **🎛️ Menu Bar Controls & System Sync**:
  - Live sensitivity adjustment slider (50% – 250%) with presets.
  - Automatic synchronization with macOS System Settings trackpad tracking speed (`com.apple.trackpad.scaling`).
  - Natural Scrolling auto-detection.

- **🖥️ Multi-Monitor & External Display Ready**:
  Fully compatible with secondary displays and negative coordinate spaces.

---

## 📥 Installation & Quick Start

### 1. Prerequisites
- macOS 12.0 (Monterey) or later (Apple Silicon M1/M2/M3/M4 or Intel).
- Xcode Command Line Tools:
  ```bash
  xcode-select --install
  ```

### 2. Clone & Install
```bash
git clone https://github.com/datb2404981/JomaaDrag.git
cd JomaaDrag
make install
```
This script will:
1. Compile the native Objective-C binary with `-O2` optimizations.
2. Package it into `/Applications/JomaaDrag.app` with an application icon.
3. Sign the application bundle with a persistent designated requirement.
4. Set up auto-start at login via `~/Library/LaunchAgents/com.jomaa.drag.plist`.

---

## 🔐 Granting Accessibility Permission

macOS requires **Accessibility** permission for event taps:

1. Open **System Settings** > **Privacy & Security** > **Accessibility**.
2. Click the `+` button and add `/Applications/JomaaDrag.app`.
3. Ensure the toggle switch next to **JomaaDrag** is enabled.

*(The status item in the menu bar will display `Trạng thái: Hoạt động mượt mà 🟢` when permission is active).*

---

## 🛠️ Building Manually

To compile the application bundle without installing:
```bash
make build
```
The output `.app` will be created inside `./build/JomaaDrag.app`.

---

## 🗑️ Uninstallation

To completely remove JomaaDrag:
```bash
launchctl unload ~/Library/LaunchAgents/com.jomaa.drag.plist 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.jomaa.drag.plist
killall JomaaDrag 2>/dev/null || true
rm -rf /Applications/JomaaDrag.app
```

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
