import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import test from 'node:test'
import { AuthzCache } from '../src/authz-cache.js'
import { authorizeChannel, buildProxyClaims, parseChannel } from '../src/channel.js'
import { loadConfig } from '../src/config.js'
import { signConnectionToken } from '../src/connection-token.js'
import { constantTimeEqual, matchesAny } from '../src/constant-time.js'
import { JwksResolver } from '../src/jwks.js'
import { RateLimiter } from '../src/rate-limit.js'
import { verifySupabaseToken } from '../src/supabase-token.js'

const USER_ID = '11111111-1111-4111-8111-111111111111'
const OTHER_USER_ID = '22222222-2222-4222-8222-222222222222'
const TENANT_ID = '33333333-3333-4333-8333-333333333333'
const OTHER_TENANT_ID = '44444444-4444-4444-8444-444444444444'
const ISSUER = 'test-issuer'

const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' })

function encode(value) {
  return Buffer.from(JSON.stringify(value)).toString('base64url')
}

function signJwt(claims, { alg = 'ES256', kid = 'test-key', secret = '' } = {}) {
  const header = { alg, typ: 'JWT' }
  if (alg === 'ES256') header.kid = kid
  const unsigned = `${encode(header)}.${encode(claims)}`
  const signature = alg === 'ES256'
    ? crypto.sign('sha256', Buffer.from(unsigned), { key: privateKey, dsaEncoding: 'ieee-p1363' })
    : crypto.createHmac('sha256', secret).update(unsigned).digest()
  return `${unsigned}.${signature.toString('base64url')}`
}

function claims(overrides = {}) {
  const now = Math.floor(Date.now() / 1000)
  return {
    iss: ISSUER,
    aud: 'authenticated',
    role: 'authenticated',
    sub: USER_ID,
    iat: now,
    exp: now + 60,
    app_metadata: { tenant_id: TENANT_ID },
    ...overrides,
  }
}

function verify(token, overrides = {}) {
  return verifySupabaseToken(token, {
    jwks: { getKey: async () => publicKey },
    jwtSecret: 'legacy-secret',
    issuers: [ISSUER, 'supabase'],
    audience: 'authenticated',
    nowSeconds: Math.floor(Date.now() / 1000),
    ...overrides,
  })
}

test('verifies an ES256 Supabase token and extracts tenant', async () => {
  const result = await verify(signJwt(claims()))
  assert.equal(result.sub, USER_ID)
  assert.equal(result.role, 'authenticated')
  assert.equal(result.tenantId, TENANT_ID)
})

test('rejects expired, service-role, wrong-audience, and unsupported tokens', async () => {
  const now = Math.floor(Date.now() / 1000)
  await assert.rejects(verify(signJwt(claims({ exp: now - 120 }))), { code: 'token_expired' })
  await assert.rejects(verify(signJwt(claims({ role: 'service_role' }))), {
    code: 'role_not_allowed',
    status: 403,
  })
  await assert.rejects(verify(signJwt(claims({ role: 'anon' }))), {
    code: 'role_not_allowed',
    status: 403,
  })
  await assert.rejects(verify(signJwt(claims({ aud: 'other' }))), { code: 'invalid_audience' })
  await assert.rejects(verify(signJwt(claims(), { alg: 'none' })), {
    code: 'unsupported_algorithm',
  })
})

test('does not trust user-editable user_metadata for tenant authorization', async () => {
  const result = await verify(
    signJwt(claims({ app_metadata: {}, user_metadata: { tenant_id: TENANT_ID } }))
  )
  assert.equal(result.tenantId, null)

  const decision = await authorizeChannel({
    action: 'subscribe',
    channel: `tenant:${TENANT_ID}:table:messages`,
    userId: USER_ID,
    claims: { user_metadata: { tenant_id: TENANT_ID } },
  })
  assert.equal(decision.allowed, false)
  assert.equal(decision.reason, 'tenant_mismatch')
})

