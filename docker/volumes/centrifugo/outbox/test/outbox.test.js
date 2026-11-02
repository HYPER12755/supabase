import assert from 'node:assert/strict'
import test from 'node:test'
import { loadConfig } from '../src/config.js'
import {
  OutboxWorker,
  backoffSeconds,
  buildMessageData,
} from '../src/outbox.js'
import { Metrics } from '../src/metrics.js'
import { PublishError } from '../src/publisher.js'

const config = loadConfig({
  CENTRIFUGO_OUTBOX_DATABASE_URL: 'postgresql://centrifugo_outbox:secret@db:5432/postgres',
  CENTRIFUGO_HTTP_API_URL: 'http://centrifugo:8000',
  CENTRIFUGO_HTTP_API_KEY: 'secret-key',
  CENTRIFUGO_OUTBOX_MAX_ATTEMPTS: '2',
})

function makeRow(overrides = {}) {
  return {
    id: '1',
    message_id: '11111111-1111-4111-8111-111111111111',
    channel: 'tenant:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa:table:messages',
    tenant_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    event: 'insert',
    payload: { event: 'insert', tenant_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' },
    attempts: 0,
    ...overrides,
  }
}

function fakePool() {
  const calls = []
  const pool = {
    calls,
    async query(sql, params) {
      calls.push({ sql, params })

      if (sql.includes('WITH deleted')) {
        return { rows: [], rowCount: 1 }
      }
      if (sql.includes('QUEUE_METRICS_SQL_MARKER')) {
        return { rows: [{ pending: 0, lag_seconds: 0 }], rowCount: 1 }
      }
      if (sql.includes('count(*)::integer AS pending')) {
        return { rows: [{ pending: 0, lag_seconds: 0 }], rowCount: 1 }
      }
      if (sql.includes('WITH candidates')) {
        return { rows: [], rowCount: 0 }
      }
      return { rows: [], rowCount: 1 }
    },
  }
  return pool
}

function workerWith(pool, publishImpl) {
  return new OutboxWorker({
    config,
    pool,
    metrics: new Metrics(),
    publishImpl,
  })
}

test('backoffSeconds grows exponentially and respects the cap', () => {
  assert.equal(backoffSeconds(1, { baseSeconds: 1, maxSeconds: 60 }), 1)
  assert.equal(backoffSeconds(2, { baseSeconds: 1, maxSeconds: 60 }), 2)
  assert.equal(backoffSeconds(4, { baseSeconds: 1, maxSeconds: 60 }), 8)
  assert.equal(backoffSeconds(20, { baseSeconds: 1, maxSeconds: 60 }), 60)
})

test('buildMessageData keeps payload data and adds the stable message id', () => {
  const row = makeRow({ payload: { event: 'insert', body: 'hello' } })
  const data = buildMessageData(row)

  assert.deepEqual(data, {
    event: 'insert',
    body: 'hello',
    message_id: row.message_id,
  })
  assert.equal(row.payload.message_id, undefined)
})

test('processRow publishes with the message id as idempotency key', async () => {
  const pool = fakePool()
  let published = null
  const worker = workerWith(pool, async (request) => {
    published = request
  })

  const result = await worker.processRow(makeRow())

  assert.equal(result, true)
  assert.equal(published.messageId, '11111111-1111-4111-8111-111111111111')
  assert.equal(published.channel, makeRow().channel)
  assert.equal(published.data.message_id, makeRow().message_id)
  assert.equal(worker.metrics.publishedTotal, 1)
})

test('transient failures are retried with backoff and attempts', async () => {
  const pool = fakePool()
  const worker = workerWith(pool, async () => {
    throw new PublishError('temporary', { retryable: true })
  })

  await worker.processRow(makeRow({ attempts: 0 }))

  const retry = pool.calls.find((call) => call.sql.includes('available_at = now()'))
  assert.ok(retry)
  assert.equal(retry.params[0], '1')
  assert.equal(retry.params[2], 1)
  assert.equal(retry.params[3], 1)
  assert.equal(worker.metrics.retriesTotal, 1)
  assert.equal(worker.metrics.failuresTotal, 1)
})

test('permanent failures move the row to the dead-letter table', async () => {
  const pool = fakePool()
  const worker = workerWith(pool, async () => {
    throw new PublishError('bad payload', { retryable: false })
  })

  await worker.processRow(makeRow())

  const deadLetter = pool.calls.find((call) => call.sql.includes('WITH deleted'))
  assert.ok(deadLetter)
  assert.equal(deadLetter.params[2], 1)
  assert.equal(worker.metrics.deadLetterTotal, 1)
  assert.equal(worker.metrics.retriesTotal, 0)
})

test('exhausted retries move the row to the dead-letter table', async () => {
  const pool = fakePool()
  const worker = workerWith(pool, async () => {
    throw new PublishError('still failing', { retryable: true })
  })

  await worker.processRow(makeRow({ attempts: 1 }))

  const deadLetter = pool.calls.find((call) => call.sql.includes('WITH deleted'))
  assert.ok(deadLetter)
  assert.equal(deadLetter.params[2], 2)
  assert.equal(worker.metrics.deadLetterTotal, 1)
})

test('partitioned mode scopes claims to the configured hash partition', async () => {
  const partitionedConfig = loadConfig({
    CENTRIFUGO_OUTBOX_DATABASE_URL: 'postgresql://centrifugo_outbox:secret@db:5432/postgres',
    CENTRIFUGO_HTTP_API_URL: 'http://centrifugo:8000',
    CENTRIFUGO_HTTP_API_KEY: 'secret-key',
    CENTRIFUGO_OUTBOX_ORDERING_MODE: 'partitioned',
    CENTRIFUGO_OUTBOX_PARTITION_COUNT: '4',
    CENTRIFUGO_OUTBOX_PARTITION_INDEX: '2',
  })
  const pool = fakePool()
  const worker = new OutboxWorker({
    config: partitionedConfig,
    pool,
    metrics: new Metrics(),
    publishImpl: async () => {},
  })

  await worker.claimBatch()

  const claim = pool.calls.find((call) => call.sql.includes('WITH candidates'))
  assert.ok(claim)
  assert.equal(claim.params[1], 4)
  assert.equal(claim.params[2], 2)
  assert.match(claim.sql, /hashtext\(outbox\.channel\)/)
  assert.match(claim.sql, /delayed\.available_at > now\(\)/)
})

test('a transient failure pauses the rest of the batch to preserve order', async () => {
  const pool = fakePool()
  const published = []

  pool.query = async (sql, params) => {
    pool.calls.push({ sql, params })

    if (sql.includes('WITH candidates')) {
      return {
        rows: [
          makeRow({ id: '1', message_id: '11111111-1111-4111-8111-111111111111' }),
          makeRow({ id: '2', message_id: '22222222-2222-4222-8222-222222222222' }),
        ],
        rowCount: 2,
      }
    }
    if (sql.includes('count(*)::integer AS pending')) {
      return { rows: [{ pending: 0, lag_seconds: 0 }], rowCount: 1 }
    }
    return { rows: [], rowCount: 1 }
  }

  const worker = workerWith(pool, async (request) => {
    published.push(request.messageId)
    throw new PublishError('temporary', { retryable: true })
  })
  worker.running = true

  await worker.runOnce()

  assert.deepEqual(published, ['11111111-1111-4111-8111-111111111111'])
  assert.equal(worker.metrics.retriesTotal, 1)

  const release = pool.calls.find(
    (call) =>
      call.sql.includes('ANY($1::bigint[])') &&
      call.params?.[1] === worker.config.workerId
  )
  assert.ok(release)
  assert.deepEqual(release.params[0], ['1', '2'])
})

test('runOnce claims and publishes rows in id order', async () => {
  const pool = fakePool()
  const published = []
  pool.query = async (sql, params) => {
    pool.calls.push({ sql, params })

    if (sql.includes('WITH candidates')) {
      return {
        rows: [
          makeRow({ id: '3', message_id: '33333333-3333-4333-8333-333333333333' }),
          makeRow({ id: '1', message_id: '11111111-1111-4111-8111-111111111111' }),
          makeRow({ id: '2', message_id: '22222222-2222-4222-8222-222222222222' }),
        ],
        rowCount: 3,
      }
    }
    if (sql.includes('count(*)::integer AS pending')) {
      return { rows: [{ pending: 0, lag_seconds: 0 }], rowCount: 1 }
    }
    return { rows: [], rowCount: 1 }
  }

  const worker = workerWith(pool, async (request) => {
    published.push(request.messageId)
  })
  worker.running = true

  await worker.runOnce()

  assert.deepEqual(published, [
    '11111111-1111-4111-8111-111111111111',
    '22222222-2222-4222-8222-222222222222',
    '33333333-3333-4333-8333-333333333333',
  ])
})
