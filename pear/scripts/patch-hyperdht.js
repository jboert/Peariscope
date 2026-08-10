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
        ' punching=' + (p ? p.punching : 'n/a') +
        ' connected=' + (p ? p.connected : 'n/a') +
        ' remoteAddrs=' + (p && p.remoteAddresses ? p.remoteAddresses.length : 0) +
        ' localAddrs=' + (p && p.nat && p.nat.addresses ? p.nat.addresses.length : 0)
      ${EMIT}
    } catch (e) {}
`,
    replaceAnchor: true
  },
  {
    file: 'holepuncher.js',
    name: 'puncher-destroy',
    anchor: '      this.onabort()',
    insert: `      // [peariscope] The puncher was destroyed before connecting. Log the NAT
      // view it had, to distinguish "never got a remote address" from
      // "punched and got no reply".
      try {
        const FIREWALL_NAMES = ['UNKNOWN', 'OPEN', 'CONSISTENT', 'RANDOM']
        const logMsg = 'PUNCHER-DESTROY: remoteFirewall=' + (FIREWALL_NAMES[this.remoteFirewall] || this.remoteFirewall) +
          ' localFirewall=' + (this.nat ? (FIREWALL_NAMES[this.nat.firewall] || this.nat.firewall) : 'n/a') +
          ' remoteAddrs=' + (this.remoteAddresses ? this.remoteAddresses.length : 0) +
          ' punching=' + this.punching
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
