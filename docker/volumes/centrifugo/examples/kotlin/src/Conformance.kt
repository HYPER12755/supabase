package io.supabase.centrifugo.examples

import io.github.centrifugal.centrifuge.Client
import io.github.centrifugal.centrifuge.ClientState
import io.github.centrifugal.centrifuge.HistoryOptions
import io.github.centrifugal.centrifuge.HistoryResult
import io.github.centrifugal.centrifuge.Options
import io.github.centrifugal.centrifuge.PresenceResult
import io.github.centrifugal.centrifuge.PublicationEvent
import io.github.centrifugal.centrifuge.SubscribedEvent
import io.github.centrifugal.centrifuge.Subscription
import io.github.centrifugal.centrifuge.SubscriptionErrorEvent
import io.github.centrifugal.centrifuge.SubscriptionEventListener
import io.github.centrifugal.centrifuge.SubscriptionOptions
import java.nio.charset.StandardCharsets
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.system.exitProcess
import okhttp3.OkHttpClient

private fun requireEnv(name: String): String =
  System.getenv(name)?.takeIf { it.isNotBlank() } ?: throw IllegalArgumentException("$name is required")

private fun waitForPublication(queue: LinkedBlockingQueue<ByteArray>, messageId: String): ByteArray {
  val deadline = System.currentTimeMillis() + 15_000
  while (System.currentTimeMillis() < deadline) {
    val data = queue.poll(500, TimeUnit.MILLISECONDS) ?: continue
    if (String(data, StandardCharsets.UTF_8).contains("\"$messageId\"")) return data
  }
  throw IllegalStateException("publication $messageId timed out")
}

private fun waitForDeliveries(
  delivered: ConcurrentHashMap<String, AtomicInteger>,
  messageId: String,
  expected: Int,
) {
  val deadline = System.currentTimeMillis() + 15_000
  while (System.currentTimeMillis() < deadline) {
    if ((delivered[messageId]?.get() ?: 0) >= expected) return
    Thread.sleep(20)
  }
  throw IllegalStateException("publication $messageId was delivered fewer than $expected times")
}

