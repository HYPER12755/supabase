import { AuthzCache } from './authz-cache.js'
import { authorizeChannel, buildProxyClaims } from './channel.js'
import { signConnectionToken } from './connection-token.js'
import { matchesAny } from './constant-time.js'
import { HttpError, isObject } from './errors.js'
import {
  getClientIp,
  getHeader,
  methodNotAllowed,
  parseBearer,
  readJson,
  sendJson,
  sendNoContent,
  setCorsHeaders,
} from './http.js'
import { isUuid } from './identifiers.js'
import { RateLimiter } from './rate-limit.js'
import { verifySupabaseToken } from './supabase-token.js'

function retryAfterHeader(result) {
  return result.retryAfterSeconds > 0
    ? { 'Retry-After': String(result.retryAfterSeconds) }
    : {}
}

function proxyError(res, code, message) {
  sendJson(res, 200, { error: { code, message } })
}

function safeErrorFields(error) {
  return {
    error: error?.name || 'Error',
    code: error?.code || 'UNKNOWN',
  }
}

export function createApp({ config, logger, jwks, dbAuthorizer, now = () => Date.now() }) {
  const authzCache = new AuthzCache({
    ttlSeconds: config.authzCacheSeconds,
    version: config.authzCacheVersion,
    now,
  })
  const tokenIpLimiter = new RateLimiter({
    limit: config.tokenRateIpLimit,
    windowMs: config.tokenRateWindowMs,
    now,
  })
  const tokenUserLimiter = new RateLimiter({
    limit: config.tokenRateUserLimit,
    windowMs: config.tokenRateWindowMs,
    now,
  })
  const authzLimiter = new RateLimiter({
    limit: config.authzRateLimit,
    windowMs: config.authzRateWindowMs,
    now,
  })
  const publishLimiter = new RateLimiter({
    limit: config.publishRateLimit,
    windowMs: config.publishRateWindowMs,
    now,
  })

  async function decisionFor({ action, channel, user, claims }) {
    const cached = authzCache.get(action, user, channel)
    if (cached) return cached

    const decision = await authorizeChannel({
      action,
      channel,
      userId: user,
      claims,
      dbAuthorize: dbAuthorizer?.authorize,
    })

    if (!decision.error) {
      authzCache.set(action, user, channel, {
        allowed: decision.allowed,
        reason: decision.reason,
      })
    }

    return decision
  }

  function proxyRequestContext(body, res, action) {
    if (typeof body.channel !== 'string' || body.channel.length === 0) {
      sendJson(res, 400, { error: 'invalid_request', message: 'channel is required' })
      return null
    }
    if (typeof body.user !== 'string') {
      sendJson(res, 400, { error: 'invalid_request', message: 'user is required' })
      return null
    }
    if (body.user && !isUuid(body.user)) {
      proxyError(res, 403, 'permission denied')
      return null
    }

    const meta = isObject(body.meta) ? body.meta : {}
    return {
      action,
      channel: body.channel,
      user: body.user,
      claims: buildProxyClaims({ user: body.user, meta }),
    }
  }

  async function handleToken(req, res) {
    const origin = setCorsHeaders(req, res, config.allowedOriginSet)
    if (!origin.allowed) {
      sendJson(res, 403, { error: 'origin_not_allowed', message: 'origin not allowed' })
      return
    }
    if (req.method === 'OPTIONS') {
      sendNoContent(res, 204)
      return
    }
    if (req.method !== 'POST') {
      methodNotAllowed(res, 'POST,OPTIONS')
      return
    }

    const ipLimit = tokenIpLimiter.consume(`ip:${getClientIp(req, config.trustProxy)}`)
    if (!ipLimit.allowed) {
      sendJson(
        res,
        429,
        { error: 'rate_limit_exceeded', message: 'rate limit exceeded' },
        retryAfterHeader(ipLimit)
      )
      return
    }

    const apiKey = getHeader(req, 'apikey') || getHeader(req, 'x-api-key')
    if (!apiKey) {
      throw new HttpError(401, 'missing_apikey', 'missing apikey')
    }
    if (matchesAny(apiKey, config.serviceKeys)) {
      throw new HttpError(403, 'service_key_not_allowed', 'service key not allowed')
    }
    if (!matchesAny(apiKey, config.anonKeys)) {
      throw new HttpError(401, 'invalid_apikey', 'invalid apikey')
    }

    const authorization = getHeader(req, 'authorization')
    let user = null
    if (authorization !== undefined) {
      const supabaseToken = parseBearer(authorization)
      if (!supabaseToken) throw new HttpError(401, 'invalid_authorization', 'invalid authorization')
      if (matchesAny(supabaseToken, config.serviceKeys)) {
        throw new HttpError(403, 'service_key_not_allowed', 'service key not allowed')
      }
      if (!matchesAny(supabaseToken, config.anonKeys)) {
        user = await verifySupabaseToken(supabaseToken, {
          jwks,
          jwtSecret: config.jwtSecret,
          issuers: config.jwtIssuers,
          audience: config.jwtAudience,
          allowLegacyHs256: config.allowLegacyHs256,
          clockToleranceSeconds: config.clockToleranceSeconds,
          nowSeconds: Math.floor(now() / 1000),
        })
      }
    }

    if (user) {
      const userLimit = tokenUserLimiter.consume(`user:${user.sub}`)
      if (!userLimit.allowed) {
        sendJson(
          res,
          429,
          { error: 'rate_limit_exceeded', message: 'rate limit exceeded' },
          retryAfterHeader(userLimit)
        )
        return
      }
    }

    const signed = signConnectionToken({
      sub: user?.sub,
      isAnonymous: !user,
      tenantId: user?.tenantId,
      secret: config.tokenSecret,
      kid: config.tokenKid,
      ttlSeconds: config.tokenTtlSeconds,
      issuer: config.tokenIssuer,
      audience: config.tokenAudience,
      nowSeconds: Math.floor(now() / 1000),
    })

    sendJson(res, 200, {
      token: signed.token,
      token_type: 'Bearer',
      expires_in: signed.expiresIn,
      expires_at: signed.expiresAt,
    })
  }

  async function handleSubscribe(req, res) {
    if (req.method !== 'POST') {
      methodNotAllowed(res, 'POST')
      return
    }

    const body = await readJson(req, config.maxBodyBytes)
    const context = proxyRequestContext(body, res, 'subscribe')
    if (!context) return

    const limit = authzLimiter.consume(`authz:${context.user || 'anon'}`)
    if (!limit.allowed) {
      logger.info('authz_rate_limited', { action: 'subscribe' })
      proxyError(res, 429, 'rate limit exceeded')
      return
    }

    const decision = await decisionFor(context)
    if (decision.allowed) {
      sendJson(res, 200, { result: {} })
      return
    }

    if (decision.error) {
      logger.error('authz_database_error', {
        action: 'subscribe',
        ...safeErrorFields(decision.error),
      })
      proxyError(res, 503, 'authorization unavailable')
      return
    }

    logger.info('authz_denied', { action: 'subscribe', reason: decision.reason })
    proxyError(res, 403, 'permission denied')
  }

  async function handlePublish(req, res) {
    if (req.method !== 'POST') {
      methodNotAllowed(res, 'POST')
      return
    }

    const body = await readJson(req, config.maxBodyBytes)
    const context = proxyRequestContext(body, res, 'publish')
    if (!context) return

    let payloadBytes = 0
    if (body.data !== undefined) payloadBytes = Buffer.byteLength(JSON.stringify(body.data))
    if (typeof body.b64data === 'string') {
      payloadBytes = Math.max(payloadBytes, Buffer.byteLength(body.b64data, 'base64'))
    }
    if (payloadBytes > config.maxPublishBytes) {
      logger.info('publish_rejected', { reason: 'payload_too_large' })
      proxyError(res, 413, 'payload too large')
      return
    }

    const limit = publishLimiter.consume(`publish:${context.user || 'anon'}`)
    if (!limit.allowed) {
      logger.info('publish_rate_limited', {})
      proxyError(res, 429, 'rate limit exceeded')
      return
    }

    const decision = await decisionFor(context)
    if (decision.allowed) {
      sendJson(res, 200, { result: {} })
      return
    }

    if (decision.error) {
      logger.error('authz_database_error', {
        action: 'publish',
        ...safeErrorFields(decision.error),
      })
      proxyError(res, 503, 'authorization unavailable')
      return
    }

    logger.info('authz_denied', { action: 'publish', reason: decision.reason })
    proxyError(res, 403, 'permission denied')
  }

  return async function handler(req, res) {
    const startedAt = now()
    let path = '/'
    try {
      path = req.url.split('?')[0]
    } catch {
      sendJson(res, 400, { error: 'invalid_request', message: 'invalid request' })
      return
    }

    res.on('finish', () => {
      if (path === '/health') return
      logger.info('http_request', {
        method: req.method,
        path,
        status: res.statusCode,
        duration_ms: now() - startedAt,
      })
    })

    try {
      if (path === '/health') {
        if (req.method !== 'GET') {
          methodNotAllowed(res, 'GET')
          return
        }
        sendJson(res, 200, { status: 'ok' })
        return
      }

      if (path === '/auth/token') {
        await handleToken(req, res)
        return
      }

      if (path === '/auth/subscribe') {
        await handleSubscribe(req, res)
        return
      }

      if (path === '/auth/publish') {
        await handlePublish(req, res)
        return
      }

      sendJson(res, 404, { error: 'not_found', message: 'not found' })
    } catch (error) {
      if (error instanceof HttpError) {
        logger.info('request_denied', {
          method: req.method,
          path,
          status: error.status,
          reason: error.code,
        })
        sendJson(res, error.status, { error: error.code, message: error.message })
        return
      }

      logger.error('request_failed', {
        method: req.method,
        path,
        ...safeErrorFields(error),
      })
      if (!res.headersSent) {
        sendJson(res, 500, { error: 'internal_error', message: 'internal error' })
      }
    }
  }
}
