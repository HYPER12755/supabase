export class RateLimiter {
  constructor({ limit, windowMs, maxEntries = 10000, now = () => Date.now() }) {
    this.limit = limit
    this.windowMs = windowMs
    this.maxEntries = maxEntries
    this.now = now
    this.entries = new Map()
  }

  consume(key) {
    const now = this.now()
    let entry = this.entries.get(key)

    if (!entry || entry.resetAt <= now) {
      entry = { count: 0, resetAt: now + this.windowMs }
      if (this.entries.size >= this.maxEntries) {
        const oldest = this.entries.keys().next().value
        if (oldest !== undefined) this.entries.delete(oldest)
      }
      this.entries.set(key, entry)
    }

    if (entry.count >= this.limit) {
      return {
        allowed: false,
        retryAfterSeconds: Math.max(1, Math.ceil((entry.resetAt - now) / 1000)),
      }
    }

    entry.count += 1
    return { allowed: true, retryAfterSeconds: 0 }
  }
}
