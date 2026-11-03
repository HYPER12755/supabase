package io.supabase.centrifugo.examples

import io.github.centrifugal.centrifuge.Client
import io.github.centrifugal.centrifuge.ConnectedEvent
import io.github.centrifugal.centrifuge.DisconnectedEvent
import io.github.centrifugal.centrifuge.ErrorEvent
import io.github.centrifugal.centrifuge.EventListener
import io.github.centrifugal.centrifuge.JoinEvent
import io.github.centrifugal.centrifuge.LeaveEvent
import io.github.centrifugal.centrifuge.Options
import io.github.centrifugal.centrifuge.PublicationEvent
import io.github.centrifugal.centrifuge.SubscribedEvent
import io.github.centrifugal.centrifuge.Subscription
import io.github.centrifugal.centrifuge.SubscriptionErrorEvent
import io.github.centrifugal.centrifuge.SubscriptionEventListener
import io.github.centrifugal.centrifuge.SubscriptionOptions
import java.nio.charset.StandardCharsets
import kotlin.system.exitProcess
import okhttp3.OkHttpClient

fun main() {
  val baseUrl = System.getenv("SUPABASE_URL") ?: throw IllegalArgumentException("SUPABASE_URL is required")
  val apikey = System.getenv("SUPABASE_ANON_KEY") ?: throw IllegalArgumentException("SUPABASE_ANON_KEY is required")
  val tenantId = System.getenv("CENTRIFUGO_TENANT_ID") ?: throw IllegalArgumentException("CENTRIFUGO_TENANT_ID is required")
  val accessToken = System.getenv("SUPABASE_ACCESS_TOKEN")
  val httpClient = OkHttpClient()
  val tokens = TokenProvider(baseUrl, apikey, { accessToken }, httpClient)

  val options = Options().apply {
    name = "supabase-centrifugo-kotlin-example"
    version = "0.1.0"
    tokenGetter = tokens
    okHttpClient = httpClient
  }

  val client = Client(
    websocketEndpoint(baseUrl, System.getenv("CENTRIFUGO_WS_PATH") ?: "/realtime/v1/connection/websocket"),
    options,
    object : EventListener() {
      override fun onConnected(client: Client, event: ConnectedEvent) {
        println("connected")
      }

      override fun onDisconnected(client: Client, event: DisconnectedEvent) {
        println("disconnected ${event.code} ${event.reason}")
      }

      override fun onError(client: Client, event: ErrorEvent) {
        println(actionableError(errorCode(event.error), event.error.message ?: "unknown"))
      }
    },
  )

  val subscription = client.newSubscription(
    Channels.tenant(tenantId, "table", "messages"),
    SubscriptionOptions().apply {
      setJoinLeave(true)
      setRecoverable(true)
      setPositioned(true)
    },
    object : SubscriptionEventListener() {
      override fun onPublication(sub: Subscription, event: PublicationEvent) {
        println("publication ${String(event.data, StandardCharsets.UTF_8)}")
      }

      override fun onJoin(sub: Subscription, event: JoinEvent) {
        println("join ${event.info.user}")
      }

      override fun onLeave(sub: Subscription, event: LeaveEvent) {
        println("leave ${event.info.user}")
      }

      override fun onSubscribed(sub: Subscription, event: SubscribedEvent) {
        println("subscribed recovered=${event.recovered}")
      }

      override fun onError(sub: Subscription, event: SubscriptionErrorEvent) {
        println(actionableError(errorCode(event.error), event.error.message ?: "unknown"))
      }
    },
  )

  try {
    client.connect()
    waitForState(client, io.github.centrifugal.centrifuge.ClientState.CONNECTED)
    subscription.subscribe()
    Runtime.getRuntime().addShutdownHook(Thread {
      try {
        client.close(1_000)
      } catch (_: InterruptedException) {
        Thread.currentThread().interrupt()
      }
    })
  } catch (error: Throwable) {
    System.err.println(error.message)
    client.close(1_000)
    exitProcess(1)
  }
}
