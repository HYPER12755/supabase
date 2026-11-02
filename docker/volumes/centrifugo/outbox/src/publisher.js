export class PublishError extends Error {
  constructor(message, options = {}) {
    super(message, options.cause ? { cause: options.cause } : undefined)
    this.name = 'PublishError'
    this.retryable = options.retryable === true
    this.status = options.status
  }
}

export function isRetryableStatus(status) {
  return status === 408 || status === 425 || status === 429 || status >= 500
}

export async function publish({
  apiUrl,
  apiKey,
  channel,
  data,
  messageId,
  timeoutMs,
  fetchImpl = fetch,
}) {
  const endpoint = `${apiUrl.replace(/\/+$/, '')}/api/publish`
  let response

  try {
    response = await fetchImpl(endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-API-Key': apiKey,
      },
      body: JSON.stringify({
        channel,
        data,
        idempotency_key: messageId,
      }),
      signal: AbortSignal.timeout(timeoutMs),
    })
  } catch (error) {
    throw new PublishError('Centrifugo publish request failed', {
      cause: error,
      retryable: true,
    })
  }

  if (!response.ok) {
    throw new PublishError(`Centrifugo publish failed with status ${response.status}`, {
      retryable: isRetryableStatus(response.status),
      status: response.status,
    })
  }

  return true
}
