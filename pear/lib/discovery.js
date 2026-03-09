import crypto from 'node:crypto'
import b4a from 'b4a'

/**
 * Manages DHT topic discovery for Peariscope.
 *
 * Connection codes are derived from the host's public key + a one-time token.
 * The DHT topic is the hash of the connection code, so viewers can find hosts.
 */

const CODE_LENGTH = 24 // 24-character alphanumeric codes (~124 bits entropy)

/**
 * Generate a short connection code from a public key.
 * The code is deterministic per session (includes a random token).
 */
export function generateConnectionCode (publicKey) {
  const token = crypto.randomBytes(8)
  const combined = Buffer.concat([publicKey, token])
  const hash = crypto.createHash('sha256').update(combined).digest()

  // Encode three 64-bit chunks as base36 and concatenate for enough characters
  const part1 = hash.readBigUInt64BE(0).toString(36).toUpperCase()
  const part2 = hash.readBigUInt64BE(8).toString(36).toUpperCase()
  const part3 = hash.readBigUInt64BE(16).toString(36).toUpperCase()
  const code = (part1 + part2 + part3).slice(0, CODE_LENGTH)

  return {
    code,
    token,
    topic: deriveTopicFromCode(code)
  }
}

/**
 * Derive a 32-byte DHT topic from a connection code.
 * Both host and viewer compute the same topic from the same code.
 */
export function deriveTopicFromCode (code) {
  const normalized = code.toUpperCase().trim()
  return crypto.createHash('sha256').update(`peariscope:${normalized}`).digest()
}

/**
 * Derive a persistent topic from a public key (for trusted device reconnection).
 * Rotates daily to limit the window for unauthorized reconnection.
 */
export function deriveTopicFromKey (publicKey) {
  const daysSinceEpoch = Math.floor(Date.now() / (1000 * 60 * 60 * 24))
  const epoch = Buffer.alloc(4)
  epoch.writeUInt32BE(daysSinceEpoch)
  return crypto.createHash('sha256').update(
    Buffer.concat([Buffer.from('peariscope:persistent:'), publicKey, epoch])
  ).digest()
}

/**
 * Encode pairing info for QR code.
 * Returns a string suitable for encoding into a QR code.
 */
export function encodePairingInfo (publicKey, connectionCode, token) {
  const payload = {
    v: 1,
    k: b4a.toString(publicKey, 'hex'),
    c: connectionCode,
    t: b4a.toString(token, 'hex')
  }
  return `peariscope://${Buffer.from(JSON.stringify(payload)).toString('base64url')}`
}

/**
 * Decode pairing info from a QR code string.
 */
export function decodePairingInfo (uri) {
  if (!uri.startsWith('peariscope://')) {
    throw new Error('Invalid Peariscope URI')
  }
  const b64 = uri.slice('peariscope://'.length)
  const payload = JSON.parse(Buffer.from(b64, 'base64url').toString())

  if (payload.v !== 1) {
    throw new Error(`Unsupported pairing version: ${payload.v}`)
  }

  return {
    publicKey: b4a.from(payload.k, 'hex'),
    connectionCode: payload.c,
    token: b4a.from(payload.t, 'hex')
  }
}
