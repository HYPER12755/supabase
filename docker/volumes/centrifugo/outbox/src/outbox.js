import { publish as defaultPublish } from './publisher.js'

const CLAIM_SQL = `
WITH candidates AS (
  SELECT outbox.id
  FROM centrifugo.outbox AS outbox
  WHERE outbox.published_at IS NULL
    AND outbox.available_at <= now()
    AND (outbox.locked_until IS NULL OR outbox.locked_until < now())
    AND ($2::integer = 1 OR ((hashtext(outbox.channel) & 2147483647) % $2::integer) = $3::integer)
    AND NOT EXISTS (
      SELECT 1
      FROM centrifugo.outbox AS delayed
      WHERE delayed.published_at IS NULL
        AND delayed.id < outbox.id
        AND (
          delayed.available_at > now()
          OR (delayed.locked_until IS NOT NULL AND delayed.locked_until > now())
        )
        AND ($2::integer = 1 OR ((hashtext(delayed.channel) & 2147483647) % $2::integer) = $3::integer)
    )
  ORDER BY outbox.id
  FOR UPDATE OF outbox SKIP LOCKED
  LIMIT $1::integer
)
UPDATE centrifugo.outbox AS outbox
SET locked_by = $4,
    locked_until = now() + make_interval(secs => $5::integer)
FROM candidates
WHERE outbox.id = candidates.id
RETURNING outbox.id,
          outbox.message_id,
          outbox.channel,
          outbox.tenant_id,
          outbox.event,
          outbox.payload,
          outbox.attempts
`

const RENEW_SQL = `
UPDATE centrifugo.outbox
SET locked_until = now() + make_interval(secs => $3::integer)
WHERE id = $1 AND locked_by = $2 AND published_at IS NULL
`

const PUBLISHED_SQL = `
UPDATE centrifugo.outbox
SET published_at = now(),
    locked_by = NULL,
    locked_until = NULL,
    last_error = NULL
WHERE id = $1 AND locked_by = $2
`

const RETRY_SQL = `
UPDATE centrifugo.outbox
SET attempts = $3,
    available_at = now() + make_interval(secs => $4),
    last_error = $5,
    locked_by = NULL,
    locked_until = NULL
WHERE id = $1 AND locked_by = $2
`

const DEAD_LETTER_SQL = `
WITH deleted AS (
  DELETE FROM centrifugo.outbox
  WHERE id = $1 AND locked_by = $2
  RETURNING id, message_id, channel, tenant_id, event, payload, created_at
)
INSERT INTO centrifugo.dead_letter (
  message_id,
  original_id,
  channel,
  tenant_id,
  event,
  payload,
  attempts,
  last_error,
  created_at
)
SELECT message_id,
       id,
       channel,
       tenant_id,
       event,
       payload,
       $3,
       $4,
       created_at
FROM deleted
ON CONFLICT (message_id) DO NOTHING
`

const RELEASE_LOCKS_SQL = `
UPDATE centrifugo.outbox
SET locked_by = NULL,
    locked_until = NULL
WHERE id = ANY($1::bigint[])
  AND locked_by = $2
  AND published_at IS NULL
`

const QUEUE_METRICS_SQL = `
SELECT count(*)::integer AS pending,
       coalesce(extract(epoch FROM now() - min(created_at))::double precision, 0) AS lag_seconds
FROM centrifugo.outbox
WHERE published_at IS NULL
`

const CLEANUP_SQL = `
DELETE FROM centrifugo.outbox
WHERE published_at IS NOT NULL
  AND published_at < now() - make_interval(secs => $1::integer)
`

export function backoffSeconds(
  attempt,
  { baseSeconds = 1, maxSeconds = 60 } = {}
) {
  const exponent = Math.min(20, Math.max(0, attempt - 1))
  return Math.min(maxSeconds, baseSeconds * 2 ** exponent)
}

export function buildMessageData(row) {
  const payload =
    row.payload && typeof row.payload === 'object' && !Array.isArray(row.payload)
      ? row.payload
      : {}

  return {
    ...payload,
    event: row.event,
    message_id: row.message_id,
  }
}

function compareIds(left, right) {
  const leftId = BigInt(left.id)
  const rightId = BigInt(right.id)

  if (leftId < rightId) return -1
  if (leftId > rightId) return 1
  return 0
}

function errorMessage(error) {
  const message = error instanceof Error ? error.message : String(error)
  return message.slice(0, 2000)
}

const noopLogger = {
  info() {},
  error() {},
}

export class OutboxWorker {
  constructor({
    config,
    pool,
    metrics,
    logger = noopLogger,
    publishImpl = defaultPublish,
  }) {
    this.config = config
    this.pool = pool
    this.metrics = metrics
    this.logger = logger
    this.publishImpl = publishImpl
    this.running = false
    this.waiters = new Set()
    this.done = null
    this.lastPollAt = null
    this.lastErrorAt = null
    this.lastError = null
    this.lastCleanupAt = 0
  }

  async claimBatch() {
    const result = await this.pool.query(CLAIM_SQL, [
      this.config.batchSize,
      this.config.partitionCount,
      this.config.partitionIndex,
      this.config.workerId,
      this.config.lockTimeoutSeconds,
    ])

    this.metrics.addClaimed(result.rows.length)
    this.metrics.setBatchSize(result.rows.length)
    return result.rows
  }

  async renewLock(row) {
    const result = await this.pool.query(RENEW_SQL, [
      row.id,
      this.config.workerId,
      this.config.lockTimeoutSeconds,
    ])

    return result.rowCount > 0
  }

