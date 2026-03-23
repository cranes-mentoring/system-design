# Модуль 07: Паттерны распределённых систем

> **Для кого**: бэкенд-разработчики, которые уже работали с микросервисами и понимают, почему «просто сделай транзакцию» перестаёт работать.
>
> **Что внутри**: distributed transactions, Saga, Outbox, CQRS, Event Sourcing, Consensus, Idempotency, Bulkhead/Backpressure.

---

## Содержание

1. [Распределённые транзакции: проблема](#1-распределённые-транзакции-проблема)
2. [Saga Pattern](#2-saga-pattern)
3. [Transactional Outbox Pattern](#3-transactional-outbox-pattern)
4. [CQRS](#4-cqrs-command-query-responsibility-segregation)
5. [Event Sourcing](#5-event-sourcing)
6. [Distributed Consensus](#6-distributed-consensus)
7. [Idempotency и дедупликация](#7-idempotency-и-дедупликация)
8. [Bulkhead, Backpressure и паттерны устойчивости](#8-bulkhead-backpressure-и-другие-паттерны-устойчивости)

---

## 1. Распределённые транзакции: проблема

### Почему ACID не работает через сервисы

В монолите с одной СУБД транзакция — это атомарная операция на одном database engine. BEGIN / COMMIT / ROLLBACK — всё в рамках одного соединения.

В микросервисах данные живут в разных базах:

```
OrderService     →  orders_db      (PostgreSQL)
PaymentService   →  payments_db    (PostgreSQL)
InventoryService →  inventory_db   (MySQL)
ShippingService  →  shipping_db    (PostgreSQL)
```

Вызов через REST/gRPC не участвует в транзакции базы данных. Нельзя открыть BEGIN через HTTP. Нельзя сделать ROLLBACK, если удалённый сервис уже закоммитил.

**Типичная ломаная сценарий:**

```
1. OrderService создаёт заказ          ✓ OK
2. PaymentService списывает деньги     ✓ OK
3. InventoryService резервирует товар  ✗ FAIL (нет на складе)

→ Деньги списаны, заказ создан, но товара нет.
   Как откатить PaymentService?
```

Это не теоретическая проблема — это ежедневная реальность production-систем.

---

### Two-Phase Commit (2PC)

2PC — классический протокол для распределённых транзакций. Добавляет специальный **координатор** между участниками.

**Фазы:**

```
Coordinator                 Participant A    Participant B
    │                            │                │
    │──── PREPARE ──────────────>│                │
    │──── PREPARE ───────────────────────────────>│
    │                            │                │
    │<─── VOTE: YES ─────────────│                │
    │<─── VOTE: YES ──────────────────────────────│
    │                            │                │
    │ (все YES → COMMIT)         │                │
    │                            │                │
    │──── COMMIT ───────────────>│                │
    │──── COMMIT ────────────────────────────────>│
    │                            │                │
    │<─── ACK ───────────────────│                │
    │<─── ACK ────────────────────────────────────│
```

**Фаза Prepare**: каждый участник блокирует ресурсы и записывает в WAL готовность закоммитить, но не коммитит.

**Фаза Commit**: координатор отправляет COMMIT (или ABORT если хоть один ответил NO).

**Почему 2PC тормозит и блокирует:**

- Между PREPARE и COMMIT все участники держат **блокировки**. Чем длиннее транзакция, тем дольше блокировки.
- **Blocking problem**: если координатор упадёт после PREPARE, участники **не могут** ни закоммитить, ни откатить — они ждут решения координатора вечно (или до восстановления).
- Два сетевых round-trip минимум.
- Координатор — единая точка отказа.

**Когда 2PC допустимо:**

| Сценарий | Допустимо? |
|---|---|
| Два сервиса в одном дата-центре, latency < 1ms | Да, с оговорками |
| Базы данных поддерживают XA-транзакции (PostgreSQL, MySQL) | Да, но осторожно |
| Распределённые сервисы через интернет | Нет |
| Высокая нагрузка, требования к latency < 10ms | Нет |
| Длинные бизнес-транзакции (секунды, минуты) | Категорически нет |

XA — стандарт для 2PC поверх разных СУБД. PostgreSQL и MySQL его поддерживают, но в production это редкость из-за проблем с блокировками.

---

### Three-Phase Commit (3PC)

3PC добавляет промежуточную фазу **PRE-COMMIT**, чтобы решить blocking problem 2PC:

```
PREPARE → PRE-COMMIT → COMMIT
```

Если координатор упал после PRE-COMMIT, участники могут сами договориться о коммите (все видели PRE-COMMIT → знают, что все проголосовали YES).

**Почему на практике не используют:**

- Не устойчив к network partitions. При split-brain можно получить divergent state.
- CAP theorem: в присутствии сетевых разделений нельзя одновременно гарантировать consistency и availability.
- Сложность реализации значительно выше 2PC.
- Добавляет третий round-trip.

Реальные системы идут в сторону **Saga Pattern** и **eventual consistency** вместо попыток сделать настоящий distributed atomic commit.

---

## 2. Saga Pattern

Saga — последовательность **локальных транзакций**, каждая из которых публикует событие или вызывает следующий шаг. Если один шаг падает, выполняются **компенсирующие транзакции** для предыдущих шагов.

**Ключевая идея:** вместо одной распределённой транзакции — цепочка маленьких локальных транзакций с явным rollback через компенсации.

```
T1 → T2 → T3 → ... → Tn   (happy path)
         ↑ fail here
C2 ← C1                    (compensating transactions)
```

Существует два способа координации: **Orchestration** и **Choreography**.

---

### Orchestration

Центральный **оркестратор** явно вызывает каждый сервис и знает весь flow. Сервисы не знают друг о друге.

```
                    ┌─────────────────┐
                    │   Orchestrator  │
                    │  (OrderSaga)    │
                    └────────┬────────┘
                             │
          ┌──────────────────┼──────────────────┐
          │                  │                  │
          ▼                  ▼                  ▼
   ┌─────────────┐  ┌────────────────┐  ┌──────────────────┐
   │PaymentSvc   │  │InventorySvc    │  │ShippingSvc       │
   │             │  │                │  │                  │
   │reserve()    │  │reserve()       │  │schedule()        │
   │release()    │  │release()       │  │cancel()          │
   └─────────────┘  └────────────────┘  └──────────────────┘
```

**Сценарий успеха:**

```
Orchestrator                PaymentSvc     InventorySvc    ShippingSvc
     │                          │               │               │
     │──── reservePayment() ───>│               │               │
     │<─── OK ─────────────────│               │               │
     │                          │               │               │
     │──── reserveInventory() ──────────────── >│               │
     │<─── OK ──────────────────────────────────│               │
     │                          │               │               │
     │──── scheduleShipping() ───────────────────────────────── >│
     │<─── OK ────────────────────────────────────────────────── │
     │                          │               │               │
     │──── confirmPayment() ───>│               │               │
     │──── confirmInventory() ──────────────── >│               │
```

**Сценарий отказа (InventorySvc упал):**

```
Orchestrator                PaymentSvc     InventorySvc
     │                          │               │
     │──── reservePayment() ───>│               │
     │<─── OK ─────────────────│               │
     │                          │               │
     │──── reserveInventory() ──────────────── >│
     │<─── FAIL: out of stock ──────────────────│
     │                          │               │
     │ [начать компенсацию]     │               │
     │                          │               │
     │──── cancelPayment() ────>│               │
     │<─── OK ─────────────────│               │
     │                          │               │
     │ [saga failed, rollback complete]
```

---

### Choreography

Сервисы **реагируют на события** без центрального координатора. Каждый сервис знает, что делать при получении конкретного события.

```
OrderSvc          PaymentSvc        InventorySvc      ShippingSvc
   │                  │                  │                 │
   │ OrderCreated     │                  │                 │
   │─────────────────>│                  │                 │
   │                  │ PaymentReserved  │                 │
   │                  │────────────────>│                 │
   │                  │                  │ InventoryReserv │
   │                  │                  │──────────────── >│
   │                  │                  │                 │
   │                  │                  │    ShippingSchd │
   │                  │                  │                 │ → event bus
```

**Сценарий отказа в choreography:**

```
OrderSvc          PaymentSvc        InventorySvc
   │                  │                  │
   │ OrderCreated     │                  │
   │─────────────────>│                  │
   │                  │ PaymentReserved  │
   │                  │────────────────>│
   │                  │                  │
   │                  │  InventoryFailed │
   │                  │<────────────────│
   │                  │                  │
   │  PaymentCancelled│                  │
   │<─────────────────│                  │
   │                  │                  │
   │ [OrderSvc обновляет статус на FAILED]
```

---

### Компенсирующие транзакции: как проектировать rollback

Компенсирующая транзакция — это **бизнес-операция**, которая отменяет эффект оригинальной транзакции. Это не database rollback.

**Принципы проектирования компенсаций:**

1. **Каждая транзакция должна иметь компенсацию.** Проектируй их одновременно.
2. **Компенсация должна быть идемпотентной.** Она может вызываться несколько раз.
3. **Некоторые операции некомпенсируемы.** Отправленное письмо нельзя "неотправить". Используй pivot transaction (точку невозврата) осознанно.
4. **Порядок компенсаций — обратный** порядку основных транзакций.

```
Операция          Компенсация
─────────────     ──────────────────────────
createOrder()  →  markOrderFailed()
reservePay()   →  releasePayment()
reserveInv()   →  releaseInventory()
scheduleShip() →  cancelShipping()
sendEmail()    →  (нет — pivot transaction)
```

---

### Плюсы и минусы

| | Orchestration | Choreography |
|---|---|---|
| **Понимаемость** | Весь flow в одном месте | Размазан по сервисам |
| **Coupling** | Оркестратор знает всех | Сервисы связаны только через events |
| **Single point of failure** | Да (оркестратор) | Нет |
| **Debugging** | Легче — trace в одном месте | Сложнее — надо собирать trace |
| **Масштабируемость** | Оркестратор может стать узким местом | Каждый сервис масштабируется независимо |
| **Добавление шага** | Меняешь только оркестратор | Нужно менять несколько сервисов |
| **Циклические зависимости** | Редки | Риск event loops |

**Выбирай orchestration**, когда:
- Сложный flow с множеством условий
- Нужен чёткий audit trail
- Команда небольшая

**Выбирай choreography**, когда:
- Простой линейный flow
- Важна независимость сервисов
- Готов инвестировать в distributed tracing

---

### Пример на Go: Orchestrator для заказа

```go
package saga

import (
	"context"
	"errors"
	"fmt"
	"log"
)

// Шаги саги и их компенсации
type Step struct {
	Name       string
	Execute    func(ctx context.Context, order *Order) error
	Compensate func(ctx context.Context, order *Order) error
}

// Order — агрегат, который передаётся через шаги
type Order struct {
	ID          string
	UserID      string
	Amount      float64
	Items       []OrderItem
	PaymentID   string  // заполняется PaymentService
	ShippingID  string  // заполняется ShippingService
}

type OrderItem struct {
	ProductID string
	Quantity  int
}

// Orchestrator выполняет шаги по порядку и откатывает при ошибке
type Orchestrator struct {
	steps []Step
}

func NewOrderOrchestrator(
	paymentSvc PaymentService,
	inventorySvc InventoryService,
	shippingSvc ShippingService,
) *Orchestrator {
	return &Orchestrator{
		steps: []Step{
			{
				Name: "ReservePayment",
				Execute: func(ctx context.Context, order *Order) error {
					paymentID, err := paymentSvc.Reserve(ctx, order.UserID, order.Amount)
					if err != nil {
						return fmt.Errorf("payment reserve: %w", err)
					}
					order.PaymentID = paymentID
					return nil
				},
				Compensate: func(ctx context.Context, order *Order) error {
					if order.PaymentID == "" {
						return nil // не было зарезервировано
					}
					return paymentSvc.Release(ctx, order.PaymentID)
				},
			},
			{
				Name: "ReserveInventory",
				Execute: func(ctx context.Context, order *Order) error {
					return inventorySvc.Reserve(ctx, order.ID, order.Items)
				},
				Compensate: func(ctx context.Context, order *Order) error {
					return inventorySvc.Release(ctx, order.ID)
				},
			},
			{
				Name: "ScheduleShipping",
				Execute: func(ctx context.Context, order *Order) error {
					shippingID, err := shippingSvc.Schedule(ctx, order.ID, order.UserID)
					if err != nil {
						return fmt.Errorf("shipping schedule: %w", err)
					}
					order.ShippingID = shippingID
					return nil
				},
				Compensate: func(ctx context.Context, order *Order) error {
					if order.ShippingID == "" {
						return nil
					}
					return shippingSvc.Cancel(ctx, order.ShippingID)
				},
			},
			{
				Name: "ConfirmPayment",
				Execute: func(ctx context.Context, order *Order) error {
					return paymentSvc.Confirm(ctx, order.PaymentID)
				},
				Compensate: func(ctx context.Context, order *Order) error {
					// ConfirmPayment — pivot transaction.
					// После подтверждения платежа компенсация уже другая
					// (возврат через refund, а не release).
					return paymentSvc.Refund(ctx, order.PaymentID)
				},
			},
		},
	}
}

// Execute выполняет сагу. При ошибке запускает компенсации в обратном порядке.
func (o *Orchestrator) Execute(ctx context.Context, order *Order) error {
	completed := make([]int, 0, len(o.steps))

	for i, step := range o.steps {
		log.Printf("saga step [%d/%d]: %s", i+1, len(o.steps), step.Name)

		if err := step.Execute(ctx, order); err != nil {
			log.Printf("saga step %s failed: %v — starting compensation", step.Name, err)

			// Компенсируем выполненные шаги в обратном порядке
			compensationErr := o.compensate(ctx, order, completed)
			if compensationErr != nil {
				// Компенсация тоже упала — нужен manual intervention
				return fmt.Errorf("saga failed: %w; compensation error: %v", err, compensationErr)
			}

			return fmt.Errorf("saga failed at step %s: %w", step.Name, err)
		}

		completed = append(completed, i)
	}

	return nil
}

func (o *Orchestrator) compensate(ctx context.Context, order *Order, completed []int) error {
	var errs []error

	for i := len(completed) - 1; i >= 0; i-- {
		stepIdx := completed[i]
		step := o.steps[stepIdx]

		log.Printf("compensating step: %s", step.Name)

		if err := step.Compensate(ctx, order); err != nil {
			errs = append(errs, fmt.Errorf("compensate %s: %w", step.Name, err))
			// Продолжаем компенсировать остальные шаги, даже если один упал
		}
	}

	return errors.Join(errs...)
}

// Интерфейсы сервисов
type PaymentService interface {
	Reserve(ctx context.Context, userID string, amount float64) (paymentID string, err error)
	Confirm(ctx context.Context, paymentID string) error
	Release(ctx context.Context, paymentID string) error
	Refund(ctx context.Context, paymentID string) error
}

type InventoryService interface {
	Reserve(ctx context.Context, orderID string, items []OrderItem) error
	Release(ctx context.Context, orderID string) error
}

type ShippingService interface {
	Schedule(ctx context.Context, orderID, userID string) (shippingID string, err error)
	Cancel(ctx context.Context, shippingID string) error
}
```

**Использование:**

```go
func CreateOrder(ctx context.Context, req CreateOrderRequest) error {
	order := &Order{
		ID:     generateOrderID(),
		UserID: req.UserID,
		Amount: req.Amount,
		Items:  req.Items,
	}

	// Сохраняем заказ в статусе PENDING
	if err := orderRepo.Save(ctx, order); err != nil {
		return err
	}

	orchestrator := NewOrderOrchestrator(paymentSvc, inventorySvc, shippingSvc)

	if err := orchestrator.Execute(ctx, order); err != nil {
		// Компенсации уже выполнены внутри Execute
		orderRepo.UpdateStatus(ctx, order.ID, StatusFailed)
		return err
	}

	orderRepo.UpdateStatus(ctx, order.ID, StatusConfirmed)
	return nil
}
```

---

### Приёмы для Saga: Semantic Lock, Commutative Updates, Pessimistic View

**Semantic Lock** — помечать ресурс как «in progress», пока сага не завершена.

```sql
-- Вместо status = 'available' устанавливаем status = 'locked'
UPDATE inventory SET status = 'locked', saga_id = $1
WHERE product_id = $2 AND status = 'available';
```

Другие саги видят `locked` и либо ждут, либо отказывают. Снимается при завершении или компенсации.

**Commutative Updates** — операции, которые можно применять в любом порядке без потери корректности.

```
Non-commutative: SET balance = 100   (порядок важен)
Commutative:     ADD balance += 10   (порядок не важен, результат тот же)
```

Проектируй операции как commutative там, где это возможно — это упрощает saga.

**Pessimistic View** — читай **последнее незакоммиченное состояние**, а не оптимистично предполагай успех.

```
Вместо: "заказ будет подтверждён, покажем клиенту 'успех'"
Лучше:  "заказ в обработке, мы сообщим о результате"
```

Снижает вероятность аномалий dirty read / lost update в рамках саги.

---

## 3. Transactional Outbox Pattern

### Проблема Dual Write

В событийных системах после бизнес-операции нужно:
1. Сохранить данные в БД
2. Отправить событие в Kafka/RabbitMQ

Наивный код:

```go
func CreateOrder(ctx context.Context, order Order) error {
    // Шаг 1: сохранить в БД
    if err := db.Save(order); err != nil {
        return err
    }

    // Шаг 2: отправить событие
    // ЧТО ЕСЛИ KAFKA НЕДОСТУПЕН?
    // ЧТО ЕСЛИ ПРИЛОЖЕНИЕ УПАЛО МЕЖДУ ШАГАМИ?
    if err := kafka.Publish("order.created", order); err != nil {
        return err // Заказ уже сохранён, но событие не отправлено!
    }

    return nil
}
```

**Три сценария отказа:**

```
Сценарий 1: БД упала
→ Ни заказа, ни события. OK.

Сценарий 2: Kafka недоступен
→ Заказ есть, события нет. ПРОБЛЕМА.
   Другие сервисы не знают о заказе.

Сценарий 3: Приложение упало между Save и Publish
→ Заказ есть, события нет. ПРОБЛЕМА.
   Случается даже при здоровых системах.
```

---

### Решение: Outbox Table

Пишем событие **в ту же транзакцию**, что и основные данные. Отдельный процесс (relay/publisher) читает outbox и отправляет в Kafka.

```
┌─────────────────────────────────────────┐
│          Application                    │
│                                         │
│   BEGIN TRANSACTION                     │
│   INSERT INTO orders ...                │
│   INSERT INTO outbox (event) ...        │
│   COMMIT                                │
│                                         │
└──────────────────┬──────────────────────┘
                   │
                   ▼
         ┌─────────────────┐
         │   orders table  │
         │   outbox table  │ ← атомарно
         └────────┬────────┘
                  │
     ┌────────────┘
     │
     ▼
┌─────────────┐         ┌──────────────┐
│   Relay/    │ publish │    Kafka /   │
│  Publisher  │────────>│  RabbitMQ   │
│             │         │              │
└─────────────┘         └──────────────┘
```

Атомарность записи в `orders` + `outbox` гарантирует: **если заказ создан, событие будет отправлено** (eventually).

---

### Relay: Polling vs CDC

**Polling** — relay периодически опрашивает outbox:

```
SELECT * FROM outbox
WHERE published_at IS NULL
ORDER BY created_at
LIMIT 100;
```

Плюсы: просто реализовать, не нужна дополнительная инфраструктура.

Минусы: latency (зависит от интервала polling), нагрузка на БД.

**CDC (Change Data Capture)** — relay подписывается на WAL (Write-Ahead Log) PostgreSQL через Debezium или pglogical. Получает события сразу после коммита.

```
PostgreSQL WAL → Debezium → Kafka Connect → Kafka topic
```

Плюсы: near-realtime, нет нагрузки на основную таблицу.

Минусы: сложность инфраструктуры, Debezium как дополнительный компонент.

| | Polling | CDC (Debezium) |
|---|---|---|
| Latency | Секунды | Миллисекунды |
| Нагрузка на БД | Регулярные SELECT | Чтение WAL (легче) |
| Инфраструктура | Минимальная | Debezium + Kafka Connect |
| Ordering | В порядке created_at | Точный порядок из WAL |
| Внедрение | Просто | Сложнее |

---

### Структура Outbox таблицы

```sql
CREATE TABLE outbox (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregate_type  VARCHAR(100) NOT NULL,  -- 'Order', 'Payment', ...
    aggregate_id    VARCHAR(100) NOT NULL,  -- ID агрегата
    event_type      VARCHAR(100) NOT NULL,  -- 'OrderCreated', 'PaymentReserved', ...
    payload         JSONB        NOT NULL,  -- данные события
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    published_at    TIMESTAMPTZ,            -- NULL = не опубликовано
    attempts        INT          NOT NULL DEFAULT 0,
    last_error      TEXT                    -- для debugging
);

CREATE INDEX idx_outbox_unpublished
    ON outbox (created_at)
    WHERE published_at IS NULL;
```

---

### Пример SQL: вставка заказа + события в одной транзакции

```sql
BEGIN;

INSERT INTO orders (id, user_id, amount, status, created_at)
VALUES ('order-123', 'user-456', 99.99, 'pending', NOW());

INSERT INTO outbox (aggregate_type, aggregate_id, event_type, payload)
VALUES (
    'Order',
    'order-123',
    'OrderCreated',
    '{
        "order_id": "order-123",
        "user_id": "user-456",
        "amount": 99.99,
        "status": "pending",
        "occurred_at": "2026-03-23T09:42:00Z"
    }'::jsonb
);

COMMIT;
```

---

### Пример на Go: Order + Outbox в одной транзакции

```go
package outbox

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"github.com/google/uuid"
)

type Order struct {
	ID        string
	UserID    string
	Amount    float64
	Status    string
	CreatedAt time.Time
}

type OutboxEvent struct {
	AggregateType string
	AggregateID   string
	EventType     string
	Payload       interface{}
}

type OrderRepository struct {
	db *sql.DB
}

func NewOrderRepository(db *sql.DB) *OrderRepository {
	return &OrderRepository{db: db}
}

// CreateOrder атомарно создаёт заказ и кладёт событие в outbox
func (r *OrderRepository) CreateOrder(ctx context.Context, order Order) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback() // no-op если tx.Commit() уже вызван

	// 1. Сохранить заказ
	_, err = tx.ExecContext(ctx,
		`INSERT INTO orders (id, user_id, amount, status, created_at)
		 VALUES ($1, $2, $3, $4, $5)`,
		order.ID, order.UserID, order.Amount, order.Status, order.CreatedAt,
	)
	if err != nil {
		return fmt.Errorf("insert order: %w", err)
	}

	// 2. Подготовить payload события
	eventPayload := map[string]interface{}{
		"order_id":    order.ID,
		"user_id":     order.UserID,
		"amount":      order.Amount,
		"status":      order.Status,
		"occurred_at": order.CreatedAt.UTC().Format(time.RFC3339),
	}

	payloadJSON, err := json.Marshal(eventPayload)
	if err != nil {
		return fmt.Errorf("marshal event payload: %w", err)
	}

	// 3. Сохранить событие в outbox В ТОЙ ЖЕ транзакции
	_, err = tx.ExecContext(ctx,
		`INSERT INTO outbox (id, aggregate_type, aggregate_id, event_type, payload, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6)`,
		uuid.New().String(),
		"Order",
		order.ID,
		"OrderCreated",
		payloadJSON,
		time.Now().UTC(),
	)
	if err != nil {
		return fmt.Errorf("insert outbox event: %w", err)
	}

	// 4. Коммит — атомарно сохраняет и заказ, и событие
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}

	return nil
}

// OutboxRelay читает outbox и публикует события (polling-подход)
type OutboxRelay struct {
	db        *sql.DB
	publisher EventPublisher
}

type EventPublisher interface {
	Publish(ctx context.Context, topic string, key string, payload []byte) error
}

func (r *OutboxRelay) Run(ctx context.Context) {
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := r.processOutbox(ctx); err != nil {
				fmt.Printf("outbox relay error: %v\n", err)
			}
		}
	}
}

func (r *OutboxRelay) processOutbox(ctx context.Context) error {
	rows, err := r.db.QueryContext(ctx,
		`SELECT id, aggregate_type, aggregate_id, event_type, payload
		 FROM outbox
		 WHERE published_at IS NULL
		 ORDER BY created_at
		 LIMIT 100
		 FOR UPDATE SKIP LOCKED`, // SKIP LOCKED — для нескольких relay-воркеров
	)
	if err != nil {
		return fmt.Errorf("query outbox: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var (
			id, aggregateType, aggregateID, eventType string
			payload                                    []byte
		)

		if err := rows.Scan(&id, &aggregateType, &aggregateID, &eventType, &payload); err != nil {
			return err
		}

		topic := fmt.Sprintf("%s.%s", aggregateType, eventType) // "Order.OrderCreated"

		if err := r.publisher.Publish(ctx, topic, aggregateID, payload); err != nil {
			// Увеличиваем счётчик попыток, но не блокируем остальные события
			r.db.ExecContext(ctx,
				`UPDATE outbox SET attempts = attempts + 1, last_error = $1 WHERE id = $2`,
				err.Error(), id,
			)
			continue
		}

		// Помечаем как опубликованное
		r.db.ExecContext(ctx,
			`UPDATE outbox SET published_at = NOW() WHERE id = $1`,
			id,
		)
	}

	return rows.Err()
}
```

---

### Inbox Pattern: дедупликация на стороне consumer

Outbox гарантирует **at-least-once delivery** — одно и то же событие может прийти дважды. Consumer должен быть готов к дублям.

**Inbox table** — хранит ID уже обработанных событий:

```sql
CREATE TABLE inbox (
    event_id       UUID PRIMARY KEY,
    event_type     VARCHAR(100) NOT NULL,
    processed_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
```

```go
func (h *OrderHandler) HandleOrderCreated(ctx context.Context, eventID string, payload []byte) error {
	tx, _ := h.db.BeginTx(ctx, nil)
	defer tx.Rollback()

	// Проверяем, не обрабатывали ли уже это событие
	var exists bool
	tx.QueryRowContext(ctx,
		`SELECT EXISTS(SELECT 1 FROM inbox WHERE event_id = $1)`,
		eventID,
	).Scan(&exists)

	if exists {
		return nil // дубль — пропускаем
	}

	// Обрабатываем событие
	if err := h.processOrderCreated(ctx, tx, payload); err != nil {
		return err
	}

	// Записываем в inbox — атомарно с обработкой
	tx.ExecContext(ctx,
		`INSERT INTO inbox (event_id, event_type) VALUES ($1, $2)`,
		eventID, "OrderCreated",
	)

	return tx.Commit()
}
```

Inbox записи можно удалять после определённого retention периода (например, 7 дней), если повторная доставка через такой срок невозможна.

---

## 4. CQRS (Command Query Responsibility Segregation)

### Идея

**CQS** (Bertrand Meyer, 1988): метод либо выполняет команду (изменяет состояние), либо возвращает данные — но не то и другое одновременно.

**CQRS** — применение этого принципа на уровне архитектуры: отдельные модели для **записи** (Command) и **чтения** (Query).

```
Традиционный подход:
┌────────────────────────────────────┐
│  Одна модель Order для всего:      │
│  CREATE, UPDATE, DELETE, SELECT    │
└────────────────────────────────────┘

CQRS:
┌──────────────────┐    ┌──────────────────┐
│  Write Model     │    │  Read Model      │
│  (Command side)  │    │  (Query side)    │
│                  │    │                  │
│  Валидация       │    │  Денормализо-    │
│  Бизнес-правила  │    │  ванные данные   │
│  Транзакции      │    │  Оптимизировано  │
│  Нормализовано   │    │  для чтения      │
└──────────────────┘    └──────────────────┘
```

---

### Простой CQRS: одна БД, разные модели в коде

Не обязательно сразу иметь два разных хранилища. Можно начать с разделения кода:

```go
// Command-сторона: строгая модель с бизнес-правилами
type OrderAggregate struct {
	id     string
	status OrderStatus
	items  []OrderItem
	total  float64
}

func (o *OrderAggregate) AddItem(item OrderItem) error {
	if o.status != StatusDraft {
		return errors.New("cannot add item to non-draft order")
	}
	o.items = append(o.items, item)
	o.total += item.Price * float64(item.Quantity)
	return nil
}

// Query-сторона: плоская read-optimized структура
type OrderListView struct {
	ID         string    `json:"id"`
	UserName   string    `json:"user_name"`
	TotalItems int       `json:"total_items"`
	Total      float64   `json:"total"`
	Status     string    `json:"status"`
	CreatedAt  time.Time `json:"created_at"`
}

// Специализированный запрос — возвращает именно то, что нужно UI
func (r *OrderQueryRepository) GetOrdersForUser(
	ctx context.Context, userID string, page, size int,
) ([]OrderListView, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT
			o.id,
			u.name AS user_name,
			COUNT(oi.id) AS total_items,
			o.total,
			o.status,
			o.created_at
		FROM orders o
		JOIN users u ON u.id = o.user_id
		JOIN order_items oi ON oi.order_id = o.id
		WHERE o.user_id = $1
		GROUP BY o.id, u.name
		ORDER BY o.created_at DESC
		LIMIT $2 OFFSET $3
	`, userID, size, (page-1)*size)
	// ...
}
```

---

### Полный CQRS: разные хранилища

```
                    ┌──────────────────────────────────┐
                    │           Application             │
                    └──────┬───────────────┬────────────┘
                           │               │
                  Commands │               │ Queries
                           ▼               ▼
               ┌─────────────────┐ ┌────────────────────┐
               │  Command Side   │ │   Query Side       │
               │  PostgreSQL     │ │   Elasticsearch    │
               │  (normalized)   │ │   (denormalized)   │
               └────────┬────────┘ └────────────────────┘
                        │               ▲
                        │  Events       │
                        └───────────────┘
                          (sync via events)
```

**Примеры разных хранилищ:**

| Write Store | Read Store | Когда |
|---|---|---|
| PostgreSQL | PostgreSQL (read replica) | Базовый случай |
| PostgreSQL | Elasticsearch | Полнотекстовый поиск |
| PostgreSQL | Redis | Очень горячие данные, счётчики |
| PostgreSQL | MongoDB | Гибкая схема для отображения |
| Event Store | Materialized views | Event Sourcing + CQRS |

---

### Синхронизация read-модели через события

```
Write side          Event Bus         Read side (Projection)
    │                   │                     │
    │ OrderCreated      │                     │
    │──────────────────>│                     │
    │                   │  OrderCreated       │
    │                   │────────────────────>│
    │                   │                     │ UPDATE elasticsearch
    │                   │                     │ index order_view
    │                   │                     │ SET status = 'created'
    │                   │                     │
    │ OrderShipped      │                     │
    │──────────────────>│                     │
    │                   │  OrderShipped       │
    │                   │────────────────────>│
    │                   │                     │ UPDATE order_view
    │                   │                     │ SET status = 'shipped'
    │                   │                     │   tracking = ...
```

**Eventual consistency**: между записью команды и обновлением read-модели есть задержка. Клиент может видеть старые данные некоторое время. Это trade-off, который нужно осознанно принять.

---

### Когда CQRS нужен (и когда нет)

**Нужен, когда:**
- Read и write нагрузки кардинально различаются (100:1, 1000:1)
- Разным клиентам нужны разные представления одних данных
- Нужен полнотекстовый поиск (Elasticsearch) поверх транзакционных данных
- Команда готова к eventual consistency
- Используется Event Sourcing (CQRS — естественная пара)

**Не нужен, когда:**
- Простой CRUD без сложных запросов
- Маленькая команда, нет ресурсов на поддержку двух моделей
- Latency eventual consistency неприемлема для бизнеса
- PostgreSQL с правильными индексами справляется со всей нагрузкой

> CQRS — это инструмент, а не цель. Большинство систем не нуждаются в полном CQRS.

---

### Пример на Go: Command Handler + Event → Projection

```go
package cqrs

import (
	"context"
	"time"
)

// ─── Command Side ───────────────────────────────────────────────────────────

type CreateOrderCommand struct {
	OrderID string
	UserID  string
	Items   []CommandOrderItem
}

type CommandOrderItem struct {
	ProductID   string
	ProductName string
	Price       float64
	Quantity    int
}

// OrderCommandHandler обрабатывает команды и публикует события
type OrderCommandHandler struct {
	repo      WriteOrderRepository
	publisher DomainEventPublisher
}

func (h *OrderCommandHandler) HandleCreateOrder(
	ctx context.Context, cmd CreateOrderCommand,
) error {
	// Бизнес-логика на write-стороне
	total := 0.0
	for _, item := range cmd.Items {
		total += item.Price * float64(item.Quantity)
	}

	order := WriteOrder{
		ID:        cmd.OrderID,
		UserID:    cmd.UserID,
		Total:     total,
		Status:    "pending",
		CreatedAt: time.Now().UTC(),
	}

	if err := h.repo.Save(ctx, order); err != nil {
		return err
	}

	// Публикуем доменное событие
	event := OrderCreatedEvent{
		OrderID:   cmd.OrderID,
		UserID:    cmd.UserID,
		Items:     cmd.Items,
		Total:     total,
		CreatedAt: order.CreatedAt,
	}

	return h.publisher.Publish(ctx, "order.created", event)
}

// ─── Events ─────────────────────────────────────────────────────────────────

type OrderCreatedEvent struct {
	OrderID   string
	UserID    string
	Items     []CommandOrderItem
	Total     float64
	CreatedAt time.Time
}

type OrderShippedEvent struct {
	OrderID    string
	TrackingID string
	ShippedAt  time.Time
}

// ─── Read Side (Projections) ─────────────────────────────────────────────────

// OrderSummaryView — денормализованное представление для списка заказов
type OrderSummaryView struct {
	OrderID    string    `json:"order_id"`
	UserID     string    `json:"user_id"`
	TotalItems int       `json:"total_items"`
	Total      float64   `json:"total"`
	Status     string    `json:"status"`
	TrackingID string    `json:"tracking_id,omitempty"`
	CreatedAt  time.Time `json:"created_at"`
}

// OrderProjection слушает события и обновляет read-модель
type OrderProjection struct {
	readDB ReadOrderRepository
}

// OnOrderCreated обновляет read-модель при создании заказа
func (p *OrderProjection) OnOrderCreated(ctx context.Context, event OrderCreatedEvent) error {
	view := OrderSummaryView{
		OrderID:    event.OrderID,
		UserID:     event.UserID,
		TotalItems: len(event.Items),
		Total:      event.Total,
		Status:     "pending",
		CreatedAt:  event.CreatedAt,
	}

	return p.readDB.Upsert(ctx, view)
}

// OnOrderShipped обновляет статус и трекинг в read-модели
func (p *OrderProjection) OnOrderShipped(ctx context.Context, event OrderShippedEvent) error {
	return p.readDB.UpdateStatus(ctx, event.OrderID, "shipped", event.TrackingID)
}

// ─── Query Side ──────────────────────────────────────────────────────────────

type OrderQueryService struct {
	readDB ReadOrderRepository
}

func (s *OrderQueryService) GetUserOrders(
	ctx context.Context, userID string,
) ([]OrderSummaryView, error) {
	// Читаем из оптимизированного read-хранилища
	return s.readDB.FindByUserID(ctx, userID)
}

func (s *OrderQueryService) SearchOrders(
	ctx context.Context, query string,
) ([]OrderSummaryView, error) {
	// Полнотекстовый поиск — только возможен на read-стороне (Elasticsearch)
	return s.readDB.FullTextSearch(ctx, query)
}
```

---

## 5. Event Sourcing

### Идея

Вместо хранения **текущего состояния** объекта — храним **последовательность событий**, которые к нему привели.

```
Традиционный подход:
┌──────────────────────────────────────────┐
│ accounts table:                          │
│ id=123, balance=750, status=active       │ ← только финальное состояние
└──────────────────────────────────────────┘

Event Sourcing:
┌──────────────────────────────────────────┐
│ events table (append-only):              │
│ 1. AccountCreated  {balance: 0}          │
│ 2. MoneyDeposited  {amount: 1000}        │
│ 3. MoneyWithdrawn  {amount: 200}         │
│ 4. MoneyDeposited  {amount: 500}         │
│ 5. MoneyWithdrawn  {amount: 550}         │
│                            balance = 750  │ ← вычисляется replay
└──────────────────────────────────────────┘
```

Текущее состояние = результат применения всех событий по порядку (**replay**).

---

### Event Store: Append-Only Log

```
┌──────────────────────────────────────────────────────────────────┐
│                        Event Store                               │
│                                                                  │
│  stream: account-123                                             │
│  ┌──────┬──────────────────┬────────┬──────────────────────────┐ │
│  │  v1  │ AccountCreated   │ t=0001 │ {owner: "alice"}         │ │
│  ├──────┼──────────────────┼────────┼──────────────────────────┤ │
│  │  v2  │ MoneyDeposited   │ t=0042 │ {amount: 1000}           │ │
│  ├──────┼──────────────────┼────────┼──────────────────────────┤ │
│  │  v3  │ MoneyWithdrawn   │ t=0089 │ {amount: 200}            │ │
│  ├──────┼──────────────────┼────────┼──────────────────────────┤ │
│  │  v4  │ MoneyDeposited   │ t=0156 │ {amount: 500}            │ │
│  └──────┴──────────────────┴────────┴──────────────────────────┘ │
│                                                                  │
│  Только INSERT, никогда UPDATE/DELETE                            │
└──────────────────────────────────────────────────────────────────┘
```

---

### Snapshots: оптимизация для длинных цепочек

Если у агрегата 10 000 событий, replay при каждом запросе — дорого.

**Snapshot** — сохранённое состояние агрегата на определённой версии:

```
┌─────────────────────────────────────────────────┐
│ events: v1...v1000                              │
│ snapshot at v1000: {balance: 5000}              │ ← сохраняем состояние
│ events: v1001...v1050                           │
│                                                 │
│ Replay = snapshot(v1000) + events v1001..v1050  │
│          вместо полного replay v1..v1050        │
└─────────────────────────────────────────────────┘
```

Стратегия: делать snapshot каждые N событий (например, 100 или 500).

---

### Плюсы и минусы

**Плюсы:**
- **Полная история** — можно ответить «что произошло с аккаунтом 6 месяцев назад»
- **Audit trail** из коробки — не нужен отдельный audit log
- **Time travel** — воспроизведи состояние на любой момент времени
- **Debug** — можно воспроизвести баг, переиграв события
- **Event-driven** — события уже есть, можно строить projections
- **Decoupling** — другие системы подписываются на события

**Минусы:**
- **Сложность** — нет стандартного ORM, нужен кастомный event store
- **Schema evolution** — как обрабатывать старые события при изменении схемы?
- **Eventual consistency** — read-модели обновляются асинхронно
- **Query complexity** — нельзя сделать `SELECT * WHERE balance > 1000` напрямую
- **Snapshot management** — нужно поддерживать и события, и снимки

---

### Event Sourcing + CQRS

Event Sourcing и CQRS — классическая пара. События из Event Store используются для обновления read-моделей:

```
┌──────────────┐  command  ┌──────────────┐
│    Client    │──────────>│   Command    │
│              │           │   Handler    │
│              │<──────────│              │
│              │  result   └──────┬───────┘
│              │                  │ events
│              │                  ▼
│              │    ┌─────────────────────┐
│              │    │    Event Store      │
│              │    │   (append-only)     │
│              │    └──────┬─────────────┘
│              │           │
│              │           ├──────────────────────────┐
│              │           ▼                          ▼
│              │  ┌──────────────────┐  ┌──────────────────────┐
│     query    │  │  AccountBalance  │  │  TransactionHistory  │
│──────────────┼─>│  Projection      │  │  Projection          │
│              │  │  (Redis)         │  │  (Elasticsearch)     │
└──────────────┘  └──────────────────┘  └──────────────────────┘
```

---

### Пример на Go: Event Store для банковского счёта

```go
package eventsourcing

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// ─── Events ──────────────────────────────────────────────────────────────────

type EventType string

const (
	EventAccountCreated EventType = "AccountCreated"
	EventMoneyDeposited EventType = "MoneyDeposited"
	EventMoneyWithdrawn EventType = "MoneyWithdrawn"
)

type StoredEvent struct {
	ID            string
	AggregateID   string
	AggregateType string
	EventType     EventType
	Version       int
	Payload       json.RawMessage
	OccurredAt    time.Time
}

type AccountCreatedPayload struct {
	OwnerID  string  `json:"owner_id"`
	Currency string  `json:"currency"`
	Balance  float64 `json:"balance"`
}

type MoneyDepositedPayload struct {
	Amount    float64 `json:"amount"`
	Reference string  `json:"reference"`
}

type MoneyWithdrawnPayload struct {
	Amount    float64 `json:"amount"`
	Reference string  `json:"reference"`
}

// ─── Aggregate ───────────────────────────────────────────────────────────────

type Account struct {
	ID       string
	OwnerID  string
	Currency string
	Balance  float64
	Version  int
	// Несохранённые события, появившиеся в текущей сессии
	uncommittedEvents []StoredEvent
}

// Replay восстанавливает состояние аккаунта из событий
func (a *Account) Replay(events []StoredEvent) error {
	for _, event := range events {
		if err := a.apply(event); err != nil {
			return fmt.Errorf("replay event %s v%d: %w", event.EventType, event.Version, err)
		}
	}
	return nil
}

func (a *Account) apply(event StoredEvent) error {
	switch event.EventType {
	case EventAccountCreated:
		var p AccountCreatedPayload
		if err := json.Unmarshal(event.Payload, &p); err != nil {
			return err
		}
		a.ID = event.AggregateID
		a.OwnerID = p.OwnerID
		a.Currency = p.Currency
		a.Balance = p.Balance
		a.Version = event.Version

	case EventMoneyDeposited:
		var p MoneyDepositedPayload
		if err := json.Unmarshal(event.Payload, &p); err != nil {
			return err
		}
		a.Balance += p.Amount
		a.Version = event.Version

	case EventMoneyWithdrawn:
		var p MoneyWithdrawnPayload
		if err := json.Unmarshal(event.Payload, &p); err != nil {
			return err
		}
		a.Balance -= p.Amount
		a.Version = event.Version

	default:
		return fmt.Errorf("unknown event type: %s", event.EventType)
	}
	return nil
}

// ─── Business Methods ────────────────────────────────────────────────────────

func NewAccount(id, ownerID, currency string) (*Account, error) {
	a := &Account{}
	payload, _ := json.Marshal(AccountCreatedPayload{
		OwnerID:  ownerID,
		Currency: currency,
		Balance:  0,
	})

	event := StoredEvent{
		AggregateID:   id,
		AggregateType: "Account",
		EventType:     EventAccountCreated,
		Version:       1,
		Payload:       payload,
		OccurredAt:    time.Now().UTC(),
	}

	if err := a.apply(event); err != nil {
		return nil, err
	}

	a.uncommittedEvents = append(a.uncommittedEvents, event)
	return a, nil
}

func (a *Account) Deposit(amount float64, reference string) error {
	if amount <= 0 {
		return errors.New("deposit amount must be positive")
	}

	payload, _ := json.Marshal(MoneyDepositedPayload{
		Amount:    amount,
		Reference: reference,
	})

	event := StoredEvent{
		AggregateID:   a.ID,
		AggregateType: "Account",
		EventType:     EventMoneyDeposited,
		Version:       a.Version + 1,
		Payload:       payload,
		OccurredAt:    time.Now().UTC(),
	}

	if err := a.apply(event); err != nil {
		return err
	}

	a.uncommittedEvents = append(a.uncommittedEvents, event)
	return nil
}

func (a *Account) Withdraw(amount float64, reference string) error {
	if amount <= 0 {
		return errors.New("withdrawal amount must be positive")
	}
	if a.Balance < amount {
		return fmt.Errorf("insufficient funds: balance %.2f, requested %.2f", a.Balance, amount)
	}

	payload, _ := json.Marshal(MoneyWithdrawnPayload{
		Amount:    amount,
		Reference: reference,
	})

	event := StoredEvent{
		AggregateID:   a.ID,
		AggregateType: "Account",
		EventType:     EventMoneyWithdrawn,
		Version:       a.Version + 1,
		Payload:       payload,
		OccurredAt:    time.Now().UTC(),
	}

	if err := a.apply(event); err != nil {
		return err
	}

	a.uncommittedEvents = append(a.uncommittedEvents, event)
	return nil
}

// ─── Event Store ─────────────────────────────────────────────────────────────

type EventStore interface {
	// Append добавляет события. expectedVersion для optimistic concurrency.
	Append(ctx context.Context, aggregateID string, events []StoredEvent, expectedVersion int) error
	// Load возвращает все события для агрегата, начиная с fromVersion.
	Load(ctx context.Context, aggregateID string, fromVersion int) ([]StoredEvent, error)
}

type AccountRepository struct {
	store EventStore
}

func (r *AccountRepository) Load(ctx context.Context, accountID string) (*Account, error) {
	events, err := r.store.Load(ctx, accountID, 0)
	if err != nil {
		return nil, err
	}
	if len(events) == 0 {
		return nil, fmt.Errorf("account %s not found", accountID)
	}

	account := &Account{}
	if err := account.Replay(events); err != nil {
		return nil, err
	}

	return account, nil
}

func (r *AccountRepository) Save(ctx context.Context, account *Account) error {
	if len(account.uncommittedEvents) == 0 {
		return nil
	}

	// expectedVersion = версия до текущих изменений (optimistic concurrency)
	expectedVersion := account.Version - len(account.uncommittedEvents)

	err := r.store.Append(ctx, account.ID, account.uncommittedEvents, expectedVersion)
	if err != nil {
		return err
	}

	account.uncommittedEvents = nil
	return nil
}

// ─── Пример использования ────────────────────────────────────────────────────

func ExampleUsage(ctx context.Context, repo *AccountRepository) {
	// Создать новый аккаунт
	account, _ := NewAccount("acc-001", "user-123", "USD")
	account.Deposit(1000.00, "initial-deposit")
	repo.Save(ctx, account)

	// Загрузить и изменить
	acc, _ := repo.Load(ctx, "acc-001")
	acc.Deposit(500.00, "salary-march")
	acc.Withdraw(200.00, "rent-payment")
	acc.Withdraw(550.00, "car-payment")
	repo.Save(ctx, acc)

	// Загрузить снова — состояние восстановлено из событий
	acc2, _ := repo.Load(ctx, "acc-001")
	fmt.Printf("Balance: %.2f\n", acc2.Balance) // 750.00
}
```

---

### Schema Evolution событий

При изменении схемы событий старые события должны продолжать работать. Стратегии:

```
1. Upcasting: преобразование старых событий при чтении
   v1: {"amount": 100}
   v2: {"amount": 100, "currency": "USD"} ← upcast добавляет default

2. Weak schema (JSON): добавляй поля, не удаляй старые
   Новый код читает новые поля; старый код игнорирует неизвестные.

3. Versioned events: разные типы для разных версий
   MoneyDeposited_v1, MoneyDeposited_v2
   (раздувает код, но явно)
```

---

## 6. Distributed Consensus

### Зачем нужен консенсус

Distributed consensus — соглашение нескольких узлов о едином значении, даже при отказах.

**Где используется:**
- **Leader election**: кто сейчас primary в кластере?
- **Distributed locks**: только один worker обрабатывает задачу
- **Configuration management**: все узлы видят одинаковую конфигурацию
- **Distributed counters**: атомарные счётчики

Без консенсуса: split-brain, два лидера, потеря данных.

---

### Raft: Упрощённое объяснение

Raft разработан как более понятная альтернатива Paxos. Три роли узлов:

```
Leader   — принимает все записи, репликает лог на Followers
Follower — пассивный узел, реплицирует лог от Leader
Candidate — узел, который баллотируется в лидеры
```

**Leader Election:**

```
┌────────┐  heartbeat timeout  ┌───────────┐
│Follower│ ──────────────────> │ Candidate │
└────────┘                     └─────┬─────┘
                                     │ RequestVote RPC
                    ┌────────────────┼────────────────┐
                    ▼                ▼                 ▼
               ┌────────┐      ┌────────┐       ┌────────┐
               │Node A  │      │Node B  │       │Node C  │
               │vote YES│      │vote NO │       │vote YES│
               └────────┘      └────────┘       └────────┘
                    │                                 │
                    └─────────── 2/3 votes ───────────┘
                                     │
                                     ▼
                               ┌──────────┐
                               │  Leader  │
                               └──────────┘
```

**Term** — монотонно возрастающий номер. Каждая новая election увеличивает term.

**Правила:**
- Узел голосует за кандидата только если кандидат имеет лог не хуже собственного
- Узел голосует только за одного кандидата в терм
- Liveness: если leader умер, следующий election начнётся через random timeout

**Log Replication:**

```
Client            Leader            Follower 1      Follower 2
  │                  │                   │               │
  │── write(x=5) ──>│                   │               │
  │                  │── AppendEntry ───>│               │
  │                  │── AppendEntry ────────────────── >│
  │                  │                   │               │
  │                  │<── ACK ───────────│               │
  │                  │<── ACK ────────────────────────── │
  │                  │                   │               │
  │                  │ (majority = 2/3 acknowledged)     │
  │                  │── commit ─────── >│               │
  │                  │── commit ──────────────────────── >│
  │<── OK ──────────│                   │               │
```

Leader коммитит запись только когда **большинство** узлов (quorum) подтвердили получение.

**Safety**: два лидера не могут оба набрать quorum в одном терме → не будет split-brain.

---

### Paxos

Paxos (Lamport, 1989) — первый теоретически обоснованный алгоритм консенсуса. Сложнее для понимания и реализации:

- Три фазы: Prepare → Promise → Accept → Accepted
- Multi-Paxos для репликации лога добавляет ещё сложности
- На практике везде Raft или его вариации (Zab для ZooKeeper)

Знай, что Paxos существует. Для production — используй Raft-based системы.

---

### Где используется консенсус

| Система | Алгоритм | Для чего |
|---|---|---|
| etcd | Raft | Kubernetes state, distributed locks |
| ZooKeeper | ZAB (Zookeeper Atomic Broadcast) | Координация, leader election |
| Consul | Raft | Service discovery, KV store |
| CockroachDB | Raft per range | Distributed SQL |
| MongoDB | Raft-like | Replica set elections |

---

### Distributed Locks: проблемы наивных реализаций

**Наивный lock через Redis:**

```go
// ПЛОХО: не устойчиво к падению держателя лока
ok, _ := redis.SetNX("lock:resource", "1", 30*time.Second)
if ok {
    defer redis.Del("lock:resource") // что если процесс умрёт до Del?
    doWork()
}
```

**Проблемы:**
1. Процесс держит лок и умирает. Кто снимет лок?
2. TTL истёк, а процесс ещё работает. Два процесса одновременно в критической секции.
3. GC pause — процесс думает, что держит лок, но TTL истёк во время паузы.

**Fencing Token** — решение проблемы лока после истечения TTL:

```
Process 1 получает lock: token=33
Process 2 получает lock: token=34  ← Process 1's lock expired

Process 1 пытается записать с token=33
Storage видит: 33 < текущий token 34 → REJECT

Process 2 пишет с token=34 → OK
```

Каждый лок имеет монотонно возрастающий token. Storage отклоняет операции с устаревшим token.

---

### Пример на Go: Distributed Lock через etcd с Lease

```go
package distlock

import (
	"context"
	"fmt"
	"time"

	clientv3 "go.etcd.io/etcd/client/v3"
	"go.etcd.io/etcd/client/v3/concurrency"
)

type DistributedLock struct {
	client  *clientv3.Client
	session *concurrency.Session
	mutex   *concurrency.Mutex
	key     string
}

func NewDistributedLock(endpoints []string, key string, ttl int) (*DistributedLock, error) {
	client, err := clientv3.New(clientv3.Config{
		Endpoints:   endpoints,
		DialTimeout: 5 * time.Second,
	})
	if err != nil {
		return nil, fmt.Errorf("etcd connect: %w", err)
	}

	// Session создаёт lease с TTL. Если держатель умрёт — lease истечёт,
	// лок автоматически освободится.
	session, err := concurrency.NewSession(client, concurrency.WithTTL(ttl))
	if err != nil {
		client.Close()
		return nil, fmt.Errorf("etcd session: %w", err)
	}

	mutex := concurrency.NewMutex(session, "/locks/"+key)

	return &DistributedLock{
		client:  client,
		session: session,
		mutex:   mutex,
		key:     key,
	}, nil
}

// Lock захватывает лок. Блокирует до получения лока или отмены ctx.
func (l *DistributedLock) Lock(ctx context.Context) error {
	return l.mutex.Lock(ctx)
}

// TryLock пытается захватить лок без ожидания.
func (l *DistributedLock) TryLock(ctx context.Context) error {
	return l.mutex.TryLock(ctx)
}

// Unlock освобождает лок.
func (l *DistributedLock) Unlock(ctx context.Context) error {
	return l.mutex.Unlock(ctx)
}

// Close закрывает session (lease) и connection.
func (l *DistributedLock) Close() error {
	l.session.Close()
	return l.client.Close()
}

// WithLock — хелпер для выполнения работы под локом.
func WithLock(ctx context.Context, lock *DistributedLock, fn func(ctx context.Context) error) error {
	if err := lock.Lock(ctx); err != nil {
		return fmt.Errorf("acquire lock: %w", err)
	}
	defer lock.Unlock(ctx)

	return fn(ctx)
}

// Пример использования: только один worker обрабатывает задачу
func ProcessJob(ctx context.Context, jobID string, endpoints []string) error {
	lock, err := NewDistributedLock(endpoints, "job:"+jobID, 30)
	if err != nil {
		return err
	}
	defer lock.Close()

	return WithLock(ctx, lock, func(ctx context.Context) error {
		fmt.Printf("processing job %s\n", jobID)
		// ... работа
		return nil
	})
}
```

**Как работает etcd Lease:**
- `Session` создаёт lease с TTL на etcd
- Пока процесс жив, session автоматически обновляет lease (keepalive)
- Если процесс упал — keepalive прекращается, lease истекает, лок освобождается

---

## 7. Idempotency и дедупликация

### Почему сообщения приходят дважды

В распределённых системах сети ненадёжны. Стандартные гарантии доставки:

```
At-most-once:  сообщение может быть потеряно, но не дублировано
At-least-once: сообщение будет доставлено, но возможны дубли ← самое частое
Exactly-once:  никаких потерь, никаких дублей ← дорого, требует coordination
```

**Сценарии дублей при at-least-once:**

```
Producer             Network/Broker        Consumer
   │                      │                    │
   │── send message ─────>│                    │
   │                      │── deliver ─────── >│
   │                      │<── ACK ─────────── │
   │<── timeout ──────────│                    │
   │                      │                    │
   │── retry message ────>│ ← дубль!           │
   │                      │── deliver ─────── >│ ← consumer получает дважды
```

---

### Idempotency Key

**Idempotency key** — уникальный ID операции, генерируемый на **стороне клиента**. Один и тот же ключ при повторном запросе возвращает тот же результат, не выполняя операцию снова.

```
POST /api/orders
X-Idempotency-Key: 550e8400-e29b-41d4-a716-446655440000

{
  "user_id": "user-123",
  "amount": 99.99
}
```

Сервер при повторном запросе с тем же ключом:
- Если уже обработан → возвращает сохранённый ответ
- Если в процессе → ждёт или возвращает 409 Conflict

**Хранение на сервере:**

```sql
CREATE TABLE idempotency_keys (
    key         UUID PRIMARY KEY,
    request_hash VARCHAR(64),    -- hash входных данных для валидации
    response     JSONB,          -- сохранённый ответ
    status       VARCHAR(20),    -- 'processing', 'completed', 'failed'
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at   TIMESTAMPTZ NOT NULL  -- после этого ключ можно удалить
);
```

---

### Exactly-once = At-least-once + Idempotent Consumer

На практике exactly-once semantics реализуется не через магию брокера, а через:
1. Брокер гарантирует at-least-once (Kafka, RabbitMQ)
2. Consumer идемпотентен — повторная обработка не меняет результат

```
Kafka (at-least-once)  →  Idempotent Consumer  =  Exactly-once effect
```

Kafka Transactions (Kafka >= 0.11) дают exactly-once в рамках Kafka-to-Kafka, но не для внешних систем.

---

### Пример на Go: Idempotent Handler с Redis

```go
package idempotency

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

var ErrDuplicateRequest = errors.New("duplicate request: already processed")

type StoredResult struct {
	StatusCode int             `json:"status_code"`
	Body       json.RawMessage `json:"body"`
}

type IdempotencyMiddleware struct {
	redis *redis.Client
	ttl   time.Duration
}

func NewIdempotencyMiddleware(redis *redis.Client, ttl time.Duration) *IdempotencyMiddleware {
	return &IdempotencyMiddleware{redis: redis, ttl: ttl}
}

// Execute выполняет fn один раз для данного idempotencyKey.
// При повторном вызове возвращает сохранённый результат.
func (m *IdempotencyMiddleware) Execute(
	ctx context.Context,
	idempotencyKey string,
	fn func(ctx context.Context) (interface{}, error),
) (interface{}, error) {
	redisKey := "idempotency:" + idempotencyKey

	// 1. Проверяем: уже выполнено?
	cached, err := m.redis.Get(ctx, redisKey).Bytes()
	if err == nil {
		// Уже выполнено — возвращаем сохранённый результат
		var result StoredResult
		if jsonErr := json.Unmarshal(cached, &result); jsonErr != nil {
			return nil, fmt.Errorf("unmarshal cached result: %w", jsonErr)
		}

		var body interface{}
		json.Unmarshal(result.Body, &body)
		return body, nil
	}

	if !errors.Is(err, redis.Nil) {
		return nil, fmt.Errorf("redis get: %w", err)
	}

	// 2. Захватываем слот (lock) для предотвращения concurrent duplicate
	lockKey := "idempotency:lock:" + idempotencyKey
	lockAcquired, err := m.redis.SetNX(ctx, lockKey, "1", 30*time.Second).Result()
	if err != nil {
		return nil, fmt.Errorf("redis setnx: %w", err)
	}
	if !lockAcquired {
		// Другой воркер уже обрабатывает этот же ключ
		return nil, fmt.Errorf("request with key %s is already being processed", idempotencyKey)
	}
	defer m.redis.Del(ctx, lockKey)

	// 3. Выполняем операцию
	result, fnErr := fn(ctx)

	// 4. Сохраняем результат (даже при ошибке — чтобы повтор вернул тот же ответ)
	bodyJSON, _ := json.Marshal(result)
	stored := StoredResult{
		StatusCode: 200,
		Body:       bodyJSON,
	}
	if fnErr != nil {
		stored.StatusCode = 500
	}

	storedJSON, _ := json.Marshal(stored)
	m.redis.Set(ctx, redisKey, storedJSON, m.ttl)

	return result, fnErr
}

// ─── Пример: Idempotent Payment Handler ──────────────────────────────────────

type PaymentRequest struct {
	UserID          string  `json:"user_id"`
	Amount          float64 `json:"amount"`
	IdempotencyKey  string  `json:"idempotency_key"`
}

type PaymentResponse struct {
	PaymentID string `json:"payment_id"`
	Status    string `json:"status"`
}

type PaymentHandler struct {
	idempotency *IdempotencyMiddleware
	paymentSvc  PaymentProcessor
}

type PaymentProcessor interface {
	Charge(ctx context.Context, userID string, amount float64) (string, error)
}

func (h *PaymentHandler) HandlePayment(ctx context.Context, req PaymentRequest) (*PaymentResponse, error) {
	result, err := h.idempotency.Execute(
		ctx,
		req.IdempotencyKey,
		func(ctx context.Context) (interface{}, error) {
			paymentID, err := h.paymentSvc.Charge(ctx, req.UserID, req.Amount)
			if err != nil {
				return nil, err
			}
			return &PaymentResponse{
				PaymentID: paymentID,
				Status:    "charged",
			}, nil
		},
	)
	if err != nil {
		return nil, err
	}

	return result.(*PaymentResponse), nil
}
```

**Генерация idempotency key на клиенте:**

```go
import "github.com/google/uuid"

// Детерминированный ключ: один и тот же key для одной и той же бизнес-операции
func generateIdempotencyKey(userID, orderReference string) string {
	// UUID v5 — детерминированный UUID из namespace + данных
	namespace := uuid.MustParse("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
	return uuid.NewSHA1(namespace, []byte(userID+":"+orderReference)).String()
}

// Или просто случайный UUID для каждой попытки
func generateRandomKey() string {
	return uuid.New().String()
}
```

---

## 8. Bulkhead, Backpressure и другие паттерны устойчивости

### Bulkhead: Изоляция ресурсов

Bulkhead (переборка в корабле) — изолируй ресурсы по компонентам, чтобы отказ одного не топил всё приложение.

**Проблема без bulkhead:**

```
Один HTTP-пул на все downstream-сервисы:

PaymentService   → slow!
InventoryService → slow!
NotificationSvc  → fast

→ PaymentService занял все 100 потоков HTTP-пула
→ InventoryService не может получить поток
→ NotificationService тоже не может (хотя он быстрый)
→ Всё приложение деградирует
```

**С bulkhead — отдельные пулы:**

```
PaymentService   → пул 40 потоков   ← может деградировать
InventoryService → пул 40 потоков   ← изолирован
NotificationSvc  → пул 20 потоков   ← работает независимо
```

---

### Backpressure

Backpressure — механизм, позволяющий **consumer замедлить producer**, когда не справляется.

```
Без backpressure:
Producer ──[1000 req/s]──> Consumer [обрабатывает 100 req/s]
                            ↑ очередь растёт → OOM → crash

С backpressure:
Producer ──[100 req/s]──>  Consumer [обрабатывает 100 req/s]
          ↑ producer замедлился по сигналу от consumer
```

**Стратегии:**
- **Blocking**: producer блокируется, если очередь полна (sync backpressure)
- **Drop**: отбрасываем новые задачи, если буфер переполнен (load shedding)
- **Rate limiting**: ограничиваем входящий поток на границе системы

---

### Timeout + Deadline Propagation

В Go контекст — это правильный инструмент для propagation deadline через цепочку вызовов.

```go
// Входящий HTTP-запрос: общий deadline 5 секунд на всю обработку
ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
defer cancel()

// Вызов PaymentService: не более 2 секунд
payCtx, payCancel := context.WithTimeout(ctx, 2*time.Second)
defer payCancel()
paymentID, err := paymentSvc.Reserve(payCtx, ...)

// Вызов InventoryService: не более 1 секунды
invCtx, invCancel := context.WithTimeout(ctx, 1*time.Second)
defer invCancel()
err = inventorySvc.Reserve(invCtx, ...)
```

**Deadline propagation через gRPC**: контекст с deadline автоматически передаётся во все downstream-вызовы. Убедись, что middleware-слои **не игнорируют** переданный контекст.

---

### Пример на Go: Bulkhead с Semaphore (Buffered Channel)

```go
package resilience

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"
)

var ErrBulkheadFull = errors.New("bulkhead capacity exceeded")

// Bulkhead ограничивает параллельные вызовы к downstream-сервису
type Bulkhead struct {
	semaphore chan struct{}
	name      string
}

func NewBulkhead(name string, maxConcurrent int) *Bulkhead {
	return &Bulkhead{
		semaphore: make(chan struct{}, maxConcurrent),
		name:      name,
	}
}

// Execute выполняет fn под защитой bulkhead.
// Если достигнут лимит — возвращает ErrBulkheadFull без ожидания.
func (b *Bulkhead) Execute(ctx context.Context, fn func() error) error {
	select {
	case b.semaphore <- struct{}{}: // захватываем слот
		defer func() { <-b.semaphore }() // освобождаем слот
		return fn()

	default:
		// Нет свободных слотов — отказываем немедленно
		return fmt.Errorf("%s: %w", b.name, ErrBulkheadFull)
	}
}

// ExecuteWithWait выполняет fn, ожидая свободного слота до истечения ctx.
func (b *Bulkhead) ExecuteWithWait(ctx context.Context, fn func() error) error {
	select {
	case b.semaphore <- struct{}{}:
		defer func() { <-b.semaphore }()
		return fn()

	case <-ctx.Done():
		return fmt.Errorf("%s wait: %w", b.name, ctx.Err())
	}
}

// Метрики для мониторинга
func (b *Bulkhead) ActiveCount() int {
	return len(b.semaphore)
}

func (b *Bulkhead) Capacity() int {
	return cap(b.semaphore)
}

// ─── Пример: Service с изолированными пулами ─────────────────────────────────

type OrderProcessor struct {
	paymentBulkhead     *Bulkhead
	inventoryBulkhead   *Bulkhead
	notificationBulkhead *Bulkhead

	httpClient *http.Client
}

func NewOrderProcessor() *OrderProcessor {
	return &OrderProcessor{
		// Каждый downstream получает свой изолированный пул
		paymentBulkhead:      NewBulkhead("payment-svc", 40),
		inventoryBulkhead:    NewBulkhead("inventory-svc", 40),
		notificationBulkhead: NewBulkhead("notification-svc", 20),
		httpClient:           &http.Client{Timeout: 10 * time.Second},
	}
}

func (p *OrderProcessor) ProcessOrder(ctx context.Context, orderID string) error {
	// Вызов PaymentService — под защитой своего bulkhead
	if err := p.paymentBulkhead.Execute(ctx, func() error {
		return p.callPaymentService(ctx, orderID)
	}); err != nil {
		if errors.Is(err, ErrBulkheadFull) {
			// Payment-пул перегружен — применяем degrade-стратегию
			return fmt.Errorf("payment service overloaded, try again later: %w", err)
		}
		return err
	}

	// Вызов InventoryService — под защитой своего bulkhead
	if err := p.inventoryBulkhead.Execute(ctx, func() error {
		return p.callInventoryService(ctx, orderID)
	}); err != nil {
		if errors.Is(err, ErrBulkheadFull) {
			return fmt.Errorf("inventory service overloaded: %w", err)
		}
		return err
	}

	// Уведомление — fire-and-forget с отдельным пулом
	// Даже если notification-пул полон — заказ уже обработан
	go p.notificationBulkhead.Execute(context.Background(), func() error {
		return p.sendNotification(context.Background(), orderID)
	})

	return nil
}

func (p *OrderProcessor) callPaymentService(ctx context.Context, orderID string) error {
	// Добавляем timeout на конкретный downstream-вызов
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	// ... HTTP call
	return nil
}

func (p *OrderProcessor) callInventoryService(ctx context.Context, orderID string) error {
	ctx, cancel := context.WithTimeout(ctx, 1*time.Second)
	defer cancel()
	// ... HTTP call
	return nil
}

func (p *OrderProcessor) sendNotification(ctx context.Context, orderID string) error {
	ctx, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
	defer cancel()
	// ... HTTP call
	return nil
}

// ─── Backpressure через bounded channel ──────────────────────────────────────

type WorkQueue struct {
	tasks chan func()
}

func NewWorkQueue(workers, bufferSize int) *WorkQueue {
	q := &WorkQueue{
		tasks: make(chan func(), bufferSize), // bounded buffer = backpressure
	}

	for i := 0; i < workers; i++ {
		go func() {
			for task := range q.tasks {
				task()
			}
		}()
	}

	return q
}

// Submit добавляет задачу в очередь.
// Если очередь полна — ctx.Done() или немедленный отказ.
func (q *WorkQueue) Submit(ctx context.Context, task func()) error {
	select {
	case q.tasks <- task:
		return nil
	case <-ctx.Done():
		return fmt.Errorf("queue submit: %w", ctx.Err())
	default:
		// Non-blocking: если буфер полон — load shedding
		return errors.New("work queue is full: load shedding")
	}
}
```

---

### Сводная таблица паттернов модуля

| Паттерн | Проблема | Решение | Trade-off |
|---|---|---|---|
| **2PC** | Атомарность через сервисы | Coordinator + prepare/commit | Blocking, тормоза |
| **Saga (Orchestration)** | Длинные транзакции | Компенсации через центр | Координатор = SPOF |
| **Saga (Choreography)** | Coupling между сервисами | Event-driven компенсации | Сложный debugging |
| **Transactional Outbox** | Dual write | Событие в той же транзакции | Relay как доп. компонент |
| **CQRS** | Разная нагрузка read/write | Разные модели | Eventual consistency |
| **Event Sourcing** | Нет истории изменений | Append-only event log | Сложность, schema evolution |
| **Distributed Lock** | Race conditions в кластере | etcd lease + fencing token | Дополнительный сервис |
| **Idempotency Key** | Дубли запросов | Дедупликация по ключу | Хранилище для ключей |
| **Bulkhead** | Каскадные отказы | Изолированные пулы | Конфигурация размеров |
| **Backpressure** | Consumer не справляется | Bounded queues, rate limit | Latency или rejections |

---

## Что дальше

- **Модуль 08**: Messaging Patterns — Kafka, RabbitMQ, stream processing
- **Модуль 09**: Observability — metrics, tracing, logging в распределённых системах
- **Модуль 10**: Data Consistency Patterns — CRDTs, vector clocks, conflict resolution

---

## Дополнительное чтение

- [Designing Data-Intensive Applications](https://dataintensive.net/) — Kleppmann, главы 7, 9, 11
- [Saga Pattern](https://microservices.io/patterns/data/saga.html) — microservices.io
- [Transactional Outbox](https://microservices.io/patterns/data/transactional-outbox.html) — microservices.io
- [Raft Consensus Algorithm](https://raft.github.io/) — raft.github.io (с визуализацией)
- [Martin Fowler: CQRS](https://martinfowler.com/bliki/CQRS.html)
- [Martin Fowler: Event Sourcing](https://martinfowler.com/eaaDev/EventSourcing.html)
- [The Chubby Lock Service](https://research.google/pubs/pub27897/) — Google Research (про distributed locks)
