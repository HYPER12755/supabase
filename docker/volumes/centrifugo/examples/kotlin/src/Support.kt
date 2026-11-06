package io.supabase.centrifugo.examples

import io.github.centrifugal.centrifuge.Client
import io.github.centrifugal.centrifuge.ClientState
import io.github.centrifugal.centrifuge.ConnectionTokenEvent
import io.github.centrifugal.centrifuge.ConnectionTokenGetter
import io.github.centrifugal.centrifuge.ReplyError
import io.github.centrifugal.centrifuge.ResultCallback
import io.github.centrifugal.centrifuge.TokenCallback
import io.github.centrifugal.centrifuge.UnauthorizedException
import java.io.IOException
import java.net.URI
import java.nio.charset.StandardCharsets
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONObject

private val UUID_PATTERN =
  Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", RegexOption.IGNORE_CASE)
private val SEGMENT_PATTERN = Regex("^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
private val PUBLIC_NAME_PATTERN = Regex("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
private val TOKEN_PATTERN = Regex("\"token\"\\s*:\\s*\"([^\"]+)\"")
private val ERROR_PATTERN = Regex("\"error\"\\s*:\\s*\"([^\"]+)\"")
private val MESSAGE_PATTERN = Regex("\"message\"\\s*:\\s*\"([^\"]*)\"")

class ChannelNameException(message: String) : IllegalArgumentException(message)

object Channels {
  fun tenant(tenantId: String, vararg segments: String): String {
    val tenant = requireUuid(tenantId, "tenantId")
    if (segments.size > 4) throw ChannelNameException("tenant channels support at most four segments")
    val validated = segments.map {
      if (!SEGMENT_PATTERN.matches(it)) {
        throw ChannelNameException(
          "tenant segments must start with a letter or digit and use at most 64 letters, digits, dots, hyphens, or underscores"
        )
      }
      it
    }
    return validate(listOf("tenant", tenant, *validated.toTypedArray()).joinToString(":"))
  }

  fun user(userId: String): String = validate("user:${requireUuid(userId, "userId")}")

  fun publicChannel(name: String): String {
    if (!PUBLIC_NAME_PATTERN.matches(name)) {
      throw ChannelNameException(
        "public channel names must start with a letter or digit and use at most 128 letters, digits, dots, hyphens, or underscores"
      )
    }
    return "public:$name"
  }

  fun tenantOf(channel: String): String? {
    if (!channel.startsWith("tenant:")) return null
    val tenant = channel.split(":", limit = 3).getOrNull(1) ?: return null
    return if (UUID_PATTERN.matches(tenant)) tenant.lowercase() else null
  }

  private fun requireUuid(value: String, label: String): String {
    if (!UUID_PATTERN.matches(value)) throw ChannelNameException("$label must be a UUID")
    return value.lowercase()
  }

  private fun validate(channel: String): String {
    if (channel.length < 3 || channel.length > 255) {
      throw ChannelNameException("channel must be between 3 and 255 characters")
    }
    if (channel.any(Char::isWhitespace)) throw ChannelNameException("channel cannot contain whitespace")
    return channel
  }
}

fun publicationKey(data: ByteArray?, offset: Long): String? {
  if (data != null) {
    val messageId = try {
      JSONObject(String(data, StandardCharsets.UTF_8)).optString("message_id", "")
    } catch (_: Exception) {
      ""
    }
    if (messageId.isNotEmpty()) return messageId
  }
  return if (offset > 0) offset.toString() else null
}

class Deduplicator(
  private val limit: Int = 2048,
  private val ttlMillis: Long = 10 * 60 * 1000,
  private val now: () -> Long = System::currentTimeMillis,
) {
  private val seen = LinkedHashMap<String, Long>()

  @Synchronized
  fun accept(key: String?): Boolean {
    if (key.isNullOrEmpty()) return true
    val timestamp = now()
    val previous = seen[key]
    if (previous != null && timestamp - previous < ttlMillis) return false
    seen.remove(key)
    seen[key] = timestamp
    prune(timestamp)
    return true
  }

  @Synchronized
  fun clear() {
    seen.clear()
  }

  private fun prune(timestamp: Long) {
    val iterator = seen.entries.iterator()
    while (iterator.hasNext()) {
      val entry = iterator.next()
      if (timestamp - entry.value >= ttlMillis || seen.size > limit) {
        iterator.remove()
      } else {
        break
      }
    }
  }
}

class TokenProvider(
  private val baseUrl: String,
  private val apikey: String,
  private val accessToken: () -> String?,
  private val httpClient: OkHttpClient = OkHttpClient(),
) : ConnectionTokenGetter() {
  private val calls = AtomicInteger()

  @Volatile
  var callCount: Int = 0
    private set

  @Volatile
  var lastError: Exception? = null
    private set

  override fun getConnectionToken(event: ConnectionTokenEvent, cb: TokenCallback) {
    callCount = calls.incrementAndGet()
    lastError = null

    if (apikey.isBlank()) {
      failUnauthorized(cb, IOException("apikey is required"))
      return
    }

    val token = try {
      accessToken()
    } catch (error: Exception) {
      fail(cb, error)
      return
    }

    val builder = Request.Builder()
      .url("${baseUrl.trimEnd('/')}/centrifugo/v1/auth/token")
      .header("apikey", apikey)
      .header("accept", "application/json")
      .post(ByteArray(0).toRequestBody("application/json".toMediaType()))
    if (!token.isNullOrBlank()) builder.header("authorization", "Bearer $token")

    httpClient.newCall(builder.build()).enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) {
        fail(cb, e)
      }

      override fun onResponse(call: Call, response: Response) {
        response.use {
          val body = it.body?.string().orEmpty()
          if (!it.isSuccessful) {
            val code = ERROR_PATTERN.find(body)?.groupValues?.get(1) ?: "token_http_error"
            val message = MESSAGE_PATTERN.find(body)?.groupValues?.get(1)
              ?: "token endpoint returned ${it.code}"
            val error = IOException("$code: $message")
            if (it.code == 429 || it.code >= 500) fail(cb, error) else failUnauthorized(cb, error)
            return
          }

          val connectionToken = TOKEN_PATTERN.find(body)?.groupValues?.get(1)
          if (connectionToken.isNullOrEmpty()) {
            failUnauthorized(cb, IOException("token endpoint returned no token"))
            return
          }
          cb.Done(null, connectionToken)
        }
      }
    })
  }

  private fun fail(cb: TokenCallback, error: Exception) {
    lastError = error
    cb.Done(error, null)
  }

  private fun failUnauthorized(cb: TokenCallback, error: Exception) {
    lastError = error
    cb.Done(UnauthorizedException(), null)
  }
}

