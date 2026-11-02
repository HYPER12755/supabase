import { isObject } from './errors.js'
import { isUuid } from './identifiers.js'

const NAMESPACES = new Set(['tenant', 'user', 'public'])
const SEGMENT_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/
const PUBLIC_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/
const MAX_CHANNEL_LENGTH = 255

export function parseChannel(channel) {
  if (typeof channel !== 'string' || channel.length === 0 || channel.length > MAX_CHANNEL_LENGTH) {
    return null
  }

  const separator = channel.indexOf(':')
  if (separator <= 0 || separator === channel.length - 1) return null

  const namespace = channel.slice(0, separator)
  if (!NAMESPACES.has(namespace)) return null

  const remainder = channel.slice(separator + 1)
  if (namespace === 'public') {
    if (remainder.includes(':') || !PUBLIC_NAME_RE.test(remainder)) return null
    return { channel, namespace, id: remainder, segments: [] }
  }

  const parts = remainder.split(':')
  const id = parts[0]
  const segments = parts.slice(1)
  if (!isUuid(id) || segments.length > 4) return null
  if (segments.some((segment) => !SEGMENT_RE.test(segment))) return null

  return { channel, namespace, id, segments }
}

export function extractTenantId(claims) {
  if (!isObject(claims)) return null
  const candidates = [
    claims.app_metadata?.tenant_id,
    claims.tenant_id,
  ]
  return candidates.find((value) => isUuid(value)) || null
}

export function buildProxyClaims({ user, meta }) {
  const tenantId = isObject(meta) && isUuid(meta.tenant_id) ? meta.tenant_id : null
  return {
    sub: user || '',
    role: user ? 'authenticated' : 'anon',
    app_metadata: tenantId ? { tenant_id: tenantId } : {},
  }
}

export async function authorizeChannel({ action, channel, userId, claims, dbAuthorize }) {
  if (action !== 'subscribe' && action !== 'publish') {
    return { allowed: false, reason: 'invalid_action', parsed: null }
  }

  const parsed = parseChannel(channel)
  if (!parsed) return { allowed: false, reason: 'malformed_channel', parsed: null }

  if (dbAuthorize) {
    try {
      const allowed = await dbAuthorize({ channel, action, claims })
      return {
        allowed: allowed === true,
        reason: allowed === true ? 'allowed' : 'database_denied',
        parsed,
      }
    } catch (error) {
      return {
        allowed: false,
        reason: 'authorization_unavailable',
        parsed,
        error,
      }
    }
  }

  if (parsed.namespace === 'public') {
    if (action === 'publish' && !userId) {
      return { allowed: false, reason: 'anonymous_publish_denied', parsed }
    }
    return { allowed: true, reason: 'allowed', parsed }
  }

  if (!userId) return { allowed: false, reason: 'anonymous_denied', parsed }

  if (parsed.namespace === 'user') {
    return {
      allowed: userId === parsed.id,
      reason: userId === parsed.id ? 'allowed' : 'user_mismatch',
      parsed,
    }
  }

  const tenantId = extractTenantId(claims)
  return {
    allowed: tenantId === parsed.id,
    reason: tenantId === parsed.id ? 'allowed' : 'tenant_mismatch',
    parsed,
  }
}
