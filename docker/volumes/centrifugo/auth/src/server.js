import http from 'node:http'
import { createApp } from './app.js'
import { loadConfig } from './config.js'
import { createDbAuthorizer } from './db-authorizer.js'
import { sendJson } from './http.js'
import { JwksResolver } from './jwks.js'
import { createLogger } from './logger.js'

function errorFields(error) {
  return {
    error: error?.name || 'Error',
    code: error?.code || 'UNKNOWN',
  }
}

async function main() {
  let config
  try {
    config = loadConfig()
  } catch (error) {
    process.stderr.write(
      `${JSON.stringify({ level: 'error', msg: 'config_invalid', error: error.message })}\n`
    )
    process.exit(1)
  }

  const logger = createLogger({ level: process.env.CENTRIFUGO_AUTH_LOG_LEVEL || 'info' })
  const jwks = new JwksResolver({
    url: config.jwksUrl,
    ttlMs: config.jwksCacheSeconds * 1000,
    timeoutMs: config.jwksTimeoutMs,
    logger,
  })
  const dbAuthorizer = config.databaseUrl
    ? createDbAuthorizer({
        connectionString: config.databaseUrl,
        statementTimeoutMs: config.databaseStatementTimeoutMs,
        logger,
      })
    : null

  const app = createApp({ config, logger, jwks, dbAuthorizer })
  const server = http.createServer((req, res) => {
    app(req, res).catch((error) => {
      logger.error('request_handler_failed', errorFields(error))
      if (!res.headersSent) {
        sendJson(res, 500, { error: 'internal_error', message: 'internal error' })
      } else {
        res.destroy()
      }
    })
  })

  server.requestTimeout = 15000
  server.headersTimeout = 10000
  server.keepAliveTimeout = 5000

  server.on('error', (error) => {
    logger.error('server_error', errorFields(error))
    process.exit(1)
  })

  server.listen(config.port, '0.0.0.0', () => {
    logger.info('started', {
      port: config.port,
      authz_mode: dbAuthorizer ? 'database' : 'local',
    })
  })

  let shuttingDown = false
  async function shutdown(signal) {
    if (shuttingDown) return
    shuttingDown = true
    logger.info('shutdown_started', { signal })
    server.close()
    const forceTimer = setTimeout(() => {
      server.closeAllConnections()
      process.exit(1)
    }, 10000)
    forceTimer.unref()

    try {
      await dbAuthorizer?.close()
    } catch (error) {
      logger.warn('shutdown_db_close_failed', errorFields(error))
    }

    process.exit(0)
  }

  process.on('SIGTERM', () => shutdown('SIGTERM'))
  process.on('SIGINT', () => shutdown('SIGINT'))
  process.on('unhandledRejection', (error) => {
    logger.error('unhandled_rejection', errorFields(error))
  })
  process.on('uncaughtException', (error) => {
    logger.error('uncaught_exception', errorFields(error))
    process.exit(1)
  })
}

main()
