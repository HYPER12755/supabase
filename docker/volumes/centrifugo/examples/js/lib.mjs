import { Centrifuge, UnauthorizedError } from 'centrifuge'

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const SEGMENT_RE = /^[A-Za-z0-9_-]{1,64}$/
const PUBLIC_NAME_RE = /^[A-Za-z0-9._~-]{1,128}$/

export class TokenError extends Error {
  constructor(message, { status = 0, code = 'token_error', retryable = false } = {}) {
    super(message)
    this.name = 'TokenError'
    this.status = status
    this.code = code
    this.retryable = retryable
  }
}

export class ChannelNameError extends Error {
  constructor(message) {
    super(message)
    this.name = 'ChannelNameError'
    this.code = 'invalid_channel'
  }
}

export async function fetchConnectionToken({
  baseUrl,
  apikey,
  getAccessToken,
  fetchImpl = globalThis.fetch,
}) {
  if (!apikey) throw new TokenError('apikey is required', { code: 'missing_apikey' })
  const accessToken = await getAccessToken?.()
  const headers = { apikey, accept: 'application/json' }
  if (accessToken) headers.authorization = `Bearer ${accessToken}`

  let response
  try {
    response = await fetchImpl(new URL('/centrifugo/v1/auth/token', baseUrl), {
      method: 'POST',
      headers,
    })
  } catch (error) {
    throw new TokenError(String(error?.message ?? 'token request failed'), {
      code: 'network_error',
      retryable: true,
    })
  }

  let body = {}
  try {
    body = await response.json()
  } catch {
    body = {}
  }

  if (!response.ok) {
    throw new TokenError(String(body.message ?? `token endpoint returned ${response.status}`), {
      status: response.status,
      code: String(body.error ?? 'token_http_error'),
      retryable: response.status === 429 || response.status >= 500,
    })
  }
  if (typeof body.token !== 'string' || body.token.length === 0) {
    throw new TokenError('token endpoint returned no token', { code: 'invalid_token_response' })
  }
  return body.token
}

export function websocketEndpoint(baseUrl, path = '/realtime/v1/connection/websocket') {
  const url = new URL(path, baseUrl)
  if (url.protocol === 'http:') url.protocol = 'ws:'
  else if (url.protocol === 'https:') url.protocol = 'wss:'
  if (url.protocol !== 'ws:' && url.protocol !== 'wss:') {
    throw new Error('baseUrl must use http or https')
  }
  return url.toString()
}

export function createClient({
  baseUrl,
  apikey,
  getAccessToken,
  path,
  fetchImpl,
  onTokenRequest,
  ...options
}) {
  const getToken = async () => {
    onTokenRequest?.()
    try {
      return await fetchConnectionToken({ baseUrl, apikey, getAccessToken, fetchImpl })
    } catch (error) {
      if (error instanceof TokenError && !error.retryable) {
        const unauthorized = new UnauthorizedError(error.message)
        unauthorized.cause = error
        throw unauthorized
      }
      throw error
    }
  }

  return new Centrifuge(websocketEndpoint(baseUrl, path), {
    ...options,
    getToken,
    websocket: globalThis.WebSocket,
    name: options.name ?? 'supabase-centrifugo-js',
    version: options.version ?? '0.1.0',
  })
}

function requireUuid(value, label) {
  const normalized = String(value ?? '').toLowerCase()
  if (!UUID_RE.test(normalized)) throw new ChannelNameError(`${label} must be a UUID`)
  return normalized
}

function validateChannel(channel) {
  if (channel.length === 0 || channel.length > 255) {
    throw new ChannelNameError('channel must be between 1 and 255 characters')
  }
  if (/\s/.test(channel)) throw new ChannelNameError('channel cannot contain whitespace')
  return channel
}

export function tenantChannel(tenantId, ...segments) {
  const tenant = requireUuid(tenantId, 'tenantId')
  if (segments.length > 4) {
    throw new ChannelNameError('tenant channels support at most four segments')
  }
  const validated = segments.map((segment) => {
    if (!SEGMENT_RE.test(segment)) {
      throw new ChannelNameError('tenant segments must be 1-64 URL-safe characters')
    }
    return segment
  })
  return validateChannel(['tenant', tenant, ...validated].join(':'))
}

export function userChannel(userId) {
  return validateChannel(`user:${requireUuid(userId, 'userId')}`)
}

export function channelTenant(channel) {
  if (typeof channel !== 'string' || !channel.startsWith('tenant:')) return null
  const tenant = channel.split(':', 3)[1]
  return UUID_RE.test(tenant) ? tenant.toLowerCase() : null
}

export function publicChannel(name) {
  if (!PUBLIC_NAME_RE.test(name)) {
    throw new ChannelNameError('public channel names must be 1-128 URL-safe characters')
  }
  return `public:${name}`
}

export function publicationKey(publication) {
  return publication?.data?.message_id ?? publication?.offset ?? publication?.id ?? null
}

export class Deduplicator {
  constructor({ limit = 2048, ttl = 10 * 60 * 1000, now = Date.now } = {}) {
    this.limit = limit
    this.ttl = ttl
    this.now = now
    this.seen = new Map()
  }

  accept(key) {
    if (key === null || key === undefined || key === '') return true
    const normalized = String(key)
    const timestamp = this.now()
    const previous = this.seen.get(normalized)
    if (previous !== undefined && timestamp - previous < this.ttl) return false
    this.seen.delete(normalized)
    this.seen.set(normalized, timestamp)
    this.prune(timestamp)
    return true
  }

  prune(timestamp = this.now()) {
    for (const [key, seenAt] of this.seen) {
      if (timestamp - seenAt >= this.ttl || this.seen.size > this.limit) {
        this.seen.delete(key)
      } else {
        break
      }
    }
  }
}

export function waitForEvent(emitter, event, predicate = () => true, timeout = 15000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      emitter.off(event, handler)
      reject(new Error(`${event} timed out`))
    }, timeout)
    const handler = (context) => {
      if (!predicate(context)) return
      clearTimeout(timer)
      emitter.off(event, handler)
      resolve(context)
    }
    emitter.on(event, handler)
  })
}

const ERROR_ACTIONS = new Map([
  [403, 'authorization'],
  [429, 'rate_limit'],
  [109, 'token_expired'],
  [3500, 'invalid_token'],
  [2500, 'resubscribe'],
  [3014, 'reconnect'],
  [112, 'reload'],
  [103, 'authorization'],
])

export function normalizeError(error) {
  const source = error?.error && typeof error.error === 'object' ? error.error : error
  const code = Number(source?.code ?? error?.status ?? 0)
  const message = String(source?.message ?? error?.message ?? 'unknown error')
  const action = ERROR_ACTIONS.get(code) ?? (error?.retryable ? 'retry' : 'fail')
  return { code, message, action, retryable: action === 'rate_limit' || action === 'retry' }
}
