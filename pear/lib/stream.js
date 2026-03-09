/**
 * Stream multiplexer for Peariscope.
 *
 * Each peer connection is multiplexed into channels:
 * - Channel 0: Video stream (host -> viewer)
 * - Channel 1: Input events (viewer -> host)
 * - Channel 2: Control messages (bidirectional)
 *
 * Frame format over the Hyperswarm encrypted stream:
 *   [channel: 1 byte] [length: 4 bytes BE] [payload: N bytes]
 */

const CHANNEL_HEADER_SIZE = 5 // 1 byte channel + 4 bytes length

export const Channel = {
  VIDEO: 0,
  INPUT: 1,
  CONTROL: 2
}

export class StreamMux {
  constructor (stream) {
    this.stream = stream
    this.handlers = new Map()
    this._recvBuf = Buffer.alloc(0)

    stream.on('data', (chunk) => {
      this._recvBuf = Buffer.concat([this._recvBuf, chunk])
      this._drainFrames()
    })
  }

  /** Register a handler for a channel */
  onChannel (channel, handler) {
    this.handlers.set(channel, handler)
  }

  /** Send data on a specific channel */
  send (channel, data) {
    const header = Buffer.alloc(CHANNEL_HEADER_SIZE)
    header.writeUInt8(channel, 0)
    header.writeUInt32BE(data.length, 1)
    this.stream.write(header)
    this.stream.write(data)
  }

  _drainFrames () {
    const MAX_FRAME_LENGTH = 5 * 1024 * 1024 // 5MB
    while (this._recvBuf.length >= CHANNEL_HEADER_SIZE) {
      const channel = this._recvBuf.readUInt8(0)
      const length = this._recvBuf.readUInt32BE(1)

      if (length > MAX_FRAME_LENGTH) {
        console.error(`[stream] frame length ${length} exceeds max ${MAX_FRAME_LENGTH}, dropping buffer`)
        this._recvBuf = Buffer.alloc(0)
        return
      }

      if (this._recvBuf.length < CHANNEL_HEADER_SIZE + length) break

      const payload = this._recvBuf.subarray(CHANNEL_HEADER_SIZE, CHANNEL_HEADER_SIZE + length)
      this._recvBuf = this._recvBuf.subarray(CHANNEL_HEADER_SIZE + length)

      const handler = this.handlers.get(channel)
      if (handler) {
        handler(payload)
      }
    }
  }

  destroy () {
    this.stream.destroy()
    this.handlers.clear()
  }
}
