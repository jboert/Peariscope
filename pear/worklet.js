/* eslint-disable */
// Bare runtime worklet for Peariscope P2P networking
// Runs inside BareWorklet on both macOS and iOS via BareKit
const WORKLET_VERSION = 'v46-topic-filter-20260319'

// Register global error handlers FIRST to prevent SIGABRT on unhandled errors
if (typeof Bare !== 'undefined') {
  Bare.on('unhandledRejection', (err) => {
    console.error('[worklet] Unhandled rejection:', err && err.message ? err.message : String(err))
    if (err && err.stack) console.error(err.stack)
    sendLog('REJECTION: ' + (err && err.message ? err.message : String(err)))
  })
  Bare.on('uncaughtException', (err) => {
    console.error('[worklet] Uncaught exception:', err && err.message ? err.message : String(err))
    if (err && err.stack) console.error(err.stack)
    sendLog('UNCAUGHT: ' + (err && err.message ? err.message : String(err)))
  })
}

// --- IPC Setup (must be first so sendLog works) ---
// BareKit exposes IPC as a global object in the worklet

const MSG = {
  // Native -> Worklet
  START_HOSTING: 0x01,
  STOP_HOSTING: 0x02,
  CONNECT_TO_PEER: 0x03,
  DISCONNECT: 0x04,
  STREAM_DATA: 0x05,
  STATUS_REQUEST: 0x06,
  LOOKUP_PEER: 0x07,
  CACHED_DHT_NODES: 0x08,
  SUSPEND: 0x09,
  RESUME: 0x0A,
  APPROVE_PEER: 0x0B,
  CONNECT_LOCAL_PEER: 0x0C,
  REANNOUNCE: 0x0D,

  // Worklet -> Native
  HOSTING_STARTED: 0x81,
  HOSTING_STOPPED: 0x82,
  CONNECTION_ESTABLISHED: 0x83,
  CONNECTION_FAILED: 0x84,
  PEER_CONNECTED: 0x85,
  PEER_DISCONNECTED: 0x86,
  STREAM_DATA_OUT: 0x87,
  STATUS_RESPONSE: 0x88,
  ERROR: 0x89,
  LOG: 0x8A,
  LOOKUP_RESULT: 0x8B,
  DHT_NODES: 0x8C,
  UPDATE_AVAILABLE: 0x8D,
  CONNECTION_STATUS: 0x8E
}

let ipcPipe = null
let recvBuf = Buffer.alloc(0)

// Try multiple patterns to find the IPC pipe
if (typeof IPC !== 'undefined') {
  ipcPipe = IPC
} else if (typeof Bare !== 'undefined' && Bare.IPC) {
  ipcPipe = Bare.IPC
} else {
  try {
    const Pipe = require('bare-pipe')
    ipcPipe = new Pipe(3)
  } catch (e) {
    // bare-pipe not available — use Node.js stdin/stdout as IPC
    // Windows IpcBridge pipes child stdin/stdout for communication
    if (typeof process !== 'undefined' && process.stdin && process.stdout) {
      ipcPipe = {
        on (event, cb) {
          if (event === 'data') process.stdin.on('data', cb)
          else if (event === 'error') process.stdin.on('error', cb)
          return this
        },
        write (data) { return process.stdout.write(data) },
        writable: true
      }
      process.stdin.resume()
    }
  }
}

if (ipcPipe) {
  ipcPipe.on('data', (chunk) => {
    recvBuf = Buffer.concat([recvBuf, chunk])
    drainFrames()
  })

  ipcPipe.on('error', (err) => {
    console.error('[worklet] IPC pipe error:', err.message)
  })
}

let drainStallCount = 0
let drainCorruptCount = 0
function drainFrames () {
  while (recvBuf.length >= 4) {
    const frameLen = recvBuf.readUInt32BE(0)
    // Sanity check: frame length should be reasonable (< 1MB) and non-zero
    if (frameLen > 1000000 || frameLen === 0) {
      drainCorruptCount++
      if (drainCorruptCount <= 10 || drainCorruptCount % 100 === 0) {
        sendLog('drainFrames: corrupt frameLen=' + frameLen + ' bufLen=' + recvBuf.length + ' count=' + drainCorruptCount)
      }
      // Scan for the next valid frame boundary.
      // A valid frame has: 4-byte length (1..100000) followed by a valid message type (0x01-0x06).
      // Validate by also checking that the NEXT frame after the candidate is also valid.
      let found = false
      for (let i = 1; i < recvBuf.length - 5; i++) {
        const candidateLen = recvBuf.readUInt32BE(i)
        if (candidateLen < 1 || candidateLen > 100000) continue
        if (i + 4 + candidateLen > recvBuf.length) continue
        const candidateType = recvBuf[i + 4]
        if (candidateType < 0x01 || candidateType > 0x07) continue
        // Double-check: verify the next frame header is also valid (if present)
        const nextFrameStart = i + 4 + candidateLen
        if (nextFrameStart + 5 <= recvBuf.length) {
          const nextLen = recvBuf.readUInt32BE(nextFrameStart)
          const nextType = recvBuf[nextFrameStart + 4]
          if (nextLen < 1 || nextLen > 1000000 || nextType < 0x01 || nextType > 0x07) continue
        }
        recvBuf = recvBuf.subarray(i)
        found = true
        break
      }
      if (!found) {
        recvBuf = Buffer.alloc(0)
      }
      continue
    }
    if (recvBuf.length < 4 + frameLen) {
      drainStallCount++
      if (drainStallCount % 100 === 0) {
        sendLog('drainFrames: waiting for ' + frameLen + ' bytes, have ' + (recvBuf.length - 4) + ', stalls=' + drainStallCount)
      }
      break
    }
    drainStallCount = 0
    const frame = recvBuf.subarray(4, 4 + frameLen)
    recvBuf = recvBuf.subarray(4 + frameLen)
    handleFrame(frame)
  }
}

let sendFrameCount = 0
const MAX_IPC_PAYLOAD = 16000

