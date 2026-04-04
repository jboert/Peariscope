import Hyperswarm from 'hyperswarm'
import crypto from 'hypercore-crypto'
import b4a from 'b4a'
import protobuf from 'protobufjs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { IpcBridge, getLocalIP } from './lib/ipc.js'
import { generateConnectionCode, deriveTopicFromCode, deriveTopicFromKey } from './lib/discovery.js'
import { StreamMux, Channel } from './lib/stream-mux.js'

const __dirname = typeof import.meta.dirname !== 'undefined'
  ? import.meta.dirname
  : path.dirname(fileURLToPath(import.meta.url))
import os from 'node:os'
import fs from 'node:fs'

const platform = typeof Bare !== 'undefined' ? Bare.platform : (typeof process !== 'undefined' ? process.platform : 'unknown')
const isWindows = platform === 'win32'
const IPC_SOCKET = (typeof process !== 'undefined' && process.env && process.env.PEARISCOPE_IPC_SOCKET) ||
  (isWindows ? '\\\\.\\pipe\\peariscope' : (() => {
    const appDir = path.join(os.homedir(), 'Library', 'Application Support', 'Peariscope')
    try { fs.mkdirSync(appDir, { recursive: true }) } catch {}
    return path.join(appDir, 'peariscope.sock')
  })())

class PeariscopeNetwork {
  constructor () {
    this.swarm = null
    this.ipc = new IpcBridge(IPC_SOCKET)
    this.proto = null
    this.IpcMessage = null

    // State
    this.keyPair = null
    this.isHosting = false
    this.connectionInfo = null // { code, token, topic }
    this.peers = new Map()     // peerKey hex -> { stream, mux, info }
    this.discovery = null      // active discovery session
    this.maxPeers = 10         // Maximum concurrent viewers
  }

  async start () {
    // Load protobuf definitions
    this.proto = await protobuf.load(path.join(__dirname, '..', 'protocol', 'messages.proto'))
    this.IpcMessage = this.proto.lookupType('peariscope.IpcMessage')

    // Generate or load key pair
    this.keyPair = crypto.keyPair()
    console.log('[pear] Public key:', b4a.toString(this.keyPair.publicKey, 'hex').slice(0, 16) + '...')

    // Initialize Hyperswarm with relay support for NAT traversal
    this.swarm = new Hyperswarm({
      keyPair: this.keyPair,
      relayThrough: (force) => {
        if (force) {
          console.log('[pear] Hole-punching failed, attempting relay through DHT node')
          return this.swarm.dht.findNode(this.keyPair.publicKey)
        }
        return null
      }
    })

    this.swarm.on('connection', (stream, info) => {
      this._onPeerConnection(stream, info)
    })

    // Start IPC server and wait for native app to connect
    await this.ipc.listen()
    console.log('[pear] IPC listening on', IPC_SOCKET)

    // Start TCP server for remote clients (iOS)
    this.tcpPort = await this.ipc.listenTcp(9880)
    this.localIP = getLocalIP()
    console.log('[pear] TCP relay at', this.localIP + ':' + this.tcpPort)

    this.ipc.on('connected', (client) => {
      console.log('[pear] Client connected via IPC')
    })

    this.ipc.on('message', (buf, client) => {
      this._handleIpcMessage(buf, client)
    })

    this.ipc.on('disconnected', (client) => {
      console.log('[pear] Client disconnected')
      // Clean up relay client if it was one
      if (this._relayClients && this._relayClients.has(client)) {
        const info = this._relayClients.get(client)
        this._relayClients.delete(client)
        // Notify host native app that the relay peer disconnected
        const peerKey = Buffer.alloc(32)
        this._sendIpc(0, 'peerDisconnected', {
          peerKey: Uint8Array.from(peerKey),
          reason: 'Relay client disconnected'
        })
        console.log('[pear] Relay viewer disconnected, streamId:', info.streamId)
      }
    })
  }

  _handleIpcMessage (buf, client) {
    let msg
    try {
      msg = this.IpcMessage.decode(buf)
    } catch (err) {
      console.error('[pear] Failed to decode IPC message:', err.message)
      return
    }

    const payload = msg.payload
    switch (payload) {
      case 'startHosting':
        this._startHosting(msg.id, msg.startHosting, client)
        break
      case 'stopHosting':
        this._stopHosting(msg.id, client)
        break
      case 'connectToPeer':
        this._connectToPeer(msg.id, msg.connectToPeer, client)
        break
      case 'disconnect':
        this._disconnectPeer(msg.id, msg.disconnect)
        break
      case 'streamData':
        this._forwardStreamData(msg.streamData, client)
        break
      case 'statusRequest':
        this._handleStatusRequest(msg.id, client)
        break
      default:
        console.warn('[pear] Unknown IPC message type:', payload)
    }
  }

