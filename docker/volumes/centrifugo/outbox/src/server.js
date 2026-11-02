import { Client, Pool } from 'pg'
import { loadConfig } from './config.js'
import { Metrics } from './metrics.js'
import { createMetricsServer } from './metrics-server.js'
import { OutboxWorker } from './outbox.js'

const config = loadConfig()
const metrics = new Metrics()

const logger = {
  info(message, details) {
    if (details) {
      console.log(message, details)
      return
    }
    console.log(message)
  },
  error(message, details) {
    if (details) {
      console.error(message, details)
      return
    }
    console.error(message)
  },
}

const pool = new Pool({
  connectionString: config.databaseUrl,
  max: 5,
  application_name: 'centrifugo-outbox',
  statement_timeout: config.statementTimeoutMs,
  query_timeout: config.statementTimeoutMs,
  connectionTimeoutMillis: 5000,
})

pool.on('error', (error) => {
  logger.error('outbox database pool error', { error: error.message })
})

const worker = new OutboxWorker({
  config,
  pool,
  metrics,
  logger,
})

const metricsServer = createMetricsServer({ metrics, worker })

let listener = null
let listenerTimer = null
let stopping = false

function scheduleListenerReconnect() {
  if (stopping || listenerTimer !== null) {
    return
  }

  listenerTimer = setTimeout(() => {
    listenerTimer = null
    connectListener().catch((error) => {
      logger.error('outbox listener reconnect failed', { error: error.message })
      scheduleListenerReconnect()
    })
  }, 1000)
}

async function connectListener() {
  if (stopping) {
    return
  }

  const client = new Client({
    connectionString: config.databaseUrl,
    application_name: 'centrifugo-outbox-listener',
    connectionTimeoutMillis: 5000,
  })

  listener = client

  client.on('notification', (message) => {
    if (message.channel === config.notificationChannel) {
      worker.wake()
    }
  })

  client.on('error', (error) => {
    logger.error('outbox listener error', { error: error.message })
  })

  client.on('end', () => {
    if (listener === client) {
      listener = null
    }
    if (!stopping) {
      scheduleListenerReconnect()
    }
  })

  await client.connect()
  await client.query('LISTEN centrifugo_outbox')
  logger.info('outbox listening for notifications')
}

async function shutdown(signal) {
  if (stopping) {
    return
  }

  stopping = true
  logger.info('outbox shutting down', { signal })

  if (listenerTimer !== null) {
    clearTimeout(listenerTimer)
    listenerTimer = null
  }

  await worker.stop()

  if (listener !== null) {
    try {
      await listener.end()
    } catch (error) {
      logger.error('outbox listener shutdown failed', { error: error.message })
    }
  }

  await new Promise((resolve) => metricsServer.close(resolve))
  await pool.end()
}

metricsServer.on('error', (error) => {
  logger.error('outbox metrics server error', { error: error.message })
  process.exitCode = 1
})

metricsServer.listen(config.metricsPort, config.metricsHost, () => {
  logger.info('outbox metrics listening', {
    host: config.metricsHost,
    port: config.metricsPort,
  })
})

connectListener().catch((error) => {
  logger.error('outbox listener connection failed', { error: error.message })
  scheduleListenerReconnect()
})

worker.start()
logger.info('outbox worker started', {
  workerId: config.workerId,
  orderingMode: config.orderingMode,
  partitionCount: config.partitionCount,
  partitionIndex: config.partitionIndex,
})

process.on('SIGTERM', (signal) => {
  shutdown(signal).catch((error) => {
    logger.error('outbox shutdown failed', { error: error.message })
    process.exit(1)
  })
})

process.on('SIGINT', (signal) => {
  shutdown(signal).catch((error) => {
    logger.error('outbox shutdown failed', { error: error.message })
    process.exit(1)
  })
})