function sendFrame (type, jsonPayload, binaryPayload) {
  if (!ipcPipe) return

  // Early exit for droppable messages BEFORE any Buffer allocations.
  // Without this, each sendFrame call allocates jsonBuf + payload Buffers
  // even if _writeIpcFrame would drop them. At 43K calls/sec during burst
  // delivery (from StreamMux phantom frames), this wastes ~200MB/sec of V8 heap.
  if (type === MSG.STREAM_DATA_OUT && ipcWriteLen > MAX_IPC_WRITE_BUFFER) {
    ipcDropCount++
    if (ipcDropCount <= 10 || ipcDropCount % 100 === 0) {
      sendLog('sendFrame: early drop, writeBuf=' + ipcWriteLen + ' dropped=' + ipcDropCount)
    }
    // Don't pause peer streams — pause() stops the readable side which freezes
    // ALL incoming data (video + control). Input still works (writable side)
    // but video dies. Let UDX handle its own flow control instead.
    return
  }

  let payload
  if (binaryPayload) {
    const jsonBuf = Buffer.from(JSON.stringify(jsonPayload || {}))
    const totalSize = 1 + 2 + jsonBuf.length + binaryPayload.length

    // If the frame is small enough, send as one IPC message
    if (totalSize <= MAX_IPC_PAYLOAD) {
      payload = Buffer.alloc(totalSize)
      payload.writeUInt8(type, 0)
      payload.writeUInt16BE(jsonBuf.length, 1)
      jsonBuf.copy(payload, 3)
      binaryPayload.copy(payload, 3 + jsonBuf.length)
      sendFrameCount++
      if (sendFrameCount <= 5 || sendFrameCount % 300 === 0) {
        sendLog('sendFrame type=0x' + type.toString(16) + ' len=' + totalSize + ' binLen=' + binaryPayload.length + ' count=' + sendFrameCount)
      }
      _writeIpcFrame(payload)
      return
    }

    // Large binary: chunk the binary data, keeping the JSON header in each chunk
    // so the native side can parse each chunk independently.
    // Pre-build ALL chunks first, then check if the entire frame fits in the
    // IPC write buffer. This prevents partial chunk drops that leave the Swift
    // ChunkBuffer incomplete forever (assembled=0).
    const chunkDataMax = MAX_IPC_PAYLOAD - (1 + 2 + jsonBuf.length + 4) // 4 bytes for chunk header
    const totalChunks = Math.ceil(binaryPayload.length / chunkDataMax)

    // Estimate total IPC size for all chunks to check backpressure atomically
    const estimatedTotalSize = totalChunks * (4 + 1 + 2 + 80 + chunkDataMax) // 4=header, 80~json overhead
    if (ipcWriteLen + estimatedTotalSize > MAX_IPC_WRITE_BUFFER && type === MSG.STREAM_DATA_OUT) {
      // Drop the ENTIRE frame — never send partial chunks
      ipcDropCount++
      if (ipcDropCount <= 10 || ipcDropCount % 100 === 0) {
        sendLog('ipc-write: dropping entire chunked frame, writeBuf=' + ipcWriteLen + ' frameSize=' + estimatedTotalSize + ' chunks=' + totalChunks + ' dropped=' + ipcDropCount)
      }
      return
    }

    for (let i = 0; i < totalChunks; i++) {
      const offset = i * chunkDataMax
      const end = Math.min(offset + chunkDataMax, binaryPayload.length)
      const chunk = binaryPayload.subarray(offset, end)

      // Extended JSON with chunk info
      const chunkJson = Object.assign({}, jsonPayload || {}, {
        _chunkIndex: i,
        _totalChunks: totalChunks
      })
      const chunkJsonBuf = Buffer.from(JSON.stringify(chunkJson))

      const chunkPayload = Buffer.alloc(1 + 2 + chunkJsonBuf.length + chunk.length)
      chunkPayload.writeUInt8(type, 0)
      chunkPayload.writeUInt16BE(chunkJsonBuf.length, 1)
      chunkJsonBuf.copy(chunkPayload, 3)
      chunk.copy(chunkPayload, 3 + chunkJsonBuf.length)
      _writeIpcFrame(chunkPayload, true)
    }
    sendFrameCount++
    if (sendFrameCount <= 5 || sendFrameCount % 300 === 0) {
      sendLog('sendFrame-chunked type=0x' + type.toString(16) + ' binLen=' + binaryPayload.length + ' chunks=' + totalChunks + ' count=' + sendFrameCount)
    }
  } else {
    const jsonBuf = jsonPayload ? Buffer.from(JSON.stringify(jsonPayload)) : Buffer.alloc(0)
    payload = Buffer.alloc(1 + jsonBuf.length)
    payload.writeUInt8(type, 0)
    jsonBuf.copy(payload, 1)
    _writeIpcFrame(payload)
  }
}

// Array-based IPC write buffer. Previous approach used Buffer.concat on every
// write under backpressure, creating O(n²) allocation pressure — 28 chunks per
// frame each concat'd onto a growing buffer = ~372MB/sec of V8 allocations.
// Array approach: push chunks to array, single concat when draining.
let ipcWriteChunks = []
let ipcWriteLen = 0
let ipcDraining = false
let ipcDropCount = 0
let streamsPaused = false
let streamsPauseTimer = null
const MAX_IPC_WRITE_BUFFER = 500000  // 500KB — lower threshold to trigger backpressure sooner
const IPC_RESUME_THRESHOLD = 100000  // 100KB — resume streams when buffer drains
const STREAM_PAUSE_TIMEOUT = 2000    // Force-resume after 2s to prevent permanent freeze

function _writeIpcFrame (payload, forceWrite) {
  // Drop video data when write buffer is too large to prevent jetsam kill.
  // Video frames are the bulk of data and can be re-requested via IDR.
  // forceWrite=true skips this check — used by chunking loop where the
  // frame-level atomic check already decided to send ALL chunks.
  // Dropping individual chunks mid-frame breaks assembly (assembled=0 bug).
  if (!forceWrite && ipcWriteLen > MAX_IPC_WRITE_BUFFER) {
    // Check if this is a STREAM_DATA_OUT (0x87) message — only drop video (channel 0)
    if (payload.length > 3 && payload[0] === MSG.STREAM_DATA_OUT) {
      ipcDropCount++
      if (ipcDropCount <= 10 || ipcDropCount % 100 === 0) {
        sendLog('ipc-write: dropping video frame, writeBuf=' + ipcWriteLen + ' dropped=' + ipcDropCount)
      }
      return
    }
  }

  const header = Buffer.alloc(4)
  header.writeUInt32BE(payload.length, 0)

  if (ipcWriteChunks.length > 0 || ipcDraining) {
    // Under backpressure or have buffered data — append to our buffer.
    // Don't call write() directly during backpressure to avoid flooding
    // the pipe's internal buffer.
    ipcWriteChunks.push(header, payload)
    ipcWriteLen += 4 + payload.length
    if (!ipcDraining) {
      ipcDraining = true
      ipcPipe.once('drain', _drainIpcWriteBuffer)
    }
    return
  }

  const frame = Buffer.concat([header, payload])
  const ok = ipcPipe.write(frame)
  if (ok === false) {
    // Backpressure: pipe accepted the data but is above its watermark.
    // Do NOT push to ipcWriteChunks — the data is already in the pipe's
    // internal buffer. Pushing it back caused infinite duplication: each
    // drain event re-sent all previously-accepted data, generating hundreds
    // of duplicate IPC frames (352KB × hundreds = jetsam kill).
    if (!ipcDraining) {
      ipcDraining = true
      ipcPipe.once('drain', _drainIpcWriteBuffer)
    }
  }
}

function _drainIpcWriteBuffer () {
  ipcDraining = false
  if (ipcWriteChunks.length === 0) {
    _resumeStreamsIfNeeded()
    return
  }

  // Single concat from array — replaces per-write concat cascade
  const buf = ipcWriteChunks.length === 1
    ? ipcWriteChunks[0]
    : Buffer.concat(ipcWriteChunks, ipcWriteLen)
  ipcWriteChunks = []
  ipcWriteLen = 0

  const ok = ipcPipe.write(buf)
  if (ok === false) {
    // Pipe accepted the data but is still above watermark.
    // Do NOT push buf back — it's already in the pipe's internal buffer.
    // Just stay in backpressure mode so new writes go to our buffer.
    ipcDraining = true
    ipcPipe.once('drain', _drainIpcWriteBuffer)
  } else {
    _resumeStreamsIfNeeded()
  }
}

function _pauseStreams () {
  if (streamsPaused || typeof worklet === 'undefined') return
  streamsPaused = true
  for (const [, peer] of worklet.peers) {
    try { peer.stream.pause() } catch (e) {}
  }
  // Safety net: force-resume after timeout to prevent permanent video freeze.
  // If drain events restore flow sooner, _resumeStreams clears this timer.
  if (streamsPauseTimer) clearTimeout(streamsPauseTimer)
  streamsPauseTimer = setTimeout(() => {
    if (streamsPaused) {
      sendLog('ipc-write: force-resuming streams after ' + STREAM_PAUSE_TIMEOUT + 'ms timeout')
      _resumeStreams()
    }
  }, STREAM_PAUSE_TIMEOUT)
}

function _resumeStreams () {
  if (!streamsPaused || typeof worklet === 'undefined') return
  streamsPaused = false
  if (streamsPauseTimer) { clearTimeout(streamsPauseTimer); streamsPauseTimer = null }
  for (const [, peer] of worklet.peers) {
    try { peer.stream.resume() } catch (e) {}
  }
  sendLog('ipc-write: resumed peer streams')
}