  async _startHosting (reqId, _msg, client) {
    if (this.isHosting) return

    this.connectionInfo = generateConnectionCode(this.keyPair.publicKey)
    const { topic, code } = this.connectionInfo

    console.log('[pear] Starting hosting, connection code:', code)

    // Join the topic so viewers can find us
    this.discovery = this.swarm.join(topic, { server: true, client: false })
    this.isHosting = true

    // Notify native app immediately (don't wait for DHT flush)
    this._sendIpc(reqId, 'hostingStarted', {
      publicKey: Uint8Array.from(this.keyPair.publicKey),
      connectionCode: code,
      relayHost: this.localIP,
      relayPort: this.tcpPort
    }, client)

    // Flush in background — peers can start connecting once this completes
    await this.discovery.flushed()
    console.log('[pear] DHT topic flushed for code:', code)

    // Also join persistent topic for trusted devices
    const persistentTopic = deriveTopicFromKey(this.keyPair.publicKey)
    this.swarm.join(persistentTopic, { server: true, client: false })
  }

  async _stopHosting (reqId, client) {
    if (!this.isHosting) return

    this.isHosting = false
    this.connectionInfo = null

    // Respond immediately
    this._sendIpc(reqId, 'hostingStopped', {}, client)
    console.log('[pear] Stopped hosting')

    // Clean up discovery in background
    if (this.discovery) {
      this.discovery.destroy().catch(() => {})
      this.discovery = null
    }
  }

  async _connectToPeer (reqId, msg, client) {
    const code = msg.connectionCode
    console.log('[pear] Connecting with code:', code)

    // If we're hosting with this code and the request comes from a remote (TCP) client,
    // treat the TCP connection as a direct relay peer — no DHT needed
    if (this.isHosting && this.connectionInfo && this.connectionInfo.code === code && client) {
      console.log('[pear] Relay viewer connected for hosted code:', code)
      const streamId = this.peers.size + 100 // offset to avoid collision with P2P peers
      const relayPeerKey = Buffer.alloc(32)
      crypto.randomBytes(32).copy(relayPeerKey)
      const keyHex = relayPeerKey.toString('hex')

      this._relayClients = this._relayClients || new Map()
      this._relayClients.set(client, { streamId, keyHex })

      // Notify host native app of new peer
      this._sendIpc(0, 'peerConnected', {
        peerKey: Uint8Array.from(relayPeerKey),
        peerName: 'relay-viewer',
        streamId
      })

      // Tell the relay client the connection is established
      this._sendIpc(reqId, 'connectionEstablished', {
        peerKey: Uint8Array.from(this.keyPair.publicKey),
        streamId: 1 // the relay client sees host as stream 1
      }, client)

      // Also send peerConnected to the relay client
      this._sendIpc(0, 'peerConnected', {
        peerKey: Uint8Array.from(this.keyPair.publicKey),
        peerName: 'host',
        streamId: 1
      }, client)

      return
    }

    this._connectAttempt(reqId, code, client, 1)
  }

  _connectAttempt (reqId, code, client, attempt) {
    const maxAttempts = 3
    const timeoutMs = 45000

    console.log(`[pear] Connection attempt ${attempt}/${maxAttempts} for code: ${code}`)

    const topic = deriveTopicFromCode(code)
    const discovery = this.swarm.join(topic, { server: false, client: true })
    discovery.flushed().then(() => {
      console.log(`[pear] DHT lookup flushed for code: ${code} (attempt ${attempt})`)
    })

    const timeout = setTimeout(() => {
      discovery.destroy().catch(() => {})

      if (attempt < maxAttempts && !this._connectionSucceeded) {
        console.log(`[pear] Attempt ${attempt} timed out, retrying...`)
        this._connectAttempt(reqId, code, client, attempt + 1)
      } else {
        this._sendIpc(reqId, 'connectionFailed', {
          connectionCode: code,
          reason: `Connection timed out after ${maxAttempts} attempts`
        }, client)
        this._pendingConnection = null
      }
    }, timeoutMs)

    this._connectionSucceeded = false
    this._pendingConnection = { reqId, code, timeout, discovery, client }
  }

  _disconnectPeer (reqId, msg) {
    const keyHex = b4a.toString(msg.peerKey, 'hex')
    const peer = this.peers.get(keyHex)
    if (peer) {
      peer.mux.destroy()
      this.peers.delete(keyHex)
      console.log('[pear] Disconnected peer:', keyHex.slice(0, 16) + '...')
    }
  }

