import crypto from 'node:crypto'

function encodePart(value) {
  return Buffer.from(JSON.stringify(value)).toString('base64url')
}

export function signConnectionToken({
  sub,
  isAnonymous,
  tenantId,
  secret,
  kid,
  ttlSeconds,
  issuer,
  audience,
  nowSeconds = Math.floor(Date.now() / 1000),
}) {
  if (typeof secret !== 'string' || secret.length === 0) {
    throw new Error('token secret is required')
  }

  const header = {
    alg: 'HS256',
    typ: 'JWT',
    kid,
  }
  const payload = {
    iss: issuer,
    sub: isAnonymous ? '' : sub,
    aud: audience,
    iat: nowSeconds,
    exp: nowSeconds + ttlSeconds,
    info: isAnonymous
      ? { role: 'anon', is_anonymous: true }
      : { role: 'authenticated', user_id: sub, is_anonymous: false },
    meta: tenantId ? { tenant_id: tenantId } : {},
  }

  const unsigned = `${encodePart(header)}.${encodePart(payload)}`
  const signature = crypto.createHmac('sha256', secret).update(unsigned).digest('base64url')

  return {
    token: `${unsigned}.${signature}`,
    expiresIn: ttlSeconds,
    expiresAt: payload.exp,
  }
}