test('verifies legacy HS256 tokens when a secret is configured', async () => {
  const token = signJwt(claims({ iss: 'supabase' }), { alg: 'HS256', secret: 'legacy-secret' })
  const result = await verify(token)
  assert.equal(result.sub, USER_ID)
  await assert.rejects(
    verify(token, { allowLegacyHs256: false }),
    { code: 'unsupported_algorithm' }
  )
})

test('parses only the declared channel namespaces', () => {
  assert.deepEqual(parseChannel(`tenant:${TENANT_ID}:table:messages`), {
    channel: `tenant:${TENANT_ID}:table:messages`,
    namespace: 'tenant',
    id: TENANT_ID,
    segments: ['table', 'messages'],
  })
  assert.equal(parseChannel(`user:${USER_ID}`)?.namespace, 'user')
  assert.equal(parseChannel('public:news')?.id, 'news')
  assert.equal(parseChannel('unknown:value'), null)
  assert.equal(parseChannel('tenant:not-a-uuid'), null)
  assert.equal(parseChannel('public:news:extra'), null)
  assert.equal(parseChannel('public:'), null)
  assert.equal(parseChannel(`tenant:${TENANT_ID}:${'x'.repeat(256)}`), null)
})

test('authorizes public, user, and tenant channels with default deny', async () => {
  assert.equal((await authorizeChannel({ action: 'subscribe', channel: 'public:news' })).allowed, true)
  assert.equal((await authorizeChannel({ action: 'publish', channel: 'public:news' })).allowed, false)
  assert.equal(
    (await authorizeChannel({
      action: 'publish',
      channel: 'public:news',
      userId: USER_ID,
      claims: {},
    })).allowed,
    true
  )
  assert.equal(
    (await authorizeChannel({
      action: 'subscribe',
      channel: `user:${USER_ID}`,
      userId: USER_ID,
      claims: {},
    })).allowed,
    true
  )
  assert.equal(
    (await authorizeChannel({
      action: 'subscribe',
      channel: `user:${OTHER_USER_ID}`,
      userId: USER_ID,
      claims: {},
    })).allowed,
    false
  )
  assert.equal(
    (await authorizeChannel({
      action: 'subscribe',
      channel: `tenant:${TENANT_ID}:table:messages`,
      userId: USER_ID,
      claims: { app_metadata: { tenant_id: TENANT_ID } },
    })).allowed,
    true
  )
  assert.equal(
    (await authorizeChannel({
      action: 'subscribe',
      channel: `tenant:${OTHER_TENANT_ID}:table:messages`,
      userId: USER_ID,
      claims: { app_metadata: { tenant_id: TENANT_ID } },
    })).allowed,
    false
  )
})

test('uses the database decision when configured and defaults deny on database failure', async () => {
  const allowed = await authorizeChannel({
    action: 'subscribe',
    channel: `tenant:${TENANT_ID}`,
    userId: USER_ID,
    claims: {},
    dbAuthorize: async () => true,
  })
  assert.equal(allowed.allowed, true)

  const denied = await authorizeChannel({
    action: 'subscribe',
    channel: `tenant:${TENANT_ID}`,
    userId: USER_ID,
    claims: {},
    dbAuthorize: async () => false,
  })
  assert.equal(denied.allowed, false)

  const failed = await authorizeChannel({
    action: 'subscribe',
    channel: `tenant:${TENANT_ID}`,
    userId: USER_ID,
    claims: {},
    dbAuthorize: async () => {
      throw new Error('database unavailable')
    },
  })
  assert.equal(failed.allowed, false)
  assert.equal(failed.reason, 'authorization_unavailable')
})

test('builds proxy claims from trusted connection metadata', () => {
  assert.deepEqual(buildProxyClaims({ user: USER_ID, meta: { tenant_id: TENANT_ID } }), {
    sub: USER_ID,
    role: 'authenticated',
    app_metadata: { tenant_id: TENANT_ID },
  })
  assert.deepEqual(buildProxyClaims({ user: '', meta: {} }), {
    sub: '',
    role: 'anon',
    app_metadata: {},
  })
})

