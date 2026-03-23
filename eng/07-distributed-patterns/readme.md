# Module 07: Distributed Systems Patterns

> **Audience**: Backend developers who have already worked with microservices and understand why "just use a transaction" stops working.
>
> **What's inside**: distributed transactions, Saga, Outbox, CQRS, Event Sourcing, Consensus, Idempotency, Bulkhead/Backpressure.

---

## Table of Contents

1. [Distributed Transactions: The Problem](#1-distributed-transactions-the-problem)
2. [Saga Pattern](#2-saga-pattern)
3. [Transactional Outbox Pattern](#3-transactional-outbox-pattern)
4. [CQRS](#4-cqrs-command-query-responsibility-segregation)
5. [Event Sourcing](#5-event-sourcing)
6. [Distributed Consensus](#6-distributed-consensus)
7. [Idempotency and Deduplication](#7-idempotency-and-deduplication)
8. [Bulkhead, Backpressure, and Resilience Patterns](#8-bulkhead-backpressure-and-resilience-patterns)

---

## 1. Distributed Transactions: The Problem

### Why ACID Does Not Work Across Services

In a monolith with a single DBMS, a transaction is an atomic operation on one database engine. BEGIN / COMMIT / ROLLBACK — all within a single connection.

In microservices, data lives in different databases:

```
OrderService     →  orders_db      (PostgreSQL)
PaymentService   →  payments_db    (PostgreSQL)
InventoryService →  inventory_db   (MySQL)
ShippingService  →  shipping_db    (PostgreSQL)
```

A call via REST/gRPC does not participate in a database transaction. You cannot open a BEGIN over HTTP. You cannot issue a ROLLBACK if the remote service has already committed.

**A typical broken scenario:**

```
1. OrderService creates an order         ✓ OK
2. PaymentService charges the user       ✓ OK
3. InventoryService reserves the item    ✗ FAIL (out of stock)

→ Money was charged, order was created, but the item is out of stock.
   How do you roll back PaymentService?
```

This is not a theoretical problem — it is the daily reality of production systems.

---

### Two-Phase Commit (2PC)

2PC is a classical protocol for distributed transactions. It introduces a special **coordinator** between participants.

**Phases:**

```
Coordinator                 Participant A    Participant B
    │                            │                │
    │──── PREPARE ──────────────>│                │
    │──── PREPARE ───────────────────────────────>│
    │                            │                │
    │<─── VOTE: YES ─────────────│                │
    │<─── VOTE: YES ──────────────────────────────│
    │                            │                │
    │ (all YES → COMMIT)         │                │
    │                            │                │
    │──── COMMIT ───────────────>│                │
    │──── COMMIT ────────────────────────────────>│
    │                            │                │
    │<─── ACK ───────────────────│                │
    │<─── ACK ────────────────────────────────────│
```

**Prepare phase**: each participant locks resources and writes its readiness to commit to the WAL, but does not yet commit.

**Commit phase**: the coordinator sends COMMIT (or ABORT if at least one voted NO).

**Why 2PC is slow and causes blocking:**

- Between PREPARE and COMMIT, all participants hold **locks**. The longer the transaction, the longer the locks are held.
- **Blocking problem**: if the coordinator crashes after PREPARE, participants **cannot** commit or roll back — they wait for the coordinator's decision forever (or until it recovers).
- At least two network round-trips.
- The coordinator is a single point of failure.

**When 2PC is acceptable:**

| Scenario | Acceptable? |
|---|---|
| Two services in the same datacenter, latency < 1ms | Yes, with caveats |
| Databases support XA transactions (PostgreSQL, MySQL) | Yes, but carefully |
| Distributed services over the internet | No |
| High load, latency requirements < 10ms | No |
| Long-running business transactions (seconds, minutes) | Absolutely not |

XA is the standard for 2PC across different DBMSs. PostgreSQL and MySQL support it, but in production it is rare due to locking issues.

---

### Three-Phase Commit (3PC)

3PC adds an intermediate **PRE-COMMIT** phase to address the blocking problem of 2PC:

```
PREPARE → PRE-COMMIT → COMMIT
```

If the coordinator crashes after PRE-COMMIT, participants can agree to commit on their own (all saw PRE-COMMIT → they know everyone voted YES).

**Why it is not used in practice:**

- Not resilient to network partitions. Under split-brain, you can end up with divergent state.
- CAP theorem: in the presence of network partitions, you cannot simultaneously guarantee consistency and availability.
- Implementation complexity is significantly higher than 2PC.
- Adds a third round-trip.

Real-world systems move toward the **Saga Pattern** and **eventual consistency** instead of attempting a true distributed atomic commit.

---

## 2. Saga Pattern

A Saga is a sequence of **local transactions**, each of which publishes an event or triggers the next step. If one step fails, **compensating transactions** are executed for the previous steps.

**Key idea:** instead of one distributed transaction — a chain of small local transactions with explicit rollback via compensations.

```
T1 → T2 → T3 → ... → Tn   (happy path)
         ↑ fail here
C2 ← C1                    (compensating transactions)
```

There are two coordination approaches: **Orchestration** and **Choreography**.

---

### Orchestration

A central **orchestrator** explicitly calls each service and knows the entire flow. Services are unaware of each other.

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

**Success scenario:**

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

**Failure scenario (InventorySvc fails):**

```
Orchestrator                PaymentSvc     InventorySvc
     │                          │               │
     │──── reservePayment() ───>│               │
     │<─── OK ─────────────────│               │
     │                          │               │
     │──── reserveInventory() ──────────────── >│
     │<─── FAIL: out of stock ──────────────────│
     │                          │               │
     │ [begin compensation]     │               │
     │                          │               │
     │──── cancelPayment() ────>│               │
     │<─── OK ─────────────────│               │
     │                          │               │
     │ [saga failed, rollback complete]
```

---

### Choreography

Services **react to events** without a central coordinator. Each service knows what to do when it receives a specific event.

```
OrderSvc          PaymentSvc        InventorySvc      ShippingSvc
   │                  │                  │                 │
   │ OrderCreated     │                  │                 │
   │─────────────────>│                  │                 │
   │                  │ PaymentReserved  │                 │
   │                  │────────────────>│                 │
   │                  │                  │ InventoryReserved
   │                  │                  │──────────────── >│
   │                  │                  │                 │
   │                  │                  │  ShippingScheduled
   │                  │                  │                 │ → event bus
```

**Failure scenario in choreography:**

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
   │ [OrderSvc updates status to FAILED]
```

---

### Compensating Transactions: How to Design Rollback

A compensating transaction is a **business operation** that undoes the effect of the original transaction. It is not a database rollback.

**Principles for designing compensations:**

1. **Every transaction must have a compensation.** Design them together.
2. **Compensation must be idempotent.** It may be called multiple times.
3. **Some operations cannot be compensated.** A sent email cannot be "unsent". Use a pivot transaction (the point of no return) deliberately.
4. **Compensations run in reverse order** of the main transactions.

```
Operation          Compensation
─────────────     ──────────────────────────
createOrder()  →  markOrderFailed()
reservePay()   →  releasePayment()
reserveInv()   →  releaseInventory()
scheduleShip() →  cancelShipping()
sendEmail()    →  (none — pivot transaction)
```

---

### Pros and Cons

| | Orchestration | Choreography |
|---|---|---|
| **Understandability** | Entire flow in one place | Spread across services |
| **Coupling** | Orchestrator knows everyone | Services coupled only via events |
| **Single point of failure** | Yes (orchestrator) | No |
| **Debugging** | Easier — trace in one place | Harder — need to assemble trace |
| **Scalability** | Orchestrator can become a bottleneck | Each service scales independently |
| **Adding a step** | Change only the orchestrator | Need to modify multiple services |
| **Circular dependencies** | Rare | Risk of event loops |

**Choose orchestration** when:
- Complex flow with many conditions
- A clear audit trail is needed
- Small team

**Choose choreography** when:
- Simple linear flow
- Service independence is important
- Willing to invest in distributed tracing

---

### Go Example: Orchestrator for an Order

```go
package saga

import (
	"context"
	"errors"
	"fmt"
	"log"
)

// Saga steps and their compensations
type Step struct {
	Name       string
	Execute    func(ctx context.Context, order *Order) error
	Compensate func(ctx context.Context, order *Order) error
}

// Order — the aggregate passed through the steps
type Order struct {
	ID          string
	UserID      string
	Amount      float64
	Items       []OrderItem
	PaymentID   string  // populated by PaymentService
	ShippingID  string  // populated by ShippingService
}

type OrderItem struct {
	ProductID string
	Quantity  int
}

// Orchestrator executes steps in order and rolls back on failure
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
						return nil // was not reserved
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
					// ConfirmPayment is a pivot transaction.
					// After confirming payment, the compensation is different
					// (a refund, not a release).
					return paymentSvc.Refund(ctx, order.PaymentID)
				},
			},
		},
	}
}

// Execute runs the saga. On failure, runs compensations in reverse order.
func (o *Orchestrator) Execute(ctx context.Context, order *Order) error {
	completed := make([]int, 0, len(o.steps))

	for i, step := range o.steps {
		log.Printf("saga step [%d/%d]: %s", i+1, len(o.steps), step.Name)

		if err := step.Execute(ctx, order); err != nil {
			log.Printf("saga step %s failed: %v — starting compensation", step.Name, err)

			// Compensate completed steps in reverse order
			compensationErr := o.compensate(ctx, order, completed)
			if compensationErr != nil {
				// Compensation also failed — manual intervention required
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
			// Continue compensating the remaining steps even if one failed
		}
	}

	return errors.Join(errs...)
}

// Service interfaces
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

**Usage:**

```go
func CreateOrder(ctx context.Context, req CreateOrderRequest) error {
	order := &Order{
		ID:     generateOrderID(),
		UserID: req.UserID,
		Amount: req.Amount,
		Items:  req.Items,
	}

	// Save the order in PENDING status
	if err := orderRepo.Save(ctx, order); err != nil {
		return err
	}

	orchestrator := NewOrderOrchestrator(paymentSvc, inventorySvc, shippingSvc)

	if err := orchestrator.Execute(ctx, order); err != nil {
		// Compensations have already been run inside Execute
		orderRepo.UpdateStatus(ctx, order.ID, StatusFailed)
		return err
	}

	orderRepo.UpdateStatus(ctx, order.ID, StatusConfirmed)
	return nil
}
```

---

### Saga Techniques: Semantic Lock, Commutative Updates, Pessimistic View

**Semantic Lock** — mark a resource as "in progress" while the saga has not yet completed.

```sql
-- Instead of status = 'available', set status = 'locked'
UPDATE inventory SET status = 'locked', saga_id = $1
WHERE product_id = $2 AND status = 'available';
```

Other sagas see `locked` and either wait or fail. The lock is released on saga completion or compensation.

**Commutative Updates** — operations that can be applied in any order without losing correctness.

```
Non-commutative: SET balance = 100   (order matters)
Commutative:     ADD balance += 10   (order does not matter, result is the same)
```

Design operations as commutative where possible — this simplifies the saga.

**Pessimistic View** — read the **last uncommitted state**, rather than optimistically assuming success.

```
Instead of: "the order will be confirmed, show the client 'success'"
Better:     "the order is being processed, we will notify you of the result"
```

This reduces the likelihood of dirty read / lost update anomalies within the saga.

---

## 3. Transactional Outbox Pattern

### The Dual Write Problem

In event-driven systems, after a business operation you need to:
1. Save data to the DB
2. Send an event to Kafka/RabbitMQ

Naïve code:

```go
func CreateOrder(ctx context.Context, order Order) error {
    // Step 1: save to DB
    if err := db.Save(order); err != nil {
        return err
    }

    // Step 2: publish event
    // WHAT IF KAFKA IS UNAVAILABLE?
    // WHAT IF THE APP CRASHES BETWEEN THESE STEPS?
    if err := kafka.Publish("order.created", order); err != nil {
        return err // Order was saved, but the event was not published!
    }

    return nil
}
```

**Three failure scenarios:**

```
Scenario 1: DB fails
→ Neither order nor event. OK.

Scenario 2: Kafka unavailable
→ Order exists, no event. PROBLEM.
   Other services don't know about the order.

Scenario 3: App crashes between Save and Publish
→ Order exists, no event. PROBLEM.
   Happens even with healthy systems.
```

---

### Solution: Outbox Table

Write the event **in the same transaction** as the main data. A separate process (relay/publisher) reads the outbox and publishes to Kafka.

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
         │   outbox table  │ ← atomically
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

The atomicity of writing to `orders` + `outbox` guarantees: **if the order was created, the event will be published** (eventually).

---

### Relay: Polling vs CDC

**Polling** — the relay periodically queries the outbox:

```
SELECT * FROM outbox
WHERE published_at IS NULL
ORDER BY created_at
LIMIT 100;
```

Pros: simple to implement; no additional infrastructure needed.

Cons: latency (depends on the polling interval); load on the DB.

**CDC (Change Data Capture)** — the relay subscribes to the PostgreSQL WAL (Write-Ahead Log) via Debezium or pglogical. Events are received immediately after commit.

```
PostgreSQL WAL → Debezium → Kafka Connect → Kafka topic
```

Pros: near-realtime; no additional load on the main table.

Cons: infrastructure complexity; Debezium as an additional component.

| | Polling | CDC (Debezium) |
|---|---|---|
| Latency | Seconds | Milliseconds |
| DB load | Regular SELECTs | WAL reads (lighter) |
| Infrastructure | Minimal | Debezium + Kafka Connect |
| Ordering | By created_at | Exact order from WAL |
| Setup | Simple | More complex |

---

### Outbox Table Structure

```sql
CREATE TABLE outbox (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregate_type  VARCHAR(100) NOT NULL,  -- 'Order', 'Payment', ...
    aggregate_id    VARCHAR(100) NOT NULL,  -- aggregate ID
    event_type      VARCHAR(100) NOT NULL,  -- 'OrderCreated', 'PaymentReserved', ...
    payload         JSONB        NOT NULL,  -- event data
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    published_at    TIMESTAMPTZ,            -- NULL = not yet published
    attempts        INT          NOT NULL DEFAULT 0,
    last_error      TEXT                    -- for debugging
);

CREATE INDEX idx_outbox_unpublished
    ON outbox (created_at)
    WHERE published_at IS NULL;
```

---

### SQL Example: Inserting an Order and an Event in a Single Transaction

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

### Go Example: Order + Outbox in a Single Transaction

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

// CreateOrder atomically creates an order and writes an event to the outbox
func (r *OrderRepository) CreateOrder(ctx context.Context, order Order) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback() // no-op if tx.Commit() was already called

	// 1. Save the order
	_, err = tx.ExecContext(ctx,
		`INSERT INTO orders (id, user_id, amount, status, created_at)
		 VALUES ($1, $2, $3, $4, $5)`,
		order.ID, order.UserID, order.Amount, order.Status, order.CreatedAt,
	)
	if err != nil {
		return fmt.Errorf("insert order: %w", err)
	}

	// 2. Prepare the event payload
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

	// 3. Save the event to outbox IN THE SAME transaction
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

	// 4. Commit — atomically saves both the order and the event
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}

	return nil
}

// OutboxRelay reads the outbox and publishes events (polling approach)
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
		 FOR UPDATE SKIP LOCKED`, // SKIP LOCKED — for multiple relay workers
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
			// Increment the attempt counter but don't block other events
			r.db.ExecContext(ctx,
				`UPDATE outbox SET attempts = attempts + 1, last_error = $1 WHERE id = $2`,
				err.Error(), id,
			)
			continue
		}

		// Mark as published
		r.db.ExecContext(ctx,
			`UPDATE outbox SET published_at = NOW() WHERE id = $1`,
			id,
		)
	}

	return rows.Err()
}
```

---

### Inbox Pattern: Deduplication on the Consumer Side

The Outbox guarantees **at-least-once delivery** — the same event may arrive twice. Consumers must be prepared for duplicates.

**Inbox table** — stores IDs of already-processed events:

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

	// Check if this event was already processed
	var exists bool
	tx.QueryRowContext(ctx,
		`SELECT EXISTS(SELECT 1 FROM inbox WHERE event_id = $1)`,
		eventID,
	).Scan(&exists)

	if exists {
		return nil // duplicate — skip
	}

	// Process the event
	if err := h.processOrderCreated(ctx, tx, payload); err != nil {
		return err
	}

	// Write to inbox — atomically with the processing
	tx.ExecContext(ctx,
		`INSERT INTO inbox (event_id, event_type) VALUES ($1, $2)`,
		eventID, "OrderCreated",
	)

	return tx.Commit()
}
```

Inbox records can be deleted after a certain retention period (e.g., 7 days), if redelivery beyond that period is not possible.

---

## 4. CQRS (Command Query Responsibility Segregation)

### The Idea

**CQS** (Bertrand Meyer, 1988): a method either executes a command (changes state) or returns data — but not both at the same time.

**CQRS** — applying this principle at the architecture level: separate models for **writes** (Command) and **reads** (Query).

```
Traditional approach:
┌────────────────────────────────────┐
│  One Order model for everything:   │
│  CREATE, UPDATE, DELETE, SELECT    │
└────────────────────────────────────┘

CQRS:
┌──────────────────┐    ┌──────────────────┐
│  Write Model     │    │  Read Model      │
│  (Command side)  │    │  (Query side)    │
│                  │    │                  │
│  Validation      │    │  Denormalized    │
│  Business rules  │    │  data            │
│  Transactions    │    │  Optimized       │
│  Normalized      │    │  for reads       │
└──────────────────┘    └──────────────────┘
```

---

### Simple CQRS: One DB, Separate Models in Code

You don't need two separate data stores right away. Start by separating the code:

```go
// Command side: strict model with business rules
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

// Query side: flat, read-optimized structure
type OrderListView struct {
	ID         string    `json:"id"`
	UserName   string    `json:"user_name"`
	TotalItems int       `json:"total_items"`
	Total      float64   `json:"total"`
	Status     string    `json:"status"`
	CreatedAt  time.Time `json:"created_at"`
}

// Specialized query — returns exactly what the UI needs
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

### Full CQRS: Separate Data Stores

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

**Example store combinations:**

| Write Store | Read Store | When |
|---|---|---|
| PostgreSQL | PostgreSQL (read replica) | Base case |
| PostgreSQL | Elasticsearch | Full-text search |
| PostgreSQL | Redis | Very hot data, counters |
| PostgreSQL | MongoDB | Flexible schema for display |
| Event Store | Materialized views | Event Sourcing + CQRS |

---

### Syncing the Read Model via Events

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

**Eventual consistency**: there is a delay between writing a command and updating the read model. The client may see stale data for a short time. This is a trade-off that must be consciously accepted.

---

### When CQRS Is Needed (and When It Is Not)

**Needed when:**
- Read and write loads differ drastically (100:1, 1000:1)
- Different clients need different views of the same data
- Full-text search (Elasticsearch) is needed over transactional data
- The team is prepared for eventual consistency
- Event Sourcing is in use (CQRS is the natural complement)

**Not needed when:**
- Simple CRUD without complex queries
- Small team with no resources to maintain two models
- The latency of eventual consistency is unacceptable for the business
- PostgreSQL with proper indexes handles all the load

> CQRS is a tool, not a goal. Most systems do not need full CQRS.

---

### Go Example: Command Handler + Event → Projection

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

// OrderCommandHandler processes commands and publishes events
type OrderCommandHandler struct {
	repo      WriteOrderRepository
	publisher DomainEventPublisher
}

func (h *OrderCommandHandler) HandleCreateOrder(
	ctx context.Context, cmd CreateOrderCommand,
) error {
	// Business logic on the write side
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

	// Publish domain event
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

// OrderSummaryView — denormalized view for the order list
type OrderSummaryView struct {
	OrderID    string    `json:"order_id"`
	UserID     string    `json:"user_id"`
	TotalItems int       `json:"total_items"`
	Total      float64   `json:"total"`
	Status     string    `json:"status"`
	TrackingID string    `json:"tracking_id,omitempty"`
	CreatedAt  time.Time `json:"created_at"`
}

// OrderProjection listens to events and updates the read model
type OrderProjection struct {
	readDB ReadOrderRepository
}

// OnOrderCreated updates the read model when an order is created
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

// OnOrderShipped updates the status and tracking in the read model
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
	// Read from the optimized read store
	return s.readDB.FindByUserID(ctx, userID)
}

func (s *OrderQueryService) SearchOrders(
	ctx context.Context, query string,
) ([]OrderSummaryView, error) {
	// Full-text search — only possible on the read side (Elasticsearch)
	return s.readDB.FullTextSearch(ctx, query)
}
```

---

## 5. Event Sourcing

### The Idea

Instead of storing the **current state** of an object — store the **sequence of events** that led to it.

```
Traditional approach:
┌──────────────────────────────────────────┐
│ accounts table:                          │
│ id=123, balance=750, status=active       │ ← only the final state
└──────────────────────────────────────────┘

Event Sourcing:
┌──────────────────────────────────────────┐
│ events table (append-only):              │
│ 1. AccountCreated  {balance: 0}          │
│ 2. MoneyDeposited  {amount: 1000}        │
│ 3. MoneyWithdrawn  {amount: 200}         │
│ 4. MoneyDeposited  {amount: 500}         │
│ 5. MoneyWithdrawn  {amount: 550}         │
│                            balance = 750  │ ← computed by replay
└──────────────────────────────────────────┘
```

Current state = result of applying all events in order (**replay**).

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
│  INSERT only, never UPDATE/DELETE                                │
└──────────────────────────────────────────────────────────────────┘
```

---

### Snapshots: Optimization for Long Event Chains

If an aggregate has 10,000 events, replaying on every request is expensive.

**Snapshot** — a saved state of the aggregate at a specific version:

```
┌─────────────────────────────────────────────────┐
│ events: v1...v1000                              │
│ snapshot at v1000: {balance: 5000}              │ ← save the state
│ events: v1001...v1050                           │
│                                                 │
│ Replay = snapshot(v1000) + events v1001..v1050  │
│          instead of full replay v1..v1050       │
└─────────────────────────────────────────────────┘
```

Strategy: take a snapshot every N events (e.g., 100 or 500).

---

### Pros and Cons

**Pros:**
- **Full history** — you can answer "what happened to the account 6 months ago"
- **Audit trail** out of the box — no separate audit log needed
- **Time travel** — reproduce state at any point in time
- **Debug** — reproduce a bug by replaying events
- **Event-driven** — events already exist; projections can be built on top
- **Decoupling** — other systems subscribe to events

**Cons:**
- **Complexity** — no standard ORM; a custom event store is needed
- **Schema evolution** — how to handle old events when the schema changes?
- **Eventual consistency** — read models are updated asynchronously
- **Query complexity** — you cannot do `SELECT * WHERE balance > 1000` directly
- **Snapshot management** — both events and snapshots must be maintained

---

### Event Sourcing + CQRS

Event Sourcing and CQRS are a classic pair. Events from the Event Store are used to update read models:

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

### Go Example: Event Store for a Bank Account

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
	// Unsaved events that appeared in the current session
	uncommittedEvents []StoredEvent
}

