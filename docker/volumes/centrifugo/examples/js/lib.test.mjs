import assert from 'node:assert/strict'
import test from 'node:test'
import {
  ChannelNameError,
  Deduplicator,
  TokenError,
  channelTenant,
  fetchConnectionToken,
  normalizeError,
  publicChannel,
  publicationKey,
  tenantChannel,
  userChannel,
} from './lib.mjs'

const tenant = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const user = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'

test('builds tenant, user, and public channels', () => {
  assert.equal(tenantChannel(tenant.toUpperCase(), 'table', 'messages'), `tenant:${tenant}:table:messages`)
  assert.equal(tenantChannel(tenant), `tenant:${tenant}`)
  assert.equal(userChannel(user), `user:${user}`)
  assert.equal(publicChannel('news.room-1'), 'public:news.room-1')
  assert.equal(channelTenant(`tenant:${tenant}:table:messages`), tenant)
  assert.equal(channelTenant(userChannel(user)), null)
})

test('rejects invalid channels', () => {
  assert.throws(() => tenantChannel('not-a-uuid'), ChannelNameError)
  assert.throws(() => tenantChannel(tenant, 'a', 'b', 'c', 'd', 'e'), ChannelNameError)
  assert.throws(() => tenantChannel(tenant, 'bad segment'), ChannelNameError)
  assert.throws(() => userChannel('not-a-user'), ChannelNameError)
  assert.throws(() => publicChannel('bad:name'), ChannelNameError)
  assert.throws(() => publicChannel('bad name'), ChannelNameError)
})

test('deduplicates message ids and offsets with ttl and limit', () => {
  let now = 1000
  const dedupe = new Deduplicator({ limit: 2, ttl: 100, now: () => now })
  assert.equal(dedupe.accept(publicationKey({ data: { message_id: 'm1' } })), true)
  assert.equal(dedupe.accept(publicationKey({ data: { message_id: 'm1' } })), false)
  assert.equal(dedupe.accept(publicationKey({ offset: 2 })), true)
  assert.equal(dedupe.accept(publicationKey({ offset: 3 })), true)
  assert.equal(dedupe.accept(publicationKey({ data: { message_id: 'm1' } })), true)
  assert.equal(dedupe.accept(undefined), true)
  now += 101
  assert.equal(dedupe.accept(publicationKey({ offset: 3 })), true)
})

test('normalizes SDK and subscription errors', () => {
  assert.deepEqual(normalizeError({ code: 403, message: 'denied' }), {
    code: 403,
    message: 'denied',
    action: 'authorization',
    retryable: false,
  })
  assert.deepEqual(normalizeError({ type: 'subscribe', error: { code: 2500, message: 'restart' } }), {
    code: 2500,
    message: 'restart',
    action: 'resubscribe',
    retryable: false,
  })
  assert.deepEqual(normalizeError({ status: 429, message: 'slow down', retryable: true }), {
    code: 429,
    message: 'slow down',
    action: 'rate_limit',
    retryable: true,
  })
})

test('fetches a connection token with credentials', async () => {
  let request
  const token = await fetchConnectionToken({
    baseUrl: 'https://example.test',
    apikey: 'anon-key',
    getAccessToken: () => 'user-token',
    fetchImpl: async (url, options) => {
      request = { url: String(url), options }
      return Response.json({ token: 'connection-token', expires_in: 900 })
    },
  })
  assert.equal(token, 'connection-token')
  assert.equal(request.url, 'https://example.test/centrifugo/v1/auth/token')
  assert.equal(request.options.headers.apikey, 'anon-key')
  assert.equal(request.options.headers.authorization, 'Bearer user-token')
})

test('maps token endpoint failures', async () => {
  await assert.rejects(
    fetchConnectionToken({
      baseUrl: 'https://example.test',
      apikey: 'anon-key',
      fetchImpl: async () => Response.json({ error: 'service_key_not_allowed' }, { status: 403 }),
    }),
    (error) => {
      assert.ok(error instanceof TokenError)
      assert.equal(error.status, 403)
      assert.equal(error.code, 'service_key_not_allowed')
      assert.equal(error.retryable, false)
      return true
    }
  )

  await assert.rejects(
    fetchConnectionToken({
      baseUrl: 'https://example.test',
      apikey: 'anon-key',
      fetchImpl: async () => Response.json({ message: 'busy' }, { status: 503 }),
    }),
    (error) => error.retryable === true
  )

  await assert.rejects(
    fetchConnectionToken({
      baseUrl: 'https://example.test',
      apikey: 'anon-key',
      fetchImpl: async () => {
        throw new Error('offline')
      },
    }),
    (error) => error.code === 'network_error' && error.retryable === true
  )
})
