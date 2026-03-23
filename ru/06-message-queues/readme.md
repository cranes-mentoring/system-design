# Модуль 06: Очереди и асинхронная обработка

> **Уровень:** Senior / Staff Backend Engineer  
> **Время:** ~4 часа  
> **Предыдущий модуль:** [05 — Кэширование](../05-caching/readme.md)  
> **Следующий модуль:** [07 — Базы данных: шардирование и репликация](../07-databases-sharding/readme.md)

---

## Содержание

1. [Синхронная vs Асинхронная коммуникация](#1-синхронная-vs-асинхронная-коммуникация)
2. [Apache Kafka — deep dive](#2-apache-kafka--deep-dive)
3. [NATS и NATS JetStream](#3-nats-и-nats-jetstream)
4. [RabbitMQ](#4-rabbitmq)
5. [Паттерны работы с очередями](#5-паттерны-работы-с-очередями)
6. [Event-Driven Architecture](#6-event-driven-architecture)
7. [Выбор message broker](#7-выбор-message-broker)

---

## 1. Синхронная vs Асинхронная коммуникация

### Sync: HTTP/gRPC

Caller ждёт ответа. Весь стек вызова держит соединение открытым.

```
Client ──HTTP/gRPC──► Service A ──HTTP/gRPC──► Service B
  ◄─────────────────────────────────────────────────────
                    ждём ответа от B
```

**Плюсы:**
- Простота: request/response семантика понятна любому разработчику
- Немедленный ответ: клиент знает результат синхронно
- Простая отладка: distributed trace линеен, ошибки видны сразу
- Простота транзакционности: один HTTP-вызов = одна атомарная операция с точки зрения клиента

**Минусы:**
- Temporal coupling: оба сервиса должны быть живы одновременно
- Каскадные отказы: если Service B упал → Service A получает ошибку → клиент получает ошибку
- Backpressure: при spike нагрузки Service B становится bottleneck для всей цепочки
- Latency amplification: итоговая latency = sum(latencies всех сервисов в цепочке)

### Async: через очередь/брокер

Caller отправляет сообщение в брокер и не ждёт обработки.

```
Client ──publish──► [Message Broker] ──consume──► Worker
  ◄──ack──           (буфер)
```

**Плюсы:**
- Temporal decoupling: producer и consumer не должны работать одновременно
- Буферизация: брокер поглощает traffic spikes, worker обрабатывает в своём темпе
- Retry из коробки: брокер перепоставит сообщение при ошибке consumer'а
- Масштабирование независимо: добавить worker'ов можно без изменения producer'а
- Fault isolation: упавший consumer не роняет producer

**Минусы:**
- Операционная сложность: брокер — ещё один компонент с мониторингом, backup, scaling
- Eventual consistency: клиент не знает результат немедленно
- Отладка сложнее: нужна distributed tracing с correlation ID через все сообщения
- Ordering: в general case не гарантирован, требует дополнительных усилий
- Дублирование: at-least-once delivery → consumer должен быть idempotent

### Когда что использовать

| Сценарий | Подход | Обоснование |
|---|---|---|
| Списание средств / оплата | **Sync** | Клиент ждёт подтверждения, требуется немедленный ответ |
| Отправка email / SMS | **Async** | Клиенту не нужно ждать, email может придти через секунды |
| Генерация PDF-отчёта | **Async** | Долгая операция, polling или webhook для результата |
| Проверка инвентаря при заказе | **Sync** | Нужно знать наличие до подтверждения заказа |
| Обновление аналитики / дашборда | **Async** | Eventual consistency приемлема |
| Синхронизация поиска (Elasticsearch) | **Async** | Индексация может отставать на секунды — нормально |
| Уведомление о смене статуса | **Async** | Fan-out на несколько подписчиков |
| Login / Auth | **Sync** | Пользователь блокирован до получения токена |
| Resize изображений | **Async** | CPU-intensive, не держать HTTP connection |
| Webhook к внешним системам | **Async** | Внешняя система может быть недоступна |

---

## 2. Apache Kafka — deep dive

### Архитектура

Kafka — это distributed commit log. Не традиционная очередь, а append-only log с retention.

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

**Ключевые компоненты:**

- **Broker** — один узел Kafka-кластера. Хранит subset партиций.
- **Topic** — логическая категория сообщений (аналог таблицы в БД).
- **Partition** — физический append-only log. Единица параллелизма.
- **Replica** — копия партиции на другом брокере. Одна replica — leader, остальные — followers.
- **Consumer Group** — набор consumer'ов, которые совместно читают topic. Каждая партиция в каждый момент читается ровно одним consumer'ом в группе.
- **ZooKeeper / KRaft** — ZooKeeper исторически управлял метаданными кластера. С Kafka 3.x KRaft (Kafka Raft) заменяет ZooKeeper, убирая внешнюю зависимость.

### Ordering: гарантии и ограничения

**Ordering гарантирован ТОЛЬКО внутри одной partition.**

```
Partition 0: msg1 → msg4 → msg7   (строгий порядок)
Partition 1: msg2 → msg5 → msg8   (строгий порядок)
Partition 2: msg3 → msg6 → msg9   (строгий порядок)

Между партициями: msg1, msg2, msg3 могут быть доставлены в любом порядке
```

Если нужен глобальный порядок — используй одну партицию (теряешь параллелизм).  
Если нужен порядок в рамках сущности (все события по order_id=123 в нужном порядке) — используй partition key = order_id.

### Partition Key: выбор и последствия

Partition, куда попадёт сообщение = `hash(key) % num_partitions`.

**Правила выбора partition key:**

| Ситуация | Хороший ключ | Плохой ключ |
|---|---|---|
| События заказов | `order_id` | `user_country` (мало значений) |
| Действия пользователей | `user_id` | `event_type` ("click", "view" — не равномерно) |
| Финансовые транзакции | `account_id` | `null` (random распределение — теряем ordering) |
| Логи по сервисам | `service_name` | `timestamp` (каждый ключ уникален → много одиночных партиций) |

**Hot Partition:**  
Если ключ имеет skewed distribution (например, 80% сообщений от top-10 пользователей), одна партиция получает несоразмерно большую нагрузку. Симптомы: один consumer в группе перегружен, остальные простаивают.

Решения:
- Составной ключ: `user_id + random_suffix` (теряем ordering, но выравниваем нагрузку)
- Увеличить количество партиций
- Использовать custom partitioner

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

- **Log End Offset (LEO)** — следующий offset, куда будет записано сообщение.
- **Committed Offset** — offset, до которого consumer подтвердил обработку.
- **Consumer Lag** = LEO − committed offset. Основная метрика здоровья pipeline.

Offset хранится в специальном Kafka topic `__consumer_offsets`.

### Delivery Guarantees

#### At-most-once
Producer отправил → не ждёт ack. Consumer commits offset перед обработкой.

```go
// Producer: fire-and-forget (acks=0)
// Consumer: commit до обработки
offset.commit()
process(message)  // если упало здесь — сообщение потеряно
```

Используется для: метрики, логи, где потеря допустима.

#### At-least-once (default)
Producer ждёт ack от leader. Consumer commits после обработки.

```go
// Consumer: commit после обработки
process(message)
offset.commit()  // если упало до commit — сообщение обработается повторно
```

Consumer **должен быть idempotent** — обработка дубликата не должна менять результат.

#### Exactly-once (EOS)
Требует: idempotent producer + transactional API.

```
Producer → (idempotent writes, sequence numbers) → Kafka
Kafka → (transactional reads) → Consumer → (transactional writes) → Kafka/DB
```

- **Idempotent producer** (`enable.idempotence=true`): каждое сообщение имеет sequence number. Kafka отклоняет дубликаты при retry.
- **Transactions**: producer открывает транзакцию, пишет в несколько топиков атомарно, коммитит или откатывает.

Exactly-once дорого — latency растёт, throughput падает. Использовать только когда действительно нужно (финансы, инвентарь).

### Retention

| Тип retention | Конфигурация | Когда использовать |
|---|---|---|
| Time-based | `retention.ms=604800000` (7 дней) | Стандартный случай, события с TTL |
| Size-based | `retention.bytes=10737418240` (10 GB) | Ограниченное дисковое пространство |
| Compact | `cleanup.policy=compact` | Event sourcing, changelog topics |

**Compacted topics:**  
Kafka хранит только последнее сообщение для каждого ключа. Удалённые записи помечаются tombstone (сообщение с `null` payload). Используется в Kafka Streams для changelog, в Debezium для CDC.

### Consumer Groups: Rebalancing

Rebalancing происходит когда:
- Новый consumer присоединяется к группе
- Consumer умирает (heartbeat timeout)
- Consumer вызывает `unsubscribe()`
- Изменяется количество партиций

**Стратегии назначения партиций:**

| Стратегия | Поведение | Когда использовать |
|---|---|---|
| **Range** | Партиции сортируются, делятся последовательными блоками | Default. Предсказуемо, но неравномерно при кол-ве партиций не кратном кол-ву consumers |
| **Round-robin** | Партиции распределяются по кругу | Равномерная нагрузка, если все consumer'ы подписаны на одинаковые topics |
| **Sticky** | Как round-robin, но при rebalance сохраняет предыдущие назначения где возможно | Снижает количество перемещений при rebalance |
| **Cooperative Sticky** | Инкрементальный rebalance — перераспределяет только изменившиеся партиции | **Рекомендуется.** Нет stop-the-world паузы, consumer продолжает читать во время rebalance |

**Stop-the-world rebalance (старое поведение):**  
Все consumers останавливают чтение → group coordinator назначает партиции → consumers возобновляют чтение. Пауза может быть 30+ секунд в больших группах.

**Cooperative Sticky (Kafka 2.4+):**  
Rebalance происходит инкрементально — только те consumers, которым нужно передать партиции, останавливаются. Остальные продолжают работать.

### Kafka Connect

Kafka Connect — фреймворк для интеграции Kafka с внешними системами без написания кода.

```
MySQL ──(Source Connector)──► Kafka Topic ──(Sink Connector)──► Elasticsearch
                                                              ──► S3
                                                              ──► PostgreSQL
```

- **Source Connector** — читает из внешней системы, пишет в Kafka.
- **Sink Connector** — читает из Kafka, пишет во внешнюю систему.
- **CDC (Change Data Capture)** — Debezium source connector читает binlog MySQL/PostgreSQL и публикует каждое изменение строки как Kafka message.

```
PostgreSQL WAL → Debezium → Kafka Topic "postgres.public.orders"
  {op: "c", before: null, after: {id: 123, status: "created"}}
  {op: "u", before: {status: "created"}, after: {status: "shipped"}}
  {op: "d", before: {id: 123}, after: null}
```

### Kafka Streams vs ksqlDB

| | **Kafka Streams** | **ksqlDB** |
|---|---|---|
| Что это | Java/Kotlin библиотека | SQL-движок поверх Kafka |
| Деплой | Часть вашего приложения | Отдельный сервис |
| Язык | Java/Kotlin (Go не поддерживается нативно) | SQL |
| Гибкость | Полная (любая логика) | Ограничена SQL |
| Операционная сложность | Низкая (нет отдельного сервиса) | Высокая |
| Когда использовать | Сложная обработка, joins, aggregations | Быстрые ad-hoc запросы, простые трансформации |

### Примеры на Go

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
        // Идемпотентность включается через AllowAutoTopicCreation + правильный acks
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
            Key:   []byte(order.ID), // partition key: все события order-123 → одна партиция
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
        MinBytes:       1,                  // минимум байт для fetch
        MaxBytes:       10e6,               // 10 MB
        CommitInterval: 0,                  // manual commit
        // StartOffset: kafka.LastOffset,   // читать только новые сообщения
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
        // FetchMessage не коммитит offset автоматически
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
            // Пропускаем, но коммитим — poison pill обрабатывается отдельно
            if err := reader.CommitMessages(ctx, msg); err != nil {
                log.Printf("commit error: %v", err)
            }
            continue
        }

        if err := processOrder(ctx, order); err != nil {
            log.Printf("process error for order %s: %v", order.ID, err)
            // Не коммитим — сообщение будет перечитано (at-least-once)
            // При постоянных ошибках → DLQ логика
            continue
        }

        // Коммитим только после успешной обработки
        if err := reader.CommitMessages(ctx, msg); err != nil {
            log.Printf("commit error: %v", err)
        }

        fmt.Printf("processed order %s (partition=%d, offset=%d)\n",
            order.ID, msg.Partition, msg.Offset)
    }
}

func processOrder(ctx context.Context, order Order) error {
    // бизнес-логика
    fmt.Printf("processing order: %+v\n", order)
    return nil
}
```

### Обработка заказов: Retry Topic и DLQ

Стандартная схема для resilient обработки:

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
    // Читаем текущий attempt count из заголовка
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

**Retry consumer** — отдельный сервис, который читает retry topic'и и ждёт нужное время перед обработкой. Простой способ: проверить заголовок `failed-at`, если время не наступило — sleep до нужного момента, затем переобработать.

---

## 3. NATS и NATS JetStream

### NATS Core

NATS — это lightweight, high-performance messaging system. В базовом режиме (Core NATS) — fire-and-forget pub/sub без персистентности.

```
Publisher ──publish("orders.created")──► NATS Server ──► Subscriber 1
                                                     ──► Subscriber 2
                                                     ──► Subscriber 3

Если Subscriber offline в момент публикации — сообщение потеряно.
```

**Паттерны Core NATS:**
- **Pub/Sub**: publisher не знает о subscribers, 1:N.
- **Request/Reply**: встроенный механизм. Publisher ждёт ответа от одного из subscribers.
- **Queue Groups**: несколько subscribers в одной queue group — сообщение доставляется только одному (load balancing без consumer groups).

### NATS JetStream

JetStream добавляет персистентность, at-least-once delivery и consumer semantics.

```
Publisher ──publish──► JetStream Stream ──► Consumer (push/pull)
                       (persistent log)
                       
Stream = хранилище сообщений для одного или нескольких subjects
Consumer = подписка на stream с состоянием (последний processed message)
```

**Ключевые отличия от Core NATS:**

| | Core NATS | JetStream |
|---|---|---|
| Персистентность | Нет (memory only) | Да (disk/memory) |
| Delivery guarantee | At-most-once | At-least-once |
| Consumer state | Нет | Есть (durable consumers) |
| Replay | Нет | Да (с любого offset) |
| Retention | Нет | Time/size/limit-based |

### Когда NATS вместо Kafka

| Критерий | NATS/JetStream | Kafka |
|---|---|---|
| Операционная сложность | Низкая (один бинарник, встроенный clustering) | Высокая (ZooKeeper/KRaft, множество настроек) |
| Throughput | До ~10M msg/s | До ~100M msg/s |
| Retention | Ограниченная | Практически неограниченная |
| Ordering | Per-consumer, не partition-based | Per-partition (строже) |
| Ecosystem | Меньший | Огромный (Connect, Streams, ksqlDB) |
| **Вывод** | Microservices с умеренной нагрузкой | High-throughput data pipelines, event sourcing |

**Выбирай NATS JetStream, если:**
- Команда небольшая, Kafka операционно избыточен
- Latency важнее throughput (NATS latency < 1ms vs Kafka ~5ms)
- Нужен request/reply паттерн
- Нагрузка: сотни тысяч, не десятки миллионов сообщений в секунду

### Пример на Go: NATS JetStream pub/sub

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

    // Создаём stream (идемпотентно)
    stream, err := js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
        Name:      "ORDERS",
        Subjects:  []string{"orders.>"},  // wildcard: orders.created, orders.paid, etc.
        Retention: jetstream.LimitsPolicy,
        MaxAge:    7 * 24 * time.Hour,
        Storage:   jetstream.FileStorage,
        Replicas:  1, // в продакшене: 3
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
        MaxDeliver:    3,                            // максимум 3 попытки доставки
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

        // Успешно обработали → ack
        msg.Ack()
    }
}
```

---

## 4. RabbitMQ

### Модель: Exchange → Queue → Consumer

RabbitMQ — это AMQP broker с моделью "smart broker / dumb consumer". Вся логика маршрутизации в брокере.

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

### Типы Exchange

| Тип | Routing логика | Пример использования |
|---|---|---|
| **Direct** | routing_key точно совпадает с binding key | Направить сообщение в конкретный сервис |
| **Fanout** | Рассылает во все привязанные очереди, routing_key игнорируется | Broadcast: уведомление всем подписчикам |
| **Topic** | routing_key совпадает по паттерну (`*` — одно слово, `#` — ноль или больше) | `order.created`, `order.*.paid`, `#.error` |
| **Headers** | Routing по заголовкам сообщения (AMQP headers), не по routing_key | Сложные условия маршрутизации |

**Topic exchange примеры:**
```
routing_key: "order.europe.paid"
Паттерны:
  "order.#"        → match (order + любое количество слов)
  "order.*.paid"   → match (* = одно слово "europe")
  "order.europe.*" → match
  "#.paid"         → match
  "order.asia.*"   → no match
```

### Acknowledgments

**Auto-ack (`no-ack=true`):**  
Брокер считает сообщение доставленным сразу при отправке. Если consumer упал до обработки — сообщение потеряно. Используется только для некритичных данных с максимальным throughput.

**Manual ack:**  
Consumer явно подтверждает обработку:
- `basicAck(deliveryTag)` — успешно обработано, удалить из очереди
- `basicNack(deliveryTag, requeue=true)` — ошибка, вернуть в очередь
- `basicNack(deliveryTag, requeue=false)` — ошибка, не возвращать (→ DLX если настроен)
- `basicReject(deliveryTag, requeue=false)` — отклонить (аналог Nack для одного сообщения)

**Prefetch count:**  
Количество неподтверждённых сообщений, которые брокер может отправить consumer'у. `prefetch=1` — обрабатываем строго по одному (медленно, надёжно). `prefetch=100` — батч обработка (быстро, но при падении теряем до 100 сообщений в flight).

### Dead Letter Exchange (DLX)

```
Queue: "orders"
  DLX: "orders.dlx"
  DLQ: "orders.dead-letter"
  
Сообщение попадает в DLX если:
  - basicNack/basicReject с requeue=false
  - TTL сообщения истёк
  - Очередь переполнена (x-max-length)
```

```go
// Создание очереди с DLX
args := amqp.Table{
    "x-dead-letter-exchange":    "orders.dlx",
    "x-dead-letter-routing-key": "dead",
    "x-message-ttl":             int32(30000), // 30 секунд TTL
}
q, err := ch.QueueDeclare("orders", true, false, false, false, args)
```

### RabbitMQ vs Kafka: принципиальная разница

```
RabbitMQ: "Smart Broker / Dumb Consumer"
──────────────────────────────────────
Producer → Exchange → Queue → Consumer
                ▲
         вся логика здесь:
         routing, filtering,
         transformations,
         TTL, DLX, priority

Broker знает о consumer'ах и pushes им сообщения.
После delivery → сообщение удаляется.


Kafka: "Dumb Broker / Smart Consumer"
──────────────────────────────────────
Producer → Partition Log → Consumer
                           ▲
                    вся логика здесь:
                    какой offset читать,
                    как интерпретировать,
                    reprocessing, backfill

Broker — просто хранит log. Consumer сам управляет offset.
Сообщения не удаляются при чтении.
```

| | RabbitMQ | Kafka |
|---|---|---|
| Модель | Push (broker pushes to consumer) | Pull (consumer fetches) |
| Хранение | Удаляет после delivery | Retention-based (дни/недели) |
| Повторное чтение | Невозможно (deleted) | Возможно (сбросить offset) |
| Routing | Богатый (exchanges, bindings) | Только по partition key |
| Priority queues | Да | Нет |
| Throughput | ~100K msg/s | ~1M+ msg/s |
| Ordering | Per-queue | Per-partition |

### Когда RabbitMQ

- Сложная маршрутизация: разные типы событий должны идти в разные сервисы по условиям
- Priority queues: VIP клиенты обрабатываются быстрее
- Task queues: долгие задачи с worker pool
- Legacy: существующая инфраструктура на AMQP
- Не нужен replay: сообщения не нужно перечитывать после обработки
- Малый throughput: десятки/сотни тысяч сообщений в секунду, не миллионы

---

## 5. Паттерны работы с очередями

### Competing Consumers

Несколько consumer'ов читают из одной очереди. Каждое сообщение обрабатывается ровно одним.

```
Queue: [msg1][msg2][msg3][msg4][msg5]
         │       │       │
    Worker 1  Worker 2  Worker 3
   (обрабатывает (обрабатывает (обрабатывает
    msg1, msg4)   msg2, msg5)   msg3)
```

Используется для: горизонтальное масштабирование обработки.  
В Kafka: один consumer group = competing consumers. Максимальный параллелизм = количество партиций.

### Fan-out

Одно сообщение доставляется нескольким независимым consumer'ам.

```
Event: order.created
         │
         ├──► Email Service (отправить подтверждение)
         ├──► Analytics Service (обновить метрики)
         ├──► Inventory Service (зарезервировать товары)
         └──► Notification Service (push уведомление)
```

В Kafka: несколько consumer groups читают один topic независимо.  
В RabbitMQ: fanout exchange + отдельная очередь для каждого сервиса.

### Dead Letter Queue (DLQ)

```
orders ──► [Processor] ──success──► done
                │
                └──failure (все retries исчерпаны)──► orders.dlq

DLQ содержит:
  - оригинальное сообщение
  - заголовки: количество попыток, последняя ошибка, время ошибки
  - метаданные: partition, offset, consumer

Операционный процесс:
  1. Alert при появлении сообщений в DLQ
  2. Инженер анализирует причину
  3. Исправляет код или данные
  4. Реплеит сообщения из DLQ в основной topic
```

### Retry с Exponential Backoff

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

**Реализация через отдельные retry topics (Kafka):**

```
orders ──► [Processor]
              │
              └──error──► orders.retry (delay header: 30s)
                              │
                         [Retry Scheduler]
                              │ (ждёт 30s)
                              └──► orders (переопубликовать)
```

**Реализация через задержанную очередь (RabbitMQ):**

```go
// Создаём очередь с TTL и DLX, который направляет обратно в работу
retryQueue := amqp.Table{
    "x-message-ttl":             int32(30000), // 30s delay
    "x-dead-letter-exchange":    "orders",     // после TTL → вернуть в работу
    "x-dead-letter-routing-key": "process",
}
```

### Idempotent Consumer

Защита от повторной обработки дублирующихся сообщений.

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

**Пример на Go с Redis:**

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

// Process возвращает nil если сообщение уже обработано (idempotent skip)
func (p *IdempotentProcessor) Process(ctx context.Context, msg Message, fn func(context.Context, Message) error) error {
    key := "processed:" + msg.ID

    // SET NX (set if not exists) — атомарная операция
    set, err := p.redis.SetNX(ctx, key, "1", p.ttl).Result()
    if err != nil {
        return fmt.Errorf("redis setnx: %w", err)
    }

    if !set {
        // Ключ уже существует — сообщение уже обработано
        log.Printf("skipping duplicate message: %s", msg.ID)
        return nil
    }

    // Обрабатываем
    if err := fn(ctx, msg); err != nil {
        // Откатываем ключ чтобы можно было retry
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
            // Ваша бизнес-логика здесь
            fmt.Printf("processing message: %s\n", m.ID)
            return nil
        })

        if err != nil && !errors.Is(err, context.Canceled) {
            log.Printf("processing error: %v", err)
            continue // не коммитим → retry
        }

        reader.CommitMessages(ctx, kafkaMsg)
    }
}
```

**Важно:** `SET NX` + `DEL` при ошибке содержит race condition при параллельных consumer'ах. В продакшене используйте Lua script или database-level уникальный индекс для строгой гарантии.

### Poison Pill

Poison pill — сообщение, которое consumer не может обработать и постоянно падает на нём.

```
Queue: [msg1][msg2][POISON][msg4][msg5]
                     │
              consumer crashes
              broker redelivers
              consumer crashes again
              ...
              все остальные сообщения заблокированы
```

**Обнаружение:**
- Kafka: отслеживать количество redeliveries через заголовок `attempt-count`
- RabbitMQ: поле `x-death` в заголовках сообщения содержит историю reject'ов

**Обработка:**

```go
func handleMessage(ctx context.Context, msg kafka.Message) error {
    attemptCount := getAttemptCount(msg.Headers) // читаем из заголовка

    if attemptCount >= MaxAttempts {
        // Poison pill detected — отправляем в DLQ без retry
        log.Printf("poison pill detected for key=%s, sending to DLQ", string(msg.Key))
        return sendToDLQ(ctx, msg, fmt.Errorf("exceeded max attempts: %d", MaxAttempts))
    }

    if err := process(ctx, msg); err != nil {
        return sendToRetryTopic(ctx, msg, err, attemptCount+1)
    }

    return nil
}
```

### Ordered Processing при параллельной обработке

Задача: обработать события одного заказа строго по порядку, при этом разные заказы обрабатывать параллельно.

```
Events:
order-1: [created] [paid] [shipped]  → строго по порядку
order-2: [created] [paid]            → строго по порядку
order-3: [created]                   → строго по порядку

Но order-1, order-2, order-3 можно обрабатывать параллельно.
```

**Решение 1: Kafka partition key = entity ID**  
Все события order-1 идут в одну партицию → один consumer в group их обрабатывает последовательно.

**Решение 2: Virtual partitions в памяти**

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
                processMessage(msg) // строго последовательно для каждого worker
            }
        }(p.channels[i])
    }
    return p
}

func (p *OrderedProcessor) Submit(msg Message) {
    // Детерминированное назначение: все сообщения одного order_id → один worker
    workerIdx := hash(msg.OrderID) % p.workers
    p.channels[workerIdx] <- msg
}
```

---

## 6. Event-Driven Architecture

### Events vs Commands vs Queries

| | **Event** | **Command** | **Query** |
|---|---|---|---|
| Определение | Что-то случилось (факт) | Просьба что-то сделать | Запрос данных |
| Форма | `OrderCreated`, `PaymentProcessed` | `CreateOrder`, `ProcessPayment` | `GetOrder`, `ListOrders` |
| Отправитель | Не знает кто обработает | Знает получателя | Знает получателя |
| Ответ | Нет (fire-and-forget) | Может быть | Обязателен |
| Направление | 1:N (может быть несколько handlers) | 1:1 | 1:1 |
| Семантика | "Это произошло" | "Сделай это" | "Дай мне это" |

### Паттерны событий

#### Event Notification
Минимальное событие — только факт, без данных. Получатель сам запрашивает детали.

```json
{
  "type": "order.created",
  "order_id": "123",
  "timestamp": "2026-03-23T09:00:00Z"
}
```

Плюс: маленький payload, decoupling.  
Минус: получатель делает дополнительный API вызов за данными (latency, coupling с API).

#### Event-Carried State Transfer
Событие содержит все необходимые данные. Получатель не делает дополнительных запросов.

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

Плюс: получатель автономен, нет дополнительных запросов.  
Минус: большой payload, данные могут устареть.

#### Event Sourcing
Состояние системы = последовательность событий. Вместо хранения текущего состояния хранится лог изменений.

```
Events:
  OrderCreated   → {id: 123, status: "created"}
  PaymentMade    → {id: 123, amount: 99.99}
  OrderShipped   → {id: 123, tracking: "TRK456"}

Current state = apply(all events) = {
  id: 123, status: "shipped", amount: 99.99, tracking: "TRK456"
}
```

Плюсы: полная история, replay, temporal queries ("каким был заказ вчера в 15:00").  
Минусы: сложность, eventual consistency, схема эволюции событий.

### Choreography vs Orchestration

```
Choreography (танец без режиссёра):
─────────────────────────────────
Order Service → event: order.created
                    │
    ┌───────────────┼───────────────┐
    ▼               ▼               ▼
Payment Service  Inventory       Notification
  │               Service           Service
  └─► event: payment.processed
              │
        Inventory Service слушает и резервирует

Каждый сервис реагирует на события других.
Нет центрального координатора.
Плюс: loose coupling. Минус: сложно отследить бизнес-процесс целиком.


Orchestration (дирижёр):
──────────────────────────
Order Saga Orchestrator
  │── command: process_payment → Payment Service
  │                              │── reply: payment_ok
  │── command: reserve_items   → Inventory Service
  │                              │── reply: items_reserved
  └── command: send_notification → Notification Service

Один сервис координирует весь процесс.
Плюс: бизнес-процесс виден в одном месте. Минус: orchestrator — SPOF, coupling.
```

**Когда что:**
- **Choreography**: простые, независимые реакции на события. Малое количество участников.
- **Orchestration**: сложные многошаговые процессы с компенсациями (saga pattern). Нужен явный контроль состояния.

### Schema Evolution

Проблема: producer обновил схему события, старые consumer'ы сломались.

#### Avro + Schema Registry

```
Producer ──serialize(Avro)──► Schema Registry ──schema ID──► Kafka Message
Consumer ──deserialize──► Schema Registry (fetch schema by ID) ──► object
```

Правила совместимости (Confluent Schema Registry):
- **BACKWARD**: новая схема может читать старые данные (новые поля — optional с default)
- **FORWARD**: старая схема может читать новые данные
- **FULL**: и BACKWARD, и FORWARD одновременно

#### Protobuf

Нумерованные поля — основа совместимости. Никогда не удаляй номера полей, только помечай `reserved`.

```protobuf
message OrderCreated {
  string order_id = 1;
  string user_id = 2;
  double amount = 3;
  // Новое поле — backward compatible (клиенты без этого поля просто игнорируют)
  string coupon_code = 4;
  // Удалённое поле:
  // reserved 5; reserved "old_field"; // не переиспользуем номер
}
```

#### Рекомендации для schema evolution

1. Всегда делай новые поля optional с разумным default
2. Никогда не меняй тип поля
3. Никогда не переименовывай поля в JSON (только добавляй новые)
4. Версионируй topic name при breaking changes: `orders.v1`, `orders.v2`
5. Используй Schema Registry в проде — автоматическая проверка совместимости

### Пример: Order Created Fan-out

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

Все три consumer group читают один topic независимо.
Каждая group получает все сообщения.
Добавить новый consumer group = нулевые изменения в Order Service.
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
        GroupID: "email-service", // уникальный group ID → получаем все сообщения
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
    // интеграция с email провайдером
    fmt.Printf("sending email to: %s\n", event.Email)
    return nil
}
```

---

## 7. Выбор Message Broker

### Сравнительная таблица

| Критерий | **Kafka** | **RabbitMQ** | **NATS JetStream** | **AWS SQS/SNS** | **Google Pub/Sub** |
|---|---|---|---|---|---|
| **Throughput** | Очень высокий (1M+ msg/s) | Высокий (~100K msg/s) | Высокий (~10M msg/s) | Высокий (managed) | Очень высокий (managed) |
| **Latency** | ~5-15ms | ~1-5ms | <1ms | ~10-100ms | ~10-100ms |
| **Ordering** | Per-partition | Per-queue | Per-consumer | Per-FIFO queue (SQS FIFO) | Per-key ordering |
| **Delivery** | At-least-once, Exactly-once | At-least-once, At-most-once | At-least-once | At-least-once | At-least-once |
| **Retention** | Дни/недели/навсегда | До ACK | Configurable | 4 дня (max 14) | 7 дней |
| **Replay** | Да (reset offset) | Нет | Да | Нет | Ограниченно |
| **Routing** | Только partition key | Богатый (exchanges) | Subject wildcards | Атрибуты фильтрации | Фильтрация атрибутов |
| **Операц. сложность** | Высокая | Средняя | Низкая | Нет (managed) | Нет (managed) |
| **Стоимость** | Инфраструктура | Инфраструктура | Инфраструктура | Pay-per-use | Pay-per-use |
| **Ecosystem** | Огромный | Большой | Растущий | AWS | GCP |
| **Priority queues** | Нет | Да | Нет | Нет | Нет |
| **CDC** | Да (Debezium) | Нет | Нет | Нет | Нет |
| **Stream processing** | Kafka Streams, ksqlDB | Нет | Нет | Нет | Dataflow |
| **Max сообщение** | 1MB (configurable) | 2GB | 1MB (configurable) | 256KB (SQS) | 10MB |

### Дополнительные характеристики

**Kafka**  
- Kafka Connect: сотни готовых коннекторов (Debezium, S3, JDBC, Elasticsearch)
- Kafka Streams: stateful stream processing встроен
- Confluent Platform: enterprise-версия с Schema Registry, KSQL, Control Center
- MSK (AWS): managed Kafka от Amazon
- Confluent Cloud: fully managed Kafka-as-a-service

**AWS SQS/SNS**  
- SQS: простая очередь, SNS: pub/sub fanout
- SQS FIFO: ordering + exactly-once (до 300 msg/s или 3000 с batching)
- Dead-letter queue встроен
- Нет replay — после обработки сообщение удаляется

**Google Cloud Pub/Sub**  
- Автоматическое масштабирование
- Seek: перемотка к timestamp или snapshot (limited replay)
- BigQuery, Dataflow интеграция из коробки

### Decision Tree

```
Нужен replay / event sourcing?
├── Да → Kafka или NATS JetStream
│         │
│         ├── Нужен богатый ecosystem (Connect, Streams)?
│         │   └── Да → Kafka
│         │
│         └── Приоритет: операционная простота / latency?
│             └── Да → NATS JetStream
│
└── Нет
     │
     ├── Используешь AWS?
     │   └── Да → SQS/SNS (если managed подходит)
     │
     ├── Используешь GCP?
     │   └── Да → Google Pub/Sub
     │
     ├── Нужна сложная маршрутизация / priority queues?
     │   └── Да → RabbitMQ
     │
     ├── Нужен максимальный throughput (>1M msg/s)?
     │   └── Да → Kafka
     │
     ├── Команда небольшая, нужна простота операций?
     │   └── Да → NATS JetStream или RabbitMQ
     │
     └── Нужна строгая ordering гарантия глобально?
         └── Да → Kafka (один partition) или SQS FIFO
```

### Сценарии и рекомендации

| Сценарий | Рекомендация | Обоснование |
|---|---|---|
| Data pipeline, analytics, event streaming | **Kafka** | Retention, replay, высокий throughput, Kafka Connect |
| Microservices task queue | **RabbitMQ** или **NATS JetStream** | Простота, rich routing, меньше операций |
| Real-time notifications | **NATS Core** или **Kafka** | Низкая latency для NATS, масштаб для Kafka |
| CDC (database to downstream) | **Kafka + Debezium** | Единственный mature CDC ecosystem |
| Serverless / cloud-native AWS | **SQS + SNS** | Zero ops, pay-per-use, нативная интеграция Lambda |
| ML pipeline, batch processing | **Kafka** или **GCP Pub/Sub** | Retention для reprocessing, интеграция с ML инфра |
| IoT с миллионами устройств | **Kafka** или **NATS** | Высокий throughput, NATS — меньше overhead |
| Финансовые транзакции | **Kafka (EOS)** | Exactly-once семантика |
| Game events, leaderboard | **NATS** или **Redis Streams** | Sub-millisecond latency |

---

## Итоги модуля

**Ключевые принципы:**

1. **Выбирай async осознанно.** Async решает temporal coupling и buffering, но добавляет eventual consistency и операционную сложность. Не async всё подряд.

2. **Kafka — не очередь, это log.** Retention, replay, consumer groups с независимыми offsets — это другая парадигма, чем RabbitMQ.

3. **Partition key — критическое решение.** Плохой ключ → hot partition → узкое горлышко. Partition key определяет и ordering, и распределение нагрузки.

4. **Consumer lag — главная метрика.** Если lag растёт — нужно добавить consumer'ов или оптимизировать обработку.

5. **Idempotent consumer — не опция, а требование.** При at-least-once delivery дубликаты неизбежны. Consumer обязан их обрабатывать корректно.

6. **DLQ — обязательная часть архитектуры.** Без DLQ poison pill заблокирует всю обработку. DLQ + alerting + replay — полный цикл.

7. **Schema evolution — думай заранее.** Сломать consumer неожиданным изменением схемы — распространённая ошибка. Schema Registry или Protobuf + дисциплина.

**Что читать дальше:**

- [Kafka: The Definitive Guide](https://www.confluent.io/resources/kafka-the-definitive-guide/) — Neha Narkhede, Gwen Shapira, Todd Palino
- [Designing Event-Driven Systems](https://www.confluent.io/designing-event-driven-systems/) — Ben Stopford
- [Enterprise Integration Patterns](https://www.enterpriseintegrationpatterns.com/) — Hohpe & Woolf (классика паттернов интеграции)
- [NATS Documentation](https://docs.nats.io/) — официальная документация, особенно JetStream
- [Confluent Documentation](https://docs.confluent.io/) — Kafka deep-dive

---

*Модуль 06 из 12 | [← Модуль 05: Кэширование](../05-caching/readme.md) | [Модуль 07: Базы данных →](../07-databases-sharding/readme.md)*