// Replay restores the account state from events
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
	// Append adds events. expectedVersion is for optimistic concurrency.
	Append(ctx context.Context, aggregateID string, events []StoredEvent, expectedVersion int) error
	// Load returns all events for an aggregate, starting from fromVersion.
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

	// expectedVersion = version before current changes (optimistic concurrency)
	expectedVersion := account.Version - len(account.uncommittedEvents)

	err := r.store.Append(ctx, account.ID, account.uncommittedEvents, expectedVersion)
	if err != nil {
		return err
	}

	account.uncommittedEvents = nil
	return nil
}

// ─── Usage Example ────────────────────────────────────────────────────────────

func ExampleUsage(ctx context.Context, repo *AccountRepository) {
	// Create a new account
	account, _ := NewAccount("acc-001", "user-123", "USD")
	account.Deposit(1000.00, "initial-deposit")
	repo.Save(ctx, account)

	// Load and modify
	acc, _ := repo.Load(ctx, "acc-001")
	acc.Deposit(500.00, "salary-march")
	acc.Withdraw(200.00, "rent-payment")
	acc.Withdraw(550.00, "car-payment")
	repo.Save(ctx, acc)

	// Load again — state restored from events
	acc2, _ := repo.Load(ctx, "acc-001")
	fmt.Printf("Balance: %.2f\n", acc2.Balance) // 750.00
}
```

---

### Event Schema Evolution

When an event schema changes, old events must continue to work. Strategies:

```
1. Upcasting: transform old events on read
   v1: {"amount": 100}
   v2: {"amount": 100, "currency": "USD"} ← upcast adds default

