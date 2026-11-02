export class AuthzCache {
  constructor({ ttlSeconds, version, maxEntries = 10000, now = () => Date.now() }) {
    this.ttlMs = ttlSeconds * 1000
    this.version = version
    this.maxEntries = maxEntries
    this.now = now
    this.entries = new Map()
  }

  key(action, userId, channel) {
    return `${this.version}|${action}|${userId || '-'}|${channel}`
  }

  get(action, userId, channel) {
    if (this.ttlMs <= 0) return null
    const key = this.key(action, userId, channel)
    const entry = this.entries.get(key)
    if (!entry) return null
    if (entry.expiresAt <= this.now()) {
      this.entries.delete(key)
      return null
    }
    return entry.value
  }

  set(action, userId, channel, value) {
    if (this.ttlMs <= 0) return
    if (this.entries.size >= this.maxEntries) {
      const oldest = this.entries.keys().next().value
      if (oldest !== undefined) this.entries.delete(oldest)
    }
    this.entries.set(this.key(action, userId, channel), {
      value,
      expiresAt: this.now() + this.ttlMs,
    })
  }

  clear() {
    this.entries.clear()
  }
}