function _resumeStreamsIfNeeded () {
  if (streamsPaused && ipcWriteLen < IPC_RESUME_THRESHOLD) {
    _resumeStreams()
  }
}

function sendLog (msg) {
  sendFrame(MSG.LOG, { message: msg })
}

function sendConnectionStatus (phase, detail) {
  sendFrame(MSG.CONNECTION_STATUS, { phase, detail })
}

// --- Load core modules ---
// Use top-level imports so bare-pack resolves them correctly
const b4a = require('b4a')
const crypto = require('hypercore-crypto')
const Hyperswarm = require('hyperswarm')
const HyperDHT = require('hyperdht')

sendLog('Core modules loaded OK')

const randomBytes = crypto.randomBytes
const discoveryKey = crypto.discoveryKey

// --- Hyperswarm networking ---

const CODE_LENGTH = 12 // 12 BIP39 words
const BIP39_WORDS = require('./lib/bip39-words')

class PeariscopeWorklet {
  constructor () {
    this.swarm = null
    this.keyPair = null
    this.isHosting = false
    this.connectionInfo = null
    this.peers = new Map()
    this.discovery = null
    this._pendingConnection = null
    this.maxPeers = 10
    this._cachedNodes = null
    this._cachedKeyPair = null
    this._dhtNodeReportInterval = null
    this._warmupInterval = null
    this._nextStreamId = 1
  }

  setCachedKeyPair (publicKeyHex, secretKeyHex) {
    try {
      this._cachedKeyPair = {
        publicKey: b4a.from(publicKeyHex, 'hex'),
        secretKey: b4a.from(secretKeyHex, 'hex')
      }
      sendLog('Using cached keypair: ' + publicKeyHex.slice(0, 16) + '...')
    } catch (e) {
      sendLog('Invalid cached keypair: ' + (e.message || e))
      this._cachedKeyPair = null
    }
  }

  setCachedNodes (nodes) {
    this._cachedNodes = nodes
    sendLog('Received ' + nodes.length + ' cached DHT nodes from native')
    // If swarm is already running, add nodes to the DHT
    if (this.swarm && this.swarm.dht) {
      this._injectCachedNodes(nodes)
    }
  }

  _injectCachedNodes (nodes) {
    if (!this.swarm || !this.swarm.dht || !nodes || nodes.length === 0) return
    let added = 0
    for (const node of nodes) {
      if (node.host && node.port && node.host !== '127.0.0.1' && node.host !== '::1') {
        try {
          this.swarm.dht.addNode({ host: node.host, port: node.port })
          added++
        } catch (e) {}
      }
    }
    sendLog('Injected ' + added + '/' + nodes.length + ' cached DHT nodes')
  }

  _startDhtNodeReporting () {
    if (this._dhtNodeReportInterval) return
    // Report DHT routing table nodes to native every 60s for caching
    this._dhtNodeReportInterval = setInterval(() => {
      if (!this.swarm || !this.swarm.dht) return
      try {
        const table = this.swarm.dht.toArray()
        if (table && table.length > 0) {
          const nodes = table.map(n => ({
            host: n.host,
            port: n.port,
            lastSeen: Date.now()
          }))
          sendFrame(MSG.DHT_NODES, { nodes })
        }
      } catch (e) {
        sendLog('DHT node report error: ' + (e.message || e))
      }
    }, 60000)
  }