2. Weak schema (JSON): add fields, don't remove old ones
   New code reads new fields; old code ignores unknown ones.

3. Versioned events: different types for different versions
   MoneyDeposited_v1, MoneyDeposited_v2
   (inflates code but is explicit)
```

---

## 6. Distributed Consensus

### Why Consensus Is Needed

Distributed consensus — agreement among multiple nodes on a single value, even in the presence of failures.

**Where it is used:**
- **Leader election**: who is the current primary in the cluster?
- **Distributed locks**: only one worker processes a task
- **Configuration management**: all nodes see the same configuration
- **Distributed counters**: atomic counters

Without consensus: split-brain, two leaders, data loss.

---

### Raft: Simplified Explanation

Raft was designed as a more understandable alternative to Paxos. Three node roles:

```
Leader   — accepts all writes, replicates the log to Followers
Follower — passive node, replicates the log from the Leader
Candidate — a node campaigning to become the leader
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

**Term** — a monotonically increasing number. Each new election increments the term.

**Rules:**
- A node votes for a candidate only if the candidate's log is at least as up-to-date as its own
- A node votes for only one candidate per term
- Liveness: if the leader dies, the next election starts after a random timeout

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

The leader commits a write only when a **majority** of nodes (quorum) have acknowledged receipt.

**Safety**: two leaders cannot both achieve quorum in the same term → no split-brain.

