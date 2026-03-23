# Module 01: System Design Fundamentals

> This module is the foundation of the course. There is not a single "just memorize this" here. Every concept comes with a calculation or example, because in real projects (and in interviews) these are exactly the things you'll be asked about.

---

## Table of Contents

1. [What is System Design and Why It Matters](#1-what-is-system-design-and-why-it-matters)
2. [Framework for Approaching Design](#2-framework-for-approaching-design)
3. [Load Estimation (Back-of-the-envelope estimation)](#3-load-estimation-back-of-the-envelope-estimation)
4. [SLA, SLO, SLI — How to Measure Reliability](#4-sla-slo-sli--how-to-measure-reliability)
5. [CAP Theorem and PACELC](#5-cap-theorem-and-pacelc)
6. [Horizontal vs Vertical Scaling](#6-horizontal-vs-vertical-scaling)

---

## 1. What is System Design and Why It Matters

### Definition

System Design is the process of designing the architecture of a software system: how its components interact, how it handles load, scales with growth, and remains reliable during failures.

More specifically: you make decisions about which databases to use, how to split the system into services, where to cache, and how to handle failures. This is not about language syntax or GoF patterns — it's about system structure at the infrastructure and component level.

### Low-Level Design (LLD) vs High-Level Design (HLD)

| Aspect | LLD | HLD |
|---|---|---|
| Focus | Classes, modules, algorithms | Components, services, storage |
| Question | "How do we implement this?" | "What is it made of?" |
| Artifacts | UML diagrams, pseudocode, API methods | Architecture diagrams, DB selection, data flow |
| Example | `UserRepository` class structure, SOLID | "Frontend → API Gateway → services → PostgreSQL + Redis" schema |
| Who does it | Developer before implementation | Architect / senior developer at planning stage |

This course focuses on HLD. LLD is a separate discipline, though the boundary is blurry: a good system designer understands both levels.

### When System Design is Needed

**1. Technical interview at senior/staff level**

Starting from the senior level, most companies (Google, Meta, Amazon, Yandex, Ozon, VK) conduct a separate System Design Interview lasting 45–60 minutes. This is not about algorithms — it's about how you think about systems under load.

**2. Starting a new product or feature**

Before writing the first line of code in a new service, you need to answer: what is the expected load? Which DB is appropriate? How does the service scale? If you skip this step, six months later you'll be refactoring the architecture under deadline pressure.

**3. Refactoring an overloaded monolith**

When deployment takes 40 minutes, CI fails due to unexpected dependencies, and a team of 5 people conflicts over a single file — that's a signal to decompose. System design helps plan the decomposition: where to draw boundaries, how to organize data ownership, how to migrate without downtime.

**4. Infrastructure migration**

MySQL → PostgreSQL, on-premise → cloud, monolith → microservices. Any migration requires understanding the current architecture and the target state, as well as a transition plan without data loss or availability degradation.

---

## 2. Framework for Approaching Design

Without structure, a system design session turns into chaotic brainstorming. You need a repeatable process. One popular framework is **RESHADED**:

```
R — Requirements        (what the system must do)
E — Estimation          (what load is expected)
S — Storage Design      (where and how to store data)
H — High-Level Design   (components and their interactions)
A — API Design          (contracts between components)
D — Detailed Design     (depth in critical paths)
E — Error Handling      (what happens on failure)
D — Discussion          (trade-offs, scaling, alternatives)
```

### Step 1: Requirements

We split requirements into two types:

**Functional Requirements** — what the system must do:
- User can register and log in
- System sends email/push/SMS notifications
- Notification history is stored for 30 days

**Non-Functional Requirements** — how the system must do it:
- Latency: notification delivered in < 1 second
- Availability: 99.9% uptime
- Scalability: 10M users, 100M notifications per day
- Durability: no notification is lost

In an interview, always clarify scope. "Design Twitter" is too broad. Clarify: do we need DMs? Trends? An advertising system? This affects the entire design.

### Step 2: Estimation

We calculate numbers before drawing components. Without this, it's impossible to make informed decisions about storage and infrastructure.

Basic calculations:
- DAU (Daily Active Users) × actions per user → events per day
- events per day / 86,400 → average RPS
- average RPS × 3–5 → peak RPS (load during peak hours)
- size of one event × events per day × 365 × N years → storage size

Detailed example — in section 3.

### Step 3: Storage Design

Based on estimation, we choose storage:

| Data type | Candidates |
|---|---|
| Structured transactional data | PostgreSQL, MySQL |
| Documents, flexible schema | MongoDB, Couchbase |
| High-throughput writes, wide column | Cassandra, ScyllaDB |
| Cache, sessions | Redis, Memcached |
| Full-text search | Elasticsearch, OpenSearch |
| Queues, streaming | Kafka, RabbitMQ, SQS |
| Object storage (media, backups) | S3, GCS |
| Time-series metrics | InfluxDB, Prometheus + Thanos |

### Step 4: High-Level Design

We draw components and arrows between them. At this stage — only large blocks, no implementation details.

```
Client → Load Balancer → API Gateway → [Auth Service]
                                     → [Notification Service] → Kafka → [Email Worker]
                                                                       → [Push Worker]
                                                                       → [SMS Worker]
                                     → [User Service] → PostgreSQL
```

### Step 5: API Design

We define contracts. REST, gRPC, or GraphQL — we justify the choice.

```
POST /v1/notifications
{
  "user_id": "u_123",
  "type": "email" | "push" | "sms",
  "template_id": "order_shipped",
  "variables": {"order_id": "42", "eta": "2026-03-24"}
}

Response 202 Accepted
{
  "notification_id": "n_456",
  "status": "queued"
}
```

202 Accepted (not 200 OK) — because the notification is sent asynchronously.

### Step 6: Detailed Design

We dive deep into critical paths. For a notification service, the critical elements are:
- Delivery guarantee (at-least-once vs exactly-once)
- Retry logic on temporary failures from external providers (SendGrid, Firebase)
- Rate limiting — you can't send 1000 emails per second without risking landing in spam

```
Notification Service
  ↓
Kafka (topic: notifications, retention: 7d)
  ↓
Email Worker
  ├── Reads from Kafka (consumer group)
  ├── Calls SendGrid API
  ├── On 5xx → exponential backoff retry (1s, 2s, 4s, 8s, max 3 retries)
  ├── On retry exhaustion → DLQ (Dead Letter Queue)
  └── Writes status to PostgreSQL (notification_logs)
```

### Step 7: Error Handling and Edge Cases

Questions to ask about the system:
- What if Kafka is unavailable? → in-memory buffer + alert + graceful degradation
- What if SendGrid returned 429 (rate limit)? → backoff + retry from a different IP
- What if the user unsubscribed from notifications? → check before sending, not after
- What if the same notification is processed twice (consumer failure)? → idempotency key

### Step 8: Discussion — Trade-offs

Every decision is a compromise. A good system designer doesn't "know the right answer" but can justify trade-offs:

| Decision | Pros | Cons |
|---|---|---|
| Kafka instead of direct provider call | Decoupling, retry, peak buffering | Complexity, latency +50–200ms |
| At-least-once delivery | Delivery guarantee | Duplicates → need idempotency |
| Separate service per channel | Independent deployment, failure isolation | More services → operational complexity |

---

### Full RESHADED walkthrough: notification service

**Task**: design a notification system for an e-commerce platform with 5M DAU.

---

**R — Requirements**

Functional:
- Support for three channels: email, push, SMS
- Triggered by internal services (order placed, shipped, cancelled)
- Templates with variables
- Notification history — 90 days
- User can unsubscribe from a specific type

Non-functional:
- Notification delivery: < 5 seconds from event
- Availability: 99.9%
- No notifications can be lost
- Scalability: up to 50M DAU in 2 years

---

**E — Estimation**

- DAU: 5M
- Notifications per user per day: ~3 (transactional)
- Total notifications per day: 5M × 3 = 15M
- Average RPS: 15M / 86,400 ≈ 174 RPS
- Peak RPS (morning + sales × 5): ~870 RPS
- Size of one notification (metadata + content): ~2 KB
- Storage per day: 15M × 2 KB = 30 GB/day
- Storage for 90 days: 30 GB × 90 = 2.7 TB

---

**S — Storage Design**

- PostgreSQL: users, subscription settings, templates
- Cassandra: notification log (high write throughput, TTL 90 days)
- Redis: user settings cache (frequently read, rarely changed)
- Kafka: event queue between services

---

**H — High-Level Design**

```
[Order Service]    ──→ Kafka (topic: order.events)
[Payment Service]  ─→ Kafka
[Delivery Service] → Kafka
                          ↓
                  [Notification Service]
                    ├── reads events
                    ├── checks preferences (Redis → PostgreSQL)
                    ├── renders template
                    └── writes to Kafka (topic: notifications.email / push / sms)
                          ↓
           ┌──────────────┼──────────────┐
    [Email Worker]  [Push Worker]  [SMS Worker]
        ↓                 ↓              ↓
    SendGrid         Firebase       Twilio/SMSC
        ↓                 ↓              ↓
               [Cassandra: notification_logs]
```

---

**A — API Design**

Internal API (called by other services):

```
POST /internal/v1/events
{
  "event_type": "order.shipped",
  "user_id": "u_123",
  "payload": {"order_id": "o_456", "tracking_url": "https://..."}
}
```

User-facing API:

```
GET  /v1/notifications?user_id=u_123&limit=20&cursor=...
PUT  /v1/notifications/preferences
{
  "email": true,
  "push": true,
  "sms": false
}
```

---

**D — Detailed Design (critical path: Email Worker)**

```go
func (w *EmailWorker) ProcessMessage(msg kafka.Message) error {
    var notification Notification
    if err := json.Unmarshal(msg.Value, &notification); err != nil {
        return fmt.Errorf("unmarshal: %w", err)
    }

    // Idempotency check
    if sent, _ := w.store.IsSent(notification.ID); sent {
        return nil // already sent, skip
    }

    if err := w.sendWithRetry(notification); err != nil {
        w.dlq.Publish(notification) // to Dead Letter Queue
        return nil                  // do not return error — Kafka won't retry
    }

    w.store.MarkSent(notification.ID)
    return nil
}

func (w *EmailWorker) sendWithRetry(n Notification) error {
    delays := []time.Duration{1, 2, 4, 8} // seconds
    for i, delay := range delays {
        err := w.provider.Send(n)
        if err == nil {
            return nil
        }
        if i < len(delays)-1 {
            time.Sleep(delay * time.Second)
        }
    }
    return fmt.Errorf("all retries exhausted for notification %s", n.ID)
}
```

---

**E — Error Handling**

| Scenario | Handling |
|---|---|
| Kafka unavailable | Notification Service buffers in memory (bounded queue), alert, fallback to direct write |
| SendGrid 429 | Exponential backoff, switch IP/account |
| Duplicate notification | Idempotency key = notification_id in Redis (TTL 24h) |
| User unsubscribed | Check preferences before writing to Kafka, not in the worker |

---

**D — Discussion**

Key trade-off: **Kafka vs direct provider call**.

Direct call is simpler: Order Service → SendGrid. But during a peak (Black Friday 10× load) SendGrid will start returning 429 and notifications are lost. Kafka buffers the peak, workers process at their own pace. The cost: +100–300ms latency and operational complexity.

Conclusion: for transactional notifications — Kafka. For critical ones (2FA code) — direct call + Kafka as fallback.

---

## 3. Load Estimation (Back-of-the-envelope estimation)

Back-of-the-envelope estimation is a fast, approximate calculation with accuracy of ±1 order of magnitude. In an interview, exact precision doesn't matter — what matters is demonstrating that you understand scale and can work with it.

### Key Numbers to Know

#### Latency Numbers (Jeff Dean's table, updated)

| Operation | Latency | Human-readable |
|---|---|---|
| L1 cache reference | ~1 ns | 1 second (relative) |
| L2 cache reference | ~4 ns | 4 seconds |
| Branch misprediction | ~5 ns | 5 seconds |
| L3 cache reference | ~10 ns | 10 seconds |
| Mutex lock/unlock | ~25 ns | 25 seconds |
| Main memory (RAM) reference | ~100 ns | 100 seconds |
| Compress 1KB with Snappy | ~3 µs | 50 minutes |
| Read 1MB sequentially from RAM | ~10 µs | 2.5 hours |
| SSD random read (4KB) | ~100 µs | 11 days |
| Read 1MB sequentially from SSD | ~1 ms | 4 months |
| Round trip within one DC | ~0.5 ms | 2 months |
| HDD seek + read | ~10 ms | 3 years |
| Round trip between DCs in same region | ~10–30 ms | 10–30 years |
| Round trip New York–Europe | ~100–150 ms | 100+ years |
| Virtual machine reboot | ~1–10 s | — |

> **Key takeaway**: the difference between RAM and HDD is 5 orders of magnitude. The difference between L1 cache and a datacenter network is 6 orders. This is exactly why caching is so critical.

#### Throughput

| Device/interface | Throughput |
|---|---|
| HDD sequential read | ~150 MB/s |
| SSD sequential read | ~500 MB/s – 3 GB/s (NVMe) |
| NVMe SSD sequential read | 3–7 GB/s |
| RAM bandwidth | ~50 GB/s |
| Network: 1 Gbps Ethernet | 125 MB/s |
| Network: 10 Gbps Ethernet | 1.25 GB/s |
| Network: 100 Gbps (backbone) | 12.5 GB/s |

#### Typical Object Sizes

| Object | Size |
|---|---|
| UUID (string) | 36 bytes |
| Integer (int64) | 8 bytes |
| Tweet (text) | ~300 bytes |
| Email (text) | 1–10 KB |
| Web page | ~100 KB |
| Avatar/thumbnail | 5–20 KB |
| Photo (JPEG, average) | 200 KB – 1 MB |
| Photo (RAW) | 15–30 MB |
| Video (1 min, 720p) | ~50 MB |
| Video (1 min, 1080p) | ~150 MB |
| Video (1 min, 4K) | ~400 MB |

#### Useful Time Constants

| Period | Seconds (approximate) |
|---|---|
| 1 minute | 60 s |
| 1 hour | 3,600 s |
| 1 day | 86,400 s (~100K) |
| 1 month | 2.6M s |
| 1 year | 31.5M s (~30M) |

Tip: for estimation, remember **1 day ≈ 100K seconds**. This simplifies RPS calculations.

---

### Load Estimation Formula

```
RPS_avg = (DAU × actions_per_user) / 86_400
RPS_peak = RPS_avg × peak_factor   // peak_factor = 3–5 for consumer apps,
                                    // up to 10 for event-driven (sales)

Storage_year = events_per_day × event_size_bytes × 365
Storage_N_years = Storage_year × N × replication_factor

Bandwidth_ingress = RPS_avg × avg_request_size
Bandwidth_egress  = RPS_avg × avg_response_size × fan_out_factor
```

---

### Practical Example: messenger with 10M DAU

**Given:**
- DAU: 10 million users
- Average messages per user per day: 40
- Average message size: 100 bytes (text) + metadata ~50 bytes = 150 bytes
- Media messages: 10% of all, average size: 500 KB
- Message history retention: 5 years
- Replication factor (for reliability): 3

#### Step 1: Events per day

```
Text messages per day:
  10M × 40 × 0.9 = 360M messages

Media messages per day:
  10M × 40 × 0.1 = 40M media messages
```

#### Step 2: RPS

```
Average RPS (text only):
  360M / 86,400 ≈ 4,166 RPS ≈ ~4,200 RPS

Media upload RPS:
  40M / 86,400 ≈ 463 RPS

Peak RPS (×3 for messenger, peak — evening):
  (4,200 + 463) × 3 ≈ 14,000 RPS
```

#### Step 3: Storage per year (text messages)

```
Text:
  360M messages/day × 150 bytes = 54 GB/day
  54 GB × 365 = ~19.7 TB/year

With replication factor 3:
  19.7 TB × 3 = ~59 TB/year
```

#### Step 4: Storage per year (media)

```
Media:
  40M × 500 KB = 20 TB/day (!)
  20 TB × 365 = 7,300 TB/year = ~7.3 PB/year

With replication factor 3:
  ~22 PB/year

Conclusion: media is the bottleneck. Solution: compression, CDN, deletion after 1 year for inactive chats.
```

#### Step 5: Bandwidth

```
Ingress (upload):
  Text: 4,200 RPS × 150 bytes ≈ 630 KB/s ≈ ~5 Mbps — negligible
  Media: 463 RPS × 500 KB ≈ 232 MB/s ≈ ~1.85 Gbps — this is serious

Egress (message delivery to recipients):
  Each message is delivered on average to 1 chat with 2+ participants.
  Fan-out = 2 for P2P chats, up to 100+ for groups.
  Assume average fan-out = 3:
  
  Text egress: 4,200 × 3 × 150 bytes ≈ 1.9 MB/s ≈ ~15 Mbps
  Media egress: 463 × 3 × 500 KB ≈ 695 MB/s ≈ ~5.5 Gbps
```

#### Summary

| Metric | Value |
|---|---|
| DAU | 10M |
| Messages per day | 400M (360M text + 40M media) |
| Average RPS | ~4,700 |
| Peak RPS | ~14,000 |
| Storage (text, 5 years, ×3) | ~295 TB |
| Storage (media, 5 years, ×3) | ~110 PB |
| Ingress bandwidth (media) | ~1.85 Gbps |
| Egress bandwidth (media) | ~5.5 Gbps |

**Conclusions from estimation:**
1. Text messages — not a problem. 14,000 RPS is handled by 5–10 service instances.
2. Media — a completely different story: needs a separate pipeline with S3-compatible storage, CDN, and a retention strategy.
3. Egress bandwidth dictates the need for CDN and geo-distributed storage.

---

## 4. SLA, SLO, SLI — How to Measure Reliability

Reliability is not "the system is working." Reliability is a measurable characteristic. Without numbers there is no accountability and no way to know whether things have improved.

### SLI — Service Level Indicator

**SLI** — a concrete, measurable metric of system performance or reliability.

Examples of SLI:
- **Availability**: `successful_requests / total_requests` (over a 30-day window)
- **Latency**: `p99 latency` — 99th percentile response time
- **Error rate**: `5xx_responses / total_responses`
- **Throughput**: number of requests processed per second
- **Freshness**: time since last successful data update

Why p99 and not the average? Because the average lies. If 99% of requests complete in 10ms but 1% take 10 seconds, the average shows ~110ms, but the user sees a frozen interface every hundredth time. For systems with multiple dependencies, p99 degrades quickly:

```
If service A has p99 = 100ms and it calls services B and C,
the resulting p99 ≈ 100ms + 100ms + 100ms = 300ms (sequential calls)
```

### SLO — Service Level Objective

**SLO** — the target value for an SLI over a specific period.

Examples of SLO:
- `p99 latency < 200ms` (over a rolling 30-day window)
- `availability ≥ 99.9%` (per calendar month)
- `error rate < 0.1%`

SLO is an internal team commitment to itself. Violating an SLO is a signal to act, but not a legal obligation.

### SLA — Service Level Agreement

**SLA** — a legally binding agreement with external clients, based on SLO. Typically, the SLA is slightly looser than the SLO — this is a buffer:

```
SLO: availability ≥ 99.95%  (internal team target)
SLA: availability ≥ 99.9%   (commitment to the client)
```

Violating an SLA — compensation, penalties, contract termination.

### The "Nines" of Availability

| SLA | Downtime per year | Downtime per month | Downtime per week |
|---|---|---|---|
| 90% (one nine) | 36.5 days | 73 hours | 16.8 hours |
| 99% (two nines) | 3.65 days | 7.3 hours | 1.68 hours |
| 99.5% | 1.83 days | 3.65 hours | 50.4 minutes |
| 99.9% (three nines) | 8.76 hours | 43.8 minutes | 10.1 minutes |
| 99.95% | 4.38 hours | 21.9 minutes | 5 minutes |
| 99.99% (four nines) | 52.6 minutes | 4.38 minutes | 1 minute |
| 99.999% (five nines) | 5.26 minutes | 26.3 seconds | 6 seconds |

**Practical implications:**
- 99.9% — standard for most B2B SaaS
- 99.99% — requires automated failover, active-active topology, and serious SRE investment
- 99.999% — telephony and financial transaction level; achieved at the cost of enormous operational complexity

Don't chase five nines where three are sufficient. Each additional nine costs disproportionately more than the previous one.

### Error Budget

**Error budget** — the allowable volume of failures per period, derived from the SLO.

```
Error budget = 1 - SLO

If SLO = 99.9%:
  Error budget = 0.1% of time = 0.1% × 43,200 min/month = 43.2 minutes/month

If SLO = 99.99%:
  Error budget = 0.01% × 43,200 = 4.32 minutes/month
```

Error budget is a tool for balancing development speed and reliability:

- If error budget is not exhausted → the team can deploy new features, run experiments, take risks
- If error budget is exhausted → the team focuses exclusively on reliability, new deployments are frozen

```
Example of consumed error budget calculation:

During the month there were 2 incidents:
  Incident 1: 15 minutes of downtime
  Incident 2: 20 minutes of degradation (50% of requests with errors)
             = 20 × 0.5 = 10 minutes of full equivalent

Consumed: 15 + 10 = 25 minutes
Available budget (at SLO 99.9%): 43.2 minutes
Remaining: 43.2 - 25 = 18.2 minutes (42% remaining) → deployments can continue
```

### How to Measure SLI in Practice (Go example)

```go
package metrics

import (
    "time"
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
)

var (
    httpRequestsTotal = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "http_requests_total",
            Help: "Total HTTP requests by status class",
        },
        []string{"method", "path", "status_class"},
    )
    
    httpRequestDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "http_request_duration_seconds",
            Help:    "HTTP request duration in seconds",
            Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.5, 1.0, 2.5},
        },
        []string{"method", "path"},
    )
)

func Middleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        rw := &responseWriter{ResponseWriter: w, statusCode: 200}
        
        next.ServeHTTP(rw, r)
        
        duration := time.Since(start).Seconds()
        statusClass := fmt.Sprintf("%dxx", rw.statusCode/100)
        
        httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, statusClass).Inc()
        httpRequestDuration.WithLabelValues(r.Method, r.URL.Path).Observe(duration)
    })
}
```

Prometheus query for availability SLI:

```promql
# Availability over the last 30 days
(
  sum(rate(http_requests_total{status_class!="5xx"}[30d]))
  /
  sum(rate(http_requests_total[30d]))
) * 100

# p99 latency over the last 5 minutes
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
)
```

---

## 5. CAP Theorem and PACELC

### CAP Theorem

The CAP theorem (Brewer's theorem, 2000) states: a distributed system cannot simultaneously guarantee all three properties:

```
        C — Consistency
       / \
      /   \
     /     \
    A ——————P
Availability  Partition
              Tolerance
```

**C — Consistency**
Every read receives the most recent write or an error. After a successful write, all subsequent reads on any node return the written value.

*Example*: you transferred money — any node in the system must immediately show the new balance.

**A — Availability**
Every request receives a response (not necessarily the most recent). The system never returns an error due to data unavailability.

*Example*: DNS — you always get a response, though it may be stale (cache not updated).

**P — Partition Tolerance**
The system continues operating despite loss or delay of network messages between nodes.

### Why P is Always Present

In a distributed system of 2+ nodes, network partitions are inevitable. Networks go down, packets are lost, datacenters get isolated. Giving up P means giving up distributed systems altogether.

So the real choice is: **CP or AP** when a partition occurs.

```
CP (Consistency + Partition Tolerance):
  During a partition → the system refuses to respond (error or timeout)
  instead of returning stale data.
  
  Examples: ZooKeeper, etcd, HBase, MongoDB (with write concern majority)
  When needed: financial transactions, distributed locks, configuration

AP (Availability + Partition Tolerance):
  During a partition → the system returns possibly stale data.
  
  Examples: Cassandra, DynamoDB (default), CouchDB, DNS
  When needed: social feeds, shopping carts, view counters
```

### Database Examples and Their CAP Position

| Database | CAP type | Behavior during partition |
|---|---|---|
| PostgreSQL (single node) | CA* | No partition (single node) |
| PostgreSQL (streaming replication) | CP | Replica lag → reads stale data or blocks |
| MongoDB | CP (configurable) | Majority write concern → failure on quorum loss |
| Cassandra | AP | Always available, eventual consistency |
| DynamoDB | AP (default) / CP | Eventually consistent reads / strongly consistent reads |
| Redis (Cluster) | AP | Possible data loss during failover |
| etcd / ZooKeeper | CP | Fails on quorum loss (Raft/ZAB) |
| HBase | CP | HDFS + ZooKeeper → strict consistency |
| CouchDB | AP | Multi-master, eventual consistency, conflict resolution |

> *CA without P is only possible for single-node systems — i.e., non-distributed ones.

### PACELC Theorem

CAP describes behavior only during a partition. But what happens in **normal operation** (without partition)? This is the extension PACELC (Daniel Abadi, 2010):

```
If Partition:
  → choose between Availability and Consistency (as in CAP)
Else (no partition):
  → choose between Latency and Consistency
```

```
PACELC = PAC + ELC

P: Partition
A: Availability
C: Consistency
E: Else (no partition)
L: Latency
C: Consistency
```

**Why Latency vs Consistency in normal operation?**

To guarantee consistency on writes in a replicated system, you must wait for acknowledgment from multiple nodes (quorum write). This adds latency. If we choose low latency — we write asynchronously and lose strong consistency.

```
Cassandra: PA/EL — high availability during partition, low latency in normal operation
DynamoDB: PA/EL — similar (default)
PostgreSQL synchronous_commit=on: PC/EC — consistency over latency
Spanner (Google): PC/EC — strong consistency globally, but at the cost of latency
MongoDB: PC/EC — with majority read/write
```

### PACELC: Extended Table

| System | During partition | During normal operation | Classification |
|---|---|---|---|
| Cassandra | Availability | Latency | PA/EL |
| DynamoDB (default) | Availability | Latency | PA/EL |
| Riak | Availability | Latency | PA/EL |
| PostgreSQL | Consistency | Consistency | PC/EC |
| MySQL (with semi-sync) | Consistency | Consistency | PC/EC |
| Google Spanner | Consistency | Consistency | PC/EC |
| MongoDB | Configurable | Configurable | PA/EL or PC/EC |
| DynamoDB (strong) | Consistency | Consistency | PC/EC |

### Practical Choice

```
Financial operations, transfers, inventory → CP / PC/EC
  Use: PostgreSQL, Spanner, CockroachDB

Social feed, likes, counters → AP / PA/EL
  Use: Cassandra, DynamoDB

User sessions, shopping cart → AP (eventual consistency OK)
  Use: DynamoDB, Redis

Distributed coordination (leader election, locks) → CP
  Use: etcd, ZooKeeper
```

---

## 6. Horizontal vs Vertical Scaling

### Vertical Scaling (Scale Up)

We add resources to the existing instance: more CPU, RAM, faster disks.

```
Before: [Server: 4 CPU, 16 GB RAM]
After:  [Server: 32 CPU, 256 GB RAM]
```

**Pros:**
- Simplicity: no need to change application architecture
- No distributed state problems
- No network overhead between nodes
- Transactions and ACID out of the box

**Cons:**
- Physical ceiling: the largest server in cloud is 192 vCPU, 24 TB RAM (AWS u-24tb1.metal)
- Single point of failure: one server goes down — everything goes down
- Scaling requires downtime (instance restart)
- Non-linear cost: a server ×8 in resources costs >×8 in price

**When to use vertical scaling:**
- Database up to a certain size (PostgreSQL works great on a powerful server)
- ML models that don't parallelize without effort
- Legacy systems that can't run in multiple instances
- Quick temporary solution until an architectural refactor

### Horizontal Scaling (Scale Out)

We add new instances and distribute the load among them.

```
Before: [Server A]

After:  [Load Balancer]
           ├── [Server A]
           ├── [Server B]
           └── [Server C]
```

**Pros:**
- Theoretically unlimited scaling
- Fault tolerance: when one instance goes down, others pick up the load
- Updates without downtime (rolling deploy)
- Linear cost (3 servers ×3 in resources = ×3 in price)

**Cons:**
- Stateful applications are harder to scale (need external cache, sticky sessions, or stateless architecture)
- Network latency between instances
- Distributed transactions — a headache
- Operational complexity: need load balancer, service discovery, monitoring of each instance

**When to use horizontal scaling:**
- Stateless services (API servers, task processors)
- When load is unpredictable and autoscaling is needed
- When high availability is required (multiple AZs)

### Practical Decision Criteria

```
Step 1: Determine if the service is stateless.
  Stateless (does not store state between requests) → horizontal scaling
  Stateful (sessions, in-memory state) → either move state to external storage,
                                         or vertical scaling

Step 2: Estimate the load.
  Peak RPS × avg_request_duration_ms < 1000 ms and 1 instance can handle it
  → vertical (simpler and cheaper)
  Otherwise → horizontal

Step 3: Availability requirements.
  99.99% and above → horizontal (multiple AZs, no single point of failure)
```

### Example: stateless Go service for horizontal scaling

The key requirement for horizontal scaling: **no local state that other instances need**.

```go
package main

import (
    "context"
    "encoding/json"
    "log"
    "net/http"
    "os"
    "time"
    
    "github.com/redis/go-redis/v9"
)

// Bad: state in process memory
// var sessions = map[string]Session{} // with horizontal scaling
                                       // each instance has its own map → problems

// Good: state in external storage
type SessionStore struct {
    rdb *redis.Client
}

func NewSessionStore() *SessionStore {
    rdb := redis.NewClient(&redis.Options{
        Addr: os.Getenv("REDIS_ADDR"), // redis:6379
    })
    return &SessionStore{rdb: rdb}
}

func (s *SessionStore) Get(ctx context.Context, sessionID string) (*Session, error) {
    val, err := s.rdb.Get(ctx, "session:"+sessionID).Result()
    if err == redis.Nil {
        return nil, nil // session not found
    }
    if err != nil {
        return nil, err
    }
    
    var session Session
    if err := json.Unmarshal([]byte(val), &session); err != nil {
        return nil, err
    }
    return &session, nil
}

func (s *SessionStore) Set(ctx context.Context, sessionID string, session *Session) error {
    data, err := json.Marshal(session)
    if err != nil {
        return err
    }
    return s.rdb.Set(ctx, "session:"+sessionID, data, 24*time.Hour).Err()
}

type Session struct {
    UserID    string    `json:"user_id"`
    CreatedAt time.Time `json:"created_at"`
    ExpiresAt time.Time `json:"expires_at"`
}

type Handler struct {
    sessions *SessionStore
    db       *Database // abstraction over PostgreSQL
}

// This handler is completely stateless:
// - stores nothing between requests in memory
// - all state is in Redis and PostgreSQL
// - can be run on any number of machines behind a load balancer

func (h *Handler) GetProfile(w http.ResponseWriter, r *http.Request) {
    sessionID := r.Header.Get("X-Session-ID")
    if sessionID == "" {
        http.Error(w, "unauthorized", http.StatusUnauthorized)
        return
    }
    
    session, err := h.sessions.Get(r.Context(), sessionID)
    if err != nil || session == nil {
        http.Error(w, "session not found", http.StatusUnauthorized)
        return
    }
    
    if time.Now().After(session.ExpiresAt) {
        http.Error(w, "session expired", http.StatusUnauthorized)
        return
    }
    
    user, err := h.db.GetUser(r.Context(), session.UserID)
    if err != nil {
        http.Error(w, "internal error", http.StatusInternalServerError)
        return
    }
    
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(user)
}

func main() {
    store := NewSessionStore()
    db := NewDatabase(os.Getenv("DATABASE_URL"))
    
    handler := &Handler{sessions: store, db: db}
    
    mux := http.NewServeMux()
    mux.HandleFunc("/profile", handler.GetProfile)
    
    // This service can be run on any number of machines.
    // Load balancer (nginx, AWS ALB) distributes traffic round-robin.
    // Each instance is identical — no sticky sessions, no shared memory.
    
    port := os.Getenv("PORT")
    if port == "" {
        port = "8080"
    }
    
    log.Printf("Starting server on :%s", port)
    if err := http.ListenAndServe(":"+port, mux); err != nil {
        log.Fatal(err)
    }
}
```

### Autoscaling: horizontal scaling in practice

The advantage of stateless services — automatic scaling under load:

```yaml
# Kubernetes HorizontalPodAutoscaler
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: profile-service
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: profile-service
  minReplicas: 2   # minimum for HA
  maxReplicas: 50  # maximum to protect DB from overload
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70  # when CPU > 70% → add pods
    - type: Pods
      pods:
        metric:
          name: http_requests_per_second  # custom metric from Prometheus
        target:
          type: AverageValue
          averageValue: "1000"  # 1000 RPS per pod → add more
```

### Comparing Scaling Strategies

| Criterion | Vertical (Scale Up) | Horizontal (Scale Out) |
|---|---|---|
| Implementation complexity | Low | High |
| Operational complexity | Low | High |
| Scaling ceiling | Physical limit | Theoretically ∞ |
| Cost | Grows non-linearly | Grows linearly |
| Downtime when scaling | Usually required | Not required (rolling update) |
| Fault tolerance | Low (SPOF) | High (N-1 redundancy) |
| Latency | No overhead | +network overhead |
| Stateful systems | Works | Requires refactoring |
| Best for | DBs, ML, legacy | APIs, workers, stateless |

---

## Summary: What to Remember from This Module

1. **System Design is about trade-offs**, not correct answers. The ability to justify your choices matters more than the choice itself.

2. **Estimation is the foundation of everything**. Without numbers, you can't reasonably choose storage, determine the required infrastructure, or estimate costs.

3. **Reliability is measured through SLI/SLO/SLA**. Error budget is a tool for balancing development speed and stability.

4. **CAP: the real choice is CP or AP**. P cannot be removed. PACELC adds another dimension: Latency vs Consistency in normal operation.

5. **Stateless is not an option, it's a requirement** for horizontal scaling. All state goes in Redis, PostgreSQL, Cassandra — not in process memory.

6. **Vertical scaling is a temporary solution**, horizontal is architectural. You can start with vertical, but you should design with horizontal in mind.

---

## Additional Resources

- [Designing Data-Intensive Applications](https://dataintensive.net/) — Martin Kleppmann. Required reading for understanding Chapter 5 (replication) and Chapter 9 (consistency and consensus).
- [Google SRE Book](https://sre.google/sre-book/table-of-contents/) — chapters on SLI/SLO/SLA and error budgets. Free online.
- [The System Design Primer](https://github.com/donnemartin/system-design-primer) — extensive repository with real system design examples.
- [Latency Numbers Every Programmer Should Know](https://github.com/sirupsen/napkin-math) — updated version of Jeff Dean's table with calculations.
- [PACELC theorem (Abadi, 2012)](https://www.cs.umd.edu/~abadi/papers/abadi-pacelc.pdf) — the original paper.

---

*Next module: [02 — Networking](../02-networking/readme.md)*
