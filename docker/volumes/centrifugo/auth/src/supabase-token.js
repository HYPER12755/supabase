import crypto from 'node:crypto'
import { HttpError, isObject } from './errors.js'
import { isUuid } from './identifiers.js'

const MAX_TOKEN_LENGTH = 16384
const PART_RE = /^[A-Za-z0-9_-]+$/

function decodePart(part) {
  if (!PART_RE.test(part)) throw new HttpError(401, 'invalid_token', 'invalid token')
  try {
    const parsed = JSON.parse(Buffer.from(part, 'base64url').toString('utf8'))
    if (!isObject(parsed)) throw new Error('not an object')
    return parsed
  } catch {
    throw new HttpError(401, 'invalid_token', 'invalid token')
  }
}

function audienceMatches(audience, expected) {
  if (audience === expected) return true
  return Array.isArray(audience) && audience.includes(expected)
}

function tenantIdFromClaims(claims) {
  const candidates = [
    claims.app_metadata?.tenant_id,
    claims.user_metadata?.tenant_id,
    claims.tenant_id,
  ]
  return candidates.find((value) => isUuid(value)) || null
}

export function validateClaims(claims, { issuers, audience, nowSeconds, clockToleranceSeconds }) {
  if (typeof claims.exp !== 'number' || !Number.isFinite(claims.exp)) {
    throw new HttpError(401, 'invalid_token', 'invalid token')
  }
  if (claims.exp < nowSeconds - clockToleranceSeconds) {
    throw new HttpError(401, 'token_expired', 'token expired')
  }
  if (claims.nbf !== undefined && (typeof claims.nbf !== 'number' || claims.nbf > nowSeconds + clockToleranceSeconds)) {
    throw new HttpError(401, 'invalid_token', 'invalid token')
  }
  if (claims.iat !== undefined && (typeof claims.iat !== 'number' || claims.iat > nowSeconds + clockToleranceSeconds)) {
    throw new HttpError(401, 'invalid_token', 'invalid token')
  }
  if (typeof claims.iss !== 'string' || !issuers.includes(claims.iss)) {
    throw new HttpError(401, 'invalid_issuer', 'invalid issuer')
  }
  if (!audienceMatches(claims.aud, audience)) {
    throw new HttpError(401, 'invalid_audience', 'invalid audience')
  }
  if (claims.role === 'service_role') {
    throw new HttpError(403, 'role_not_allowed', 'role not allowed')
  }
  if (claims.role !== 'authenticated') {
    throw new HttpError(403, 'role_not_allowed', 'role not allowed')
  }
  if (!isUuid(claims.sub)) {
    throw new HttpError(401, 'invalid_token', 'invalid token')
  }

  return {
    claims,
    sub: claims.sub,
    role: claims.role,
    isAnonymous: claims.is_anonymous === true,
    tenantId: tenantIdFromClaims(claims),
  }
}

export async function verifySupabaseToken(
  token,
  {
    jwks,
    jwtSecret,
    issuers,
    audience,
    allowLegacyHs256 = true,
    clockToleranceSeconds = 30,
    nowSeconds = Math.floor(Date.now() / 1000),
  }
) {
  if (typeof token !== 'string' || token.length === 0 || token.length > MAX_TOKEN_LENGTH) {
    throw new HttpError(401, 'invalid_token', 'invalid token')
  }

  const parts = token.split('.')
  if (parts.length !== 3 || parts.some((part) => part.length === 0)) {
    throw new HttpError(401, 'invalid_token', 'invalid token')
  }

  const [headerPart, payloadPart, signaturePart] = parts
  const header = decodePart(headerPart)
  const claims = decodePart(payloadPart)
  const signature = Buffer.from(signaturePart, 'base64url')
  const signingInput = Buffer.from(`${headerPart}.${payloadPart}`)

  if (header.typ !== undefined && header.typ !== 'JWT') {
    throw new HttpError(401, 'invalid_token', 'invalid token')
  }

  if (header.alg === 'ES256') {
    const key = await jwks.getKey(header.kid)
    const valid = signature.length === 64 && crypto.verify(
      'sha256',
      signingInput,
      { key, dsaEncoding: 'ieee-p1363' },
      signature
    )
    if (!valid) throw new HttpError(401, 'invalid_token', 'invalid token')
  } else if (header.alg === 'HS256') {
    if (!allowLegacyHs256 || typeof jwtSecret !== 'string' || jwtSecret.length === 0) {
      throw new HttpError(401, 'unsupported_algorithm', 'unsupported token algorithm')
    }
    const expected = crypto.createHmac('sha256', jwtSecret).update(signingInput).digest()
    if (signature.length !== expected.length || !crypto.timingSafeEqual(signature, expected)) {
      throw new HttpError(401, 'invalid_token', 'invalid token')
    }
  } else {
    throw new HttpError(401, 'unsupported_algorithm', 'unsupported token algorithm')
  }

  return validateClaims(claims, {
    issuers,
    audience,
    nowSeconds,
    clockToleranceSeconds,
  })
}