---

### Paxos

Paxos (Lamport, 1989) is the first theoretically grounded consensus algorithm. More complex to understand and implement:

- Three phases: Prepare → Promise → Accept → Accepted
- Multi-Paxos for log replication adds even more complexity
- In practice, Raft or its variants (Zab for ZooKeeper) are used everywhere

Know that Paxos exists. For production — use Raft-based systems.

---

### Where Consensus Is Used

| System | Algorithm | Purpose |
|---|---|---|
| etcd | Raft | Kubernetes state, distributed locks |
| ZooKeeper | ZAB (ZooKeeper Atomic Broadcast) | Coordination, leader election |
| Consul | Raft | Service discovery, KV store |
| CockroachDB | Raft per range | Distributed SQL |
| MongoDB | Raft-like | Replica set elections |

---

### Distributed Locks: Problems with Naïve Implementations

**Naïve lock via Redis:**

```go
// BAD: not resilient to the lock holder crashing
ok, _ := redis.SetNX("lock:resource", "1", 30*time.Second)
if ok {
    defer redis.Del("lock:resource") // what if the process dies before Del?
    doWork()
}
```

**Problems:**
1. The process holds the lock and crashes. Who releases the lock?
2. TTL expired, but the process is still running. Two processes simultaneously in the critical section.
3. GC pause — the process thinks it holds the lock, but TTL expired during the pause.