  async start () {
    if (!crypto || !Hyperswarm) {
      throw new Error('Required modules not loaded (crypto=' + !!crypto + ', Hyperswarm=' + !!Hyperswarm + ')')
    }

    // Reuse cached keypair if available — same identity = same NAT mappings on CGNAT
    if (this._cachedKeyPair && this._cachedKeyPair.publicKey.length === 32 && this._cachedKeyPair.secretKey.length === 64) {
      this.keyPair = this._cachedKeyPair
      sendLog('Reusing cached keypair: ' + b4a.toString(this.keyPair.publicKey, 'hex').slice(0, 16) + '...')
    } else {
      this.keyPair = crypto.keyPair()
      sendLog('Generated new keypair: ' + b4a.toString(this.keyPair.publicKey, 'hex').slice(0, 16) + '...')
      // Send new keypair to native for persistence
      sendFrame(MSG.DHT_NODES, {
        keypair: {
          publicKey: b4a.toString(this.keyPair.publicKey, 'hex'),
          secretKey: b4a.toString(this.keyPair.secretKey, 'hex')
        }
      })
    }

    const dhtOpts = {
      ephemeral: false,
      port: 49800 + Math.floor(Math.random() * 1000),
      // Default randomPunchInterval is 20s with limit 1 — far too conservative for CGNAT.
      // Random punching is critical for symmetric NAT: the holepuncher tries random ports
      // on the remote side to find the NAT mapping. More frequent = faster connection.
      randomPunchInterval: 2000
    }

    // Use Pear sidecar's DHT config if available (running inside pear-runtime).
    // This gives us the sidecar's warm bootstrap/routing nodes — much faster than
    // cold-starting from the 3 default Holepunch nodes on CGNAT networks.
    // Note: In BareKit context neither API is available — these only activate inside pear-runtime.
    if (typeof Pear !== 'undefined' && Pear.app && Pear.app.dht) {
      // Pear v2 API
      const pearDht = Pear.app.dht
      if (pearDht.bootstrap && pearDht.bootstrap.length > 0) {
        dhtOpts.bootstrap = pearDht.bootstrap
        sendLog('Using Pear.app.dht bootstrap: ' + pearDht.bootstrap.length + ' nodes')
      }
      if (pearDht.nodes && pearDht.nodes.length > 0) {
        dhtOpts.nodes = pearDht.nodes
        sendLog('Using Pear.app.dht nodes: ' + pearDht.nodes.length + ' nodes')
      }
    }

    // Add cached remote nodes as routing table seeds (NOT bootstrap).
    // CRITICAL: setting dhtOpts.bootstrap OVERRIDES HyperDHT's default bootstrap
    // nodes (node1/2/3.hyperdht.org:49737). If cached nodes are stale, the DHT
    // can't bootstrap at all — connections take 30-60+ seconds or time out.
    // Use `nodes` instead — these are added to the routing table after bootstrap,
    // speeding up lookups without replacing the reliable default bootstrap.
    if (this._cachedNodes && this._cachedNodes.length > 0) {
      const routingNodes = this._cachedNodes
        .filter(n => n.host && n.port && n.host !== '127.0.0.1' && n.host !== '::1' && n.host !== 'localhost')
        .slice(0, 50)
        .map(n => ({ host: n.host, port: n.port }))
      if (routingNodes.length > 0) {
        if (dhtOpts.bootstrap) {
          // Pear.app.dht bootstrap exists — safe to supplement
          dhtOpts.bootstrap = dhtOpts.bootstrap.concat(routingNodes)
        } else {
          // No Pear bootstrap — add cached nodes as routing table seeds,
          // keep HyperDHT defaults (node1/2/3.hyperdht.org) for bootstrap
          dhtOpts.nodes = (dhtOpts.nodes || []).concat(routingNodes)
        }
        sendLog('Added ' + routingNodes.length + ' cached nodes as routing seeds')
      }
    }
    sendLog('DHT bootstrap: ' + (dhtOpts.bootstrap ? dhtOpts.bootstrap.length + ' custom' : 'defaults') + ', routing nodes: ' + (dhtOpts.nodes ? dhtOpts.nodes.length : 0))

    const dht = new HyperDHT(dhtOpts)
    sendLog('DHT created: ephemeral=false port=' + dhtOpts.port)

    const swarmOpts = {
      keyPair: this.keyPair,
      dht  // pass our pre-configured DHT instance
    }

    // relayThrough: when direct holepunch fails (symmetric NAT/CGNAT),
    // Hyperswarm relays traffic through a DHT node. Without this, connections
    // between two symmetric NAT peers silently hang after peer discovery.
    swarmOpts.relayThrough = (force) => {
      if (!this.swarm || !this.swarm.dht) return null
      if (!force && !this.swarm.dht.randomized) return null
      // CRITICAL: dht.toArray() strips node.id (returns only {host, port}).
      // dht.table.toArray() returns full routing table entries with .id (public key Buffer)
      // which is what relay needs to dht.connect(publicKey) to the relay node.
      const nodes = this.swarm.dht.table.toArray()
      if (nodes.length === 0) return null
      const node = nodes[Math.floor(Math.random() * nodes.length)]
      sendLog('relayThrough: force=' + force + ' picking from ' + nodes.length + ' nodes, id=' + (node.id ? 'yes' : 'MISSING'))
      return node.id || null
    }

    this.swarm = new Hyperswarm(swarmOpts)

    // Force DHT to persistent mode — needed so viewers can find us via DHT
    // even behind a firewall (holepunching/relay handles the actual connection).
    dht.ephemeral = false
    dht.io.ephemeral = false

    // Monkey-patch _randomPunchLimit — hardcoded to 1 in hyperdht 6.29.x.
    // Default limit of 1 means only 1 random punch attempt at a time.
    // On CGNAT/symmetric NAT, we need many concurrent attempts to guess
    // the correct port mapping. Keet's sidecar avoids this because its
    // long-running process has stable NAT mappings; we start fresh each time.
    dht._randomPunchLimit = 20
    sendLog('DHT created: port=' + dhtOpts.port + ' punchLimit=20 punchInterval=2000ms')

    this.swarm.on('connection', (stream, info) => {
      const type = info.client ? 'client' : 'server'
      sendLog('Swarm connection: ' + type + ' remoteKey=' + (info.publicKey ? b4a.toString(info.publicKey, 'hex').slice(0, 16) : 'unknown') + ' relay=' + (stream.relayType || 'none'))
      this._onPeerConnection(stream, info)
    })

    this.swarm.on('update', () => {
      const connecting = this.swarm.connecting || 0
      const firewalled = this.swarm.dht ? (this.swarm.dht.firewalled ? 'yes' : 'no') : '?'
      const randomized = this.swarm.dht ? (this.swarm.dht.randomized ? 'yes' : 'no') : '?'
      sendLog('Swarm update: connections=' + this.swarm.connections.size + ' peers=' + this.swarm.peers.size + ' connecting=' + connecting + ' firewalled=' + firewalled + ' randomized=' + randomized)
    })

    // Log banned peers — these are silently rejected
    this.swarm.on('ban', (peerInfo, err) => {
      sendLog('Swarm BAN: ' + (peerInfo.publicKey ? b4a.toString(peerInfo.publicKey, 'hex').slice(0, 16) : 'unknown') + ' err=' + (err ? err.message : 'none'))
    })

    // Monitor ALL connection attempts from the DHT level — this catches
    // holepunch failures, relay attempts, and error codes that Hyperswarm swallows.
    const origConnect = dht.connect.bind(dht)
    dht.connect = (remotePublicKey, opts) => {
      const keyHex = remotePublicKey ? b4a.toString(remotePublicKey, 'hex').slice(0, 16) : 'unknown'
      sendLog('DHT.connect: peer=' + keyHex + ' relayThrough=' + (opts && opts.relayThrough ? 'yes' : 'no') + ' relayAddrs=' + (opts && opts.relayAddresses ? opts.relayAddresses.length : 0))
      const conn = origConnect(remotePublicKey, opts)
      conn.on('open', () => {
        sendLog('DHT.connect OPEN: peer=' + keyHex + ' relay=' + (conn.relayType || 'direct'))
      })
      conn.on('error', (err) => {
        sendLog('DHT.connect ERROR: peer=' + keyHex + ' code=' + (err.code || 'none') + ' msg=' + (err.message || err))
      })
      conn.on('close', () => {
        sendLog('DHT.connect CLOSE: peer=' + keyHex + ' destroyed=' + conn.destroyed)
      })
      return conn
    }

    // Inject cached nodes into DHT after construction
    if (this._cachedNodes && this._cachedNodes.length > 0) {
      this._injectCachedNodes(this._cachedNodes)
    }

    // Wait for DHT to bootstrap before signaling readiness
    await this.swarm.listen()

    // Log detailed NAT/firewall state after bootstrap
    const addr = dht.remoteAddress()
    sendLog('Hyperswarm listening (DHT bootstrapped)')
    sendLog('NAT state: firewalled=' + dht.firewalled + ' randomized=' + dht.randomized + ' ephemeral=' + dht.ephemeral)
    sendLog('Remote address: ' + (addr ? addr.host + ':' + addr.port : 'unknown'))
    sendLog('DHT port: ' + dht.address().port + ' nodes: ' + dht.toArray().length)

    // Start periodic DHT node reporting for native caching
    this._startDhtNodeReporting()
    // Report initial nodes immediately
    try {
      const table = this.swarm.dht.toArray()
      if (table && table.length > 0) {
        const nodes = table.map(n => ({ host: n.host, port: n.port, lastSeen: Date.now() }))
        sendFrame(MSG.DHT_NODES, { nodes })
        sendLog('Initial DHT report: ' + nodes.length + ' nodes')
      }
    } catch (e) {}
  }

  async startHosting (deviceCode) {
    if (this.isHosting) {
      sendLog('Already hosting, stopping first...')
      this._cleanupHosting()
    }

    if (deviceCode) {
      this.connectionInfo = {
        code: deviceCode,
        token: null,
        topic: this._deriveTopicFromCode(deviceCode)
      }
    } else {
      this.connectionInfo = this._generateConnectionCode()
    }
    const { topic, code } = this.connectionInfo

    sendLog('Starting hosting, code: ' + code)

    this.discovery = this.swarm.join(topic, { server: true, client: false })
    this.isHosting = true

    // Wait for DHT topic announcement to propagate before telling native
    try {
      await this.discovery.flushed()
      sendLog('DHT topic flushed for code: ' + code)
    } catch (err) {
      sendLog('DHT flush error: ' + (err.message || err))
    }

    // Start periodic re-announcement to keep DHT records fresh
    this._startReannounceTimer()

    // Include DHT port so native can advertise it via Bonjour for LAN fast-connect
    const dhtPort = this.swarm && this.swarm.dht ? this.swarm.dht.address().port : 0
    sendFrame(MSG.HOSTING_STARTED, {
      publicKeyHex: b4a.toString(this.keyPair.publicKey, 'hex'),
      connectionCode: code,
      dhtPort
    })
  }

  stopHosting () {
    if (!this.isHosting) return
    this._stopReannounceTimer()
    this._cleanupHosting()
    sendFrame(MSG.HOSTING_STOPPED)
    sendLog('Stopped hosting')
  }

  // Re-announce the hosting topic on the DHT without tearing down the session.
  // Called after sleep/wake, network changes, and periodically to keep the
  // DHT record fresh so viewers can always find the host.
  reannounce () {
    if (!this.isHosting || !this.connectionInfo) return
    const { topic, code } = this.connectionInfo
    sendLog('Re-announcing DHT topic for code: ' + code)
    try {
      this.discovery = this.swarm.join(topic, { server: true, client: false })
      this.discovery.flushed().then(() => {
        sendLog('DHT re-announce flushed for code: ' + code)
      }).catch(err => {
        sendLog('DHT re-announce flush error: ' + (err.message || err))
      })
    } catch (e) {
      sendLog('Re-announce error: ' + (e.message || e))
    }
  }

  _startReannounceTimer () {
    this._stopReannounceTimer()
    // Re-announce every 5 minutes to keep DHT records fresh.
    // DHT nodes can age out records, and network transitions may
    // invalidate the announcement without any error signal.
    this._reannounceInterval = setInterval(() => {
      this.reannounce()
    }, 5 * 60 * 1000)
  }

