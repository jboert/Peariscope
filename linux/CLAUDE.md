# Peariscope Linux - Development Notes

## Deploying worklet changes

The worklet (`pear/worklet.js`) runs via `pear run --dev` which loads from the build directory.
To deploy changes, you MUST do ALL of these steps:

1. Edit `pear/worklet.js` (the source)
2. Copy to build: `cp pear/worklet.js build/pear/worklet.js`
3. Re-stage: `cd build/pear && pear stage .`
4. Kill the app AND any orphaned `pear run` processes: `pkill -f peariscope-app; pkill -f "pear run.*peariscope"`
5. Restart: `cd build && ./peariscope-app`

If you skip step 3 (staging), `pear run --dev` may load a cached version.
If you skip step 4 (killing orphans), zombie `pear run` processes compete for DHT ports.

## Building C++ changes

```bash
cd /home/jb/peariscope-linux/build
cmake --build . -j$(nproc)
```

The build copies `pear/` to `build/pear/` so C++ builds may overwrite worklet changes.
Always re-copy worklet.js AFTER building C++.

## Architecture

- Qt/C++ app (`build/peariscope-app`) — UI, screen capture, input injection
- Pear worklet (`build/pear/worklet.js`) — P2P networking via Hyperswarm/HyperDHT
- IPC: Unix domain socket at `/tmp/peariscope-ipc-<pid>.sock` (path stored in `~/.peariscope/ipc-sock`)
- Worklet runs via `pear run --dev build/pear/` (Bare runtime)

## Known Issues

- T-Mobile Home Internet (CGNAT) — `firewalled=true`, needs relay for external connections
- DHT must be `ephemeral=false` to be discoverable
- Pear worklet IPC uses UDS (not fd inheritance — pear run doesn't pass fds through)