**Fencing Token** — solution for the lock-after-TTL problem:

```
Process 1 acquires lock: token=33
Process 2 acquires lock: token=34  ← Process 1's lock expired

Process 1 attempts to write with token=33
Storage sees: 33 < current token 34 → REJECT

Process 2 writes with token=34 → OK
```

Each lock has a monotonically increasing token. Storage rejects operations with a stale token.

---

### Go Example: Distributed Lock via etcd with Lease

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

	// Session creates a lease with TTL. If the holder dies — the lease expires,
	// and the lock is automatically released.
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

// Lock acquires the lock. Blocks until acquired or ctx is cancelled.
func (l *DistributedLock) Lock(ctx context.Context) error {
	return l.mutex.Lock(ctx)
}

// TryLock attempts to acquire the lock without waiting.
func (l *DistributedLock) TryLock(ctx context.Context) error {
	return l.mutex.TryLock(ctx)
}

// Unlock releases the lock.
func (l *DistributedLock) Unlock(ctx context.Context) error {
	return l.mutex.Unlock(ctx)
}

// Close closes the session (lease) and the connection.
func (l *DistributedLock) Close() error {
	l.session.Close()
	return l.client.Close()
}

// WithLock — helper for running work under a lock.
func WithLock(ctx context.Context, lock *DistributedLock, fn func(ctx context.Context) error) error {
	if err := lock.Lock(ctx); err != nil {
		return fmt.Errorf("acquire lock: %w", err)
	}
	defer lock.Unlock(ctx)

	return fn(ctx)
}