fun main() {
  val baseUrl = requireEnv("SUPABASE_URL")
  val apikey = requireEnv("SUPABASE_ANON_KEY")
  val accessToken = requireEnv("SUPABASE_ACCESS_TOKEN")
  val channel = requireEnv("CENTRIFUGO_TEST_CHANNEL")
  val apiKey = requireEnv("CENTRIFUGO_API_KEY")
  val path = System.getenv("CENTRIFUGO_WS_PATH") ?: "/realtime/v1/connection/websocket"
  val httpClient = OkHttpClient()
  val tokens = TokenProvider(baseUrl, apikey, { accessToken }, httpClient)

  var connectedLatch = CountDownLatch(1)
  var subscribedLatch = CountDownLatch(1)
  val clientError = AtomicReference<Throwable?>()
  val subscriptionError = AtomicReference<Throwable?>()
  val recovered = AtomicBoolean(false)
  val initialRecovered = AtomicBoolean(false)
  val initialSubscribed = AtomicBoolean(false)
  val publications = LinkedBlockingQueue<ByteArray>()
  val delivered = ConcurrentHashMap<String, AtomicInteger>()
  val received = ConcurrentHashMap<String, AtomicInteger>()
  val dedupe = Deduplicator()

  val listener = object : io.github.centrifugal.centrifuge.EventListener() {
    override fun onConnected(client: Client, event: io.github.centrifugal.centrifuge.ConnectedEvent) {
      connectedLatch.countDown()
    }

    override fun onError(client: Client, event: io.github.centrifugal.centrifuge.ErrorEvent) {
      clientError.set(event.error)
      connectedLatch.countDown()
    }
  }

  val options = Options().apply {
    name = "supabase-centrifugo-kotlin-conformance"
    version = "0.1.0"
    tokenGetter = tokens
    okHttpClient = httpClient
  }
  val client = Client(websocketEndpoint(baseUrl, path), options, listener)

  try {
    client.connect()
    if (!connectedLatch.await(15, TimeUnit.SECONDS)) throw IllegalStateException("connect timed out")
    clientError.get()?.let { throw it }

    val subscription = client.newSubscription(
      channel,
      SubscriptionOptions().apply {
        setJoinLeave(true)
        setRecoverable(true)
        setPositioned(true)
      },
      object : SubscriptionEventListener() {
        override fun onPublication(sub: Subscription, event: PublicationEvent) {
          val key = publicationKey(event.data, event.offset)
          if (key != null) delivered.computeIfAbsent(key) { AtomicInteger() }.incrementAndGet()
          if (!dedupe.accept(key)) return
          if (key != null) received.computeIfAbsent(key) { AtomicInteger() }.incrementAndGet()
          publications.put(event.data ?: ByteArray(0))
        }

        override fun onSubscribed(sub: Subscription, event: SubscribedEvent) {
          if (initialSubscribed.compareAndSet(false, true)) {
            initialRecovered.set(event.recovered == true)
          }
          recovered.set(event.recovered == true)
          subscribedLatch.countDown()
        }

        override fun onError(sub: Subscription, event: SubscriptionErrorEvent) {
          subscriptionError.set(event.error)
          subscribedLatch.countDown()
        }
      },
    )

    subscription.subscribe()
    if (!subscribedLatch.await(15, TimeUnit.SECONDS)) throw IllegalStateException("subscribe timed out")
    subscriptionError.get()?.let { throw it }

    val firstId = UUID.randomUUID().toString()
    apiPublish(baseUrl, apiKey, channel, """{"message_id":"$firstId","source":"kotlin"}""", httpClient)
    waitForPublication(publications, firstId)

    val duplicateId = UUID.randomUUID().toString()
    apiPublish(baseUrl, apiKey, channel, """{"message_id":"$duplicateId","source":"kotlin"}""", httpClient)
    waitForPublication(publications, duplicateId)
    apiPublish(baseUrl, apiKey, channel, """{"message_id":"$duplicateId","source":"kotlin"}""", httpClient)
    waitForDeliveries(delivered, duplicateId, 2)
    if ((received[duplicateId]?.get() ?: 0) != 1) throw IllegalStateException("duplicate was not suppressed")

    val presence = awaitResult<PresenceResult>(10_000) { callback -> subscription.presence(callback) }
    val presenceClients = presence.clients.size
    if (presenceClients < 1) throw IllegalStateException("presence did not include the client")

    val history = awaitResult<HistoryResult>(10_000) { callback ->
      subscription.history(HistoryOptions.Builder().withLimit(10).build(), callback)
    }
    val historyPublications = history.publications.size
    if (historyPublications < 3) throw IllegalStateException("history did not contain all test publications")
    if (history.publications.none { String(it.data, StandardCharsets.UTF_8).contains("\"$firstId\"") }) {
      throw IllegalStateException("history did not contain the first publication")
    }
    if (tokens.callCount < 1) throw IllegalStateException("token callback was not invoked")

    subscribedLatch = CountDownLatch(1)
    subscriptionError.set(null)
    client.disconnect()
    waitForState(client, ClientState.DISCONNECTED, 5_000)

    val secondId = UUID.randomUUID().toString()
    apiPublish(baseUrl, apiKey, channel, """{"message_id":"$secondId","source":"kotlin"}""", httpClient)

    clientError.set(null)
    connectedLatch = CountDownLatch(1)
    client.connect()
    if (!connectedLatch.await(15, TimeUnit.SECONDS)) throw IllegalStateException("reconnect timed out")
    clientError.get()?.let { throw it }
    if (!subscribedLatch.await(15, TimeUnit.SECONDS)) throw IllegalStateException("resubscribe timed out")
    subscriptionError.get()?.let { throw it }
    waitForPublication(publications, secondId)
    if (!recovered.get()) throw IllegalStateException("reconnect did not recover the missed publication")

    println(
      "CONFORMANCE_OK " + """{"sdk":"centrifuge-java","version":"0.8.0","path":"$path",""" +
        """"channel":"$channel","connected":true,"subscribed":true,"initialRecovered":${initialRecovered.get()},""" +
        """"presenceClients":$presenceClients,"historyPublications":$historyPublications,""" +
        """"recovered":${recovered.get()},"duplicatesSuppressed":true,"tokenCalls":${tokens.callCount}}"""
    )
  } catch (error: Throwable) {
    System.err.println("CONFORMANCE_FAIL ${error.message}")
    error.printStackTrace()
    exitProcess(1)
  } finally {
    client.close(1_000)
  }
}
