# Peariscope TODO

## Performance
- [x] ~~Adaptive resolution scaling — Host downscales capture resolution based on viewer device capabilities~~
- [ ] Delta/dirty-rect encoding — Only encode regions that changed
- [ ] Audio streaming — Add channel 3 for audio (CoreAudio tap, AAC encode/decode)

## UX
- [ ] Clipboard sync — Bidirectional clipboard sharing over control channel
- [ ] Multi-viewer awareness — Show connected viewers with cursors/names, selective input control
- [ ] Connection quality indicator — Bandwidth/latency/fps overlay on viewer
- [ ] Thumbnail preview — Low-res JPEG snapshot over control channel before full video starts

## Reliability
- [ ] Structured logging — Replace crash log with JSON lines structured events
- [ ] Automatic codec fallback — Auto-switch H.265 to H.264 on decode failure
- [ ] Reconnect with backoff — Exponential backoff with jitter on reconnect attempts

## Features
- [ ] File transfer — Drag-and-drop file sending over new channel
- [ ] Session recording — Save H.264 stream to MP4
- [ ] Wake-on-LAN integration — WOL packet before connecting to sleeping host
- [ ] iPad keyboard/trackpad passthrough — Full input from iPad with Magic Keyboard

## Architecture
- [ ] Move rate limiting into StreamMux — Consolidate rate limiting logic
- [ ] Binary IPC instead of chunking — Shared-memory/mmap for large frames to eliminate chunk assembly bugs
