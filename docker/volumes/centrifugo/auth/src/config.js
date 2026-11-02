function read(source, name, fallback = '') {
  const value = source[name]
  return value === undefined || value === '' ? fallback : value
}

function integer(source, name, fallback, minimum = 0, maximum = Number.MAX_SAFE_INTEGER) {
  const raw = read(source, name, String(fallback))
  const value = Number.parseInt(raw, 10)
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer between ${minimum} and ${maximum}`)
  }
  return value
}

function boolean(source, name, fallback) {
  const raw = read(source, name, fallback ? 'true' : 'false').toLowerCase()
  if (raw === 'true' || raw === '1') return true
  if (raw === 'false' || raw === '0') return false
  throw new Error(`${name} must be true or false`)
}

function list(value) {
  return String(value || '')
    .split(/[\s,]+/)
    .map((item) => item.trim())
    .filter(Boolean)
}

function normalizeIssuer(value) {
  return String(value || '').replace(/\/+$/, '')
}

function normalizeOrigin(value) {
  try {
    const url = new URL(value)
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return null
    return url.origin
  } catch {
    return null
  }
}

function unique(values) {
  return [...new Set(values.filter(Boolean))]
}

export function loadConfig(source = process.env) {
  const tokenSecret = read(source, 'CENTRIFUGO_CLIENT_TOKEN_HMAC_SECRET_KEY')
  if (!tokenSecret) throw new Error('CENTRIFUGO_CLIENT_TOKEN_HMAC_SECRET_KEY is required')

  const anonKeys = unique([
    read(source, 'SUPABASE_ANON_KEY'),
    read(source, 'SUPABASE_PUBLISHABLE_KEY'),
    read(source, 'SUPABASE_ANON_KEY_ASYMMETRIC'),
  ])
  if (anonKeys.length === 0) throw new Error('SUPABASE_ANON_KEY or SUPABASE_PUBLISHABLE_KEY is required')

  const serviceKeys = unique([
    read(source, 'SUPABASE_SERVICE_ROLE_KEY'),
    read(source, 'SUPABASE_SECRET_KEY'),
    read(source, 'SUPABASE_SERVICE_ROLE_KEY_ASYMMETRIC'),
  ])

  const apiExternalUrl = normalizeIssuer(read(source, 'API_EXTERNAL_URL'))
  const apiAuthIssuer = apiExternalUrl.endsWith('/auth/v1')
    ? apiExternalUrl
    : apiExternalUrl
      ? `${apiExternalUrl}/auth/v1`
      : ''
  const configuredIssuers = list(read(source, 'SUPABASE_JWT_ISSUERS'))
  const issuers = unique([
    ...configuredIssuers.map(normalizeIssuer),
    apiAuthIssuer,
    normalizeIssuer(read(source, 'SUPABASE_JWT_ISSUER')),
    'supabase',
  ])

  const configuredOrigins = list(read(source, 'CENTRIFUGO_AUTH_ALLOWED_ORIGINS'))
  const fallbackOrigins = [
    read(source, 'SITE_URL'),
    read(source, 'SUPABASE_PUBLIC_URL'),
  ]
  const allowedOrigins = unique(
    (configuredOrigins.length > 0 ? configuredOrigins : fallbackOrigins)
      .map(normalizeOrigin)
      .filter(Boolean)
  )

  const jwtSecret = read(source, 'SUPABASE_JWT_SECRET')
  const jwksUrl = read(source, 'SUPABASE_JWKS_URL')
  if (!jwksUrl) throw new Error('SUPABASE_JWKS_URL is required')

  return {
    port: integer(source, 'PORT', 8090, 1, 65535),
    jwksUrl,
    jwksCacheSeconds: integer(source, 'CENTRIFUGO_AUTH_JWKS_CACHE_SECONDS', 300, 1, 3600),
    jwksTimeoutMs: integer(source, 'CENTRIFUGO_AUTH_JWKS_TIMEOUT_MS', 5000, 100, 30000),
    jwtIssuers: issuers,
    jwtAudience: read(source, 'SUPABASE_JWT_AUD', 'authenticated'),
    jwtSecret,
    allowLegacyHs256: boolean(source, 'CENTRIFUGO_AUTH_ALLOW_LEGACY_HS256', Boolean(jwtSecret)),
    clockToleranceSeconds: integer(source, 'CENTRIFUGO_AUTH_CLOCK_TOLERANCE_SECONDS', 30, 0, 300),
    tokenSecret,
    tokenKid: read(source, 'CENTRIFUGO_AUTH_TOKEN_KEY_ID', 'phase3'),
    tokenIssuer: read(source, 'CENTRIFUGO_AUTH_TOKEN_ISSUER', 'supabase-centrifugo'),
    tokenAudience: read(source, 'CENTRIFUGO_AUTH_TOKEN_AUDIENCE', 'centrifugo'),
    tokenTtlSeconds: integer(source, 'CENTRIFUGO_AUTH_TOKEN_TTL_SECONDS', 900, 60, 3600),
    anonKeys,
    serviceKeys,
    allowedOrigins,
    allowedOriginSet: new Set(allowedOrigins),
    trustProxy: boolean(source, 'CENTRIFUGO_AUTH_TRUST_PROXY', false),
    databaseUrl: read(source, 'CENTRIFUGO_AUTH_DATABASE_URL'),
    databaseStatementTimeoutMs: integer(
      source,
      'CENTRIFUGO_AUTH_DATABASE_STATEMENT_TIMEOUT_MS',
      3000,
      100,
      30000
    ),
    authzCacheSeconds: integer(source, 'CENTRIFUGO_AUTHZ_CACHE_TTL_SECONDS', 5, 0, 60),
    authzCacheVersion: read(source, 'CENTRIFUGO_AUTHZ_CACHE_VERSION', '1'),
    maxBodyBytes: integer(source, 'CENTRIFUGO_AUTH_MAX_BODY_BYTES', 32768, 1024, 1048576),
    maxPublishBytes: integer(source, 'CENTRIFUGO_AUTH_MAX_PUBLISH_BYTES', 16384, 256, 1048576),
    tokenRateIpLimit: integer(source, 'CENTRIFUGO_AUTH_TOKEN_RATE_IP_LIMIT', 60, 1, 10000),
    tokenRateUserLimit: integer(source, 'CENTRIFUGO_AUTH_TOKEN_RATE_USER_LIMIT', 30, 1, 10000),
    tokenRateWindowMs: integer(source, 'CENTRIFUGO_AUTH_TOKEN_RATE_WINDOW_SECONDS', 60, 1, 3600) * 1000,
    authzRateLimit: integer(source, 'CENTRIFUGO_AUTHZ_RATE_LIMIT', 300, 1, 10000),
    authzRateWindowMs: integer(source, 'CENTRIFUGO_AUTHZ_RATE_WINDOW_SECONDS', 10, 1, 3600) * 1000,
    publishRateLimit: integer(source, 'CENTRIFUGO_AUTH_PUBLISH_RATE_LIMIT', 30, 1, 10000),
    publishRateWindowMs:
      integer(source, 'CENTRIFUGO_AUTH_PUBLISH_RATE_WINDOW_SECONDS', 10, 1, 3600) * 1000,
  }
}
