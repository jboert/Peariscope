<div align="center">

# 🍐 Peariscope

**Peer-to-peer remote desktop — no servers, no accounts, no nonsense.**

Share your screen and control remote devices over fully encrypted P2P connections.

[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Windows%20%7C%20Linux%20%7C%20iOS%20%7C%20Android-green?style=flat-square)](#platforms)

<br>

<img src="mac-home.png" height="420" alt="macOS app">
&nbsp;&nbsp;&nbsp;&nbsp;
<img src="ios-home.png" height="420" alt="iOS app">

</div>

<br>

## How it works

> **Host** starts sharing → gets a **12-word code** + **QR code** → **Viewer** enters code or scans QR → devices find each other via P2P → **PIN verification** → screen streams with full input control.

Everything runs over [Hyperswarm](https://github.com/holepunchto/hyperswarm) — a distributed hash table for peer discovery. No relay servers, no cloud, no accounts. Connections are end-to-end encrypted.

| | |
|---|---|
| 🖥️ **Video** | H.264/H.265 with adaptive quality |
| ⌨️ **Input** | Keyboard, mouse, and touch forwarded to host |
| 📋 **Clipboard** | Text and images sync automatically |
| 🔒 **Security** | End-to-end encrypted + PIN verification |

<br>

## Platforms

| Platform | Role | Status |
|:---------|:-----|:------:|
| macOS | Host + Viewer | ✅ |
| Windows | Host + Viewer | ✅ |
| Linux | Host + Viewer | ✅ |
| iOS | Viewer | ✅ |
| Android | Viewer | 🚧 |

<br>

## Getting started

### Hosting

1. Open Peariscope and press **Start Hosting**
2. A **12-word connection code** and **QR code** appear — share either with the viewer
3. When a viewer connects, read the **PIN** to them over a trusted channel
4. The viewer enters the PIN and your desktop starts streaming

### Viewing (mobile)

1. Open Peariscope on your phone or tablet
2. **Scan the QR code** on the host's screen, or type the **12-word code** (autocomplete helps — just type the first few letters)
3. Tap **Connect**
4. Enter the **PIN** from the host
5. You're in — use touch gestures to navigate

### Viewing (desktop)

1. Open Peariscope and switch to **Viewer** mode
2. Enter the 12-word connection code and connect
3. Enter the PIN when prompted
4. Use your keyboard and mouse to control the remote desktop