  async markPublished(row) {
    const result = await this.pool.query(PUBLISHED_SQL, [
      row.id,
      this.config.workerId,
    ])

    return result.rowCount > 0
  }

  async scheduleRetry(row, attempts, delaySeconds, error) {
    const result = await this.pool.query(RETRY_SQL, [
      row.id,
      this.config.workerId,
      attempts,
      delaySeconds,
      errorMessage(error),
    ])

    return result.rowCount > 0
  }

  async moveToDeadLetter(row, attempts, error) {
    const result = await this.pool.query(DEAD_LETTER_SQL, [
      row.id,
      this.config.workerId,
      attempts,
      errorMessage(error),
    ])

    return result.rowCount > 0
  }

  async handleFailure(row, error) {
    const attempts = row.attempts + 1
    const retryable = error?.retryable !== false

    if (!retryable || attempts >= this.config.maxAttempts) {
      const moved = await this.moveToDeadLetter(row, attempts, error)

      if (moved) {
        this.metrics.addDeadLetter()
        this.logger.error('outbox row moved to dead letter', {
          id: row.id,
          messageId: row.message_id,
          attempts,
          error: errorMessage(error),
        })
      }

      return !moved
    }

    const delaySeconds = backoffSeconds(attempts, {
      baseSeconds: this.config.retryBaseSeconds,
      maxSeconds: this.config.retryMaxSeconds,
    })
    const updated = await this.scheduleRetry(row, attempts, delaySeconds, error)

    if (updated) {
      this.metrics.addRetry()
      this.logger.error('outbox row scheduled for retry', {
        id: row.id,
        messageId: row.message_id,
        attempts,
        delaySeconds,
        error: errorMessage(error),
      })
    }

    return true
  }

  async releaseLocks(rows) {
    if (rows.length === 0) {
      return
    }

    await this.pool.query(RELEASE_LOCKS_SQL, [
      rows.map((row) => row.id),
      this.config.workerId,
    ])
  }

  async processRow(row) {
    const renewed = await this.renewLock(row)
    if (!renewed) {
      return false
    }

    try {
      await this.publishImpl({
        apiUrl: this.config.apiUrl,
        apiKey: this.config.apiKey,
        channel: row.channel,
        data: buildMessageData(row),
        messageId: row.message_id,
        timeoutMs: this.config.httpTimeoutMs,
      })
    } catch (error) {
      this.metrics.addFailure()
      const pause = await this.handleFailure(row, error)
      return !pause
    }

    await this.markPublished(row)
    this.metrics.addPublished()
    return true
  }

  async runOnce() {
    const rows = await this.claimBatch()
    rows.sort(compareIds)
    let drain = true

    try {
      for (const row of rows) {
        if (!this.running) {
          drain = false
          break
        }

        const proceed = await this.processRow(row)
        if (!proceed) {
          drain = false
          break
        }
      }
    } catch (error) {
      this.logger.error('outbox row processing failed', {
        error: errorMessage(error),
      })
      throw error
    } finally {
      if (!drain) {
        try {
          await this.releaseLocks(rows)
        } catch (error) {
          this.logger.error('failed to release outbox locks', {
            error: errorMessage(error),
          })
        }
      }
    }

    await this.refreshQueueMetrics()
    return rows.length
  }

  async refreshQueueMetrics() {
    const result = await this.pool.query(QUEUE_METRICS_SQL)
    const row = result.rows[0] || {}
    this.metrics.setQueue(Number(row.pending || 0), Number(row.lag_seconds || 0))
  }

  async cleanup() {
    const result = await this.pool.query(CLEANUP_SQL, [
      this.config.retentionSeconds,
    ])

    if (result.rowCount > 0) {
      this.metrics.addCleanupDeleted(result.rowCount)
    }
  }

  sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms))
  }

  waitForWake(ms) {
    let timer
    let resolve

    const promise = new Promise((resolver) => {
      resolve = resolver
    })

    const done = () => {
      clearTimeout(timer)
      this.waiters.delete(done)
      resolve()
    }

    timer = setTimeout(done, ms)
    this.waiters.add(done)

    return promise
  }

  wake() {
    for (const waiter of [...this.waiters]) {
      waiter()
    }
  }

  async loop() {
    while (this.running) {
      try {
        const count = await this.runOnce()
        this.lastPollAt = Date.now()
        this.lastError = null
        this.lastErrorAt = null

        if (Date.now() - this.lastCleanupAt >= this.config.cleanupIntervalMs) {
          await this.cleanup()
          this.lastCleanupAt = Date.now()
        }

        if (count > 0) {
          continue
        }
      } catch (error) {
        this.lastError = error
        this.lastErrorAt = Date.now()
        this.logger.error('outbox poll failed', { error: errorMessage(error) })
        await this.sleep(this.config.pollIntervalMs)
      }

      if (!this.running) {
        break
      }

      await this.waitForWake(this.config.pollIntervalMs)
    }
  }

  start() {
    if (this.running) {
      return this.done
    }

    this.running = true
    this.metrics.setWorkerUp(true)
    this.done = this.loop()
    return this.done
  }

  async stop() {
    this.running = false
    this.metrics.setWorkerUp(false)
    this.wake()

    if (this.done) {
      await this.done
      this.done = null
    }
  }

  health() {
    const recentlyFailed =
      this.lastErrorAt !== null &&
      Date.now() - this.lastErrorAt < this.config.pollIntervalMs * 30

    return {
      status: this.running && !recentlyFailed ? 'ok' : 'degraded',
      lastPollAgeSeconds:
        this.lastPollAt === null ? null : Math.floor((Date.now() - this.lastPollAt) / 1000),
      lastError: this.lastError ? errorMessage(this.lastError) : null,
    }
  }
}