  _stopReannounceTimer () {
    if (this._reannounceInterval) {
      clearInterval(this._reannounceInterval)
      this._reannounceInterval = null
    }
  }

  _cleanupHosting () {
    sendLog('Cleaning up hosting...')

    try {
      if (this.connectionInfo && this.connectionInfo.topic) {
        this.swarm.leave(this.connectionInfo.topic).catch(() => {})
      }
      if (this.discovery) {
        this.discovery.destroy().catch(() => {})
        this.discovery = null
      }
    } catch (e) {
      sendLog('cleanupHosting error: ' + e.message)
    }

    this.isHosting = false
    this.connectionInfo = null
    sendLog('Cleanup done')
  }

  connectLocalPeer (code, host, port) {
    sendLog('LAN fast-connect: ' + host + ':' + port + ' code=' + code)
    // Inject the host's local address into the DHT routing table so the
    // DHT lookup finds it on the first hop instead of querying remote bootstrap nodes.
    if (this.swarm && this.swarm.dht && host && port) {
      try {
        this.swarm.dht.addNode({ host, port })
        sendLog('Injected local peer node: ' + host + ':' + port)
      } catch (e) {
        sendLog('addNode error: ' + (e.message || e))
      }
    }
    // Now connect normally — DHT will find the host locally
    this.connectToPeer(code)
  }

  connectToPeer (code) {
    sendLog('Connecting with code: ' + code)

    // Leave old viewer topic before joining new one — prevents stale swarm
    // connections from the previous session reconnecting to the wrong peer
    if (this._lastViewerTopic) {
      sendLog('Leaving old viewer topic before connecting to new peer')
      this.swarm.leave(this._lastViewerTopic).catch(() => {})
    }
    // Clean up any pending connection
    if (this._pendingConnection) {
      clearTimeout(this._pendingConnection.timeout)
      clearInterval(this._pendingConnection.statusInterval)
      this._pendingConnection.discovery.destroy().catch(() => {})
      this._pendingConnection = null
    }
    // Disconnect any lingering peers from previous session
    for (const [keyHex, peer] of this.peers) {
      if (!this.isHosting || !this.connectionInfo) {
        sendLog('Cleaning up stale peer: ' + keyHex.slice(0, 16) + '...')
        peer.mux.destroy()
        this.peers.delete(keyHex)
      }
    }

    const topic = this._deriveTopicFromCode(code)
    this._lastViewerTopic = topic
    this._connectionSucceeded = false
    sendConnectionStatus('starting', 'Starting network...')

    // Join the topic ONCE and let Hyperswarm handle holepunch + relay internally.
    // Previous approach: 8 attempts × 15s, each calling swarm.leave() + discovery.destroy().
    // Problem: leave() destroys peerInfo which has forceRelaying=true after a failed holepunch,
    // so the relay fallback never triggers. Hyperswarm needs the peerInfo to survive across
    // its internal retry cycle: holepunch fail → set forceRelaying → retry with relay.
    const discovery = this.swarm.join(topic, { server: false, client: true })
    sendConnectionStatus('searching', 'Searching for host...')

    discovery.flushed().then(() => {
      if (this._connectionSucceeded) return
      sendLog('DHT lookup flushed for code: ' + code)
      sendConnectionStatus('connecting', 'Connecting to host...')
    }).catch((err) => {
      sendLog('DHT lookup flush error: ' + (err.message || err))
    })

    this.swarm.flush().then(() => {
      if (this._connectionSucceeded) return
      sendLog('Swarm flush complete (all connection attempts dispatched)')
    }).catch(() => {})

    // Periodic status logging so we can see holepunch/relay progress
    const startTime = Date.now()
    const statusInterval = setInterval(() => {
      if (this._connectionSucceeded) {
        clearInterval(statusInterval)
        return
      }
      const elapsed = Math.round((Date.now() - startTime) / 1000)
      const swarmInfo = {
        connections: this.swarm.connections.size,
        peers: this.swarm.peers.size,
        connecting: this.swarm.connecting || 0,
        firewalled: this.swarm.dht ? this.swarm.dht.firewalled : '?',
        randomized: this.swarm.dht ? this.swarm.dht.randomized : '?'
      }
      sendLog('Connection status @' + elapsed + 's: ' + JSON.stringify(swarmInfo))
      // Update UI with progress
      if (swarmInfo.connecting > 0) {
        sendConnectionStatus('connecting', 'Holepunching... (' + elapsed + 's)')
      }
    }, 5000)

    // Single overall timeout — long enough for holepunch + relay fallback.
    // Holepunch can take 10-30s, relay setup adds another 10-20s.
    const OVERALL_TIMEOUT = 120000 // 2 minutes
    const timeout = setTimeout(() => {
      if (this._connectionSucceeded) return
      clearInterval(statusInterval)

      sendLog('Connection timed out after ' + (OVERALL_TIMEOUT / 1000) + 's')
      this.swarm.leave(topic).catch(() => {})
      discovery.destroy().catch(() => {})

      sendFrame(MSG.CONNECTION_FAILED, {
        code,
        reason: 'Connection timed out after ' + (OVERALL_TIMEOUT / 1000) + 's'
      })
      this._pendingConnection = null
    }, OVERALL_TIMEOUT)

    this._pendingConnection = { code, timeout, statusInterval, discovery }
  }

  disconnectAllPeers () {
    sendLog('disconnectAllPeers: peers=' + this.peers.size + ' topic=' + (this._lastViewerTopic ? 'yes' : 'no'))
    // Destroy all peer muxers
    for (const [keyHex, peer] of this.peers) {
      peer.mux.destroy()
      sendLog('Disconnected peer: ' + keyHex.slice(0, 16) + '...')
    }
    this.peers.clear()
    // Cancel pending connection attempts
    if (this._pendingConnection) {
      clearTimeout(this._pendingConnection.timeout)
      if (this._pendingConnection.statusInterval) clearInterval(this._pendingConnection.statusInterval)
      this._pendingConnection.discovery.destroy().catch(() => {})
      this._pendingConnection = null
    }
    // Leave the viewer topic so swarm doesn't reconnect
    if (this._lastViewerTopic) {
      this.swarm.leave(this._lastViewerTopic).catch(() => {})
      this._lastViewerTopic = null
    }
    this._connectionSucceeded = false
  }

  disconnectPeer (peerKeyHex) {
    const peer = this.peers.get(peerKeyHex)
    if (peer) {
      peer.mux.destroy()
      this.peers.delete(peerKeyHex)
      sendLog('Disconnected peer: ' + peerKeyHex.slice(0, 16) + '...')
    }

    // Leave the swarm topic so the host doesn't reconnect to us
    if (this._pendingConnection) {
      clearTimeout(this._pendingConnection.timeout)
      if (this._pendingConnection.statusInterval) clearInterval(this._pendingConnection.statusInterval)
      this._pendingConnection.discovery.destroy().catch(() => {})
      this._pendingConnection = null
    }

    // If we have no peers left and we're not hosting, leave all client topics
    if (this.peers.size === 0 && !this.isHosting && this._lastViewerTopic) {
      this.swarm.leave(this._lastViewerTopic).catch(() => {})
      this._lastViewerTopic = null
    }
  }

  forwardStreamData (streamId, channel, data) {
    for (const [, peer] of this.peers) {
      if (peer.streamId === streamId) {
        peer.mux.send(channel, data)
        return
      }
    }
  }

  getStatus () {
    const peers = []
    for (const [keyHex] of this.peers) {
      peers.push({ publicKeyHex: keyHex })
    }
    sendFrame(MSG.STATUS_RESPONSE, {
      isHosting: this.isHosting,
      isConnected: this.peers.size > 0,
      connectionCode: this.connectionInfo ? this.connectionInfo.code : null,
      publicKeyHex: this.keyPair ? b4a.toString(this.keyPair.publicKey, 'hex') : null,
      peers
    })
  }

