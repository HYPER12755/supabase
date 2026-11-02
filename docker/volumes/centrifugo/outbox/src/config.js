import os from 'node:os'

function readRequired(env, name) {
  const value = env[name]
  if (typeof value !== 'string' || value.trim() === '') {
    throw new Error(`${name} is required`)
  }
  return value.trim()
}

function readInteger(env, name, defaultValue, min, max) {
  const raw = env[name]
  if (raw === undefined || raw === '') {
    return defaultValue
  }

  if (!/^[0-9]+$/.test(raw)) {
    throw new Error(`${name} must be an integer`)
  }

  const value = Number(raw)
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new Error(`${name} must be between ${min} and ${max}`)
  }

  return value
}

function validateUrl(name, value, protocols) {
  let parsed
  try {
    parsed = new URL(value)
  } catch {
    throw new Error(`${name} must be a valid URL`)
  }

  if (!protocols.includes(parsed.protocol)) {
    throw new Error(`${name} must use one of: ${protocols.join(', ')}`)
  }

  return value
}

export function loadConfig(env = process.env) {
  const databaseUrl = validateUrl(
    'CENTRIFUGO_OUTBOX_DATABASE_URL',
    readRequired(env, 'CENTRIFUGO_OUTBOX_DATABASE_URL'),
    ['postgres:', 'postgresql:']
  )
  const apiUrl = validateUrl(
    'CENTRIFUGO_HTTP_API_URL',
    readRequired(env, 'CENTRIFUGO_HTTP_API_URL'),
    ['http:', 'https:']
  )
  const apiKey = readRequired(env, 'CENTRIFUGO_HTTP_API_KEY')
  const orderingMode = env.CENTRIFUGO_OUTBOX_ORDERING_MODE || 'strict'

  if (orderingMode !== 'strict' && orderingMode !== 'partitioned') {
    throw new Error('CENTRIFUGO_OUTBOX_ORDERING_MODE must be strict or partitioned')
  }

  const partitionCount = readInteger(
    env,
    'CENTRIFUGO_OUTBOX_PARTITION_COUNT',
    1,
    1,
    256
  )
  const partitionIndex = readInteger(
    env,
    'CENTRIFUGO_OUTBOX_PARTITION_INDEX',
    0,
    0,
    partitionCount - 1
  )

  if (orderingMode === 'strict' && (partitionCount !== 1 || partitionIndex !== 0)) {
    throw new Error('strict ordering requires partition count 1 and index 0')
  }

  const workerId = (
    env.CENTRIFUGO_OUTBOX_WORKER_ID || `${os.hostname()}:${process.pid}`
  ).slice(0, 128)

  return Object.freeze({
    databaseUrl,
    apiUrl,
    apiKey,
    workerId,
    orderingMode,
    partitionCount,
    partitionIndex,
    batchSize: readInteger(env, 'CENTRIFUGO_OUTBOX_BATCH_SIZE', 50, 1, 500),
    pollIntervalMs: readInteger(
      env,
      'CENTRIFUGO_OUTBOX_POLL_INTERVAL_MS',
      1000,
      100,
      60000
    ),
    lockTimeoutSeconds: readInteger(
      env,
      'CENTRIFUGO_OUTBOX_LOCK_TIMEOUT_SECONDS',
      120,
      5,
      3600
    ),
    maxAttempts: readInteger(
      env,
      'CENTRIFUGO_OUTBOX_MAX_ATTEMPTS',
      10,
      1,
      100
    ),
    retryBaseSeconds: readInteger(
      env,
      'CENTRIFUGO_OUTBOX_RETRY_BASE_SECONDS',
      1,
      1,
      3600
    ),
    retryMaxSeconds: readInteger(
      env,
      'CENTRIFUGO_OUTBOX_RETRY_MAX_SECONDS',
      60,
      1,
      3600
    ),
    retentionSeconds: readInteger(
      env,
      'CENTRIFUGO_OUTBOX_RETENTION_SECONDS',
      86400,
      60,
      2592000
    ),
    cleanupIntervalMs: readInteger(
      env,
      'CENTRIFUGO_OUTBOX_CLEANUP_INTERVAL_MS',
      60000,
      1000,
      3600000
    ),
    httpTimeoutMs: readInteger(
      env,
      'CENTRIFUGO_OUTBOX_HTTP_TIMEOUT_MS',
      5000,
      100,
      120000
    ),
    statementTimeoutMs: readInteger(
      env,
      'CENTRIFUGO_OUTBOX_STATEMENT_TIMEOUT_MS',
      10000,
      1000,
      120000
    ),
    metricsHost: env.CENTRIFUGO_OUTBOX_METRICS_HOST || '0.0.0.0',
    metricsPort: readInteger(
      env,
      'CENTRIFUGO_OUTBOX_METRICS_PORT',
      9100,
      1,
      65535
    ),
    notificationChannel: 'centrifugo_outbox',
  })
}
