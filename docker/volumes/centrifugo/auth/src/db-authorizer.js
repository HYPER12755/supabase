import pg from 'pg'

const { Pool } = pg

const AUTHORIZE_SQL = 'select centrifugo.authorize($1, $2::jsonb) as allowed'

export function createDbAuthorizer({ connectionString, statementTimeoutMs = 3000, logger }) {
  const pool = new Pool({
    connectionString,
    max: 5,
    idleTimeoutMillis: 30000,
    connectionTimeoutMillis: 3000,
    application_name: 'centrifugo-auth',
    options: `-c statement_timeout=${statementTimeoutMs}`,
  })

  pool.on('error', (error) => {
    logger?.error('auth_db_pool_error', {
      error: error.name,
      code: error.code || 'AUTH_DB_POOL_ERROR',
    })
  })

  return {
    async authorize({ channel, action, claims }) {
      const payload = JSON.stringify({ ...claims, action })
      const result = await pool.query(AUTHORIZE_SQL, [channel, payload])
      return result.rows[0]?.allowed === true
    },
    close() {
      return pool.end()
    },
  }
}