  _onPeerConnection (stream, info) {
    const remoteKey = info.publicKey
    const keyHex = b4a.toString(remoteKey, 'hex')

    // Reject connections from stale topics. After disconnectAllPeers() or
    // connectToPeer(), _lastViewerTopic is set to the new target. If a
    // lingering in-flight connection from an old topic completes, its shared
    // topics won't include the current viewer topic — destroy it immediately.
    if (this._lastViewerTopic && !this.isHosting && info.topics) {
      const topicHex = b4a.toString(this._lastViewerTopic, 'hex')
      const matchesCurrent = info.topics.some(t => b4a.toString(t, 'hex') === topicHex)
      if (!matchesCurrent) {
        sendLog('Rejecting stale connection from old topic: ' + keyHex.slice(0, 16) + '...')
        stream.destroy()
        return
      }
    }

    // Enforce max peers limit
    if (this.peers.size >= this.maxPeers) {
      sendLog('Max peers reached (' + this.maxPeers + '), rejecting: ' + keyHex.slice(0, 16) + '...')
      stream.destroy()
      return
    }

    sendLog('Peer connected: ' + keyHex.slice(0, 16) + '...')

    const mux = new StreamMux(stream)
    const streamId = this._nextStreamId++

    this.peers.set(keyHex, { stream, mux, info, streamId })

    let ch0count = 0
    let ch0drops = 0
    let ch0total = 0
    // Dual gate: Date.now()-based (33ms interval) with counter fallback.
    // Date.now() may not work in BareKit — if undefined/NaN, `NaN < 33` is false,
    // so the time gate never fires and ALL frames pass. Counter gate catches this:
    // max 1 frame per CH0_SKIP_MIN received frames (burst protection).
    const CH0_INTERVAL = 33
    const CH0_SKIP_MIN = 2 // never forward consecutive frames
    let ch0lastForward = 0
    let ch0sinceLast = 0

    mux.onChannel(0, (data) => {
      ch0total++
      ch0sinceLast++

      // Detect keyframes by inspecting first NAL unit type after Annex B start code.
      // Keyframes MUST never be dropped — missing keyframes cause blocky corruption
      // and frozen regions until the next keyframe arrives (~1 second later).
      // H.265: VPS NAL type = 32 (0x40 >> 1), SPS = 33, PPS = 34, IDR = 19/20
      // H.264: SPS NAL type = 7 (0x67 & 0x1F), IDR = 5
      let isKeyframe = false
      if (data.length >= 5) {
        // Find first NAL unit after start code (0x00 0x00 0x00 0x01 or 0x00 0x00 0x01)
        let nalByte = -1
        if (data[0] === 0 && data[1] === 0 && data[2] === 0 && data[3] === 1) {
          nalByte = data[4]
        } else if (data[0] === 0 && data[1] === 0 && data[2] === 1) {
          nalByte = data[3]
        }
        if (nalByte >= 0) {
          const h265type = (nalByte >> 1) & 0x3F
          const h264type = nalByte & 0x1F
          // H.265 VPS=32, SPS=33, PPS=34, IDR_W_RADL=19, IDR_N_LP=20
          // H.264 SPS=7, PPS=8, IDR=5
          isKeyframe = (h265type >= 32 && h265type <= 34) || h265type === 19 || h265type === 20 ||
                       h264type === 5 || h264type === 7 || h264type === 8
        }
      }

      // Counter gate: always skip if we haven't seen enough frames since last forward
      // BUT never skip keyframes
      if (!isKeyframe && ch0sinceLast < CH0_SKIP_MIN) {
        ch0drops++
        return
      }

      // Time gate: if Date.now() works, enforce minimum interval
      // BUT never gate keyframes
      const now = typeof Date !== 'undefined' && typeof Date.now === 'function' ? Date.now() : 0
      if (!isKeyframe && now > 0 && ch0lastForward > 0 && (now - ch0lastForward) < CH0_INTERVAL) {
        ch0drops++
        return
      }

      ch0sinceLast = 0
      ch0lastForward = now
      ch0count++
      if (ch0count <= 5 || ch0count % 300 === 0) {
        sendLog('ch0 fwd len=' + data.length + ' count=' + ch0count + ' drops=' + ch0drops + ' total=' + ch0total + ' dateNow=' + now)
      }
      sendFrame(MSG.STREAM_DATA_OUT, { streamId, channel: 0 }, data)
    })

    mux.onChannel(1, (data) => {
      sendFrame(MSG.STREAM_DATA_OUT, { streamId, channel: 1 }, data)
    })

    mux.onChannel(2, (data) => {
      sendFrame(MSG.STREAM_DATA_OUT, { streamId, channel: 2 }, data)
    })

    mux.onChannel(3, (data) => {
      sendFrame(MSG.STREAM_DATA_OUT, { streamId, channel: 3 }, data)
    })

    stream.on('close', () => {
      this.peers.delete(keyHex)
      sendFrame(MSG.PEER_DISCONNECTED, {
        peerKeyHex: keyHex,
        reason: 'Stream closed'
      })
      sendLog('Peer disconnected: ' + keyHex.slice(0, 16) + '...')

      if (this.isHosting && this.connectionInfo) {
        const { topic } = this.connectionInfo
        const discovery = this.swarm.join(topic, { server: true, client: false })
        discovery.flushed().catch(() => {})
      }
    })

    stream.on('error', (err) => {
      sendLog('Stream error (' + keyHex.slice(0, 8) + '): ' + err.message)
    })

    // Keep-alive: send a zero-length mux frame on channel 2 every 5s
    // to prevent NAT mappings from expiring and UDX timeouts.
    // Mobile carrier NATs can expire in as little as 10s, so 15s was too slow.
    const keepAlive = setInterval(() => {
      if (stream.destroyed) {
        clearInterval(keepAlive)
        return
      }
      try {
        mux.send(2, Buffer.alloc(0))
      } catch (e) {
        clearInterval(keepAlive)
      }
    }, 5000)

    if (this._pendingConnection) {
      clearTimeout(this._pendingConnection.timeout)
      if (this._pendingConnection.statusInterval) clearInterval(this._pendingConnection.statusInterval)
      this._connectionSucceeded = true
      if (stream.relayType) {
        sendConnectionStatus('relay', 'Connected via relay')
      } else {
        sendConnectionStatus('connected', 'Direct connection established')
      }
      sendFrame(MSG.CONNECTION_ESTABLISHED, {
        peerKeyHex: keyHex,
        streamId
      })
      this._pendingConnection = null
    }

    sendFrame(MSG.PEER_CONNECTED, {
      peerKeyHex: keyHex,
      peerName: '',
      streamId
    })
  }

  _generateConnectionCode () {
    // Generate 12 random BIP39 words (11 bits each = 132 bits entropy)
    const entropy = randomBytes(17) // 136 bits, we use 132
    const words = []
    let bitPos = 0
    for (let i = 0; i < CODE_LENGTH; i++) {
      // Extract 11 bits for each word index (0-2047)
      const byteIndex = Math.floor(bitPos / 8)
      const bitOffset = bitPos % 8
      // Read up to 3 bytes to get 11 bits
      const val = ((entropy[byteIndex] << 16) |
                   ((entropy[byteIndex + 1] || 0) << 8) |
                   (entropy[byteIndex + 2] || 0)) >> (24 - bitOffset - 11)
      words.push(BIP39_WORDS[val & 0x7FF])
      bitPos += 11
    }
    const code = words.join(' ')
    return {
      code,
      token: entropy,
      topic: this._deriveTopicFromCode(code)
    }
  }

