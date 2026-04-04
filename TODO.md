# Peariscope TODO

## Critical — Reliability
- [ ] **Connection success rate** — First-time connections over CGNAT take 10-30s and can fail silently. Add granular connection state feedback ("Searching DHT...", "Holepunching...", "Trying relay...") instead of just "Connecting...". Surface DHT lookup failures and holepunch timeouts to the user with actionable retry options.
- [ ] **Auto-reconnect** — If the stream drops mid-session, viewers should silently reconnect without returning to the home screen. Detect stream close vs intentional disconnect, auto-retry with exponential backoff, show subtle reconnecting banner over the viewer.
- [ ] **Crash resilience** — iOS has history of jetsam kills and VideoToolbox crashes on low-memory devices. Stress test on 4GB iPhones, verify memory safety nets don't trigger false positives, ensure worklet restart recovery works end-to-end.
- [x] ~~**DHT re-announcement** — Host becomes invisible after sleep/wake, WiFi reconnect, or DHT record expiry. Fixed: periodic 5-min re-announce timer, REANNOUNCE IPC message, NWPathMonitor/ConnectivityManager network change detection (macOS + Android).~~

## High Impact — Features
- [ ] **Windows host stability** — Windows C++ host exists but isn't compilable/stable. Getting it working would massively expand the user base (most common host platform).
- [ ] **Audio streaming end-to-end** — Architecture supports it (channel 3, AAC 48kHz stereo), macOS host has capture code, but not wired up on all platforms. Remote desktop without audio is a major UX gap.
- [ ] **Linux host** — Add screen capture + encoding on Linux (PipeWire/Wayland capture → VA-API H.264). Covers the developer audience.
- [x] ~~**Audio streaming** — Stream host audio to iOS/macOS via channel 3 (ScreenCaptureKit audio tap, AAC encode/decode). Watch videos, hear notifications, music.~~
- [ ] **File transfer** — Pick files on either side and send over P2P channel. Share sheet integration on iOS, drag-and-drop on host.
- [x] ~~**Picture-in-Picture** — Keep remote desktop in a floating PiP window while using other iOS apps. iOS has native PiP APIs. Dual pipeline: MTKView for normal viewing + AVSampleBufferDisplayLayer for PiP. Auto-activates on app background via `canStartPictureInPictureAutomaticallyFromInline`.~~

## High Impact — Distribution
- [ ] **App store presence** — TestFlight for iOS, Play Store for Android, Homebrew for macOS, AUR for Linux. Sideloading is the biggest friction point for new users.
- [ ] **First-run onboarding** — New users need to understand the BIP39 code flow. 30-second walkthrough on first launch.
- [ ] **Landing page** — Promo video is done, needs a website to host it with download links.

## Medium Impact
- [x] ~~**Clipboard sync for images** — Text sync exists, but copy/pasting screenshots between devices would be huge for productivity. Added `image_png` field to ClipboardData protobuf, ClipboardSharing monitors for image changes (PNG/TIFF on macOS, UIImage on iOS), sends up to 10MB images over control channel.~~
- [x] ~~**Double-tap to zoom** — Pinch zoom exists, but double-tap to snap to 1:1 pixel mapping (or fit-to-screen) is standard UX. Double-tap zooms to 1:1 pixel mapping centered on tap point, double-tap again snaps back to fit-to-screen.~~
- [ ] **Wake-on-LAN** — Send magic packet to wake a sleeping Mac before connecting. Save MAC address alongside saved hosts.
- [ ] **Drag-and-drop files onto remote desktop** — iOS drag gesture sends file data over channel, host drops it at cursor position.
- [ ] **Thumbnail preview** — Low-res JPEG snapshot over control channel before full video starts.
- [ ] **Multi-viewer awareness** — Show connected viewers with cursors/names, selective input control.

## Nice to Have
- [ ] **Host online push notifications** — Background check if saved hosts come online, notify user.
- [ ] **Session recording** — Record remote session as MP4 to camera roll.
- [ ] **Touch-to-scroll zones** — Edges of screen auto-scroll when cursor is near edge during drag.
- [ ] **Customizable shortcut buttons** — Let users create/reorder their own combos in the shortcuts panel.
- [ ] **Multi-session tabs** — Connect to multiple hosts simultaneously, swipe between them.
- [x] ~~**Bandwidth indicator** — Show current data rate (MB/s) alongside fps/latency.~~
- [x] ~~**Dark/light cursor** — Auto-switch cursor color based on what's behind it so it's always visible.~~
- [ ] **iPad Magic Keyboard passthrough** — Full physical keyboard/trackpad input forwarding.

## Performance
- [x] ~~Adaptive resolution scaling — Host downscales capture resolution based on viewer device capabilities~~
- [x] ~~Reconnect with backoff — Exponential backoff with jitter on reconnect attempts~~
- [x] ~~Clipboard sync — Bidirectional text clipboard sharing over control channel~~
- [x] ~~Connection quality indicator — FPS/latency overlay on viewer~~
- [x] ~~Delta/dirty-rect encoding — Fast pixel sampling (64-point FNV-1a hash) detects unchanged frames, skips encoding. Forces one frame every 2s to keep connection alive.~~

## Architecture
- [x] ~~Move rate limiting into StreamMux — Per-channel rate limiting centralized in StreamMux class with configurable minInterval/skipMin. Swift-side gate kept as defense-in-depth.~~
- [x] ~~Binary IPC instead of chunking — Replaced JSON metadata with 12-byte binary headers for streamData (99% of IPC traffic). JSON path kept as fallback.~~
- [x] ~~Structured logging — CrashLog now emits JSONL with ts, level, msg, mem_mb, and optional extra fields. Signal-handler safe (no DateFormatter/JSONSerialization).~~
- [x] ~~Automatic codec fallback — H.265 decoder tracks consecutive failures (10+), fires onCodecFallbackNeeded callback. Viewer sends CodecNegotiation requesting H.264, host auto-switches.~~
