import crypto from 'node:crypto'
import { HttpError } from './errors.js'

function parseJwks(payload) {
  if (!payload || !Array.isArray(payload.keys)) {
    throw new Error('JWKS response does not contain a keys array')
  }

  const keys = new Map()
  for (const jwk of payload.keys) {
    if (!jwk || jwk.kty !== 'EC') continue
    if (jwk.alg && jwk.alg !== 'ES256') continue
    if (jwk.use && jwk.use !== 'sig') continue
    if (typeof jwk.kid !== 'string' || jwk.kid.length === 0) continue

    try {
      keys.set(jwk.kid, crypto.createPublicKey({ key: jwk, format: 'jwk' }))
    } catch {
      continue
    }
  }

  if (keys.size === 0) throw new Error('JWKS response does not contain a usable ES256 key')
  return keys
}

export class JwksResolver {
  constructor({
    url,
    ttlMs,
    timeoutMs = 5000,
    fetchImpl = fetch,
    logger,
    now = () => Date.now(),
  }) {
    this.url = url
    this.ttlMs = ttlMs
    this.timeoutMs = timeoutMs
    this.fetchImpl = fetchImpl
    this.logger = logger
    this.now = now
    this.keys = new Map()
    this.expiresAt = 0
    this.inflight = null
    this.lastForcedRefreshAt = 0
  }

  async load(force = false) {
    if (!force && this.keys.size > 0 && this.now() < this.expiresAt) return
    if (this.inflight) return this.inflight

    this.inflight = (async () => {
      try {
        const response = await this.fetchImpl(this.url, {
          headers: { accept: 'application/json' },
          signal: AbortSignal.timeout(this.timeoutMs),
        })
        if (!response.ok) throw new Error(`JWKS request failed with ${response.status}`)
        const keys = parseJwks(await response.json())
        this.keys = keys
        this.expiresAt = this.now() + this.ttlMs
      } catch (error) {
        this.logger?.warn('jwks_refresh_failed', {
          error: error.name,
          code: error.code || 'JWKS_UNAVAILABLE',
        })
        throw new HttpError(503, 'jwks_unavailable', 'token verification unavailable')
      } finally {
        this.inflight = null
      }
    })()

    return this.inflight
  }

  async getKey(kid) {
    if (typeof kid !== 'string' || kid.length === 0) {
      throw new HttpError(401, 'invalid_token', 'invalid token')
    }

    if (this.keys.size === 0 || this.now() >= this.expiresAt) await this.load()
    let key = this.keys.get(kid)

    if (!key && this.now() - this.lastForcedRefreshAt >= 5000) {
      this.lastForcedRefreshAt = this.now()
      await this.load(true)
      key = this.keys.get(kid)
    }

    if (!key) throw new HttpError(401, 'invalid_token', 'invalid token')
    return key
  }
}
