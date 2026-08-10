#!/usr/bin/env node
/*
 * Re-applies Peariscope's diagnostic patches to node_modules/hyperdht.
 *
 * Why this exists: hyperdht gives us no visibility into why a connection
 * fails. The client logs only "HOLEPUNCH_ABORTED" with no reason, and the
 * server's advertised firewall state — the thing that determines whether
 * holepunching is attempted at all — is never surfaced. These log lines are
 * what identified the NAT-override bug (a host falsely advertising
 * FIREWALL.OPEN suppressed holepunching entirely).
 *
 * These were previously hand-edits to node_modules, which meant any
 * `npm install` silently deleted them. That happened during the 6.29.5 ->
 * 6.33.0 upgrade and cost us our best diagnostic mid-investigation. Running
 * this from `postinstall` makes them survive dependency changes.
 *
 * The patches are PURELY OBSERVATIONAL — they only add logging. Nothing here
 * may change control flow. If a patch ever needs to alter behaviour, it does
 * not belong in this file.
 *
 * Idempotent: each patch is skipped if its marker is already present.
 * Never fails the install — a missing anchor logs a warning and exits 0, since
 * an unpatched hyperdht still works, it is just quieter.
 */

const fs = require('fs')
const path = require('path')

const MARKER = '__peariscopeLog'
const root = path.join(__dirname, '..', 'node_modules', 'hyperdht', 'lib')

// Emits through the worklet's IPC logger when present, else console.
const EMIT = `if (typeof global !== 'undefined' && global.${MARKER}) global.${MARKER}(logMsg)
    else if (typeof console !== 'undefined') console.log(logMsg)`