// Usage example: only one worker processes a job
func ProcessJob(ctx context.Context, jobID string, endpoints []string) error {
	lock, err := NewDistributedLock(endpoints, "job:"+jobID, 30)
	if err != nil {
		return err
	}
	defer lock.Close()

	return WithLock(ctx, lock, func(ctx context.Context) error {
		fmt.Printf("processing job %s\n", jobID)
		// ... work
		return nil
	})
}
```

**How etcd Lease works:**
- `Session` creates a lease with TTL on etcd
- While the process is alive, the session automatically renews the lease (keepalive)
- If the process crashes — keepalive stops, the lease expires, the lock is released

---

## 7. Idempotency and Deduplication

### Why Messages Arrive Twice

In distributed systems, networks are unreliable. Standard delivery guarantees:

```
At-most-once:  a message may be lost, but never duplicated
At-least-once: a message will be delivered, but duplicates are possible ← most common
Exactly-once:  no losses, no duplicates ← expensive, requires coordination
```

**Duplicate scenarios with at-least-once:**

```
Producer             Network/Broker        Consumer
   │                      │                    │
   │── send message ─────>│                    │
   │                      │── deliver ─────── >│
   │                      │<── ACK ─────────── │
   │<── timeout ──────────│                    │
   │                      │                    │
   │── retry message ────>│ ← duplicate!       │
   │                      │── deliver ─────── >│ ← consumer receives it twice
```

---

### Idempotency Key

An **idempotency key** is a unique operation ID generated on the **client side**. The same key on a repeated request returns the same result without executing the operation again.

```
POST /api/orders
X-Idempotency-Key: 550e8400-e29b-41d4-a716-446655440000

