import net from 'node:net'
import os from 'node:os'
import { EventEmitter } from 'node:events'

const HEADER_SIZE = 4 // uint32 length prefix

/**
 * IPC bridge using Unix domain socket (macOS/Linux) or named pipe (Windows).
 * Also supports a TCP server for remote clients (e.g. iOS).
 * Speaks length-prefixed protobuf frames.
 * Supports multiple simultaneous clients — messages are broadcast to all.
 */
export class IpcBridge extends EventEmitter {
  constructor (socketPath) {
    super()
    this.socketPath = socketPath
    this.server = null
    this.tcpServer = null
    this.tcpPort = null
    this.clients = new Set()
  }

  /** Start as IPC server (native app connects to us) */
  async listen () {
    // Clean up stale socket file
    const fs = await import('node:fs')
    try { fs.unlinkSync(this.socketPath) } catch {}

    return new Promise((resolve, reject) => {
      this.server = net.createServer((socket) => {
        this._addClient(socket)
      })

      this.server.on('error', (err) => {
        this.emit('error', err)
        reject(err)
      })

      this.server.listen(this.socketPath, () => {
        resolve()
      })
    })
  }

  /** Start TCP server for remote clients (iOS) */
  async listenTcp (port = 0) {
    return new Promise((resolve, reject) => {
      this.tcpServer = net.createServer((socket) => {
        console.log('[ipc] Remote client connected from', socket.remoteAddress)
        this._addClient(socket)
      })

      this.tcpServer.on('error', (err) => {
        this.emit('error', err)
        reject(err)
      })

      this.tcpServer.listen(port, '0.0.0.0', () => {
        this.tcpPort = this.tcpServer.address().port
        console.log('[ipc] TCP server listening on port', this.tcpPort)
        resolve(this.tcpPort)
      })
    })
  }

  _addClient (socket) {
    const client = { socket, recvBuf: Buffer.alloc(0) }
    this.clients.add(client)

    socket.on('data', (chunk) => {
      client.recvBuf = Buffer.concat([client.recvBuf, chunk])
      this._drainFrames(client)
    })

    socket.on('close', () => {
      this.clients.delete(client)
      this.emit('disconnected', client)
    })

    socket.on('error', (err) => {
      this.emit('error', err)
    })

    this.emit('connected', client)
  }

  _drainFrames (client) {
    while (client.recvBuf.length >= HEADER_SIZE) {
      const frameLen = client.recvBuf.readUInt32BE(0)
      if (client.recvBuf.length < HEADER_SIZE + frameLen) break

      const frame = client.recvBuf.subarray(HEADER_SIZE, HEADER_SIZE + frameLen)
      client.recvBuf = client.recvBuf.subarray(HEADER_SIZE + frameLen)
      this.emit('message', frame, client)
    }
  }

  /** Send a protobuf-encoded buffer to all connected clients, optionally excluding some */
  send (buf, exclude) {
    const header = Buffer.alloc(HEADER_SIZE)
    header.writeUInt32BE(buf.length, 0)
    for (const client of this.clients) {
      if (exclude && exclude.has(client)) continue
      try {
        client.socket.write(header)
        client.socket.write(buf)
      } catch {}
    }
  }

  /** Send to a specific client */
  sendTo (client, buf) {
    const header = Buffer.alloc(HEADER_SIZE)
    header.writeUInt32BE(buf.length, 0)
    try {
      client.socket.write(header)
      client.socket.write(buf)
    } catch {}
  }

  async close () {
    for (const client of this.clients) {
      client.socket.destroy()
    }
    this.clients.clear()
    if (this.server) {
      this.server.close()
      this.server = null
    }
    if (this.tcpServer) {
      this.tcpServer.close()
      this.tcpServer = null
    }
  }
}

/** Get the first non-internal IPv4 address */
export function getLocalIP () {
  const interfaces = os.networkInterfaces()
  for (const name of Object.keys(interfaces)) {
    for (const iface of interfaces[name]) {
      if (iface.family === 'IPv4' && !iface.internal) {
        return iface.address
      }
    }
  }
  return '127.0.0.1'
}
