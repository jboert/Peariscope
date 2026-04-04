/**
 * Stream multiplexer for Peariscope — shared between worklet.js and index.js.
 *
 * Each peer connection is multiplexed into channels:
 * - Channel 0: Video stream (host -> viewer)
 * - Channel 1: Input events (viewer -> host)
 * - Channel 2: Control messages (bidirectional)
 * - Channel 3: Audio stream (host -> viewer)
 * - Channel 4: DHT node exchange (bidirectional)
 *
 * Frame format over the Hyperswarm encrypted stream:
 *   [channel: 1 byte] [length: 4 bytes BE] [payload: N bytes]
 *
 * This is the battle-hardened version from worklet.js with all rate limiting,
 * overflow handling, and diagnostics intact.
 */

const CHANNEL_HEADER_SIZE = 5 // 1 byte channel + 4 bytes length

const Channel = {
  VIDEO: 0,
  INPUT: 1,
  CONTROL: 2,
  AUDIO: 3,
  DHT_NODES: 4
}

// Logging function — overridden by worklet.js with sendLog()
let _log = typeof console !== 'undefined' ? console.log.bind(console) : () => {}

function setLogger (fn) {
  _log = fn
}

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

    this._dataEventCount = 0
    this._drainCallCount = 0
    this._framesProcessed = 0

    // Per-channel rate limiting (centralized — replaces inline gate vars)
    this._channelConfig = {}  // channel -> { minInterval, skipMin }
    this._channelState = {}   // channel -> { lastForward, sinceLast, drops, forwarded, total }

    // Track raw byte totals and largest chunk for diagnostics
    this._totalRawBytes = 0
    this._largestChunk = 0
    this._chunksOver1K = 0
    this._chunksUnder100 = 0

    stream.on('data', (chunk) => {
      this._pendingChunks.push(chunk)
      this._pendingLen += chunk.length
      this._bytesReceived += chunk.length
      this._totalRawBytes += chunk.length
      this._dataEventCount++
      if (chunk.length > this._largestChunk) this._largestChunk = chunk.length
      if (chunk.length > 1000) this._chunksOver1K++
      if (chunk.length < 100) this._chunksUnder100++
      if (this._dataEventCount <= 20 || this._dataEventCount % 100 === 0) {
        const hdr = chunk.length >= 8 ? Array.from(chunk.subarray(0, 8)).map(b => b.toString(16).padStart(2, '0')).join(' ') : ''
        _log('mux data event #' + this._dataEventCount + ' len=' + chunk.length + ' pending=' + this._pendingLen + ' recvBuf=' + this._recvBuf.length + ' drainSched=' + this._drainScheduled + ' totalRaw=' + this._totalRawBytes + ' largest=' + this._largestChunk + ' over1K=' + this._chunksOver1K + ' under100=' + this._chunksUnder100 + ' hdr=[' + hdr + ']')
      }

      // Safety cap: skip complete frames to maintain framing alignment
      if (this._pendingLen > 2000000) {
        if (this._recvBuf.length > 0) {
          this._pendingChunks.unshift(this._recvBuf)
          this._pendingLen += this._recvBuf.length
        }
        this._recvBuf = this._pendingChunks.length === 1
          ? this._pendingChunks[0]
          : Buffer.concat(this._pendingChunks, this._pendingLen)
        this._pendingChunks = []
        this._pendingLen = 0
        let skipped = 0
        while (this._recvBuf.length >= CHANNEL_HEADER_SIZE) {
          const length = this._recvBuf.readUInt32BE(1)
          if (length > 1000000) {
            this._recvBuf = Buffer.alloc(0)
            break
          }
          if (this._recvBuf.length < CHANNEL_HEADER_SIZE + length) break
          this._recvBuf = this._recvBuf.subarray(CHANNEL_HEADER_SIZE + length)
          skipped++
        }
        _log('StreamMux: overflow, skipped ' + skipped + ' frames, recvBuf=' + this._recvBuf.length)
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

      if (!this._drainScheduled) {
        this._drainScheduled = true
        setTimeout(() => {
          this._drainScheduled = false
          this._drainFrames()
        }, 0)
      }
    })
  }

  getRawStats () {
    return {
      totalRawBytes: this._totalRawBytes,
      dataEvents: this._dataEventCount,
      largestChunk: this._largestChunk,
      chunksOver1K: this._chunksOver1K,
      chunksUnder100: this._chunksUnder100,
      framesProcessed: this._framesProcessed,
      recvBufLen: this._recvBuf.length
    }
  }

  setChannelRateLimit (channel, { minInterval = 0, skipMin = 0 } = {}) {
    this._channelConfig[channel] = { minInterval, skipMin }
    this._channelState[channel] = { lastForward: 0, sinceLast: skipMin, drops: 0, forwarded: 0, total: 0, lastStatusLog: 0 }
  }

  _handleFrame (channel, data) {
    const config = this._channelConfig[channel]
    if (config) {
      const state = this._channelState[channel]
      state.total++
      state.sinceLast++

      const statusNow = typeof Date !== 'undefined' && typeof Date.now === 'function' ? Date.now() : 0
      if (statusNow > 0 && (state.lastStatusLog === 0 || statusNow - state.lastStatusLog > 2000)) {
        state.lastStatusLog = statusNow
        _log('mux ch' + channel + ' status: total=' + state.total + ' fwd=' + state.forwarded + ' drops=' + state.drops + ' sinceLast=' + state.sinceLast)
      }

      if (config.skipMin > 0 && state.sinceLast < config.skipMin) {
        state.drops++
        return
      }

      if (config.minInterval > 0) {
        const now = typeof Date !== 'undefined' && typeof Date.now === 'function' ? Date.now() : 0
        if (now > 0 && state.lastForward > 0 && (now - state.lastForward) < config.minInterval) {
          state.drops++
          return
        }
        state.lastForward = now
      }

      state.sinceLast = 0
      state.forwarded++
      if (state.forwarded <= 5 || state.forwarded % 300 === 0) {
        const now = typeof Date !== 'undefined' && typeof Date.now === 'function' ? Date.now() : 0
        _log('mux ch' + channel + ' fwd len=' + data.length + ' count=' + state.forwarded + ' drops=' + state.drops + ' total=' + state.total + ' dateNow=' + now)
      }
    }

    const handler = this.handlers.get(channel)
    if (handler) handler(data)
  }

  getDropStats () {
    const stats = {}
    for (const ch of Object.keys(this._channelState)) {
      const s = this._channelState[ch]
      stats[ch] = { drops: s.drops, forwarded: s.forwarded, total: s.total }
    }
    return stats
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
    if (this._pendingChunks.length > 0) {
      if (this._recvBuf.length > 0) {
        this._pendingChunks.unshift(this._recvBuf)
        this._pendingLen += this._recvBuf.length
      }
      if (this._pendingChunks.length === 1) {
        this._recvBuf = this._pendingChunks[0]
      } else {
        this._recvBuf = Buffer.concat(this._pendingChunks, this._pendingLen)
      }
      this._pendingChunks = []
      this._pendingLen = 0
    }

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
      _log('StreamMux: recvBuf overflow, skipped ' + skipped + ' frames, remaining=' + this._recvBuf.length)
      if (!this._streamPaused) {
        this._streamPaused = true
        this.stream.pause()
        setTimeout(() => {
          this._streamPaused = false
          if (!this.stream.destroyed) {
            this.stream.resume()
            _log('StreamMux: resumed stream after overflow')
          }
        }, 100)
      }
      return
    }
    this._drainCallCount++
    const drainNum = this._drainCallCount
    if (drainNum <= 20 || drainNum % 100 === 0) {
      _log('mux drain #' + drainNum + ' recvBuf=' + this._recvBuf.length + ' framesTotal=' + this._framesProcessed)
    }
    while (this._recvBuf.length >= CHANNEL_HEADER_SIZE) {
      const channel = this._recvBuf.readUInt8(0)
      const length = this._recvBuf.readUInt32BE(1)
      if (length > 1000000) {
        _log('StreamMux: corrupt frame length=' + length + ', resetting buffer')
        this._recvBuf = Buffer.alloc(0)
        return
      }
      if (this._recvBuf.length < CHANNEL_HEADER_SIZE + length) {
        if (this._framesProcessed <= 20 || this._drainCallCount <= 20) {
          _log('mux PARTIAL: ch=' + channel + ' need=' + (CHANNEL_HEADER_SIZE + length) + ' have=' + this._recvBuf.length)
        }
        break
      }
      const payload = this._recvBuf.subarray(CHANNEL_HEADER_SIZE, CHANNEL_HEADER_SIZE + length)
      this._recvBuf = this._recvBuf.subarray(CHANNEL_HEADER_SIZE + length)
      this._framesProcessed++
      if (this._framesProcessed <= 20 || this._framesProcessed % 300 === 0) {
        _log('mux frame #' + this._framesProcessed + ' ch=' + channel + ' len=' + length + ' remaining=' + this._recvBuf.length)
      }
      this._handleFrame(channel, payload)
    }
  }

  destroy () {
    this.stream.destroy()
    this.handlers.clear()
  }
}

// Support both ESM and CJS
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { StreamMux, Channel, CHANNEL_HEADER_SIZE, setLogger }
} else if (typeof exports !== 'undefined') {
  exports.StreamMux = StreamMux
  exports.Channel = Channel
  exports.CHANNEL_HEADER_SIZE = CHANNEL_HEADER_SIZE
  exports.setLogger = setLogger
}

export { StreamMux, Channel, CHANNEL_HEADER_SIZE, setLogger }