  async lookupPeer (code) {
    if (!this.swarm) {
      sendFrame(MSG.LOOKUP_RESULT, { code, online: false })
      return
    }
    const topic = this._deriveTopicFromCode(code)
    sendLog('lookupPeer: probing code: ' + code)
    try {
      // Use the raw DHT to look up peers announcing this topic.
      // This does NOT initiate a connection — just queries the DHT.
      const dht = this.swarm.dht
      let found = false
      const lookup = dht.lookup(topic)
      const timer = setTimeout(() => { lookup.destroy() }, 8000)
      for await (const result of lookup) {
        if (result.peers && result.peers.length > 0) {
          found = true
          break
        }
      }
      clearTimeout(timer)
      sendFrame(MSG.LOOKUP_RESULT, { code, online: found })
      sendLog('lookupPeer: ' + code + ' online=' + found)
    } catch (e) {
      sendFrame(MSG.LOOKUP_RESULT, { code, online: false })
      sendLog('lookupPeer: error for ' + code + ': ' + (e.message || e))
    }
  }

  _deriveTopicFromCode (code) {
    // Normalize: lowercase, collapse whitespace, trim
    const normalized = code.toLowerCase().trim().replace(/\s+/g, ' ')
    return crypto.data(Buffer.from('peariscope:' + normalized))
  }

}

// --- Stream Multiplexer ---

const CHANNEL_HEADER_SIZE = 5

class StreamMux {
  constructor (stream) {
    this.stream = stream
    this.handlers = new Map()
    this._recvBuf = Buffer.alloc(0)
    this._pendingChunks = []
    this._pendingLen = 0
    this._drainScheduled = false

    this._streamPaused = false

    this._bytesReceived = 0
    this._bytesReceivedStart = Date.now()

    stream.on('data', (chunk) => {
      // Collect chunks without Buffer.concat — concat on every data event
      // created a new Buffer each time, causing V8 GC pressure of hundreds
      // of MB/sec during burst delivery. Chunks are merged in _drainFrames.
      this._pendingChunks.push(chunk)
      this._pendingLen += chunk.length
      this._bytesReceived += chunk.length

      // Safety cap: when pending data exceeds 2MB, merge into _recvBuf and
      // skip complete frames to maintain framing alignment. Previous approach
      // cleared _recvBuf which lost frame boundaries — subsequent data started
      // mid-frame, causing StreamMux to misparse arbitrary bytes as channel/length,
      // generating thousands of phantom frames on ch1/ch2 (no rate gate) that
      // flooded IPC and caused 650MB/sec V8 allocation pressure.
      if (this._pendingLen > 2000000) {
        // Merge pending into _recvBuf to maintain frame alignment
        if (this._recvBuf.length > 0) {
          this._pendingChunks.unshift(this._recvBuf)
          this._pendingLen += this._recvBuf.length
        }
        this._recvBuf = this._pendingChunks.length === 1
          ? this._pendingChunks[0]
          : Buffer.concat(this._pendingChunks, this._pendingLen)
        this._pendingChunks = []
        this._pendingLen = 0
        // Skip complete frames to reduce buffer (maintaining frame alignment)
        let skipped = 0
        while (this._recvBuf.length >= CHANNEL_HEADER_SIZE) {
          const length = this._recvBuf.readUInt32BE(1)
          if (length > 1000000) {
            // Corrupt frame — must clear and accept framing loss
            this._recvBuf = Buffer.alloc(0)
            break
          }
          if (this._recvBuf.length < CHANNEL_HEADER_SIZE + length) break
          this._recvBuf = this._recvBuf.subarray(CHANNEL_HEADER_SIZE + length)
          skipped++
        }
        sendLog('StreamMux: overflow, skipped ' + skipped + ' frames, recvBuf=' + this._recvBuf.length)
        // Pause stream to reduce incoming data rate
        if (!this._streamPaused) {
          this._streamPaused = true
          this.stream.pause()
          setTimeout(() => {
            this._streamPaused = false
            if (!this.stream.destroyed) this.stream.resume()
          }, 50)
        }
        return
      }

      // Defer drain to batch multiple data events from the same tick into
      // one Buffer.concat. During burst delivery, dozens of data events fire
      // before the event loop yields — without deferral, each triggers a
      // separate concat + drain cycle.
      if (!this._drainScheduled) {
        this._drainScheduled = true
        setTimeout(() => {
          this._drainScheduled = false
          this._drainFrames()
        }, 0)
      }
    })
  }

  onChannel (channel, handler) {
    this.handlers.set(channel, handler)
  }

  send (channel, data) {
    const frame = Buffer.alloc(CHANNEL_HEADER_SIZE + data.length)
    frame.writeUInt8(channel, 0)
    frame.writeUInt32BE(data.length, 1)
    Buffer.from(data).copy(frame, CHANNEL_HEADER_SIZE)
    this.stream.write(frame)
  }

  _drainFrames () {
    // Merge pending chunks into _recvBuf (one concat per drain, not per data event)
    if (this._pendingChunks.length > 0) {
      if (this._recvBuf.length > 0) {
        this._pendingChunks.unshift(this._recvBuf)
        this._pendingLen += this._recvBuf.length
      }
      // Optimize: single chunk doesn't need concat
      if (this._pendingChunks.length === 1) {
        this._recvBuf = this._pendingChunks[0]
      } else {
        this._recvBuf = Buffer.concat(this._pendingChunks, this._pendingLen)
      }
      this._pendingChunks = []
      this._pendingLen = 0
    }

    // Safety cap: if recvBuf exceeds 1MB, skip complete frames to reduce size
    // while maintaining frame alignment. Clearing the buffer loses framing —
    // subsequent data starts mid-frame, causing phantom frame generation.
    if (this._recvBuf.length > 1000000) {
      let skipped = 0
      while (this._recvBuf.length > 100000 && this._recvBuf.length >= CHANNEL_HEADER_SIZE) {
        const length = this._recvBuf.readUInt32BE(1)
        if (length > 1000000) {
          this._recvBuf = Buffer.alloc(0)
          break
        }
        if (this._recvBuf.length < CHANNEL_HEADER_SIZE + length) break
        this._recvBuf = this._recvBuf.subarray(CHANNEL_HEADER_SIZE + length)
        skipped++
      }
      sendLog('StreamMux: recvBuf overflow, skipped ' + skipped + ' frames, remaining=' + this._recvBuf.length)
      if (!this._streamPaused) {
        this._streamPaused = true
        this.stream.pause()
        setTimeout(() => {
          this._streamPaused = false
          if (!this.stream.destroyed) {
            this.stream.resume()
            sendLog('StreamMux: resumed stream after overflow')
          }
        }, 100)
      }
      return
    }
    // Process ALL available frames per drain call without yielding.
    // Previous approach yielded every 500 frames via setTimeout(0) "to let
    // Date.now() update for the ch0 gate". But setTimeout(0) fires in <1ms,
    // and each tick allows 1 frame through the 16ms ch0 gate — resulting in
    // ~1000 frames/sec passing the gate instead of 62.5. Each frame creates
    // ~19 IPC chunks with Buffer.alloc(), causing ~900MB/sec V8 heap pressure.
    // Without yielding, Date.now() still advances within the synchronous loop
    // (V8 reads the system clock on each call), but only ~1 frame per 16ms
    // passes — the correct rate. Processing 100K dropped frames synchronously
    // takes ~10-50ms (just Date.now() + comparison + return per frame).
    while (this._recvBuf.length >= CHANNEL_HEADER_SIZE) {
      const channel = this._recvBuf.readUInt8(0)
      const length = this._recvBuf.readUInt32BE(1)
      if (length > 1000000) {
        sendLog('StreamMux: corrupt frame length=' + length + ', resetting buffer')
        this._recvBuf = Buffer.alloc(0)
        return
      }
      if (this._recvBuf.length < CHANNEL_HEADER_SIZE + length) break
      const payload = this._recvBuf.subarray(CHANNEL_HEADER_SIZE, CHANNEL_HEADER_SIZE + length)
      this._recvBuf = this._recvBuf.subarray(CHANNEL_HEADER_SIZE + length)
      const handler = this.handlers.get(channel)
      if (handler) handler(payload)
    }
  }