test('signs a short-lived connection token without secrets or service claims', () => {
  const signed = signConnectionToken({
    sub: USER_ID,
    isAnonymous: false,
    tenantId: TENANT_ID,
    secret: 'connection-secret',
    kid: 'test-key',
    ttlSeconds: 900,
    issuer: 'supabase-centrifugo',
    audience: 'centrifugo',
    nowSeconds: 1700000000,
  })
  const [, payloadPart] = signed.token.split('.')
  const payload = JSON.parse(Buffer.from(payloadPart, 'base64url').toString('utf8'))
  assert.equal(payload.sub, USER_ID)
  assert.equal(payload.exp - payload.iat, 900)
  assert.equal(payload.info.role, 'authenticated')
  assert.equal(payload.meta.tenant_id, TENANT_ID)
  assert.equal('service_role' in payload, false)

  const anonymous = signConnectionToken({
    isAnonymous: true,
    secret: 'connection-secret',
    kid: 'test-key',
    ttlSeconds: 900,
    issuer: 'supabase-centrifugo',
    audience: 'centrifugo',
    nowSeconds: 1700000000,
  })
  const anonymousPayload = JSON.parse(
    Buffer.from(anonymous.token.split('.')[1], 'base64url').toString('utf8')
  )
  assert.equal(anonymousPayload.sub, '')
  assert.equal(anonymousPayload.info.role, 'anon')
})

test('requires an explicit JWKS URL', () => {
  assert.throws(
    () =>
      loadConfig({
        CENTRIFUGO_CLIENT_TOKEN_HMAC_SECRET_KEY: 'connection-secret',
        SUPABASE_ANON_KEY: 'anon-key',
      }),
    { message: 'SUPABASE_JWKS_URL is required' }
  )
})

test('fetches and caches JWKS, then refreshes after the cache window', async () => {
  let current = 1000
  let fetchCount = 0
  const jwk = publicKey.export({ format: 'jwk' })
  jwk.kid = 'test-key'
  jwk.alg = 'ES256'
  jwk.use = 'sig'

  const resolver = new JwksResolver({
    url: 'jwks',
    ttlMs: 5000,
    timeoutMs: 100,
    now: () => current,
    fetchImpl: async () => {
      fetchCount += 1
      return { ok: true, json: async () => ({ keys: [jwk] }) }
    },
  })

  assert.equal((await resolver.getKey('test-key')).type, 'public')
  await resolver.getKey('test-key')
  assert.equal(fetchCount, 1)

  current += 5001
  await resolver.getKey('test-key')
  assert.equal(fetchCount, 2)
})

test('cache and rate limiter enforce short windows', () => {
  let current = 1000
  const cache = new AuthzCache({ ttlSeconds: 5, version: '1', now: () => current })
  cache.set('subscribe', USER_ID, 'public:news', { allowed: true })
  assert.deepEqual(cache.get('subscribe', USER_ID, 'public:news'), { allowed: true })
  current += 5001
  assert.equal(cache.get('subscribe', USER_ID, 'public:news'), null)

  const limiter = new RateLimiter({ limit: 2, windowMs: 1000, now: () => current })
  assert.equal(limiter.consume('user').allowed, true)
  assert.equal(limiter.consume('user').allowed, true)
  assert.equal(limiter.consume('user').allowed, false)
  current += 1001
  assert.equal(limiter.consume('user').allowed, true)
})

test('constant-time key comparison accepts only exact keys', () => {
  assert.equal(constantTimeEqual('one', 'one'), true)
  assert.equal(constantTimeEqual('one', 'two'), false)
  assert.equal(matchesAny('key-b', ['key-a', 'key-b']), true)
  assert.equal(matchesAny('key-c', ['key-a', 'key-b']), false)
})