  _onPeerConnection (stream, info) {
    const remoteKey = info.publicKey
    const keyHex = b4a.toString(remoteKey, 'hex')

    // Enforce max peers limit
    if (this.peers.size >= this.maxPeers) {
      console.log('[pear] Max peers reached (' + this.maxPeers + '), rejecting:', keyHex.slice(0, 16) + '...')
      stream.destroy()
      return
    }

    console.log('[pear] Peer connected:', keyHex.slice(0, 16) + '...')

    const mux = new StreamMux(stream)
    const streamId = this.peers.size + 1

    this.peers.set(keyHex, { stream, mux, info, streamId })

    // Forward video data from peer to native app
    mux.onChannel(Channel.VIDEO, (data) => {
      this._sendIpc(0, 'streamData', {
        streamId,
        channel: 0, // VIDEO
        data
      })
    })

    // Forward input events from peer to native app
    mux.onChannel(Channel.INPUT, (data) => {
      this._sendIpc(0, 'streamData', {
        streamId,
        channel: 1, // INPUT
        data
      })
    })

    // Forward control messages from peer to native app
    mux.onChannel(Channel.CONTROL, (data) => {
      this._sendIpc(0, 'streamData', {
        streamId,
        channel: 2, // CONTROL
        data
      })
    })

    // Handle stream close
    stream.on('close', () => {
      this.peers.delete(keyHex)
      this._sendIpc(0, 'peerDisconnected', {
        peerKey: Uint8Array.from(remoteKey),
        reason: 'Stream closed'
      })
      console.log('[pear] Peer disconnected:', keyHex.slice(0, 16) + '...')

      // Re-announce topics so reconnecting peers can find us
      if (this.isHosting && this.connectionInfo) {
        const { topic } = this.connectionInfo
        const discovery = this.swarm.join(topic, { server: true, client: false })
        discovery.flushed().catch(() => {})
      }
    })

    stream.on('error', (err) => {
      console.error('[pear] Stream error:', err.message)
    })

    // Resolve pending connection if this is an outbound connection
    if (this._pendingConnection) {
      clearTimeout(this._pendingConnection.timeout)
      this._connectionSucceeded = true
      this._sendIpc(this._pendingConnection.reqId, 'connectionEstablished', {
        peerKey: Uint8Array.from(remoteKey),
        streamId
      }, this._pendingConnection.client)
      this._pendingConnection = null
    }

    // Notify native app
    this._sendIpc(0, 'peerConnected', {
      peerKey: Uint8Array.from(remoteKey),
      peerName: '',
      streamId
    })
  }

  _forwardStreamData (msg, client) {
    // Check relay clients first
    if (this._relayClients) {
      // If data is from the host native app, forward to the matching relay client
      for (const [relayClient, info] of this._relayClients) {
        if (info.streamId === msg.streamId) {
          // Forward to relay client, remapping streamId to 1 (how the client sees the host)
          this._sendIpc(0, 'streamData', {
            streamId: 1,
            channel: msg.channel,
            data: msg.data
          }, relayClient)
          return
        }
      }

      // If data is from a relay client, forward to host native app
      if (client) {
        const relayInfo = this._relayClients.get(client)
        if (relayInfo) {
          this._sendIpc(0, 'streamData', {
            streamId: relayInfo.streamId,
            channel: msg.channel,
            data: msg.data
          })
          return
        }
      }
    }

    // Fall through to P2P peers
    for (const [, peer] of this.peers) {
      if (peer.streamId === msg.streamId) {
        peer.mux.send(msg.channel, msg.data)
        return
      }
    }
  }

  _handleStatusRequest (reqId, client) {
    const peers = []
    for (const [keyHex, peer] of this.peers) {
      peers.push({
        publicKey: b4a.from(keyHex, 'hex'),
        name: '',
        rttMs: 0
      })
    }

    this._sendIpc(reqId, 'statusResponse', {
      isHosting: this.isHosting,
      isConnected: this.peers.size > 0,
      connectedPeers: peers
    }, client)
  }

  _sendIpc (id, type, payload, client) {
    const msgObj = { id }
    msgObj[type] = payload

    const err = this.IpcMessage.verify(msgObj)
    if (err) {
      console.error('[pear] Proto verification error:', err)
      return
    }

    const msg = this.IpcMessage.create(msgObj)
    const buf = this.IpcMessage.encode(msg).finish()
    try {
      if (client) {
        this.ipc.sendTo(client, Buffer.from(buf))
      } else {
        // Broadcast to all, excluding relay clients (they get targeted messages)
        this.ipc.send(Buffer.from(buf), this._relayClients ? new Set(this._relayClients.keys()) : null)
      }
    } catch (e) {
      console.error('[pear] IPC send error:', e.message)
    }
  }
}

// --- Main ---

const network = new PeariscopeNetwork()
network.start().catch((err) => {
  console.error('[pear] Fatal error:', err)
  if (typeof process !== 'undefined') process.exit(1)
})

// Graceful shutdown — Pear lifecycle or process signals
if (typeof Pear !== 'undefined') {
  Pear.teardown(async () => {
    console.log('[pear] Pear.teardown: cleaning up...')
    if (network.swarm) await network.swarm.destroy()
    await network.ipc.close()
  })
} else if (typeof process !== 'undefined') {
  process.on('SIGINT', async () => {
    console.log('[pear] Shutting down...')
    if (network.swarm) await network.swarm.destroy()
    await network.ipc.close()
    process.exit(0)
  })
}
