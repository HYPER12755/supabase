# Centrifugo Beta Scale and Capacity

This page records the local scale reference, the tested limits, and the production topology guidance. The local numbers are smoke-test results, not production benchmarks. Run `tests/test-centrifugo-load.sh` against the target deployment before setting production limits. `tests/test-centrifugo-scale-ha.sh` exercises local Sentinel promotion and recovery through a master-only HAProxy endpoint; validate the production Redis HA topology separately.

## Topology

| Environment | Centrifugo | Redis | Outbox | Gateway |
| --- | --- | --- | --- | --- |
| Local scale reference | Two nodes on the shared `centrifugo` network alias | Single bundled container, password auth, no persistence, no TLS | Two partitioned consumers | Envoy; Kong uses the same alias |
| Local HA reference | Two nodes on the shared `centrifugo` network alias | Bundled master, replica, three Sentinels, and master-only HAProxy; no persistence or Sentinel auth | Two partitioned consumers | Envoy; Kong uses the same alias |
| Production recommendation | Two or more nodes, no sticky sessions | External Redis with authentication, TLS, persistence, and HA/failover | One consumer per partition, partition count scaled with consumers | Envoy or Kong with health checks and DNS refresh |

All topologies keep Redis and the Centrifugo HTTP API internal. Clients use only the gateway WebSocket and token routes. The HA reference keeps Centrifugo on a stable proxy address; HAProxy health-checks Redis `ROLE` and only routes to the current master. Direct Sentinel tracking by Centrifugo's pub/sub connection did not recover reliably in the tested version, so the proxy is the supported local HA pattern. Production can use a managed Redis HA endpoint or an equivalent master-only proxy.

## Local load results

Run on 2026-11-03 with the local two-node Compose topology, two outbox consumers, and a single local Redis container. These results verify the harness and the local target thresholds; they are not capacity claims.

| Scenario | Configuration | Result |
| --- | --- | --- |
| Reconnect storm | 100 clients, 3 waves | 1,588 ms |
| Fan-out | 100 subscribers, 10 publications | 151 ms for 1,000 deliveries |
| Large channel set | 100 channels, one subscriber | 98 ms for 100 deliveries |
| Outbox throughput | 200 rows, two partitions | 2,226 ms for 200 publications |

The load test also verifies that every fan-out subscriber receives every publication, every channel receives its publication, all outbox rows drain, and both outbox consumers advance their partition counters.

The harness creates 10 temporary users and spreads clients across their tokens. A single user would hit the 300-per-10-second subscribe authorization limit during the reconnect waves and fan-out setup; that is an expected service limit, not a delivery failure.

## Local HA result

Run on 2026-11-03 against the two-node scale stack with one Redis master, one replica, three Sentinels, and HAProxy. `tests/test-centrifugo-scale-ha.sh` passed 19 checks: Sentinel initially followed the master, the proxy routed to the master, presence and history were ready, Sentinel promoted the replica, the proxy followed the promoted master, both clients stayed connected, publish/presence/history recovered, pre-failover history was retained, and the original master was restored. This validates the local failover path, not production Redis behavior or capacity.

HAProxy closes sessions to a backend when it is marked down, preventing a subscription from staying attached to a demoted replica. The test retries a publish until a subscriber receives it because a publish sent immediately after promotion can race Centrifugo's pub/sub reconnect. Expect a small at-most-once window during failover; use history recovery for messages that must not be missed.

## Configured limits to plan around

These are enforced by the current configuration and services, not measured saturation points:

- History: latest 100 publications per channel for 300 seconds.
- Channels per client connection: 128 (`client.channel_limit`).
- Subscribe authorization: 300 calls per user per 10 seconds in `centrifugo-auth`.
- Client publish: 30 calls per user per 10 seconds in `centrifugo-auth`.
- Token issuance: 30 per user per minute and 60 per IP per minute.
- Outbox: batch size 50, poll interval 1 second, and one worker per configured partition.

The local channel test uses 100 channels per connection, below the 128-channel default. Workloads that need more channels per user must either split clients or deliberately raise the Centrifugo channel limit and validate the resulting memory and fan-out cost.

## Sizing guidance

- Start with at least two Centrifugo nodes so a single node restart does not take the service down; clients reconnect to the surviving node.
- Use Redis with the deployment's HA and persistence policy. The bundled Redis is intentionally volatile and loses history and presence on restart.
- Keep the number of outbox workers equal to the partition count. Adding workers without increasing partitions leaves some workers idle.
- Watch Redis CPU and network first: both broker fan-out and presence/history share it. Add nodes for connection and fan-out capacity, and scale Redis independently.
- Rerun the load test with larger `LOAD_*` values on production-like hardware. Record the point where reconnects, publish latency, or outbox lag exceeds the deployment's target.

## Test command

```sh
sh tests/test-centrifugo-load.sh
```

Optional environment overrides:

```sh
LOAD_USERS=10 \
LOAD_RECONNECT_CLIENTS=100 \
LOAD_RECONNECT_WAVES=3 \
LOAD_FANOUT_CLIENTS=100 \
LOAD_FANOUT_MESSAGES=10 \
LOAD_CHANNEL_COUNT=100 \
LOAD_OUTBOX_ROWS=200 \
sh tests/test-centrifugo-load.sh
```

The load test creates temporary users, drains its outbox rows, and removes the users on exit. It requires the scale overlay and does not run against the default memory-only stack.