{
  "user_id": "user-123",
  "amount": 99.99
}
```

The server on a repeat request with the same key:
- If already processed → returns the saved response
- If in progress → waits or returns 409 Conflict

**Server-side storage:**

```sql
CREATE TABLE idempotency_keys (
    key         UUID PRIMARY KEY,
    request_hash VARCHAR(64),    -- hash of input data for validation
    response     JSONB,          -- saved response
    status       VARCHAR(20),    -- 'processing', 'completed', 'failed'
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at   TIMESTAMPTZ NOT NULL  -- after this, the key can be deleted
);
```

---

### Exactly-once = At-least-once + Idempotent Consumer

In practice, exactly-once semantics are achieved not through broker magic, but through:
1. The broker guarantees at-least-once (Kafka, RabbitMQ)
2. The consumer is idempotent — reprocessing does not change the result

```
Kafka (at-least-once)  →  Idempotent Consumer  =  Exactly-once effect
```

Kafka Transactions (Kafka >= 0.11) provide exactly-once within Kafka-to-Kafka, but not for external systems.

---

### Go Example: Idempotent Handler with Redis

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

// Execute runs fn exactly once for a given idempotencyKey.
// On repeat calls, returns the saved result.
func (m *IdempotencyMiddleware) Execute(
	ctx context.Context,
	idempotencyKey string,
	fn func(ctx context.Context) (interface{}, error),
) (interface{}, error) {
	redisKey := "idempotency:" + idempotencyKey

	// 1. Check: already executed?
	cached, err := m.redis.Get(ctx, redisKey).Bytes()
	if err == nil {
		// Already executed — return the saved result
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

	// 2. Acquire slot (lock) to prevent concurrent duplicates
	lockKey := "idempotency:lock:" + idempotencyKey
	lockAcquired, err := m.redis.SetNX(ctx, lockKey, "1", 30*time.Second).Result()
	if err != nil {
		return nil, fmt.Errorf("redis setnx: %w", err)
	}
	if !lockAcquired {
		// Another worker is already processing this key
		return nil, fmt.Errorf("request with key %s is already being processed", idempotencyKey)
	}
	defer m.redis.Del(ctx, lockKey)

	// 3. Execute the operation
	result, fnErr := fn(ctx)

	// 4. Save the result (even on error — so a retry returns the same response)
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

// ─── Example: Idempotent Payment Handler ──────────────────────────────────────

type PaymentRequest struct {
	UserID         string  `json:"user_id"`
	Amount         float64 `json:"amount"`
	IdempotencyKey string  `json:"idempotency_key"`
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

**Generating the idempotency key on the client:**

```go
import "github.com/google/uuid"

