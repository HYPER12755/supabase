export class Metrics {
  constructor() {
    this.pending = 0
    this.lagSeconds = 0
    this.batchSize = 0
    this.claimedTotal = 0
    this.publishedTotal = 0
    this.retriesTotal = 0
    this.failuresTotal = 0
    this.deadLetterTotal = 0
    this.cleanupDeletedTotal = 0
    this.workerUp = 0
  }

  setQueue(pending, lagSeconds) {
    this.pending = Number.isFinite(pending) ? pending : 0
    this.lagSeconds = Number.isFinite(lagSeconds) ? Math.max(0, lagSeconds) : 0
  }

  setBatchSize(size) {
    this.batchSize = size
  }

  setWorkerUp(up) {
    this.workerUp = up ? 1 : 0
  }

  addClaimed(count) {
    this.claimedTotal += count
  }

  addPublished(count = 1) {
    this.publishedTotal += count
  }

  addRetry(count = 1) {
    this.retriesTotal += count
  }

  addFailure(count = 1) {
    this.failuresTotal += count
  }

  addDeadLetter(count = 1) {
    this.deadLetterTotal += count
  }

  addCleanupDeleted(count) {
    this.cleanupDeletedTotal += count
  }

  render() {
    return [
      '# HELP centrifugo_outbox_pending Rows waiting to be published.',
      '# TYPE centrifugo_outbox_pending gauge',
      `centrifugo_outbox_pending ${this.pending}`,
      '# HELP centrifugo_outbox_lag_seconds Age of the oldest unpublished row.',
      '# TYPE centrifugo_outbox_lag_seconds gauge',
      `centrifugo_outbox_lag_seconds ${this.lagSeconds}`,
      '# HELP centrifugo_outbox_batch_size Rows claimed in the last batch.',
      '# TYPE centrifugo_outbox_batch_size gauge',
      `centrifugo_outbox_batch_size ${this.batchSize}`,
      '# HELP centrifugo_outbox_worker_up Whether the worker loop is running.',
      '# TYPE centrifugo_outbox_worker_up gauge',
      `centrifugo_outbox_worker_up ${this.workerUp}`,
      '# HELP centrifugo_outbox_claimed_total Rows claimed from the outbox.',
      '# TYPE centrifugo_outbox_claimed_total counter',
      `centrifugo_outbox_claimed_total ${this.claimedTotal}`,
      '# HELP centrifugo_outbox_published_total Rows published successfully.',
      '# TYPE centrifugo_outbox_published_total counter',
      `centrifugo_outbox_published_total ${this.publishedTotal}`,
      '# HELP centrifugo_outbox_retries_total Rows rescheduled after a transient failure.',
      '# TYPE centrifugo_outbox_retries_total counter',
      `centrifugo_outbox_retries_total ${this.retriesTotal}`,
      '# HELP centrifugo_outbox_failures_total Publish attempts that failed.',
      '# TYPE centrifugo_outbox_failures_total counter',
      `centrifugo_outbox_failures_total ${this.failuresTotal}`,
      '# HELP centrifugo_outbox_dead_letter_total Rows moved to the dead-letter table.',
      '# TYPE centrifugo_outbox_dead_letter_total counter',
      `centrifugo_outbox_dead_letter_total ${this.deadLetterTotal}`,
      '# HELP centrifugo_outbox_cleanup_deleted_total Retained rows removed.',
      '# TYPE centrifugo_outbox_cleanup_deleted_total counter',
      `centrifugo_outbox_cleanup_deleted_total ${this.cleanupDeletedTotal}`,
      '',
    ].join('\n')
  }
}
