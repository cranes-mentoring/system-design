# Module 06: Message Queues and Asynchronous Processing

> **Level:** Senior / Staff Backend Engineer
> **Time:** ~4 hours
> **Previous module:** [05 — Caching](../05-caching/readme.md)
> **Next module:** [07 — Databases: Sharding and Replication](../07-databases-sharding/readme.md)

---

## Table of Contents

1. [Synchronous vs Asynchronous Communication](#1-synchronous-vs-asynchronous-communication)
2. [Apache Kafka — Deep Dive](#2-apache-kafka--deep-dive)
3. [NATS and NATS JetStream](#3-nats-and-nats-jetstream)
4. [RabbitMQ](#4-rabbitmq)
5. [Queue Patterns](#5-queue-patterns)
6. [Event-Driven Architecture](#6-event-driven-architecture)
7. [Choosing a Message Broker](#7-choosing-a-message-broker)

---

## 1. Synchronous vs Asynchronous Communication

### Sync: HTTP/gRPC

The caller waits for a response. The entire call stack holds the connection open.

```
Client ──HTTP/gRPC──► Service A ──HTTP/gRPC──► Service B
  ◄─────────────────────────────────────────────────────
                    waiting for a response from B
```

**Pros:**
- Simplicity: request/response semantics are familiar to every developer
- Immediate response: the client knows the result synchronously
- Easy debugging: the distributed trace is linear, errors are visible immediately
- Simple transactionality: one HTTP call = one atomic operation from the client's perspective

**Cons:**
- Temporal coupling: both services must be alive at the same time
- Cascading failures: if Service B goes down → Service A gets an error → the client gets an error
- Backpressure: during a load spike, Service B becomes a bottleneck for the entire chain
- Latency amplification: total latency = sum(latencies of all services in the chain)

### Async: via a queue/broker

The caller sends a message to a broker and does not wait for it to be processed.

```
Client ──publish──► [Message Broker] ──consume──► Worker
  ◄──ack──           (buffer)
```

**Pros:**
- Temporal decoupling: producer and consumer do not need to run at the same time
- Buffering: the broker absorbs traffic spikes; workers process at their own pace
- Built-in retry: the broker will redeliver a message on consumer failure
- Independent scaling: more workers can be added without changing the producer
- Fault isolation: a crashed consumer does not bring down the producer

**Cons:**
- Operational complexity: the broker is yet another component requiring monitoring, backup, and scaling
- Eventual consistency: the client does not know the result immediately
- Harder debugging: distributed tracing with correlation IDs is needed across all messages
- Ordering: not guaranteed in the general case; requires additional effort
- Duplication: at-least-once delivery → the consumer must be idempotent

### When to Use Which

| Scenario | Approach | Rationale |
|---|---|---|
| Account debit / payment | **Sync** | Client waits for confirmation; an immediate response is required |
| Sending email / SMS | **Async** | Client does not need to wait; email can arrive within seconds |
| Generating a PDF report | **Async** | Long-running operation; use polling or webhook for the result |
| Checking inventory on order | **Sync** | Availability must be known before confirming the order |
| Updating analytics / dashboard | **Async** | Eventual consistency is acceptable |
| Syncing search (Elasticsearch) | **Async** | Indexing can lag by seconds — that's fine |
| Status-change notification | **Async** | Fan-out to multiple subscribers |
| Login / Auth | **Sync** | User is blocked until receiving a token |
| Image resizing | **Async** | CPU-intensive; do not hold an HTTP connection |
| Webhook to external systems | **Async** | External system may be temporarily unavailable |

---

## 2. Apache Kafka — Deep Dive

### Architecture

Kafka is a distributed commit log. Not a traditional queue, but an append-only log with retention.

```
                         Kafka Cluster
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Topic: "orders"                                      │   │
│  │                                                      │   │
│  │  Partition 0: [msg0][msg1][msg4][msg7]──► leader: B1 │   │
│  │  Partition 1: [msg2][msg5][msg8]────────► leader: B2 │   │
│  │  Partition 2: [msg3][msg6][msg9]────────► leader: B3 │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
│  Broker 1 (B1)        Broker 2 (B2)        Broker 3 (B3)   │
│  ┌───────────┐        ┌───────────┐        ┌───────────┐    │
│  │ P0 leader │        │ P1 leader │        │ P2 leader │    │
│  │ P1 replica│        │ P2 replica│        │ P0 replica│    │
│  │ P2 replica│        │ P0 replica│        │ P1 replica│    │
│  └───────────┘        └───────────┘        └───────────┘    │
│                                                             │
│  ZooKeeper / KRaft (cluster metadata, leader election)      │
└─────────────────────────────────────────────────────────────┘

Producer                                   Consumer Group A
┌────────┐    partition key hash           ┌────────────────┐
│        │──msg(key="order-123")──────────►│ Consumer A1    │◄─── P0
│ Order  │──msg(key="order-456")──────────►│ Consumer A2    │◄─── P1
│ Service│──msg(key="order-789")──────────►│ Consumer A3    │◄─── P2
└────────┘                                 └────────────────┘
                                           Consumer Group B
                                           ┌────────────────┐
                                           │ Consumer B1    │◄─── P0, P1
                                           │ Consumer B2    │◄─── P2
                                           └────────────────┘
```

**Key components:**

- **Broker** — a single node in a Kafka cluster. Stores a subset of partitions.
- **Topic** — a logical category of messages (analogous to a table in a database).
- **Partition** — a physical append-only log. The unit of parallelism.
- **Replica** — a copy of a partition on another broker. One replica is the leader; the rest are followers.
- **Consumer Group** — a set of consumers that collectively read a topic. Each partition is read by exactly one consumer in the group at any given time.
- **ZooKeeper / KRaft** — ZooKeeper historically managed cluster metadata. From Kafka 3.x, KRaft (Kafka Raft) replaces ZooKeeper, removing the external dependency.

### Ordering: Guarantees and Limitations

**Ordering is guaranteed ONLY within a single partition.**

```
Partition 0: msg1 → msg4 → msg7   (strict order)
Partition 1: msg2 → msg5 → msg8   (strict order)
Partition 2: msg3 → msg6 → msg9   (strict order)

Across partitions: msg1, msg2, msg3 can be delivered in any order
```

If global order is needed — use a single partition (you lose parallelism).
If order is needed within an entity (all events for order_id=123 in the correct sequence) — use partition key = order_id.

### Partition Key: Choice and Consequences

The partition a message lands in = `hash(key) % num_partitions`.

**Rules for choosing a partition key:**

| Situation | Good Key | Bad Key |
|---|---|---|
| Order events | `order_id` | `user_country` (too few distinct values) |
| User actions | `user_id` | `event_type` ("click", "view" — uneven distribution) |
| Financial transactions | `account_id` | `null` (random distribution — loses ordering) |
| Logs by service | `service_name` | `timestamp` (each key is unique → many single-message partitions) |

**Hot Partition:**
If a key has skewed distribution (e.g., 80% of messages from the top 10 users), one partition receives a disproportionately large load. Symptoms: one consumer in the group is overwhelmed; the rest are idle.

Solutions:
- Composite key: `user_id + random_suffix` (loses ordering, but evens out load)
- Increase the number of partitions
- Use a custom partitioner

### Offsets

```
Partition 0 log:
┌────┬────┬────┬────┬────┬────┬────┬────┐
│ 0  │ 1  │ 2  │ 3  │ 4  │ 5  │ 6  │ 7  │
└────┴────┴────┴────┴────┴────┴────┴────┘
                           ▲              ▲
                           │              │
                    committed offset   log end offset
                         (=5)             (=7)

                    consumer lag = log_end_offset - committed_offset = 2
```

- **Log End Offset (LEO)** — the next offset where a message will be written.
- **Committed Offset** — the offset up to which the consumer has acknowledged processing.
- **Consumer Lag** = LEO − committed offset. The primary health metric for a pipeline.

Offsets are stored in the special Kafka topic `__consumer_offsets`.

### Delivery Guarantees

#### At-most-once
Producer sends → does not wait for ack. Consumer commits offset before processing.

```go
// Producer: fire-and-forget (acks=0)
// Consumer: commit before processing
offset.commit()
process(message)  // if this crashes — the message is lost
```

Used for: metrics, logs, where loss is acceptable.

#### At-least-once (default)
Producer waits for ack from the leader. Consumer commits after processing.

```go
// Consumer: commit after processing
process(message)
offset.commit()  // if it crashes before commit — the message will be processed again
```

The consumer **must be idempotent** — processing a duplicate must not change the result.

#### Exactly-once (EOS)
Requires: idempotent producer + transactional API.

```
Producer → (idempotent writes, sequence numbers) → Kafka
Kafka → (transactional reads) → Consumer → (transactional writes) → Kafka/DB
```

- **Idempotent producer** (`enable.idempotence=true`): each message has a sequence number. Kafka rejects duplicates on retry.
- **Transactions**: the producer opens a transaction, writes to multiple topics atomically, then commits or rolls back.

Exactly-once is expensive — latency increases, throughput drops. Use only when truly necessary (finance, inventory).

### Retention

| Retention Type | Configuration | When to Use |
|---|---|---|
| Time-based | `retention.ms=604800000` (7 days) | Standard case, events with a TTL |
| Size-based | `retention.bytes=10737418240` (10 GB) | Limited disk space |
| Compact | `cleanup.policy=compact` | Event sourcing, changelog topics |

**Compacted topics:**
Kafka retains only the last message for each key. Deleted records are marked with a tombstone (a message with a `null` payload). Used in Kafka Streams for changelogs and in Debezium for CDC.

### Consumer Groups: Rebalancing

Rebalancing occurs when:
- A new consumer joins the group
- A consumer dies (heartbeat timeout)
- A consumer calls `unsubscribe()`
- The number of partitions changes

**Partition assignment strategies:**

| Strategy | Behavior | When to Use |
|---|---|---|
| **Range** | Partitions are sorted and split into consecutive blocks | Default. Predictable but uneven when the partition count is not a multiple of the consumer count |
| **Round-robin** | Partitions are distributed in round-robin order | Even load, if all consumers subscribe to the same topics |
| **Sticky** | Like round-robin, but preserves previous assignments during rebalance where possible | Reduces the number of movements during rebalance |
| **Cooperative Sticky** | Incremental rebalance — only reassigns partitions that have changed | **Recommended.** No stop-the-world pause; consumers continue reading during rebalance |

**Stop-the-world rebalance (old behavior):**
All consumers stop reading → the group coordinator assigns partitions → consumers resume reading. The pause can be 30+ seconds in large groups.

**Cooperative Sticky (Kafka 2.4+):**
The rebalance happens incrementally — only consumers that need to hand off partitions are stopped. The rest continue working.

### Kafka Connect

Kafka Connect is a framework for integrating Kafka with external systems without writing code.

```
MySQL ──(Source Connector)──► Kafka Topic ──(Sink Connector)──► Elasticsearch
                                                              ──► S3
                                                              ──► PostgreSQL
```

- **Source Connector** — reads from an external system, writes to Kafka.
- **Sink Connector** — reads from Kafka, writes to an external system.
- **CDC (Change Data Capture)** — a Debezium source connector reads the MySQL/PostgreSQL binlog and publishes each row change as a Kafka message.

```
PostgreSQL WAL → Debezium → Kafka Topic "postgres.public.orders"
  {op: "c", before: null, after: {id: 123, status: "created"}}
  {op: "u", before: {status: "created"}, after: {status: "shipped"}}
  {op: "d", before: {id: 123}, after: null}
```

### Kafka Streams vs ksqlDB

| | **Kafka Streams** | **ksqlDB** |
|---|---|---|
| What it is | Java/Kotlin library | SQL engine on top of Kafka |
| Deployment | Part of your application | Separate service |
| Language | Java/Kotlin (Go not natively supported) | SQL |
| Flexibility | Full (any logic) | Limited by SQL |
| Operational complexity | Low (no separate service) | High |
| When to use | Complex processing, joins, aggregations | Quick ad-hoc queries, simple transformations |

### Go Examples

#### Producer

```go
package main

import (
    "context"
    "encoding/json"
    "fmt"
    "log"
    "time"

    "github.com/segmentio/kafka-go"
)

type Order struct {
    ID        string    `json:"id"`
    UserID    string    `json:"user_id"`
    Amount    float64   `json:"amount"`
    Status    string    `json:"status"`
    CreatedAt time.Time `json:"created_at"`
}

func main() {
    writer := &kafka.Writer{
        Addr:                   kafka.TCP("localhost:9092"),
        Topic:                  "orders",
        Balancer:               &kafka.Hash{}, // partition key = message key
        RequiredAcks:           kafka.RequireAll, // acks=-1 (all in-sync replicas)
        MaxAttempts:            3,
        BatchTimeout:           10 * time.Millisecond,
        Async:                  false,
        // Idempotency is enabled via AllowAutoTopicCreation + correct acks
    }
    defer writer.Close()

    order := Order{
        ID:        "order-123",
        UserID:    "user-456",
        Amount:    99.99,
        Status:    "created",
        CreatedAt: time.Now(),
    }

    payload, err := json.Marshal(order)
    if err != nil {
        log.Fatal(err)
    }

    err = writer.WriteMessages(context.Background(),
        kafka.Message{
            Key:   []byte(order.ID), // partition key: all order-123 events → one partition
            Value: payload,
            Headers: []kafka.Header{
                {Key: "correlation-id", Value: []byte("req-789")},
                {Key: "source-service", Value: []byte("order-service")},
            },
        },
    )
    if err != nil {
        log.Fatal("failed to write message:", err)
    }

    fmt.Println("message published:", order.ID)
}
```

#### Consumer

```go
package main

import (
    "context"
    "encoding/json"
    "fmt"
    "log"
    "os"
    "os/signal"
    "syscall"

    "github.com/segmentio/kafka-go"
)

func main() {
    reader := kafka.NewReader(kafka.ReaderConfig{
        Brokers:        []string{"localhost:9092"},
        Topic:          "orders",
        GroupID:        "order-processor",  // consumer group
        MinBytes:       1,                  // minimum bytes for fetch
        MaxBytes:       10e6,               // 10 MB
        CommitInterval: 0,                  // manual commit
        // StartOffset: kafka.LastOffset,   // read only new messages
    })
    defer reader.Close()

    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()

    // Graceful shutdown
    sigCh := make(chan os.Signal, 1)
    signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
    go func() {
        <-sigCh
        cancel()
    }()

    for {
        // FetchMessage does not commit the offset automatically
        msg, err := reader.FetchMessage(ctx)
        if err != nil {
            if ctx.Err() != nil {
                fmt.Println("shutting down...")
                return
            }
            log.Printf("fetch error: %v", err)
            continue
        }

        var order Order
        if err := json.Unmarshal(msg.Value, &order); err != nil {
            log.Printf("unmarshal error: %v, skipping message", err)
            // Skip but commit — poison pills are handled separately
            if err := reader.CommitMessages(ctx, msg); err != nil {
                log.Printf("commit error: %v", err)
            }
            continue
        }

        if err := processOrder(ctx, order); err != nil {
            log.Printf("process error for order %s: %v", order.ID, err)
            // Do not commit — the message will be re-read (at-least-once)
            // On persistent errors → DLQ logic
            continue
        }

        // Commit only after successful processing
        if err := reader.CommitMessages(ctx, msg); err != nil {
            log.Printf("commit error: %v", err)
        }

        fmt.Printf("processed order %s (partition=%d, offset=%d)\n",
            order.ID, msg.Partition, msg.Offset)
    }
}

func processOrder(ctx context.Context, order Order) error {
    // business logic
    fmt.Printf("processing order: %+v\n", order)
    return nil
}
```

### Order Processing: Retry Topic and DLQ

Standard pattern for resilient processing:

```
orders ──► [Order Processor]
              │
              ├── success → commit offset
              │
              └── error (attempt 1) → orders.retry.1 (delay: 1m)
                      │
                      └── error (attempt 2) → orders.retry.2 (delay: 5m)
                              │
                              └── error (attempt 3) → orders.retry.3 (delay: 30m)
                                      │
                                      └── error (final) → orders.dlq
```

```go
package main

import (
    "context"
    "encoding/json"
    "fmt"
    "log"
    "strconv"
    "time"

    "github.com/segmentio/kafka-go"
)

const (
    TopicOrders      = "orders"
    TopicRetry1      = "orders.retry.1"
    TopicRetry2      = "orders.retry.2"
    TopicRetry3      = "orders.retry.3"
    TopicDLQ         = "orders.dlq"
    MaxRetryAttempts = 3
)

var retryTopics = []string{TopicRetry1, TopicRetry2, TopicRetry3}
var retryDelays = []time.Duration{1 * time.Minute, 5 * time.Minute, 30 * time.Minute}

type MessageEnvelope struct {
    Payload      json.RawMessage `json:"payload"`
    AttemptCount int             `json:"attempt_count"`
    LastError    string          `json:"last_error"`
    OriginalTopic string         `json:"original_topic"`
}

func routeToRetryOrDLQ(ctx context.Context, writer *kafka.Writer, msg kafka.Message, processingErr error) error {
    // Read the current attempt count from the header
    attemptCount := 0
    for _, h := range msg.Headers {
        if h.Key == "attempt-count" {
            count, err := strconv.Atoi(string(h.Value))
            if err == nil {
                attemptCount = count
            }
        }
    }

    attemptCount++

    var destTopic string
    if attemptCount >= MaxRetryAttempts {
        destTopic = TopicDLQ
        log.Printf("message %s exceeded max retries, routing to DLQ", string(msg.Key))
    } else {
        destTopic = retryTopics[attemptCount-1]
        delay := retryDelays[attemptCount-1]
        log.Printf("message %s attempt %d failed, routing to %s (delay: %v)",
            string(msg.Key), attemptCount, destTopic, delay)
    }

    newMsg := kafka.Message{
        Topic: destTopic,
        Key:   msg.Key,
        Value: msg.Value,
        Headers: append(msg.Headers,
            kafka.Header{Key: "attempt-count", Value: []byte(strconv.Itoa(attemptCount))},
            kafka.Header{Key: "last-error", Value: []byte(processingErr.Error())},
            kafka.Header{Key: "failed-at", Value: []byte(time.Now().UTC().Format(time.RFC3339))},
            kafka.Header{Key: "original-topic", Value: []byte(TopicOrders)},
        ),
    }

    return writer.WriteMessages(ctx, newMsg)
}
```

**Retry consumer** — a separate service that reads retry topics and waits the required delay before processing. A simple approach: check the `failed-at` header; if the time has not yet arrived — sleep until the right moment, then reprocess.

---

## 3. NATS and NATS JetStream

### NATS Core

NATS is a lightweight, high-performance messaging system. In basic mode (Core NATS), it provides fire-and-forget pub/sub without persistence.

```
Publisher ──publish("orders.created")──► NATS Server ──► Subscriber 1
                                                     ──► Subscriber 2
                                                     ──► Subscriber 3

If Subscriber is offline at publish time — the message is lost.
```

**Core NATS patterns:**
- **Pub/Sub**: the publisher is unaware of subscribers; 1:N.
- **Request/Reply**: a built-in mechanism. The publisher waits for a response from one of the subscribers.
- **Queue Groups**: multiple subscribers in the same queue group — the message is delivered to only one (load balancing without consumer groups).

### NATS JetStream

JetStream adds persistence, at-least-once delivery, and consumer semantics.

```
Publisher ──publish──► JetStream Stream ──► Consumer (push/pull)
                       (persistent log)

Stream = storage for messages on one or more subjects
Consumer = subscription to a stream with state (last processed message)
```

**Key differences from Core NATS:**

| | Core NATS | JetStream |
|---|---|---|
| Persistence | No (memory only) | Yes (disk/memory) |
| Delivery guarantee | At-most-once | At-least-once |
| Consumer state | No | Yes (durable consumers) |
| Replay | No | Yes (from any offset) |
| Retention | No | Time/size/limit-based |

### When to Choose NATS over Kafka

| Criterion | NATS/JetStream | Kafka |
|---|---|---|
| Operational complexity | Low (single binary, built-in clustering) | High (ZooKeeper/KRaft, many configuration options) |
| Throughput | Up to ~10M msg/s | Up to ~100M msg/s |
| Retention | Limited | Practically unlimited |
| Ordering | Per-consumer, not partition-based | Per-partition (stricter) |
| Ecosystem | Smaller | Enormous (Connect, Streams, ksqlDB) |
| **Conclusion** | Microservices with moderate load | High-throughput data pipelines, event sourcing |

**Choose NATS JetStream if:**
- The team is small and Kafka is operationally excessive
- Latency matters more than throughput (NATS latency < 1ms vs Kafka ~5ms)
- The request/reply pattern is needed
- Load is in the hundreds of thousands, not tens of millions of messages per second

### Go Example: NATS JetStream pub/sub

```go
package main

import (
    "context"
    "encoding/json"
    "fmt"
    "log"
    "time"

    "github.com/nats-io/nats.go"
    "github.com/nats-io/nats.go/jetstream"
)

type OrderEvent struct {
    ID     string  `json:"id"`
    UserID string  `json:"user_id"`
    Amount float64 `json:"amount"`
    Event  string  `json:"event"` // "created", "paid", "shipped"
}

func main() {
    nc, err := nats.Connect("nats://localhost:4222",
        nats.ReconnectWait(2*time.Second),
        nats.MaxReconnects(-1),
    )
    if err != nil {
        log.Fatal(err)
    }
    defer nc.Drain()

    js, err := jetstream.New(nc)
    if err != nil {
        log.Fatal(err)
    }

    ctx := context.Background()

    // Create stream (idempotent)
    stream, err := js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
        Name:      "ORDERS",
        Subjects:  []string{"orders.>"},  // wildcard: orders.created, orders.paid, etc.
        Retention: jetstream.LimitsPolicy,
        MaxAge:    7 * 24 * time.Hour,
        Storage:   jetstream.FileStorage,
        Replicas:  1, // in production: 3
    })
    if err != nil {
        log.Fatal(err)
    }
    _ = stream

    // Publisher
    go func() {
        for i := 0; i < 5; i++ {
            event := OrderEvent{
                ID:     fmt.Sprintf("order-%d", i),
                UserID: fmt.Sprintf("user-%d", i%3),
                Amount: float64(i) * 10.5,
                Event:  "created",
            }
            payload, _ := json.Marshal(event)

            ack, err := js.Publish(ctx, "orders.created", payload,
                jetstream.WithMsgID(event.ID), // idempotency key
            )
            if err != nil {
                log.Printf("publish error: %v", err)
                continue
            }
            fmt.Printf("published %s → stream %s, seq %d\n",
                event.ID, ack.Stream, ack.Sequence)
            time.Sleep(100 * time.Millisecond)
        }
    }()

    // Consumer (durable, pull-based)
    consumer, err := js.CreateOrUpdateConsumer(ctx, "ORDERS", jetstream.ConsumerConfig{
        Name:          "order-processor",
        Durable:       "order-processor",
        FilterSubject: "orders.created",
        AckPolicy:     jetstream.AckExplicitPolicy, // manual ack
        MaxDeliver:    3,                            // maximum 3 delivery attempts
        AckWait:       30 * time.Second,
        DeliverPolicy: jetstream.DeliverNewPolicy,
    })
    if err != nil {
        log.Fatal(err)
    }

    msgs, err := consumer.Messages()
    if err != nil {
        log.Fatal(err)
    }
    defer msgs.Stop()

    for i := 0; i < 5; i++ {
        msg, err := msgs.Next()
        if err != nil {
            log.Printf("next error: %v", err)
            break
        }

        var event OrderEvent
        if err := json.Unmarshal(msg.Data(), &event); err != nil {
            log.Printf("unmarshal error: %v", err)
            msg.Nak() // negative ack → redelivery
            continue
        }

        fmt.Printf("received: %s, amount: %.2f\n", event.ID, event.Amount)

        // Successfully processed → ack
        msg.Ack()
    }
}
```

---

## 4. RabbitMQ

### Model: Exchange → Queue → Consumer

RabbitMQ is an AMQP broker with a "smart broker / dumb consumer" model. All routing logic lives in the broker.

```
                    RabbitMQ
┌────────────────────────────────────────────────────────┐
│                                                        │
│  Producer                                              │
│     │                                                  │
│     ▼                                                  │
│  Exchange ──binding(routing_key="order.*")──► Queue 1 ──► Consumer A
│  (topic)  ──binding(routing_key="order.#")──► Queue 2 ──► Consumer B
│           ──binding(routing_key="#.paid")──►  Queue 3 ──► Consumer C
│                                                        │
└────────────────────────────────────────────────────────┘
```

### Exchange Types

| Type | Routing Logic | Example Use Case |
|---|---|---|
| **Direct** | routing_key exactly matches the binding key | Route a message to a specific service |
| **Fanout** | Broadcasts to all bound queues; routing_key is ignored | Broadcast: notify all subscribers |
| **Topic** | routing_key matches a pattern (`*` — one word, `#` — zero or more) | `order.created`, `order.*.paid`, `#.error` |
| **Headers** | Routing by message headers (AMQP headers), not routing_key | Complex routing conditions |

**Topic exchange examples:**
```
routing_key: "order.europe.paid"
Patterns:
  "order.#"        → match (order + any number of words)
  "order.*.paid"   → match (* = one word "europe")
  "order.europe.*" → match
  "#.paid"         → match
  "order.asia.*"   → no match
```

### Acknowledgments

**Auto-ack (`no-ack=true`):**
The broker considers a message delivered as soon as it is sent. If the consumer crashes before processing — the message is lost. Used only for non-critical data where maximum throughput is needed.

**Manual ack:**
The consumer explicitly confirms processing:
- `basicAck(deliveryTag)` — successfully processed; remove from queue
- `basicNack(deliveryTag, requeue=true)` — error; return to queue
- `basicNack(deliveryTag, requeue=false)` — error; do not return (→ DLX if configured)
- `basicReject(deliveryTag, requeue=false)` — reject (equivalent to Nack for a single message)

**Prefetch count:**
The number of unacknowledged messages the broker may send to a consumer. `prefetch=1` — process strictly one at a time (slow, reliable). `prefetch=100` — batch processing (fast, but up to 100 in-flight messages may be lost on crash).

### Dead Letter Exchange (DLX)

```
Queue: "orders"
  DLX: "orders.dlx"
  DLQ: "orders.dead-letter"

A message goes to the DLX if:
  - basicNack/basicReject with requeue=false
  - Message TTL expired
  - Queue is full (x-max-length)
```

```go
// Creating a queue with DLX
args := amqp.Table{
    "x-dead-letter-exchange":    "orders.dlx",
    "x-dead-letter-routing-key": "dead",
    "x-message-ttl":             int32(30000), // 30 second TTL
}
q, err := ch.QueueDeclare("orders", true, false, false, false, args)
```

### RabbitMQ vs Kafka: Fundamental Difference

```
RabbitMQ: "Smart Broker / Dumb Consumer"
──────────────────────────────────────
Producer → Exchange → Queue → Consumer
                ▲
         all logic here:
         routing, filtering,
         transformations,
         TTL, DLX, priority

Broker is aware of consumers and pushes messages to them.
After delivery → the message is deleted.


Kafka: "Dumb Broker / Smart Consumer"
──────────────────────────────────────
Producer → Partition Log → Consumer
                           ▲
                    all logic here:
                    which offset to read,
                    how to interpret,
                    reprocessing, backfill

Broker simply stores the log. Consumer manages its own offset.
Messages are not deleted upon reading.
```

| | RabbitMQ | Kafka |
|---|---|---|
| Model | Push (broker pushes to consumer) | Pull (consumer fetches) |
| Storage | Deletes after delivery | Retention-based (days/weeks) |
| Re-reading | Not possible (deleted) | Possible (reset offset) |
| Routing | Rich (exchanges, bindings) | Only by partition key |
| Priority queues | Yes | No |
| Throughput | ~100K msg/s | ~1M+ msg/s |
| Ordering | Per-queue | Per-partition |

### When to Use RabbitMQ

- Complex routing: different event types must go to different services based on conditions
- Priority queues: VIP clients are processed faster
- Task queues: long-running tasks with a worker pool
- Legacy: existing AMQP infrastructure
- Replay is not needed: messages do not need to be re-read after processing
- Low throughput: tens/hundreds of thousands of messages per second, not millions

---

## 5. Queue Patterns

### Competing Consumers

Multiple consumers read from the same queue. Each message is processed by exactly one.

```
Queue: [msg1][msg2][msg3][msg4][msg5]
         │       │       │
    Worker 1  Worker 2  Worker 3
   (processes  (processes  (processes
    msg1, msg4)  msg2, msg5)  msg3)
```

Used for: horizontal scaling of processing.
In Kafka: one consumer group = competing consumers. Maximum parallelism = number of partitions.

### Fan-out

One message is delivered to multiple independent consumers.

```
Event: order.created
         │
         ├──► Email Service (send confirmation)
         ├──► Analytics Service (update metrics)
         ├──► Inventory Service (reserve items)
         └──► Notification Service (push notification)
```

In Kafka: multiple consumer groups read the same topic independently.
In RabbitMQ: fanout exchange + a separate queue for each service.

### Dead Letter Queue (DLQ)

```
orders ──► [Processor] ──success──► done
                │
                └──failure (all retries exhausted)──► orders.dlq

DLQ contains:
  - original message
  - headers: attempt count, last error, error time
  - metadata: partition, offset, consumer

Operational process:
  1. Alert when messages appear in DLQ
  2. Engineer investigates the cause
  3. Fixes code or data
  4. Replays messages from DLQ back to the main topic
```

### Retry with Exponential Backoff

```
Attempt 1: immediate
Attempt 2: delay 1s  (2^0 = 1)
Attempt 3: delay 2s  (2^1 = 2)
Attempt 4: delay 4s  (2^2 = 4)
Attempt 5: delay 8s  (2^3 = 8)
...
Max delay: 60s (cap)
After N attempts: → DLQ
```

**Implementation via separate retry topics (Kafka):**

```
orders ──► [Processor]
              │
              └──error──► orders.retry (delay header: 30s)
                              │
                         [Retry Scheduler]
                              │ (waits 30s)
                              └──► orders (republish)
```

**Implementation via a delayed queue (RabbitMQ):**

```go
// Create a queue with TTL and DLX that routes back to work
retryQueue := amqp.Table{
    "x-message-ttl":             int32(30000), // 30s delay
    "x-dead-letter-exchange":    "orders",     // after TTL → return to work
    "x-dead-letter-routing-key": "process",
}
```

### Idempotent Consumer

Protection against reprocessing duplicate messages.

```
Message: {id: "msg-123", order_id: "order-456", action: "charge"}
              │
              ▼
[Check idempotency key in Redis/DB]
              │
    ┌─────────┴──────────┐
    │                    │
  EXISTS              NOT EXISTS
    │                    │
  Skip            Process + Store key
 (already done)    (TTL: 24h)
```

**Go example with Redis:**

```go
package main

import (
    "context"
    "encoding/json"
    "errors"
    "fmt"
    "log"
    "time"

    "github.com/redis/go-redis/v9"
    "github.com/segmentio/kafka-go"
)

type Message struct {
    ID      string          `json:"id"`       // idempotency key
    Payload json.RawMessage `json:"payload"`
}

type IdempotentProcessor struct {
    redis  *redis.Client
    ttl    time.Duration
}

func NewIdempotentProcessor(redisAddr string) *IdempotentProcessor {
    rdb := redis.NewClient(&redis.Options{
        Addr: redisAddr,
    })
    return &IdempotentProcessor{
        redis: rdb,
        ttl:   24 * time.Hour,
    }
}

// Process returns nil if the message was already processed (idempotent skip)
func (p *IdempotentProcessor) Process(ctx context.Context, msg Message, fn func(context.Context, Message) error) error {
    key := "processed:" + msg.ID

    // SET NX (set if not exists) — atomic operation
    set, err := p.redis.SetNX(ctx, key, "1", p.ttl).Result()
    if err != nil {
        return fmt.Errorf("redis setnx: %w", err)
    }

    if !set {
        // Key already exists — message was already processed
        log.Printf("skipping duplicate message: %s", msg.ID)
        return nil
    }

    // Process it
    if err := fn(ctx, msg); err != nil {
        // Roll back the key so it can be retried
        p.redis.Del(ctx, key)
        return fmt.Errorf("processing failed: %w", err)
    }

    return nil
}

func main() {
    processor := NewIdempotentProcessor("localhost:6379")

    reader := kafka.NewReader(kafka.ReaderConfig{
        Brokers: []string{"localhost:9092"},
        Topic:   "orders",
        GroupID: "order-idempotent-processor",
    })
    defer reader.Close()

    ctx := context.Background()

    for {
        kafkaMsg, err := reader.FetchMessage(ctx)
        if err != nil {
            log.Fatal(err)
        }

        var msg Message
        if err := json.Unmarshal(kafkaMsg.Value, &msg); err != nil {
            log.Printf("unmarshal error: %v", err)
            reader.CommitMessages(ctx, kafkaMsg)
            continue
        }

        err = processor.Process(ctx, msg, func(ctx context.Context, m Message) error {
            // Your business logic here
            fmt.Printf("processing message: %s\n", m.ID)
            return nil
        })

        if err != nil && !errors.Is(err, context.Canceled) {
            log.Printf("processing error: %v", err)
            continue // do not commit → retry
        }

        reader.CommitMessages(ctx, kafkaMsg)
    }
}
```

**Important:** `SET NX` + `DEL` on error contains a race condition with concurrent consumers. In production, use a Lua script or a database-level unique index for a strict guarantee.

### Poison Pill

A poison pill is a message that the consumer cannot process and repeatedly crashes on.

```
Queue: [msg1][msg2][POISON][msg4][msg5]
                     │
              consumer crashes
              broker redelivers
              consumer crashes again
              ...
              all other messages are blocked
```

**Detection:**
- Kafka: track the redelivery count via the `attempt-count` header
- RabbitMQ: the `x-death` field in message headers contains the history of rejects

**Handling:**

```go
func handleMessage(ctx context.Context, msg kafka.Message) error {
    attemptCount := getAttemptCount(msg.Headers) // read from header

    if attemptCount >= MaxAttempts {
        // Poison pill detected — send to DLQ without retry
        log.Printf("poison pill detected for key=%s, sending to DLQ", string(msg.Key))
        return sendToDLQ(ctx, msg, fmt.Errorf("exceeded max attempts: %d", MaxAttempts))
    }

    if err := process(ctx, msg); err != nil {
        return sendToRetryTopic(ctx, msg, err, attemptCount+1)
    }

    return nil
}
```

### Ordered Processing with Parallel Execution

Task: process events for a single order strictly in order, while processing different orders in parallel.

```
Events:
order-1: [created] [paid] [shipped]  → strictly in order
order-2: [created] [paid]            → strictly in order
order-3: [created]                   → strictly in order

But order-1, order-2, order-3 can be processed in parallel.
```

**Solution 1: Kafka partition key = entity ID**
All events for order-1 go to the same partition → one consumer in the group processes them sequentially.

**Solution 2: Virtual partitions in memory**

```go
type OrderedProcessor struct {
    workers   int
    channels  []chan Message
    wg        sync.WaitGroup
}

func NewOrderedProcessor(workers int) *OrderedProcessor {
    p := &OrderedProcessor{
        workers:  workers,
        channels: make([]chan Message, workers),
    }
    for i := 0; i < workers; i++ {
        p.channels[i] = make(chan Message, 100)
        p.wg.Add(1)
        go func(ch <-chan Message) {
            defer p.wg.Done()
            for msg := range ch {
                processMessage(msg) // strictly sequential for each worker
            }
        }(p.channels[i])
    }
    return p
}

func (p *OrderedProcessor) Submit(msg Message) {
    // Deterministic assignment: all messages for the same order_id → same worker
    workerIdx := hash(msg.OrderID) % p.workers
    p.channels[workerIdx] <- msg
}
```

---

## 6. Event-Driven Architecture

### Events vs Commands vs Queries

| | **Event** | **Command** | **Query** |
|---|---|---|---|
| Definition | Something happened (a fact) | A request to do something | A request for data |
| Form | `OrderCreated`, `PaymentProcessed` | `CreateOrder`, `ProcessPayment` | `GetOrder`, `ListOrders` |
| Sender | Does not know who will handle it | Knows the recipient | Knows the recipient |
| Response | None (fire-and-forget) | May have one | Required |
| Direction | 1:N (may have multiple handlers) | 1:1 | 1:1 |
| Semantics | "This happened" | "Do this" | "Give me this" |

### Event Patterns

#### Event Notification
Minimal event — just the fact, without data. The recipient fetches details itself.

```json
{
  "type": "order.created",
  "order_id": "123",
  "timestamp": "2026-03-23T09:00:00Z"
}
```

Pros: small payload, decoupling.
Cons: the recipient makes an additional API call to fetch data (latency, coupling with the API).

#### Event-Carried State Transfer
The event contains all necessary data. The recipient makes no additional requests.

```json
{
  "type": "order.created",
  "order_id": "123",
  "user_id": "456",
  "items": [...],
  "total": 99.99,
  "shipping_address": {...},
  "timestamp": "2026-03-23T09:00:00Z"
}
```

Pros: the recipient is autonomous; no additional requests.
Cons: large payload; data may become stale.

#### Event Sourcing
System state = sequence of events. Instead of storing the current state, a log of changes is stored.

```
Events:
  OrderCreated   → {id: 123, status: "created"}
  PaymentMade    → {id: 123, amount: 99.99}
  OrderShipped   → {id: 123, tracking: "TRK456"}

Current state = apply(all events) = {
  id: 123, status: "shipped", amount: 99.99, tracking: "TRK456"
}
```

Pros: full history, replay, temporal queries ("what did the order look like yesterday at 3 PM").
Cons: complexity, eventual consistency, event schema evolution.

### Choreography vs Orchestration

```
Choreography (dance without a director):
─────────────────────────────────────
Order Service → event: order.created
                    │
    ┌───────────────┼───────────────┐
    ▼               ▼               ▼
Payment Service  Inventory       Notification
  │               Service           Service
  └─► event: payment.processed
              │
        Inventory Service listens and reserves items

Each service reacts to events from the others.
No central coordinator.
Pros: loose coupling. Cons: hard to trace the full business process.


Orchestration (conductor):
──────────────────────────
Order Saga Orchestrator
  │── command: process_payment → Payment Service
  │                              │── reply: payment_ok
  │── command: reserve_items   → Inventory Service
  │                              │── reply: items_reserved
  └── command: send_notification → Notification Service

One service coordinates the entire process.
Pros: the business process is visible in one place. Cons: orchestrator is a SPOF, coupling.
```

**When to use which:**
- **Choreography**: simple, independent reactions to events. Few participants.
- **Orchestration**: complex multi-step processes with compensations (saga pattern). Explicit state control is needed.

### Schema Evolution

Problem: the producer updated the event schema; old consumers break.

#### Avro + Schema Registry

```
Producer ──serialize(Avro)──► Schema Registry ──schema ID──► Kafka Message
Consumer ──deserialize──► Schema Registry (fetch schema by ID) ──► object
```

Compatibility rules (Confluent Schema Registry):
- **BACKWARD**: new schema can read old data (new fields — optional with default)
- **FORWARD**: old schema can read new data
- **FULL**: both BACKWARD and FORWARD simultaneously

#### Protobuf

Numbered fields are the foundation of compatibility. Never delete field numbers; only mark them `reserved`.

```protobuf
message OrderCreated {
  string order_id = 1;
  string user_id = 2;
  double amount = 3;
  // New field — backward compatible (clients without this field simply ignore it)
  string coupon_code = 4;
  // Deleted field:
  // reserved 5; reserved "old_field"; // do not reuse the number
}
```

#### Recommendations for Schema Evolution

1. Always make new fields optional with a sensible default
2. Never change a field's type
3. Never rename fields in JSON (only add new ones)
4. Version the topic name on breaking changes: `orders.v1`, `orders.v2`
5. Use Schema Registry in production — automatic compatibility checking

### Example: Order Created Fan-out

```
Order Service
     │
     └──publish──► Kafka: "orders" topic
                    event: OrderCreated
                    {
                      "id": "order-123",
                      "user_id": "user-456",
                      "items": [...],
                      "total": 99.99,
                      "email": "user@example.com"
                    }
                         │
          ┌──────────────┼──────────────────┐
          │              │                  │
          ▼              ▼                  ▼
   Email Service   Analytics Service  Inventory Service
   consumer        consumer           consumer
   group:          group:             group:
   "email-svc"     "analytics-svc"    "inventory-svc"
          │              │                  │
   send              update             reserve
   confirmation      dashboard          stock
   email

All three consumer groups read the same topic independently.
Each group receives all messages.
Adding a new consumer group = zero changes to Order Service.
```

```go
// Email Service consumer
package main

import (
    "context"
    "encoding/json"
    "fmt"
    "log"

    "github.com/segmentio/kafka-go"
)

type OrderCreatedEvent struct {
    ID     string  `json:"id"`
    UserID string  `json:"user_id"`
    Items  []Item  `json:"items"`
    Total  float64 `json:"total"`
    Email  string  `json:"email"`
}

type Item struct {
    ProductID string  `json:"product_id"`
    Quantity  int     `json:"quantity"`
    Price     float64 `json:"price"`
}

func main() {
    reader := kafka.NewReader(kafka.ReaderConfig{
        Brokers: []string{"localhost:9092"},
        Topic:   "orders",
        GroupID: "email-service", // unique group ID → receives all messages
    })
    defer reader.Close()

    ctx := context.Background()
    for {
        msg, err := reader.FetchMessage(ctx)
        if err != nil {
            log.Fatal(err)
        }

        var event OrderCreatedEvent
        if err := json.Unmarshal(msg.Value, &event); err != nil {
            log.Printf("invalid event: %v", err)
            reader.CommitMessages(ctx, msg)
            continue
        }

        if err := sendConfirmationEmail(ctx, event); err != nil {
            log.Printf("email send failed: %v", err)
            continue // retry
        }

        reader.CommitMessages(ctx, msg)
        fmt.Printf("sent confirmation to %s for order %s\n", event.Email, event.ID)
    }
}

func sendConfirmationEmail(ctx context.Context, event OrderCreatedEvent) error {
    // integration with email provider
    fmt.Printf("sending email to: %s\n", event.Email)
    return nil
}
```

---

## 7. Choosing a Message Broker

### Comparison Table

| Criterion | **Kafka** | **RabbitMQ** | **NATS JetStream** | **AWS SQS/SNS** | **Google Pub/Sub** |
|---|---|---|---|---|---|
| **Throughput** | Very high (1M+ msg/s) | High (~100K msg/s) | High (~10M msg/s) | High (managed) | Very high (managed) |
| **Latency** | ~5-15ms | ~1-5ms | <1ms | ~10-100ms | ~10-100ms |
| **Ordering** | Per-partition | Per-queue | Per-consumer | Per-FIFO queue (SQS FIFO) | Per-key ordering |
| **Delivery** | At-least-once, Exactly-once | At-least-once, At-most-once | At-least-once | At-least-once | At-least-once |
| **Retention** | Days/weeks/forever | Until ACK | Configurable | 4 days (max 14) | 7 days |
| **Replay** | Yes (reset offset) | No | Yes | No | Limited |
| **Routing** | Partition key only | Rich (exchanges) | Subject wildcards | Attribute filtering | Attribute filtering |
| **Operational complexity** | High | Medium | Low | None (managed) | None (managed) |
| **Cost** | Infrastructure | Infrastructure | Infrastructure | Pay-per-use | Pay-per-use |
| **Ecosystem** | Enormous | Large | Growing | AWS | GCP |
| **Priority queues** | No | Yes | No | No | No |
| **CDC** | Yes (Debezium) | No | No | No | No |
| **Stream processing** | Kafka Streams, ksqlDB | No | No | No | Dataflow |
| **Max message size** | 1MB (configurable) | 2GB | 1MB (configurable) | 256KB (SQS) | 10MB |

### Additional Characteristics

**Kafka**
- Kafka Connect: hundreds of ready-made connectors (Debezium, S3, JDBC, Elasticsearch)
- Kafka Streams: stateful stream processing built in
- Confluent Platform: enterprise edition with Schema Registry, KSQL, Control Center
- MSK (AWS): Amazon-managed Kafka
- Confluent Cloud: fully managed Kafka-as-a-Service

**AWS SQS/SNS**
- SQS: simple queue; SNS: pub/sub fanout
- SQS FIFO: ordering + exactly-once (up to 300 msg/s or 3,000 with batching)
- Built-in dead-letter queue
- No replay — messages are deleted after processing

**Google Cloud Pub/Sub**
- Automatic scaling
- Seek: rewind to a timestamp or snapshot (limited replay)
- BigQuery and Dataflow integrations out of the box

### Decision Tree

```
Need replay / event sourcing?
├── Yes → Kafka or NATS JetStream
│         │
│         ├── Need rich ecosystem (Connect, Streams)?
│         │   └── Yes → Kafka
│         │
│         └── Priority: operational simplicity / low latency?
│             └── Yes → NATS JetStream
│
└── No
     │
     ├── On AWS?
     │   └── Yes → SQS/SNS (if managed is acceptable)
     │
     ├── On GCP?
     │   └── Yes → Google Pub/Sub
     │
     ├── Need complex routing / priority queues?
     │   └── Yes → RabbitMQ
     │
     ├── Need maximum throughput (>1M msg/s)?
     │   └── Yes → Kafka
     │
     ├── Small team, need operational simplicity?
     │   └── Yes → NATS JetStream or RabbitMQ
     │
     └── Need strict global ordering guarantee?
         └── Yes → Kafka (single partition) or SQS FIFO
```

### Scenarios and Recommendations

| Scenario | Recommendation | Rationale |
|---|---|---|
| Data pipeline, analytics, event streaming | **Kafka** | Retention, replay, high throughput, Kafka Connect |
| Microservices task queue | **RabbitMQ** or **NATS JetStream** | Simplicity, rich routing, less operations |
| Real-time notifications | **NATS Core** or **Kafka** | Low latency for NATS, scale for Kafka |
| CDC (database to downstream) | **Kafka + Debezium** | The only mature CDC ecosystem |
| Serverless / cloud-native AWS | **SQS + SNS** | Zero ops, pay-per-use, native Lambda integration |
| ML pipeline, batch processing | **Kafka** or **GCP Pub/Sub** | Retention for reprocessing, ML infra integration |
| IoT with millions of devices | **Kafka** or **NATS** | High throughput; NATS has lower overhead |
| Financial transactions | **Kafka (EOS)** | Exactly-once semantics |
| Game events, leaderboard | **NATS** or **Redis Streams** | Sub-millisecond latency |

---

## Module Summary

**Key principles:**

1. **Choose async deliberately.** Async solves temporal coupling and buffering, but adds eventual consistency and operational complexity. Do not make everything async.

2. **Kafka is not a queue — it is a log.** Retention, replay, consumer groups with independent offsets represent a different paradigm from RabbitMQ.

3. **Partition key is a critical decision.** A bad key → hot partition → bottleneck. The partition key determines both ordering and load distribution.

4. **Consumer lag is the primary metric.** If lag is growing — add more consumers or optimize processing.

5. **Idempotent consumer is not optional — it is a requirement.** With at-least-once delivery, duplicates are inevitable. The consumer must handle them correctly.

6. **DLQ is a mandatory part of the architecture.** Without a DLQ, a poison pill will block all processing. DLQ + alerting + replay = the complete cycle.

7. **Schema evolution — think ahead.** Breaking a consumer with an unexpected schema change is a common mistake. Use Schema Registry or Protobuf + discipline.

**Further reading:**

- [Kafka: The Definitive Guide](https://www.confluent.io/resources/kafka-the-definitive-guide/) — Neha Narkhede, Gwen Shapira, Todd Palino
- [Designing Event-Driven Systems](https://www.confluent.io/designing-event-driven-systems/) — Ben Stopford
- [Enterprise Integration Patterns](https://www.enterpriseintegrationpatterns.com/) — Hohpe & Woolf (classic integration patterns)
- [NATS Documentation](https://docs.nats.io/) — official documentation, especially JetStream
- [Confluent Documentation](https://docs.confluent.io/) — Kafka deep-dive

---

*Module 06 of 12 | [← Module 05: Caching](../05-caching/readme.md) | [Module 07: Databases →](../07-databases-sharding/readme.md)*