  destroy () {
    this.stream.destroy()
    this.handlers.clear()
  }
}

// --- Message handler ---

function handleFrame (frame) {
  if (frame.length < 1) return
  const type = frame.readUInt8(0)
  const rest = frame.subarray(1)

  switch (type) {
    case MSG.START_HOSTING: {
      sendLog('handleFrame: START_HOSTING received')
      let deviceCode = null
      if (rest.length > 0) {
        try {
          const json = JSON.parse(rest.toString())
          deviceCode = json.deviceCode || null
        } catch (e) {}
      }
      worklet.startHosting(deviceCode).catch((e) => sendLog('startHosting error: ' + e.message))
      break
    }

    case MSG.STOP_HOSTING:
      sendLog('handleFrame: STOP_HOSTING received')
      try { worklet.stopHosting() } catch (e) { sendLog('stopHosting error: ' + e.message) }
      break

    case MSG.CONNECT_TO_PEER: {
      try {
        const json = JSON.parse(rest.toString())
        worklet.connectToPeer(json.code)
      } catch (e) {
        sendLog('CONNECT_TO_PEER: JSON parse error: ' + (e.message || e))
      }
      break
    }

    case MSG.CONNECT_LOCAL_PEER: {
      try {
        const json = JSON.parse(rest.toString())
        worklet.connectLocalPeer(json.code, json.host, json.port)
      } catch (e) {
        sendLog('CONNECT_LOCAL_PEER: JSON parse error: ' + (e.message || e))
      }
      break
    }

    case MSG.DISCONNECT: {
      try {
        const json = JSON.parse(rest.toString())
        if (json.peerKeyHex === '*') {
          worklet.disconnectAllPeers()
        } else {
          worklet.disconnectPeer(json.peerKeyHex)
        }
      } catch (e) {
        sendLog('DISCONNECT: JSON parse error: ' + (e.message || e))
      }
      break
    }

    case MSG.STREAM_DATA: {
      if (rest.length < 7) break
      const streamId = rest.readUInt32BE(0)
      const channel = rest.readUInt8(4)
      const totalChunks = rest.readUInt16BE(5)

      if (totalChunks === 0) {
        // Unchunked: data starts after 7-byte header
        const data = rest.subarray(7)
        if (!handleFrame._sdCount) handleFrame._sdCount = 0
        handleFrame._sdCount++
        if (handleFrame._sdCount <= 5 || handleFrame._sdCount % 300 === 0) {
          sendLog('fwd streamId=' + streamId + ' ch=' + channel + ' len=' + data.length + ' peers=' + worklet.peers.size + ' count=' + handleFrame._sdCount)
        }
        worklet.forwardStreamData(streamId, channel, data)
      } else {
        // Chunked: reassemble before forwarding
        if (rest.length < 9) break
        const chunkIndex = rest.readUInt16BE(7)
        const chunkData = rest.subarray(9)

        if (!handleFrame._chunkBuf) handleFrame._chunkBuf = {}
        const key = streamId + ':' + channel
        if (chunkIndex === 0) {
          handleFrame._chunkBuf[key] = { total: totalChunks, chunks: new Array(totalChunks), received: 0, size: 0 }
        }
        const buf = handleFrame._chunkBuf[key]
        if (buf && chunkIndex < buf.total && !buf.chunks[chunkIndex]) {
          buf.chunks[chunkIndex] = chunkData
          buf.received++
          buf.size += chunkData.length

          if (buf.received === buf.total) {
            // All chunks received, reassemble and forward
            const assembled = Buffer.concat(buf.chunks)
            delete handleFrame._chunkBuf[key]

            if (!handleFrame._sdCount) handleFrame._sdCount = 0
            handleFrame._sdCount++
            if (handleFrame._sdCount <= 5 || handleFrame._sdCount % 300 === 0) {
              sendLog('fwd-chunked streamId=' + streamId + ' ch=' + channel + ' len=' + assembled.length + ' chunks=' + totalChunks + ' peers=' + worklet.peers.size + ' count=' + handleFrame._sdCount)
            }
            worklet.forwardStreamData(streamId, channel, assembled)
          }
        }
      }
      break
    }

    case MSG.STATUS_REQUEST:
      worklet.getStatus()
      break

    case MSG.LOOKUP_PEER: {
      try {
        const json = JSON.parse(rest.toString())
        worklet.lookupPeer(json.code).catch((e) => sendLog('lookupPeer error: ' + e.message))
      } catch (e) {
        sendLog('LOOKUP_PEER: JSON parse error: ' + (e.message || e))
      }
      break
    }

    case MSG.CACHED_DHT_NODES: {
      try {
        const json = JSON.parse(rest.toString())
        if (json.nodes && Array.isArray(json.nodes)) {
          worklet.setCachedNodes(json.nodes)
        }
        // Accept cached keypair for identity persistence
        if (json.keypair && json.keypair.publicKey && json.keypair.secretKey) {
          worklet.setCachedKeyPair(json.keypair.publicKey, json.keypair.secretKey)
        }
      } catch (e) {
        sendLog('CACHED_DHT_NODES parse error: ' + (e.message || e))
      }
      break
    }

    case MSG.SUSPEND: {
      sendLog('SUSPEND received')
      if (worklet.swarm) {
        // Use Hyperswarm's native suspend — properly disconnects all peers,
        // stops discovery, and preserves state for fast resume.
        // Previous implementation only paused individual streams.
        worklet.swarm.suspend().then(() => {
          sendLog('Swarm suspended')
        }).catch(e => {
          sendLog('Swarm suspend error: ' + (e.message || e))
        })
      }
      break
    }

    case MSG.RESUME: {
      sendLog('RESUME received')
      if (worklet.swarm) {
        // Use Hyperswarm's native resume — reconnects peers and resumes discovery.
        worklet.swarm.resume().then(() => {
          sendLog('Swarm resumed')
          // Re-announce hosting topic after resume — swarm.resume() does NOT
          // re-announce topics automatically, so the host becomes invisible on DHT.
          worklet.reannounce()
        }).catch(e => {
          sendLog('Swarm resume error: ' + (e.message || e))
        })
      }
      break
    }

    case MSG.REANNOUNCE: {
      sendLog('REANNOUNCE received')
      worklet.reannounce()
      break
    }

    case MSG.APPROVE_PEER: {
      try {
        const json = JSON.parse(rest.toString())
        sendLog('APPROVE_PEER: ' + (json.peerKeyHex || '').slice(0, 16) + '...')
        // Currently no-op — peer approval is handled at the native layer.
        // Placeholder for future peer gating at the worklet level.
      } catch (e) {}
      break
    }

    default:
      sendLog('Unknown message type: 0x' + type.toString(16))
  }
}

// --- Main ---

const worklet = new PeariscopeWorklet()

worklet.start().then(() => {
  sendLog('Peariscope worklet ready ' + WORKLET_VERSION)
}).catch((err) => {
  sendLog('Start error: ' + err.message)
  sendFrame(MSG.ERROR, { message: 'Failed to start: ' + err.message })
})

// Handle push messages from native (alternative to IPC)
if (typeof Bare !== 'undefined') {
  Bare.on('push', (data, reply) => {
    const msg = data.toString()
    reply(Buffer.from('pong:' + msg))
  })

  Bare.on('suspend', () => {
    sendLog('Worklet suspended')
    if (ipcPipe) ipcPipe.unref()
  })

  Bare.on('resume', () => {
    sendLog('Worklet resumed')
    if (ipcPipe) ipcPipe.ref()
  })
}
