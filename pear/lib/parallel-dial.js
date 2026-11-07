// Dials one peer with several independent holepunch attempts at once.
//
// Through a carrier NAT on both ends (T-Mobile CGNAT, measured 2026-11-07)
// a single punch succeeds about 1 time in 13, and an attempt costs ~12s
// whether it wins or not, so serial retries average ~3 minutes. Every
// dht.connect() takes a fresh socket from the pool, so the carrier assigns
// it a fresh external port and the attempts are independent — running them
// side by side costs the same ~12s as running one.
//
// The first socket to open wins and the rest are destroyed immediately.
// That matters on the host: hyperswarm replaces an established connection
// when a second one from the same key completes (_handleServerConnection),
// so a loser left running could tear down the winner.

const FORCE_RELAY_CODES = new Set([
  'HOLEPUNCH_ABORTED',
  'HOLEPUNCH_DOUBLE_RANDOMIZED_NATS',
  'REMOTE_NOT_HOLEPUNCHABLE',
  'CANNOT_HOLEPUNCH'
])

function noop () {}

class ParallelDialer {
  constructor (dht, publicKey, opts = {}) {
    this.dht = dht
    this.publicKey = publicKey
    this.keyPair = opts.keyPair
    this.relayAddresses = opts.relayAddresses || null
    // Only slot 0 goes through the relay, and only after a punch has failed
    // in a way hyperswarm would also have relayed — the same policy as
    // hyperswarm's own retry, so a direct connection is still preferred.
    this.relayThrough = opts.relayThrough || null
    this.parallel = opts.parallel || 6
    // Staggered starts keep the handshakes from all landing on the
    // announce relays in the same instant.
    this.stagger = opts.stagger === undefined ? 400 : opts.stagger
    this.restartDelay = opts.restartDelay === undefined ? 250 : opts.restartDelay
    // An attempt that dies before it could have punched (PEER_NOT_FOUND, a
    // host that just went offline) would otherwise restart in a tight loop
    // and flood the DHT with findPeer queries.
    this.quickFailure = opts.quickFailure === undefined ? 3000 : opts.quickFailure
    this.quickFailureDelay = opts.quickFailureDelay === undefined ? 2000 : opts.quickFailureDelay
    this.onconnection = opts.onconnection || noop
    this.log = opts.log || noop

    this.active = new Set()
    this.attempts = 0
    this.failures = 0
    this.destroyed = false
    this._timers = new Set()
    this._forceRelay = false
  }

  start () {
    for (let slot = 0; slot < this.parallel; slot++) {
      this._schedule(slot, slot * this.stagger)
    }
  }

  destroy () {
    if (this.destroyed) return
    this.destroyed = true
    for (const timer of this._timers) clearTimeout(timer)
    this._timers.clear()
    for (const conn of this.active) conn.destroy()
    this.active.clear()
  }

  _schedule (slot, delay) {
    if (this.destroyed) return
    const timer = setTimeout(() => {
      this._timers.delete(timer)
      this._dial(slot)
    }, delay)
    this._timers.add(timer)
  }

  _dial (slot) {
    if (this.destroyed) return

    const n = ++this.attempts
    const startedAt = Date.now()
    const relayThrough = slot === 0 && this._forceRelay ? this.relayThrough : null
    const conn = this.dht.connect(this.publicKey, {
      keyPair: this.keyPair,
      relayAddresses: this.relayAddresses,
      relayThrough
    })
    this.active.add(conn)

    let opened = false
    let lastError = null

    conn.on('error', (err) => {
      lastError = err
      if (this.relayThrough && FORCE_RELAY_CODES.has(err.code)) this._forceRelay = true
    })

    conn.on('open', () => {
      opened = true
      this.active.delete(conn)
      if (this.destroyed) {
        conn.on('error', noop)
        conn.destroy()
        return
      }
      this.log('attempt #' + n + ' (slot ' + slot + ') opened after ' + (Date.now() - startedAt) + 'ms' +
        ' relay=' + (conn.relayType || (relayThrough ? 'requested' : 'none')) +
        ' — cancelling ' + this.active.size + ' others (' + this.failures + ' failed so far)')
      this.destroy()
      this.onconnection(conn)
    })

    conn.on('close', () => {
      this.active.delete(conn)
      if (opened || this.destroyed) return
      this.failures++
      const elapsed = Date.now() - startedAt
      this.log('attempt #' + n + ' (slot ' + slot + ') failed after ' + elapsed + 'ms' +
        ' code=' + ((lastError && lastError.code) || 'none'))
      this._schedule(slot, elapsed < this.quickFailure ? this.quickFailureDelay : this.restartDelay)
    })
  }
}

module.exports = ParallelDialer
