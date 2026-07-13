# Consent API — Async Write Design: Message Bus vs. Redis Streams

**Authors:** Dhiraj Kulkarni, Pavan Prasanna Kumar
**Reviewers:** Jayesh, Abhishek Gaur
**Status:** Draft
**Date:** 2026-05-04
**Jira:** IGAV-XXXX

---

## Background

The Face Liveness Web SDK executes `POST /v1/consents` synchronously on the critical path of every liveness session. Any latency or failure in the Consent API's database write directly cancels the iProov session and degrades liveness pass rates.

The original Rails monolith handled consent via `IDme::Consent.generate!` + a Sidekiq job (`Worker::Consent::Notify`, `retry: false`) — effectively fire-and-forget from the user's request thread. The move to a standalone HTTP API lost that property. We want to restore it.

**Goal:** The Consent API returns `202 Accepted` the moment it has durably enqueued the consent event. The DB write happens off the SDK's critical path, with backend retries, invisible to the member.

---

## Problem Statement

| Symptom | Root cause |
|---------|-----------|
| iProov session canceled on consent failure | SDK blocks on synchronous DB write |
| No backend retry | `retry: false` posture inherited from Sidekiq |
| Duplicate rows on SDK retry (UNS-4752) | No idempotency on `POST /v1/consents` |
| Liveness pass rate degrades with DB latency | DB commit on the SDK's hot path |

---

## Option 1 — Message Bus (Proposed by Pavan) ✅ Recommended

### How it works

The Consent API publishes a `consent.granted` event to the company message bus (`identity.consent.v1`) and immediately returns `202 Accepted`. A DB-writer subscriber owns the durable `INSERT`. `Worker::Consent::Notify` (member SMS/email) migrates from a Sidekiq enqueue to a second subscriber.

```
SDK → POST /v1/consents (Idempotency-Key)
        ↓
    Consent API → publish consent.granted → Bus ACK → 202 Accepted → SDK
                                                  ↓
                              ┌───────────────────┴────────────────────┐
                              ▼                                         ▼
                       DB Writer subscriber                  Worker::Consent::Notify
                       INSERT consents (retry/DLQ)           SMS / email (subscriber)
```

### Event schema (v1, minimal)

```json
{
  "schema": "identity.consent.v1",
  "event_id": "01JR8...ULID",
  "occurred_at": "2026-05-04T18:11:42.337Z",
  "type": "consent.granted",
  "consent": {
    "user_id": "uuid",
    "consumer_id": "uuid",
    "policy_id": "uuid",
    "definition_uuid": "uuid",
    "consenter": "user",
    "channel": "web_sdk_face_liveness"
  },
  "trace": { "session_token_hash": "...", "request_id": "..." }
}
```

No PII. Topic encrypted at rest. Schema-registry enforced.

### What the SDK gains

- No longer waits for Postgres — only waits for bus enqueue ACK (sub-millisecond)
- SDK retries are safe — `Idempotency-Key: sessionToken + definitionUuid` dedupes at publish
- Backend retries return — per-consumer DLQ on the bus, invisible to member
- `Worker::Consent::Notify` becomes a bus subscriber — member-facing behavior unchanged

### Asks of Data Platform

1. Provision topic `identity.consent.v1` (30-day replay window)
2. Onboard `idme-consent-api` as a producer (synchronous publish, ack-on-commit)
3. Approve the DB-writer subscriber pattern
4. Sign off on v1 event schema before producer code merges

---

## Option 2 — Redis Streams (Alternative)

### How it works

The Consent API writes the consent event to a Redis Stream and returns `200 OK` immediately. A background consumer (Spring `@Scheduled` or dedicated thread) reads from the stream, writes to Postgres, and ACKs the message. Unprocessed messages remain in the stream until ACKed.

```
SDK → POST /v1/consents
        ↓
    Consent API → XADD consent_stream → 200 OK → SDK

Background Consumer:
    XREADGROUP → DB write → XACK
    (no ACK on failure → message stays → retried on next poll)
```

### Redis Streams primitives used

| Primitive | Purpose |
|-----------|---------|
| `XADD` | Enqueue consent event |
| `XREADGROUP` | Consumer group reads — each message delivered once per group |
| `XACK` | Marks message processed after successful DB write |
| Pending Entries List (PEL) | Built-in visibility into unprocessed messages |
| `XCLAIM` | Re-assign stale messages to another consumer on crash |

---

## Comparison

| Dimension | Message Bus (Option 1) | Redis Streams (Option 2) |
|-----------|----------------------|--------------------------|
| **Infrastructure** | Existing Data Platform bus | Redis already in consent-api stack |
| **New infra needed** | No — topic provisioning only | No — Redis already present |
| **Fan-out** | Native — multiple subscribers | Manual — custom fan-out logic needed |
| **`Worker::Consent::Notify` migration** | Clean — becomes a subscriber | Requires separate fan-out mechanism |
| **Schema contract** | Versioned, schema-registry enforced | Ad-hoc, team-enforced |
| **DLQ / observability** | Built-in per-consumer DLQ | Manual — query PEL, build alerts |
| **Idempotency** | Event ID + `Idempotency-Key` at publish | Unique constraint on DB insert |
| **Development cost** | Medium — Data Platform coordination | Low — self-contained |
| **Delivery if bus is down** | API returns 4xx/5xx → SDK retries | Not affected (Redis separate from bus) |
| **Delivery if Redis is down** | Not affected | API returns 5xx → SDK retries |
| **Long-term scalability** | High — composable, replayable | Medium — suited for single consumer |
| **Team ownership** | Shared (consent team + Data Platform) | Consent team owns end-to-end |

---

## Failure Modes

| Scenario | Message Bus | Redis Streams |
|----------|-------------|---------------|
| DB down temporarily | Bus holds event; writer retries with DLQ | Stream holds event; consumer retries |
| Bus/Redis down | API returns 5xx; SDK retries (same as today) | API returns 5xx; SDK retries (same as today) |
| Consumer crashes mid-write | Message re-delivered (at-least-once) | PEL + `XCLAIM` re-assigns message |
| Duplicate SDK retry | `Idempotency-Key` dedupes at publish | Unique constraint on DB insert |
| Schema drift | Schema-registry catches breaking changes | Manual version management |

---

## Recommendation

**Use the Message Bus (Option 1).**

The fundamental requirement here is restoring the fire-and-forget contract that Sidekiq gave the Rails monolith. `Worker::Consent::Notify` is already a second consumer that exists today — migrating it to a bus subscriber is free leverage. A message bus is the architecturally correct primitive when you have multiple consumers and need fan-out, schema governance, and replay.

Redis Streams is the right fallback if Data Platform bandwidth is unavailable for this sprint — the technical shape is identical (publish → async DB write → 202 OK) and the two options are not in conflict. If Redis is used for v1, the migration path to the bus is straightforward: swap `XADD` for a bus publish, same event payload.

**Decision criteria:**

- If Data Platform can provision the topic and onboard the producer within the sprint → **Option 1**
- If Data Platform bandwidth is unavailable in the near term → **Option 2 (Redis)** as v1, migrate to bus as fast follow

---

## Open Items

| Item | Owner | Status |
|------|-------|--------|
| Confirm Data Platform timeline for topic provisioning | Dhiraj / Data Platform | TBD |
| Finalize `Idempotency-Key` design (`sessionToken + definitionUuid`) | Abhishek | TBD |
| Scope DB-writer subscriber implementation | Jayesh | TBD |
| Schema sign-off on `identity.consent.v1` | Data Platform | TBD |
| Redis fallback scoping if bus not available this sprint | Consent API team | TBD |
