import http from 'node:http'

function send(response, statusCode, contentType, body) {
  response.writeHead(statusCode, {
    'Content-Type': contentType,
    'Cache-Control': 'no-store',
  })
  response.end(body)
}

export function createMetricsServer({ metrics, worker }) {
  return http.createServer((request, response) => {
    if (request.method !== 'GET') {
      send(response, 405, 'text/plain; charset=utf-8', 'method not allowed\n')
      return
    }

    const path = (request.url || '/').split('?')[0]

    if (path === '/health') {
      const health = worker.health()
      const statusCode = health.status === 'ok' ? 200 : 503
      send(response, statusCode, 'application/json; charset=utf-8', `${JSON.stringify(health)}\n`)
      return
    }

    if (path === '/metrics') {
      send(response, 200, 'text/plain; version=0.0.4; charset=utf-8', metrics.render())
      return
    }

    send(response, 404, 'text/plain; charset=utf-8', 'not found\n')
  })
}
