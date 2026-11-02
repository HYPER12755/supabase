import { HttpError } from './errors.js'

export function getHeader(req, name) {
  const value = req.headers[name]
  return Array.isArray(value) ? value[0] : value
}

export function parseBearer(value) {
  if (typeof value !== 'string') return null
  const match = /^Bearer\s+(\S+)$/i.exec(value.trim())
  return match ? match[1] : null
}

export function getClientIp(req, trustProxy) {
  if (trustProxy) {
    const forwarded = getHeader(req, 'x-forwarded-for')
    if (typeof forwarded === 'string') {
      const first = forwarded.split(',')[0].trim()
      if (first) return first
    }
    const realIp = getHeader(req, 'x-real-ip')
    if (typeof realIp === 'string' && realIp.trim()) return realIp.trim()
  }
  return req.socket.remoteAddress || 'unknown'
}

export function setCorsHeaders(req, res, allowedOriginSet) {
  const origin = getHeader(req, 'origin')
  if (!origin) return { origin: null, allowed: true }
  if (!allowedOriginSet.has(origin)) return { origin, allowed: false }

  res.setHeader('Access-Control-Allow-Origin', origin)
  res.setHeader('Access-Control-Allow-Methods', 'POST,OPTIONS')
  res.setHeader('Access-Control-Allow-Headers', 'authorization,apikey,content-type,x-api-key')
  res.setHeader('Access-Control-Max-Age', '3600')
  res.setHeader('Access-Control-Expose-Headers', 'content-type')
  res.setHeader('Vary', 'Origin')
  return { origin, allowed: true }
}

export function sendJson(res, status, body, headers = {}) {
  if (res.headersSent) return
  const payload = JSON.stringify(body)
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    ...headers,
  })
  res.end(payload)
}

export function sendNoContent(res, status = 204, headers = {}) {
  if (res.headersSent) return
  res.writeHead(status, {
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    ...headers,
  })
  res.end()
}

export function methodNotAllowed(res, allow) {
  sendJson(res, 405, { error: 'method_not_allowed', message: 'method not allowed' }, { Allow: allow })
}

export function readJson(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    let tooLarge = false

    req.on('data', (chunk) => {
      size += chunk.length
      if (size > maxBytes) {
        tooLarge = true
        return
      }
      chunks.push(chunk)
    })

    req.on('end', () => {
      if (tooLarge) {
        reject(new HttpError(413, 'payload_too_large', 'payload too large'))
        return
      }
      if (size === 0) {
        resolve({})
        return
      }
      try {
        const parsed = JSON.parse(Buffer.concat(chunks).toString('utf8'))
        if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
          reject(new HttpError(400, 'invalid_payload', 'invalid payload'))
          return
        }
        resolve(parsed)
      } catch {
        reject(new HttpError(400, 'invalid_payload', 'invalid payload'))
      }
    })

    req.on('error', () => reject(new HttpError(400, 'invalid_request', 'invalid request')))
  })
}
