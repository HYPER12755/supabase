import { createClient, tenantChannel, waitForEvent } from './lib.mjs'

const baseUrl = process.env.SUPABASE_URL
const apikey = process.env.SUPABASE_ANON_KEY
const tenantId = process.env.CENTRIFUGO_TENANT_ID
const accessToken = process.env.SUPABASE_ACCESS_TOKEN

if (!baseUrl || !apikey || !tenantId) {
  throw new Error('SUPABASE_URL, SUPABASE_ANON_KEY, and CENTRIFUGO_TENANT_ID are required')
}

const client = createClient({
  baseUrl,
  apikey,
  getAccessToken: () => accessToken,
  path: process.env.CENTRIFUGO_WS_PATH,
})

const subscription = client.newSubscription(tenantChannel(tenantId, 'table', 'messages'), {
  joinLeave: true,
  recoverable: true,
  positioned: true,
})

subscription.on('publication', ({ data }) => console.log('publication', data))
subscription.on('join', ({ info }) => console.log('join', info.user))
subscription.on('leave', ({ info }) => console.log('leave', info.user))
subscription.on('subscribed', ({ recovered }) => console.log('subscribed', { recovered }))
subscription.on('error', (error) => console.error('subscription error', error))
client.on('error', (error) => console.error('client error', error))
client.on('disconnected', ({ code, reason }) => console.log('disconnected', { code, reason }))

const connected = waitForEvent(client, 'connected')
client.connect()
await connected

const subscribed = waitForEvent(subscription, 'subscribed')
subscription.subscribe()
await subscribed

const shutdown = () => {
  client.disconnect()
  process.exit(0)
}
process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)
