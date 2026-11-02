import assert from 'node:assert/strict'
import test from 'node:test'
import { loadConfig } from '../src/config.js'

const baseEnv = {
  CENTRIFUGO_OUTBOX_DATABASE_URL: 'postgresql://centrifugo_outbox:secret@db:5432/postgres',
  CENTRIFUGO_HTTP_API_URL: 'http://centrifugo:8000',
  CENTRIFUGO_HTTP_API_KEY: 'secret-key',
}

test('loadConfig applies safe defaults', () => {
  const config = loadConfig(baseEnv)

  assert.equal(config.orderingMode, 'strict')
  assert.equal(config.partitionCount, 1)
  assert.equal(config.partitionIndex, 0)
  assert.equal(config.batchSize, 50)
  assert.equal(config.maxAttempts, 10)
  assert.equal(config.metricsPort, 9100)
  assert.equal(config.notificationChannel, 'centrifugo_outbox')
})

test('loadConfig requires every secret connection value', () => {
  assert.throws(
    () => loadConfig({ ...baseEnv, CENTRIFUGO_OUTBOX_DATABASE_URL: '' }),
    /CENTRIFUGO_OUTBOX_DATABASE_URL is required/
  )
  assert.throws(
    () => loadConfig({ ...baseEnv, CENTRIFUGO_HTTP_API_URL: '' }),
    /CENTRIFUGO_HTTP_API_URL is required/
  )
  assert.throws(
    () => loadConfig({ ...baseEnv, CENTRIFUGO_HTTP_API_KEY: '' }),
    /CENTRIFUGO_HTTP_API_KEY is required/
  )
})

test('loadConfig rejects invalid URLs', () => {
  assert.throws(
    () => loadConfig({ ...baseEnv, CENTRIFUGO_HTTP_API_URL: 'file:///tmp/api' }),
    /must use one of/
  )
  assert.throws(
    () =>
      loadConfig({
        ...baseEnv,
        CENTRIFUGO_OUTBOX_DATABASE_URL: 'redis://db:6379',
      }),
    /must use one of/
  )
})

test('loadConfig rejects unsafe ordering combinations', () => {
  assert.throws(
    () =>
      loadConfig({
        ...baseEnv,
        CENTRIFUGO_OUTBOX_PARTITION_COUNT: '2',
      }),
    /strict ordering requires/
  )

  assert.throws(
    () =>
      loadConfig({
        ...baseEnv,
        CENTRIFUGO_OUTBOX_ORDERING_MODE: 'partitioned',
        CENTRIFUGO_OUTBOX_PARTITION_COUNT: '2',
        CENTRIFUGO_OUTBOX_PARTITION_INDEX: '2',
      }),
    /between 0 and 1/
  )
})

test('loadConfig rejects malformed limits', () => {
  assert.throws(
    () => loadConfig({ ...baseEnv, CENTRIFUGO_OUTBOX_BATCH_SIZE: 'zero' }),
    /must be an integer/
  )
  assert.throws(
    () => loadConfig({ ...baseEnv, CENTRIFUGO_OUTBOX_BATCH_SIZE: '0' }),
    /must be between 1 and 500/
  )
})