// Deterministic key: the same key for the same business operation
func generateIdempotencyKey(userID, orderReference string) string {
	// UUID v5 — deterministic UUID from namespace + data
	namespace := uuid.MustParse("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
	return uuid.NewSHA1(namespace, []byte(userID+":"+orderReference)).String()
}

// Or simply a random UUID for each attempt
func generateRandomKey() string {
	return uuid.New().String()
}
```

---

## 8. Bulkhead, Backpressure, and Resilience Patterns

### Bulkhead: Resource Isolation

Bulkhead (a ship's watertight partition) — isolate resources by component so that a failure in one does not sink the entire application.

**Problem without bulkhead:**

```
One HTTP pool for all downstream services:

PaymentService   → slow!
InventoryService → slow!
NotificationSvc  → fast

→ PaymentService consumed all 100 HTTP pool slots
→ InventoryService cannot get a slot
→ NotificationService cannot either (even though it is fast)
→ The entire application degrades
```

**With bulkhead — separate pools:**

```
PaymentService   → pool of 40 slots   ← may degrade
InventoryService → pool of 40 slots   ← isolated
NotificationSvc  → pool of 20 slots   ← works independently
```

---

### Backpressure

Backpressure is a mechanism that allows a **consumer to slow down the producer** when it cannot keep up.

```
Without backpressure:
Producer ──[1000 req/s]──> Consumer [processes 100 req/s]
                            ↑ queue grows → OOM → crash

With backpressure:
Producer ──[100 req/s]──>  Consumer [processes 100 req/s]
          ↑ producer slowed down by a signal from the consumer
```

**Strategies:**
- **Blocking**: producer blocks when the queue is full (sync backpressure)
- **Drop**: discard new tasks when the buffer is full (load shedding)
- **Rate limiting**: limit the incoming flow at the system boundary

---

### Timeout + Deadline Propagation

In Go, context is the right tool for propagating deadlines through a call chain.

```go
// Incoming HTTP request: total deadline of 5 seconds for all processing
ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
defer cancel()

// Call to PaymentService: no more than 2 seconds
payCtx, payCancel := context.WithTimeout(ctx, 2*time.Second)
defer payCancel()
paymentID, err := paymentSvc.Reserve(payCtx, ...)

// Call to InventoryService: no more than 1 second
invCtx, invCancel := context.WithTimeout(ctx, 1*time.Second)
defer invCancel()
err = inventorySvc.Reserve(invCtx, ...)
```

**Deadline propagation via gRPC**: a context with a deadline is automatically forwarded to all downstream calls. Make sure middleware layers do **not ignore** the passed context.

---

### Go Example: Bulkhead with Semaphore (Buffered Channel)

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

// Bulkhead limits concurrent calls to a downstream service
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

// Execute runs fn under the protection of the bulkhead.
// If the limit is reached — returns ErrBulkheadFull without waiting.
func (b *Bulkhead) Execute(ctx context.Context, fn func() error) error {
	select {
	case b.semaphore <- struct{}{}: // acquire slot
		defer func() { <-b.semaphore }() // release slot
		return fn()

	default:
		// No free slots — reject immediately
		return fmt.Errorf("%s: %w", b.name, ErrBulkheadFull)
	}
}

// ExecuteWithWait runs fn, waiting for a free slot until ctx is cancelled.
func (b *Bulkhead) ExecuteWithWait(ctx context.Context, fn func() error) error {
	select {
	case b.semaphore <- struct{}{}:
		defer func() { <-b.semaphore }()
		return fn()

	case <-ctx.Done():
		return fmt.Errorf("%s wait: %w", b.name, ctx.Err())
	}
}

// Metrics for monitoring
func (b *Bulkhead) ActiveCount() int {
	return len(b.semaphore)
}

func (b *Bulkhead) Capacity() int {
	return cap(b.semaphore)
}

// ─── Example: Service with Isolated Pools ─────────────────────────────────────

type OrderProcessor struct {
	paymentBulkhead      *Bulkhead
	inventoryBulkhead    *Bulkhead
	notificationBulkhead *Bulkhead

	httpClient *http.Client
}

func NewOrderProcessor() *OrderProcessor {
	return &OrderProcessor{
		// Each downstream gets its own isolated pool
		paymentBulkhead:      NewBulkhead("payment-svc", 40),
		inventoryBulkhead:    NewBulkhead("inventory-svc", 40),
		notificationBulkhead: NewBulkhead("notification-svc", 20),
		httpClient:           &http.Client{Timeout: 10 * time.Second},
	}
}

func (p *OrderProcessor) ProcessOrder(ctx context.Context, orderID string) error {
	// Call PaymentService — under its own bulkhead
	if err := p.paymentBulkhead.Execute(ctx, func() error {
		return p.callPaymentService(ctx, orderID)
	}); err != nil {
		if errors.Is(err, ErrBulkheadFull) {
			// Payment pool is overloaded — apply degrade strategy
			return fmt.Errorf("payment service overloaded, try again later: %w", err)
		}
		return err
	}

	// Call InventoryService — under its own bulkhead
	if err := p.inventoryBulkhead.Execute(ctx, func() error {
		return p.callInventoryService(ctx, orderID)
	}); err != nil {
		if errors.Is(err, ErrBulkheadFull) {
			return fmt.Errorf("inventory service overloaded: %w", err)
		}
		return err
	}

	// Notification — fire-and-forget with a separate pool
	// Even if the notification pool is full — the order is already processed
	go p.notificationBulkhead.Execute(context.Background(), func() error {
		return p.sendNotification(context.Background(), orderID)
	})

	return nil
}

func (p *OrderProcessor) callPaymentService(ctx context.Context, orderID string) error {
	// Add a timeout for the specific downstream call
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

// ─── Backpressure via bounded channel ──────────────────────────────────────

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

// Submit adds a task to the queue.
// If the queue is full — ctx.Done() or immediate rejection.
func (q *WorkQueue) Submit(ctx context.Context, task func()) error {
	select {
	case q.tasks <- task:
		return nil
	case <-ctx.Done():
		return fmt.Errorf("queue submit: %w", ctx.Err())
	default:
		// Non-blocking: if buffer is full — load shedding
		return errors.New("work queue is full: load shedding")
	}
}
```

---

### Pattern Summary Table

| Pattern | Problem | Solution | Trade-off |
|---|---|---|---|
| **2PC** | Atomicity across services | Coordinator + prepare/commit | Blocking, slow |
| **Saga (Orchestration)** | Long transactions | Compensations via central coordinator | Coordinator = SPOF |
| **Saga (Choreography)** | Coupling between services | Event-driven compensations | Complex debugging |
| **Transactional Outbox** | Dual write | Event in the same transaction | Relay as extra component |
| **CQRS** | Different read/write loads | Separate models | Eventual consistency |
| **Event Sourcing** | No history of changes | Append-only event log | Complexity, schema evolution |
| **Distributed Lock** | Race conditions in cluster | etcd lease + fencing token | Additional service |
| **Idempotency Key** | Duplicate requests | Deduplication by key | Storage for keys |
| **Bulkhead** | Cascading failures | Isolated pools | Sizing configuration |
| **Backpressure** | Consumer cannot keep up | Bounded queues, rate limit | Latency or rejections |

---

## What's Next

- **Module 08**: Messaging Patterns — Kafka, RabbitMQ, stream processing
- **Module 09**: Observability — metrics, tracing, logging in distributed systems
- **Module 10**: Data Consistency Patterns — CRDTs, vector clocks, conflict resolution

---

## Further Reading

- [Designing Data-Intensive Applications](https://dataintensive.net/) — Kleppmann, Chapters 7, 9, 11
- [Saga Pattern](https://microservices.io/patterns/data/saga.html) — microservices.io
- [Transactional Outbox](https://microservices.io/patterns/data/transactional-outbox.html) — microservices.io
- [Raft Consensus Algorithm](https://raft.github.io/) — raft.github.io (with visualization)
- [Martin Fowler: CQRS](https://martinfowler.com/bliki/CQRS.html)
- [Martin Fowler: Event Sourcing](https://martinfowler.com/eaaDev/EventSourcing.html)
- [The Chubby Lock Service](https://research.google/pubs/pub27897/) — Google Research (on distributed locks)
