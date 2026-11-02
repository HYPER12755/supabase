const levels = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40,
}

export function createLogger({ level = 'info', output = process.stdout, now = () => new Date() } = {}) {
  const threshold = levels[level] ?? levels.info

  function write(levelName, message, fields = {}) {
    if (levels[levelName] < threshold) return
    const line = JSON.stringify({
      ts: now().toISOString(),
      level: levelName,
      msg: message,
      ...fields,
    })
    output.write(`${line}\n`)
  }

  return {
    debug: (message, fields) => write('debug', message, fields),
    info: (message, fields) => write('info', message, fields),
    warn: (message, fields) => write('warn', message, fields),
    error: (message, fields) => write('error', message, fields),
  }
}
