#!/usr/bin/env node
/*
 * Peariscope relay node.
 *
 * Why this exists: when a direct connection cannot be established, hyperswarm
 * can retry through a relay — but only if it is given the public key of a peer
 * running one. Peariscope has exactly two participants, both typically behind
 * NAT, so neither can serve that role. This is that third party.
 *
 * Run it on a machine both ends can reach: a VPS, a box with a public IP, or
 * anything not behind the NAT that is failing to punch. Running it on the same
 * machine as the host defeats the purpose — the relay must be reachable when
 * the host is not.
 *
 *   node relay-server.js                 # ephemeral key, new identity each run
 *   node relay-server.js --seed <hex>    # stable key, survives restarts
 *
 * It prints a public key. That value goes to both ends as the relay key; see
 * README notes in the commit that added this file.
 *
 * The relay is blind: it pairs two encrypted streams by token and copies bytes.
 * It cannot read the traffic — Peariscope's encryption is end to end and the
 * relay is not a party to it. It does see that two peers are talking, and how
 * much, which is why the key should not be shared beyond the peers using it.
 */

const DHT = require('hyperdht')
const relay = require('blind-relay')
const crypto = require('hypercore-crypto')

function parseArgs (argv) {
  const args = { seed: null, port: 0 }
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === '--seed') args.seed = argv[++i]
    else if (argv[i] === '--port') args.port = Number(argv[++i])
    else if (argv[i] === '--help' || argv[i] === '-h') args.help = true
  }
  return args
}

async function main () {
  const args = parseArgs(process.argv)

  if (args.help) {
    console.log('Usage: relay-server.js [--seed <64-hex>] [--port <n>]')
    console.log('  --seed  32-byte hex seed for a stable public key across restarts.')
    console.log('          Without it the key changes every run and both ends must be')
    console.log('          reconfigured. Generate one with:')
    console.log("          node -e \"console.log(require('crypto').randomBytes(32).toString('hex'))\"")
    process.exit(0)
  }

  // A relay whose key changes on restart is useless to already-configured
  // peers, so a seed is strongly preferred outside of testing.
  const keyPair = args.seed
    ? crypto.keyPair(Buffer.from(args.seed, 'hex'))
    : crypto.keyPair()

  if (!args.seed) {
    console.warn('WARNING: no --seed given. This key is ephemeral and will change')
    console.warn('         on restart, breaking every peer configured against it.')
  }

  const dht = new DHT({ port: args.port })
  await dht.ready()

  const relayServer = new relay.Server({
    createStream (opts) {
      return dht.createRawStream(opts)
    }
  })

  // Timestamps and a live session count, because the question this log has to
  // answer is whether the two peers are ever connected AT THE SAME TIME.
  // Relaying pairs them by token; two sessions that never overlap can never
  // pair, and without timestamps that is invisible.
  let live = 0
  const stamp = () => new Date().toISOString().slice(11, 23)
  const log = (msg) => console.log(`[${stamp()}] [relay] ${msg}`)

  const server = dht.createServer((socket) => {
    const remote = socket.remotePublicKey
      ? socket.remotePublicKey.toString('hex').slice(0, 16)
      : 'unknown'
    live++
    log(`session opened from ${remote}... (live=${live})`)

    // id MUST be the CLIENT's public key. Protomux matches channels on
    // protocol + id, and the client opens its channel with its own
    // socket.publicKey (see hyperdht: relay.Client.from(sock, { id:
    // sock.publicKey })). Passing our own key here means the ids never match,
    // the channel closes on open, and every session dies in ~2ms with
    // CHANNEL_CLOSED and no pairing.
    const session = relayServer.accept(socket, { id: socket.remotePublicKey })

    // The event that matters: two peers met and were joined by token.
    session.on('pair', (isInitiator, token, id) => {
      log(`PAIRED ${remote}... initiator=${isInitiator} token=${token && token.toString('hex').slice(0, 12)}...`)
    })
    session.on('error', (err) => {
      log(`session error from ${remote}...: ${err.message}`)
    })
    session.on('close', () => {
      live--
      log(`session closed from ${remote}... (live=${live})`)
    })

    socket.on('error', () => { /* peer vanished; nothing to do */ })
  })

  await server.listen(keyPair)

  const publicKey = server.publicKey.toString('hex')
  console.log('')
  console.log('Peariscope relay is up.')
  console.log('')
  console.log('  public key: ' + publicKey)
  console.log('')
  console.log('Configure BOTH the host and the viewer with this key:')
  console.log('')
  console.log('  macOS:  defaults write com.peariscope.app PeariscopeRelayKey ' + publicKey)
  console.log('')
  console.log('Waiting for sessions. Ctrl-C to stop.')

  const shutdown = async () => {
    console.log('\n[relay] shutting down')
    try {
      await relayServer.close()
      await server.close()
      await dht.destroy()
    } catch (e) { /* going away regardless */ }
    process.exit(0)
  }

  process.on('SIGINT', shutdown)
  process.on('SIGTERM', shutdown)
}

main().catch((err) => {
  console.error('relay failed to start: ' + (err.message || err))
  process.exit(1)
})
