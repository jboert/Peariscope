// Relay pairing test on a local testnet, so DHT announce propagation cannot
// confound the result. If PAIRED does not appear here, relay-server.js is wrong.
const createTestnet = require('@hyperswarm/testnet')
const DHT = require('hyperdht')
const relay = require('blind-relay')
const crypto = require('hypercore-crypto')

async function main () {
  const testnet = await createTestnet(4)
  const boot = testnet.bootstrap

  const relayDHT = new DHT({ bootstrap: boot })
  await relayDHT.ready()

  const relayServer = new relay.Server({
    createStream (opts) { return relayDHT.createRawStream(opts) }
  })

  let accepted = 0
  const server = relayDHT.createServer((socket) => {
    accepted++
    console.log('accepted #' + accepted)
    const session = relayServer.accept(socket, { id: socket.remotePublicKey })
    session.on('open', () => console.log('  OPEN'))
    session.on('pair', () => console.log('  PAIR'))
    session.on('error', (e) => console.log('  session error: ' + e.message))
  })
  const kp = crypto.keyPair()
  await server.listen(kp)

  const a = new DHT({ bootstrap: boot }); const b = new DHT({ bootstrap: boot })
  await a.ready(); await b.ready()

  const token = relay.token()
  const sa = a.connect(server.publicKey)
  const sb = b.connect(server.publicKey)
  const ca = relay.Client.from(sa, { id: sa.publicKey })
  const cb = relay.Client.from(sb, { id: sb.publicKey })

  let n = 0
  const hit = () => { if (++n === 2) finish('BOTH PAIRED') }
  ca.pair(true, token, a.createRawStream()).on('data', hit).on('error', e => console.log('A: ' + e.message))
  cb.pair(false, token, b.createRawStream()).on('data', hit).on('error', e => console.log('B: ' + e.message))

  function finish (msg) { console.log('RESULT: ' + msg); cleanup(0) }
  const timer = setTimeout(() => { console.log('RESULT: TIMEOUT n=' + n + ' accepted=' + accepted); cleanup(1) }, 20000)
  async function cleanup (code) {
    clearTimeout(timer)
    try { await a.destroy(); await b.destroy(); await server.close(); await relayDHT.destroy(); await testnet.destroy() } catch (e) {}
    process.exit(code)
  }
}
main().catch(e => { console.log('RESULT: threw ' + (e.stack || e.message)); process.exit(1) })
