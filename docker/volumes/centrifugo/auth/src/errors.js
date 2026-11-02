export class HttpError extends Error {
  constructor(status, code, message) {
    super(message)
    this.name = 'HttpError'
    this.status = status
    this.code = code
  }
}

export function isObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
