package io.supabase.centrifugo.examples

private fun expectInvalid(block: () -> Unit) {
  try {
    block()
    throw IllegalStateException("expected ChannelNameException")
  } catch (_: ChannelNameException) {
  }
}

fun main() {
  val tenant = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  val user = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

  check(Channels.tenant(tenant.uppercase(), "table", "messages") == "tenant:$tenant:table:messages")
  check(Channels.tenant(tenant) == "tenant:$tenant")
  check(Channels.user(user) == "user:$user")
  check(Channels.publicChannel("news.room-1") == "public:news.room-1")
  check(Channels.tenantOf("tenant:$tenant:table:messages") == tenant)
  check(Channels.tenantOf("user:$user") == null)

  expectInvalid { Channels.tenant("not-a-uuid") }
  expectInvalid { Channels.tenant(tenant, "-bad") }
  expectInvalid { Channels.tenant(tenant, "a", "b", "c", "d", "e") }
  expectInvalid { Channels.user("00000000-0000-0000-0000-000000000000") }
  expectInvalid { Channels.publicChannel("~bad") }
  expectInvalid { Channels.publicChannel("-bad") }

  check(publicationKey("""{"record":{"message_id":"nested"},"message_id":"top"}""".toByteArray(), 0) == "top")
  check(publicationKey("""{"record":{"message_id":"nested"}}""".toByteArray(), 42) == "42")

  check(actionableError(403, "denied").startsWith("Not authorized"))
  check(actionableError(413, "large").startsWith("Payload too large"))
  check(actionableError(111, "slow").startsWith("Rate limited"))

  println("KOTLIN_CLIENT_SELF_TEST_OK")
}
