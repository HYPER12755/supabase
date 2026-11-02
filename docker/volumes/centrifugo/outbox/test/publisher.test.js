import assert from 'node:assert/strict'
import test from 'node:test'
import {
  PublishError,
  isRetryableStatus,
  publish,
} from '../src/publisher.js'

test('isRetryableStatus only retries transient statuses', () => {
  assert.equal(isRetryableStatus(408), true)
  assert.equal(isRetryableStatus(425), true)
  assert.equal(isRetryableStatus(429), true)
  assert.equal(isRetryableStatus(500), true)
  assert.equal(isRetryableStatus(503), true)
  assert.equal(isRetryableStatus(400), false)
  assert.equal(isRetryableStatus(401), false)
  assert.equal(isRetryableStatus(403), false)
  assert.equal(isRetryableStatus(422), false)
})

test('publish sends the API key and a stable idempotency key', async () => {
  const calls = []
  const fetchImpl = async (url, options) => {
    calls.push({ url, options })
    return { ok: true, status: 200 }
  }

  await publish({
    apiUrl: 'http://centrifugo:8000/',
    apiKey: 'api-key',
    channel: 'tenant:11111111-1111-4111-8111-111111111111:table:messages',
    data: { event: 'insert', message_id: 'message-1' },
    messageId: 'message-1',
    timeoutMs: 1000,
    fetchImpl,
  })

  assert.equal(calls.length, 1)
  assert.equal(calls[0].url, 'http://centrifugo:8000/api/publish')
  assert.equal(calls[0].options.method, 'POST')
  assert.equal(calls[0].options.headers['X-API-Key'], 'api-key')
  assert.deepEqual(JSON.parse(calls[0].options.body), {
    channel: 'tenant:11111111-1111-4111-8111-111111111111:table:messages',
    data: { event: 'insert', message_id: 'message-1' },
    idempotency_key: 'message-1',
  })
})

test('publish marks permanent and transient failures correctly', async () => {
  await assert.rejects(
    () =>
      publish({
        apiUrl: 'http://centrifugo:8000',
        apiKey: 'api-key',
        channel: 'public:test',
        data: {},
        messageId: 'message-1',
        timeoutMs: 1000,
        fetchImpl: async () => ({ ok: false, status: 422 }),
      }),
    (error) => {
      assert.ok(error instanceof PublishError)
      assert.equal(error.retryable, false)
      assert.equal(error.status, 422)
      return true
    }
  )

  await assert.rejects(
    () =>
      publish({
        apiUrl: 'http://centrifugo:8000',
        apiKey: 'api-key',
        channel: 'public:test',
        data: {},
        messageId: 'message-1',
        timeoutMs: 1000,
        fetchImpl: async () => ({ ok: false, status: 503 }),
      }),
    (error) => {
      assert.ok(error instanceof PublishError)
      assert.equal(error.retryable, true)
      assert.equal(error.status, 503)
      return true
    }
  )
})

test('publish treats network errors as transient', async () => {
  await assert.rejects(
    () =>
      publish({
        apiUrl: 'http://centrifugo:8000',
        apiKey: 'api-key',
        channel: 'public:test',
        data: {},
        messageId: 'message-1',
        timeoutMs: 1000,
        fetchImpl: async () => {
          throw new Error('connection refused')
        },
      }),
    (error) => {
      assert.ok(error instanceof PublishError)
      assert.equal(error.retryable, true)
      return true
    }
  )
})
