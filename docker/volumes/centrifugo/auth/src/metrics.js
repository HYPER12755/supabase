const HISTOGRAM_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]

const METRICS = [
  ['centrifugo_auth_http_requests_total', 'counter', 'HTTP requests by method, route, and status.'],
  [
    'centrifugo_auth_http_request_duration_seconds',
    'histogram',
    'HTTP request duration in seconds.',
  ],
  ['centrifugo_auth_token_issued_total', 'counter', 'Connection tokens issued by role.'],
  ['centrifugo_auth_token_failures_total', 'counter', 'Token issuance failures by reason.'],
  [
    'centrifugo_auth_authorization_decisions_total',
    'counter',
    'Channel authorization decisions by action and result.',
  ],
  [
    'centrifugo_auth_authorization_duration_seconds',
    'histogram',
    'Channel authorization duration in seconds.',
  ],
  ['centrifugo_auth_publish_rejected_total', 'counter', 'Publishes rejected by reason.'],
  ['centrifugo_auth_rate_limited_total', 'counter', 'Rate-limited requests by scope.'],
  [
    'centrifugo_auth_process_start_time_seconds',
    'gauge',
    'Process start time since the Unix epoch.',
  ],
]

function escapeLabel(value) {
  return String(value).replaceAll('\\', '\\\\').replaceAll('\n', '\\n').replaceAll('"', '\\"')
}

function labelKey(labels) {
  return Object.keys(labels)
    .sort()
    .map((name) => `${name}="${escapeLabel(labels[name])}"`)
    .join(',')
}

function renderLabels(labels, extra = '') {
  const parts = []
  for (const name of Object.keys(labels).sort()) {
    parts.push(`${name}="${escapeLabel(labels[name])}"`)
  }
  if (extra) parts.push(extra)
  return parts.length > 0 ? `{${parts.join(',')}}` : ''
}

export class Metrics {
  constructor({ startTimeSeconds = Math.floor(Date.now() / 1000) } = {}) {
    this.counters = new Map()
    this.gauges = new Map()
    this.histograms = new Map()
    this.set('centrifugo_auth_process_start_time_seconds', startTimeSeconds)
  }

  inc(name, labels = {}, value = 1) {
    this.#counterBucket(name, labels).value += value
  }

  set(name, value, labels = {}) {
    this.#gaugeBucket(name, labels).value = value
  }

  observe(name, seconds, labels = {}) {
    const bucket = this.#histogramBucket(name, labels)
    const value = Number.isFinite(seconds) && seconds >= 0 ? seconds : 0

    bucket.sum += value
    bucket.count += 1
    for (let index = 0; index < bucket.buckets.length; index += 1) {
      if (value <= HISTOGRAM_BUCKETS[index]) bucket.buckets[index] += 1
    }
  }

  render() {
    const lines = []

    for (const [name, type, help] of METRICS) {
      lines.push(`# HELP ${name} ${help}`)
      lines.push(`# TYPE ${name} ${type}`)

      if (type === 'histogram') {
        for (const series of this.histograms.get(name)?.values() || []) {
          for (let index = 0; index < HISTOGRAM_BUCKETS.length; index += 1) {
            lines.push(
              `${name}_bucket${renderLabels(series.labels, `le="${HISTOGRAM_BUCKETS[index]}"`)} ${series.buckets[index]}`
            )
          }
          lines.push(
            `${name}_bucket${renderLabels(series.labels, 'le="+Inf"')} ${series.count}`
          )
          lines.push(`${name}_sum${renderLabels(series.labels)} ${series.sum}`)
          lines.push(`${name}_count${renderLabels(series.labels)} ${series.count}`)
        }
        continue
      }

      const values = type === 'counter' ? this.counters : this.gauges
      for (const series of values.get(name)?.values() || []) {
        lines.push(`${name}${renderLabels(series.labels)} ${series.value}`)
      }
    }

    return `${lines.join('\n')}\n`
  }

  #counterBucket(name, labels) {
    return this.#bucket(this.counters, name, labels, () => ({ value: 0 }))
  }

  #gaugeBucket(name, labels) {
    return this.#bucket(this.gauges, name, labels, () => ({ value: 0 }))
  }

  #histogramBucket(name, labels) {
    return this.#bucket(this.histograms, name, labels, () => ({
      buckets: HISTOGRAM_BUCKETS.map(() => 0),
      sum: 0,
      count: 0,
    }))
  }

  #bucket(store, name, labels, create) {
    let named = store.get(name)
    if (!named) {
      named = new Map()
      store.set(name, named)
    }

    const key = labelKey(labels)
    let series = named.get(key)
    if (!series) {
      series = { labels: { ...labels }, ...create() }
      named.set(key, series)
    }
    return series
  }
}
