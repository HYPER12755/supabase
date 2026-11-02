import crypto from 'node:crypto'

export function constantTimeEqual(left, right) {
  if (typeof left !== 'string' || typeof right !== 'string') return false
  const leftDigest = crypto.createHash('sha256').update(left).digest()
  const rightDigest = crypto.createHash('sha256').update(right).digest()
  return crypto.timingSafeEqual(leftDigest, rightDigest)
}

export function matchesAny(value, candidates) {
  if (typeof value !== 'string' || value.length === 0) return false
  let matched = false
  for (const candidate of candidates) {
    if (constantTimeEqual(value, candidate)) matched = true
  }
  return matched
}