const patches = [
  {
    file: 'connect.js',
    name: 'handshake-recv',
    anchor: '  if (payload.version !== 1) {',
    insert: `  // [peariscope] Log the server's advertised firewall state. A host that
  // reports OPEN suppresses the holepunch block entirely (see server.js:
  // holepunch: ourRemoteAddr ? null : {...}), so peers dial it directly and
  // the connection dies ~13s later with no explanation.
  try {
    const FIREWALL_NAMES = ['UNKNOWN', 'OPEN', 'CONSISTENT', 'RANDOM']
    const logMsg = 'HANDSHAKE-RECV: server firewall=' + (FIREWALL_NAMES[payload.firewall] || payload.firewall) +
      ' holepunch=' + (payload.holepunch ? 'relays=' + (payload.holepunch.relays ? payload.holepunch.relays.length : 0) : 'null') +
      ' relayThrough=' + (payload.relayThrough ? 'yes' : 'no') +
      ' addresses=' + (payload.addresses4 ? payload.addresses4.length : 0)
    ${EMIT}
  } catch (e) {}

`
  },
  {
    file: 'connect.js',
    name: 'abort-reason',
    anchor: '  const onabort = () => {',
    insert: `  const onabort = () => {
    // [peariscope] HOLEPUNCH_ABORTED carries no reason. Record the punch state
    // so an abort can be told apart from a probe timeout or a firewall mismatch.
    try {
      const p = c.puncher
      const FIREWALL_NAMES = ['UNKNOWN', 'OPEN', 'CONSISTENT', 'RANDOM']
      const logMsg = 'PUNCH-ABORT: remoteFirewall=' + (p ? (FIREWALL_NAMES[p.remoteFirewall] || p.remoteFirewall) : 'n/a') +
        ' localFirewall=' + (p && p.nat ? (FIREWALL_NAMES[p.nat.firewall] || p.nat.firewall) : 'n/a') +
        ' punchingNow=' + (p ? p.punching : 'n/a') +
        ' destroyed=' + (p ? p.destroyed : 'n/a') +
        ' connected=' + (p ? p.connected : 'n/a') +
        ' remoteAddrs=' + (p && p.remoteAddresses ? p.remoteAddresses.length : 0) +
        ' localAddrs=' + (p && p.nat && p.nat.addresses ? p.nat.addresses.length : 0)
      ${EMIT}
    } catch (e) {}
`,
    replaceAnchor: true
  },
  {
    file: 'connect.js',
    name: 'roundpunch-throw',
    anchor: `    destroyPuncher(c)
    // TODO: retry with another relay?`,
    insert: `    // [peariscope] roundPunch() threw before punch() was ever called
    // (observed: punching=false with both NATs CONSISTENT, which rules out
    // PROBE_TIMEOUT and DOUBLE_RANDOMIZED_NATS). This error is otherwise
    // swallowed into a bare HOLEPUNCH_ABORTED with no reason.
    try {
      const logMsg = 'ROUNDPUNCH-THROW: code=' + ((err && err.code) || 'none') +
        ' msg=' + ((err && err.message) || String(err))
      ${EMIT}
    } catch (e) {}
    destroyPuncher(c)
    // TODO: retry with another relay?`,
    replaceAnchor: true
  },
  {
    file: 'connect.js',
    name: 'abort-reason-real',
    anchor: `  destroyPuncher(c)
  maybeDestroyEncryptedSocket(c, err)
}`,
    insert: `  // [peariscope] THE reason a connection failed. destroyPuncher() below fires
  // the puncher's onabort, which destroys the socket with a generic
  // HOLEPUNCH_ABORTED — so the real error passed to maybeDestroyEncryptedSocket
  // on the next line always arrives after the socket is already gone and is
  // never surfaced. Log it here, before it is masked.
  try {
    const logMsg = 'ABORT-REASON: code=' + ((err && err.code) || 'none') +
      ' msg=' + ((err && err.message) || String(err))
    ${EMIT}
  } catch (e) {}
  destroyPuncher(c)
  maybeDestroyEncryptedSocket(c, err)
}`,
    replaceAnchor: true
  },
  {
    file: 'connect.js',
    name: 'probe-throw',
    anchor: `    destroyPuncher(c)
    // TODO: we should retry here with some of the other relays, bail for now`,
    insert: `    // [peariscope] probeRound() threw. Distinct from the roundPunch catch
    // below — this fires before any punch is attempted, which matches the
    // observed punching=false aborts.
    try {
      const logMsg = 'PROBE-THROW: code=' + ((err && err.code) || 'none') +
        ' msg=' + ((err && err.message) || String(err))
      ${EMIT}
    } catch (e) {}
    destroyPuncher(c)
    // TODO: we should retry here with some of the other relays, bail for now`,
    replaceAnchor: true
  },
  {
    file: 'connect.js',
    name: 'probe-null',
    anchor: `  if (isDone(c) || !probe) return
  const { token, peerAddress } = probe`,
    insert: `  // [peariscope] probeRound() has many silent \`return null\` paths. Without
  // this, giving up here is indistinguishable from never having got this far.
  if (isDone(c) || !probe) {
    try {
      const logMsg = 'PROBE-NULL: done=' + isDone(c) + ' probe=' + (probe ? 'ok' : 'null') +
        ' round=' + c.round
      ${EMIT}
    } catch (e) {}
  }
  if (isDone(c) || !probe) return
  const { token, peerAddress } = probe`,
    replaceAnchor: true
  },
  {
    file: 'holepuncher.js',
    name: 'probe-addresses',
    anchor: `    let tries = 0

    while (this.punching && tries++ < 10) {`,
    insert: `    // [peariscope] What the punch is actually aimed at. The loop below skips
    // unverified addresses on 3 of every 4 ticks, so an unverified address gets
    // ~2 packets across the whole 10s rather than ~10 — a materially thinner
    // punch than the try count suggests.
    try {
      const addrs = (this.remoteAddresses || [])
        .map(a => a.host + ':' + a.port + (a.verified ? ' verified' : ' UNVERIFIED'))
        .join(', ')
      const logMsg = 'PROBE-ADDRS: initiator=' + this.isInitiator +
        ' count=' + (this.remoteAddresses ? this.remoteAddresses.length : 0) +
        ' [' + addrs + ']'
      ${EMIT}
    } catch (e) {}

    let tries = 0

    while (this.punching && tries++ < 10) {`,
    replaceAnchor: true
  },
  {
    file: 'holepuncher.js',
    name: 'destroy-snapshot',
    anchor: `  destroy() {
    if (this.destroyed) return
    this.destroyed = true
    this.punching = false`,
    insert: `  destroy() {
    // [peariscope] Snapshot BEFORE the flags are cleared. destroy() sets
    // this.punching = false on its third line, so any log further down — including
    // onabort()'s, which runs from inside this function — reads false
    // unconditionally and says nothing about whether a punch was in flight.
    const __wasPunching = this.punching
    const __from = (new Error().stack || '').split('\\n').slice(2, 5)
      .map(s => s.trim().replace(/^at\\s+/, '')).join(' <- ')

    if (this.destroyed) return
    this.destroyed = true
    this.punching = false`,
    replaceAnchor: true
  },
  {
    file: 'holepuncher.js',
    name: 'puncher-destroy',
    anchor: '      this.onabort()',
    insert: `      // [peariscope] The puncher was destroyed before connecting. Logs whether a
      // punch was actually in flight, and which call site tore it down — the
      // destroy() callers are spread across connect.js and are otherwise silent.
      try {
        const FIREWALL_NAMES = ['UNKNOWN', 'OPEN', 'CONSISTENT', 'RANDOM']
        const logMsg = 'PUNCHER-DESTROY: remoteFirewall=' + (FIREWALL_NAMES[this.remoteFirewall] || this.remoteFirewall) +
          ' localFirewall=' + (this.nat ? (FIREWALL_NAMES[this.nat.firewall] || this.nat.firewall) : 'n/a') +
          ' remoteAddrs=' + (this.remoteAddresses ? this.remoteAddresses.length : 0) +
          ' wasPunching=' + __wasPunching +
          ' from=' + __from
        ${EMIT}
      } catch (e) {}
      this.onabort()`,
    replaceAnchor: true
  }
]

let applied = 0
let skipped = 0
let missing = 0

for (const p of patches) {
  const file = path.join(root, p.file)
  if (!fs.existsSync(file)) {
    console.warn(`[patch-hyperdht] ${p.file} not found — skipping ${p.name}`)
    missing++
    continue
  }

  const src = fs.readFileSync(file, 'utf8')

  if (src.includes(`[peariscope]`) && src.includes(p.insert.trim().slice(0, 60))) {
    skipped++
    continue
  }

  if (!src.includes(p.anchor)) {
    // hyperdht changed shape. Not fatal: we lose logging, not function.
    console.warn(`[patch-hyperdht] anchor not found for ${p.name} in ${p.file} — hyperdht may have changed; diagnostics disabled for this site`)
    missing++
    continue
  }

  const next = p.replaceAnchor
    ? src.replace(p.anchor, p.insert)
    : src.replace(p.anchor, p.insert + p.anchor)

  fs.writeFileSync(file, next)
  applied++
}

const version = (() => {
  try {
    return require(path.join(__dirname, '..', 'node_modules', 'hyperdht', 'package.json')).version
  } catch { return 'unknown' }
})()

console.log(`[patch-hyperdht] hyperdht@${version}: ${applied} applied, ${skipped} already present, ${missing} skipped`)