fun errorCode(error: Throwable?): Int = when (error) {
  is ReplyError -> error.code
  else -> 0
}

fun actionableError(code: Int, message: String): String = when (code) {
  103, 403 -> "Not authorized for this channel: $message"
  413 -> "Payload too large; reduce it or publish through the server API: $message"
  108 -> "This channel does not expose that feature: $message"
  109 -> "Connection token expired; refresh the token: $message"
  110 -> "Connection expired; reconnect and refresh the token if requested: $message"
  111, 429 -> "Rate limited; retry after the server delay: $message"
  112 -> "History position is unrecoverable; reload state: $message"
  2500 -> "Subscription state was reset; the SDK resubscribes, and history recovery may be unavailable: $message"
  3014 -> "Connection state was invalidated; refresh the token and reconnect: $message"
  3500 -> "Invalid connection token; request a new token: $message"
  else -> "Realtime error $code: $message"
}

fun websocketEndpoint(baseUrl: String, path: String = "/realtime/v1/connection/websocket"): String {
  val uri = URI(baseUrl)
  val scheme = when (uri.scheme) {
    "http" -> "ws"
    "https" -> "wss"
    "ws", "wss" -> uri.scheme
    else -> throw IllegalArgumentException("baseUrl must use http or https")
  }
  val target = if (path.startsWith("/")) path else "/$path"
  return URI(scheme, null, uri.host, uri.port, target, null, null).toString()
}

fun waitForState(client: Client, state: ClientState, timeoutMillis: Long = 15_000) {
  val deadline = System.currentTimeMillis() + timeoutMillis
  while (System.currentTimeMillis() < deadline) {
    if (client.state == state) return
    Thread.sleep(20)
  }
  throw IllegalStateException("client did not reach $state")
}

fun <T> awaitResult(timeoutMillis: Long, operation: (ResultCallback<T>) -> Unit): T {
  val future = CompletableFuture<T>()
  operation(object : ResultCallback<T> {
    override fun onDone(error: Throwable?, result: T?) {
      if (error != null) future.completeExceptionally(error)
      else if (result != null) future.complete(result)
      else future.completeExceptionally(IllegalStateException("empty result"))
    }
  })
  return future.get(timeoutMillis, TimeUnit.MILLISECONDS)
}

fun apiPublish(baseUrl: String, apiKey: String, channel: String, data: String, httpClient: OkHttpClient) {
  val request = Request.Builder()
    .url("${baseUrl.trimEnd('/')}/centrifugo/v1/api/publish")
    .header("X-API-Key", apiKey)
    .post("""{"channel":"$channel","data":$data}""".toRequestBody("application/json".toMediaType()))
    .build()
  httpClient.newCall(request).execute().use { response ->
    if (!response.isSuccessful) {
      throw IllegalStateException("publish failed with ${response.code}: ${response.body?.string()}")
    }
  }
}
