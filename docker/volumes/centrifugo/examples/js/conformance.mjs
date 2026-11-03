import { randomUUID } from 'node:crypto'
import { createClient, Deduplicator, publicationKey, waitForEvent } from './lib.mjs'

const env = process.env
for (const name of [
  'SUPABASE_URL',
  'SUPABASE_ANON_KEY',
  'SUPABASE_ACCESS_TOKEN',
  'CENTRIFUGO_TEST_CHANNEL',
  'CENTRIFUGO_API_KEY',
]) {
  if (!env[name]) throw new Error(`${name} is required`)
}

async function apiPublish(channel, data) {
  const response = await fetch(new URL('/centrifugo/v1/api/publish', env.SUPABASE_URL), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-API-Key': env.CENTRIFUGO_API_KEY },
    body: JSON.stringify({ channel, data }),
  })
  if (!response.ok) {
    throw new Error(`publish failed with ${response.status}: ${await response.text()}`)
  }
  return response.json()
}

async function waitForDisconnected(client) {
  const deadline = Date.now() + 5000
  while (client.state !== 'disconnected' && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 25))
  }
  if (client.state !== 'disconnected') throw new Error('client did not disconnect')
}

let tokenCalls = 0
const client = createClient({
  baseUrl: env.SUPABASE_URL,
  apikey: env.SUPABASE_ANON_KEY,
  getAccessToken: () => env.SUPABASE_ACCESS_TOKEN,
  path: env.CENTRIFUGO_WS_PATH,
  onTokenRequest: () => {
    tokenCalls += 1
  },
})

const dedupe = new Deduplicator()
const received = new Map()
const subscription = client.newSubscription(env.CENTRIFUGO_TEST_CHANNEL, {
  joinLeave: true,
  recoverable: true,
  positioned: true,
})
subscription.on('publication', (publication) => {
  if (!dedupe.accept(publicationKey(publication))) return
  const messageId = publication.data?.message_id
  if (messageId) received.set(messageId, (received.get(messageId) ?? 0) + 1)
})

try {
  const connected = waitForEvent(client, 'connected')
  client.connect()
  await connected

  const subscribed = waitForEvent(subscription, 'subscribed')
  subscription.subscribe()
  const initial = await subscribed

  const firstId = randomUUID()
  const firstPublication = waitForEvent(
    subscription,
    'publication',
    (publication) => publication.data?.message_id === firstId
  )
  await apiPublish(env.CENTRIFUGO_TEST_CHANNEL, { message_id: firstId, source: 'js' })
  await firstPublication

  const duplicateId = randomUUID()
  const duplicatePublication = waitForEvent(
    subscription,
    'publication',
    (publication) => publication.data?.message_id === duplicateId
  )
  await apiPublish(env.CENTRIFUGO_TEST_CHANNEL, { message_id: duplicateId, source: 'js' })
  await duplicatePublication
  await apiPublish(env.CENTRIFUGO_TEST_CHANNEL, { message_id: duplicateId, source: 'js' })
  await new Promise((resolve) => setTimeout(resolve, 500))
  if ((received.get(duplicateId) ?? 0) !== 1) throw new Error('duplicate was not suppressed')

  const presence = await subscription.presence()
  const history = await subscription.history({ limit: 10 })
  if (!history.publications?.some((publication) => publication.data?.message_id === firstId)) {
    throw new Error('history did not contain the first publication')
  }

  client.disconnect()
  await waitForDisconnected(client)

  const secondId = randomUUID()
  const resubscribed = waitForEvent(subscription, 'subscribed')
  const secondPublication = waitForEvent(
    subscription,
    'publication',
    (publication) => publication.data?.message_id === secondId
  )
  await apiPublish(env.CENTRIFUGO_TEST_CHANNEL, { message_id: secondId, source: 'js' })

  const reconnected = waitForEvent(client, 'connected')
  client.connect()
  await reconnected
  const recovered = await resubscribed
  await secondPublication
  if (!recovered.recovered) throw new Error('reconnect did not recover the missed publication')

  console.log(
    `CONFORMANCE_OK ${JSON.stringify({
      sdk: 'centrifuge-js',
      version: '5.8.0',
      path: env.CENTRIFUGO_WS_PATH ?? '/realtime/v1/connection/websocket',
      channel: env.CENTRIFUGO_TEST_CHANNEL,
      connected: true,
      subscribed: true,
      initialRecovered: Boolean(initial.recovered),
      presenceClients: Object.keys(presence.clients ?? {}).length,
      historyPublications: history.publications.length,
      recovered: Boolean(recovered.recovered),
      duplicatesSuppressed: true,
      tokenCalls,
    })}`
  )
} finally {
  client.disconnect()
}
