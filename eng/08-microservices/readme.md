# Module 08: Microservices

> **Audience**: Backend developers who have heard "break the monolith into microservices" and want to understand when it makes sense — and when it's a trap.
>
> **What's inside**: Monolith vs microservices, design principles, communication, API design, Service Mesh, distributed transactions, data management, deployment, testing.

---

## Table of Contents

1. [Monolith → Microservices: When and Why](#1-monolith--microservices-when-and-why)
2. [Microservice Design Principles](#2-microservice-design-principles)
3. [Inter-Service Communication](#3-inter-service-communication)
4. [API Design for Microservices](#4-api-design-for-microservices)
5. [Service Mesh](#5-service-mesh)
6. [Distributed Transactions in Microservices](#6-distributed-transactions-in-microservices)
7. [Data Management in Microservices](#7-data-management-in-microservices)
8. [Deployment and DevOps](#8-deployment-and-devops)
9. [Testing Microservices](#9-testing-microservices)

---

## 1. Monolith → Microservices: When and Why

### Monolith

The entire application is deployed as a single process. One repository, one codebase, one deployment.

```
┌─────────────────────────────────────────────────────┐
│                   MONOLITH PROCESS                  │
│                                                     │
│  ┌───────────┐  ┌───────────┐  ┌───────────────┐   │
│  │   Auth    │  │  Orders   │  │   Payments    │   │
│  │  Module   │  │  Module   │  │    Module     │   │
│  └─────┬─────┘  └─────┬─────┘  └──────┬────────┘   │
│        │              │               │             │
│  ┌─────▼──────────────▼───────────────▼────────┐    │
│  │            Shared Database (PostgreSQL)      │    │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

**Monolith advantages:**

- **Development simplicity**: no network overhead between modules; a function call instead of an HTTP request.
- **Debugging simplicity**: one process, one call stack, one log stream. `grep` through the logs — the entire chain is right there.
- **Atomic transactions**: `BEGIN` / `COMMIT` work across the entire flow. No saga, no compensating transactions.
- **Simple deployment**: one artifact, one CI/CD pipeline, one server (or a few behind a load balancer).
- **Lower upfront cost**: no infrastructure overhead (service discovery, message broker, distributed tracing).

**Monolith disadvantages at scale:**

- **Scaling**: individual components cannot be scaled independently. If the reporting module is burning CPU — you scale the entire monolith, including the API that's handling load just fine.
- **Deployment**: a change in one module requires deploying the entire application. One bug in a low-priority module causes downtime for everyone.
- **Coupling**: modules start knowing about each other through direct calls and shared tables. Over time, boundaries erode.
- **Technology stack**: the whole team uses the same language, the same framework version, the same Go version.
- **Development speed**: 50+ developers in one repository = merge conflicts, slow CI pipelines, coordination overhead.

---

### Modular Monolith

An intermediate option between a monolith and microservices. A single deployment, but with clear boundaries between modules inside the codebase.

```
┌─────────────────────────────────────────────────────────────┐
│                   MODULAR MONOLITH                          │
│                                                             │
│  ┌─────────────────┐    ┌─────────────────┐                │
│  │  Orders Module  │    │ Payments Module │                │
│  │                 │    │                 │                │
│  │ - internal pkg  │    │ - internal pkg  │                │
│  │ - own DB schema │    │ - own DB schema │                │
│  │ - public API    │───>│ - public API    │                │
│  │   (interface)   │    │   (interface)   │                │
│  └─────────────────┘    └─────────────────┘                │
│                                                             │
│  Rule: modules communicate ONLY through public             │
│  interfaces, never directly through the DB.                │
└─────────────────────────────────────────────────────────────┘
```

**When a modular monolith is sufficient:**

- Team size < 20 people.
- The product is still searching for product-market fit.
- Different parts of the system have similar SLAs and scaling requirements.
- There are no strict requirements for independently deploying different parts.

A modular monolith is an honest architectural choice, not a compromise. Many mature products deliberately remain on this architecture.

---

### Microservices: When You Actually Need Them

Microservices are an organizational solution packaged in a technical form. Their true value is granting teams autonomy.

**Signs it's time:**

1. **Team > 10–15 developers**, and scaling the monolith introduces significant coordination overhead.
2. **Different parts of the system evolve at different rates**: Checkout changes 10 times a day, Invoicing — once a quarter.
3. **Different SLAs**: Real-time notifications require latency < 100ms, while reports can wait 30 seconds.
4. **Different scaling requirements**: Image Processing needs GPUs, everything else does not.
5. **Different technology stacks**: ML pipeline in Python, main API in Go, legacy integration in Java.
6. **Compliance and data isolation**: PCI DSS requires card data to be isolated from the rest of the system.

**Rule**: if the team is < 10 people and the product is at an early stage — go with a monolith. Microservices increase operational complexity by 3–5×. That cost must pay for itself.

> Netflix, Amazon, and Uber moved to microservices after hundreds of engineers and years of running a monolith. Startups that begin with microservices usually pay too high a price too early.

---

### Strangler Fig Pattern: Incremental Migration

Strangler Fig is a migration pattern named after a tree that gradually envelops and displaces its host tree.

**Step 1**: Place an API Gateway or Facade in front of the monolith. All traffic flows through it.

```
Client → API Gateway → Monolith (100% of traffic)
```

**Step 2**: Extract the first service (start with the least coupled module).

```
Client → API Gateway → /payments/* → PaymentService (new)
                    → /*          → Monolith (everything else)
```

**Step 3**: Gradually migrate functionality, routing traffic from the monolith to new services.

```
Client → API Gateway → /payments/* → PaymentService
                    → /orders/*   → OrderService
                    → /auth/*     → AuthService
                    → /*          → Monolith (legacy, shrinking)
```

**Step 4**: The monolith becomes empty — remove it.

**Key principles during migration:**
- Never extract a service and rewrite business logic simultaneously. First "cut it out" as-is, then refactor.
- Start with leaf services — those that few others depend on.
- Synchronize data via dual-write or Change Data Capture (CDC) during the transition period.

---

### Comparison Table

| Criterion | Monolith | Modular Monolith | Microservices |
|---|---|---|---|
| **Development complexity** | Low | Medium | High |
| **Deployment complexity** | Low | Low | High |
| **Scaling** | Vertical (entire app) | Vertical (entire app) | Horizontal (per service) |
| **Fault tolerance** | Everything fails | Everything fails | Partial degradation |
| **Team size** | 1–10 | 5–20 | 15+ |
| **Latency** | Minimal (in-process) | Minimal (in-process) | Higher (network) |
| **Transactions** | ACID | ACID | Saga / Eventual consistency |
| **Debugging** | Simple | Simple | Complex (distributed tracing) |
| **Technologies** | Single stack | Single stack | Multiple stacks |
| **Infrastructure cost** | Low | Low | High |
| **Time to market (early stage)** | Fast | Fast | Slow |

---

## 2. Microservice Design Principles

### Single Responsibility and Bounded Context

One microservice = one Bounded Context from Domain-Driven Design (DDD).

**Bounded Context** is a boundary within which terms and models have an unambiguous meaning. The word "Order" in the Ordering context means one thing; in the Fulfillment context — something different.

```
┌──────────────────────┐    ┌──────────────────────┐
│   Ordering Context   │    │  Fulfillment Context  │
│                      │    │                       │
│  Order:              │    │  Order:               │
│   - items            │    │   - warehouse_id      │
│   - total_price      │    │   - picker_id         │
│   - payment_method   │    │   - picking_status    │
│   - promo_code       │    │   - shipping_label    │
└──────────────────────┘    └──────────────────────┘
```

The same "Order" object in two contexts represents two different services with different data models, even if both are called Order.

**Signs of a correctly defined service:**
- Its responsibility can be described in one sentence without the word "and".
- The service is deployed and scaled independently.
- The team owning a service does not need to coordinate with other teams to deploy.

**Signs of an incorrectly defined service:**
- "UserService" handles registration, authentication, profile, settings, notifications, and billing.
- Any change in one service requires a synchronous change in another.
- Services form chains of synchronous calls: A → B → C → D.

---

### Loose Coupling / High Cohesion

**Loose Coupling**: services know as little about each other as possible. They interact through stable contracts (APIs, events), not through internal implementation details.

**High Cohesion**: everything related lives together inside a service. Business logic, data, API — all in one place.

Coupling violation: `OrderService` reads directly from the `users` table in `UserService`'s database. Now any change to the `users` schema breaks `OrderService`.

Correct approach: `OrderService` requests the needed data via `UserService`'s API, or subscribes to events.

---

### Database per Service

Each service owns its data and is the only one with direct access to it.

```
┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
│  OrderService    │    │  PaymentService  │    │  UserService     │
│                  │    │                  │    │                  │
│  ┌────────────┐  │    │  ┌────────────┐  │    │  ┌────────────┐  │
│  │ orders_db  │  │    │  │payments_db │  │    │  │  users_db  │  │
│  │ PostgreSQL │  │    │  │  MySQL     │  │    │  │  MongoDB   │  │
│  └────────────┘  │    │  └────────────┘  │    │  └────────────┘  │
└──────────────────┘    └──────────────────┘    └──────────────────┘
          │                      │                       │
          └──────────────────────┴───────────────────────┘
                Communication ONLY via API / Events
```

Even if physically it's a single PostgreSQL instance — each service has its own schema, and other services have no direct access to it.

---

### API as a Contract

A service's API is a public contract. Breaking the contract = breaking change = broken clients.

**Backward compatibility**: new clients work with older API versions.
**Forward compatibility**: old clients work with newer API versions.

Rules for safe changes:
- Adding a new field to a response — safe.
- Adding a new optional field to a request — safe.
- Removing a field — breaking change.
- Renaming a field — breaking change.
- Changing a field's type — breaking change.

---

### Design for Failure

Every network call can fail. The network is unreliable. Services restart. A timeout is the norm, not an exception.

**Rule**: write code as if any call to a remote service will return an error.

- Set explicit `timeout` on every HTTP/gRPC call.
- Implement retry with exponential backoff and jitter.
- Use a circuit breaker to avoid waiting for a timeout from a dead service.
- Implement a fallback: what to return when a dependency is unavailable?

---

### Autonomy and Graceful Degradation

A service should be able to perform its core function even when some dependencies are unavailable.

**Example**: `ProductService` returns product cards. It depends on `ReviewService` for ratings.

- Bad: if `ReviewService` is unavailable, `ProductService` returns 500.
- Good: if `ReviewService` is unavailable, `ProductService` returns cards without ratings (cached or null).

Graceful degradation = the user receives a degraded but functional service instead of an error.

---

## 3. Inter-Service Communication

### Synchronous Communication

The client sends a request and **waits** for a response. If the service doesn't respond — the request hangs.

**REST over HTTP/1.1**:
- Standard, universally understood, easy to debug via curl/Postman.
- JSON: human-readable, but slow to parse and large payload size.
- Suitable for external APIs and less latency-sensitive internal calls.

**gRPC over HTTP/2**:
- Binary protocol (Protobuf): faster parsing, smaller payload.
- Multiplexing: multiple requests over a single TCP connection.
- Streaming: server-side, client-side, bidirectional.
- Strong typing via `.proto` files — the contract is embedded in the code.
- Suitable for high-throughput internal calls where performance matters.

**When to use synchronous calls:**
- You need a response right now to continue an operation.
- Example: check a user's balance before a charge.
- Example: get an authentication token.
- Example: validate data before creating an order.

```
Checkout → InventoryService: "Is product X available in quantity 2?"
         ← "Yes, available" (synchronously — cannot proceed without this)
```

---

### Asynchronous Communication

The sender publishes a message to a broker and **does not wait** for a response. The receiver processes it at its own pace.

**Kafka**: high-throughput log-based broker. Messages are stored and can be replayed. Suitable for event streaming and audit trails.

**NATS**: lightweight, fast, sub-millisecond latency. JetStream adds persistence. Suitable for microservices messaging with low latency.

**RabbitMQ**: traditional message queue with routing, exchanges, and dead-letter queues. Suitable for complex message routing.

**When to use asynchronous calls:**
- Fire-and-forget: the operation doesn't require a response right now.
- Long-running tasks: sending an email, generating a report, processing an image.
- Fanout: one event → many consumers.
- Decoupling: the publisher doesn't know who is subscribed.

```
OrderService publishes: OrderCreated { order_id, user_id, items }
    ├── EmailService subscribes → sends confirmation email
    ├── InventoryService subscribes → reserves items
    └── AnalyticsService subscribes → updates metrics
```

---

### Request-Reply via Message Broker

Sometimes a response is needed, but through an asynchronous channel. Pattern: publish a message with a `reply_to` topic/queue, subscribe to it, and wait for the response with a timeout.

```
Client publishes:
  Topic: "payments.process"
  Message: { request_id: "uuid", reply_to: "payments.reply.uuid", payload: {...} }

PaymentService processes and publishes:
  Topic: "payments.reply.uuid"
  Message: { request_id: "uuid", status: "ok", transaction_id: "..." }

Client receives on "payments.reply.uuid" (with timeout 5s)
```

Use when: async processing is needed but with a guaranteed result; the client doesn't want to poll; backpressure is required.

---

### Comparison Table: Sync vs Async

| Criterion | Sync (REST/gRPC) | Async (Kafka/NATS) |
|---|---|---|
| **Latency** | Low (if the service is alive) | Higher (delivery via broker) |
| **Coupling** | High (knows the recipient's address) | Low (only topic/channel) |
| **Reliability** | Lower (failure = error) | Higher (broker buffers messages) |
| **Availability** | Depends on the dependency | Independent of the consumer |
| **Debugging** | Simpler (request-response) | Harder (async flow) |
| **Ordering** | N/A | Possible (Kafka partition) |
| **Replay** | No | Yes (Kafka) |
| **Use case** | Validation, data retrieval | Events, notifications, tasks |

---

## 4. API Design for Microservices

### REST API: Versioning

**URL path versioning** (`/v1/orders`):
- Pros: explicitly visible in logs, cacheable, easy to test.
- Cons: version in the URL looks "unclean" from a strict REST perspective.
- Recommendation: use for public APIs where clients are diverse and update independently.

**Header versioning** (`Accept: application/vnd.api+json;version=1`):
- Pros: cleaner URL.
- Cons: harder to test, not cacheable by default, requires infrastructure support.
- Recommendation: internal APIs where you control the clients.

**Practice**: choose one scheme and stick with it. URL versioning is easier to maintain.

---

### REST API: Pagination

**Offset-based:**
```
GET /v1/orders?offset=100&limit=20
```
Problem: if a new record is inserted during pagination — the user will skip or see a duplicate. With a large offset, the database performs a full scan.

**Cursor-based:**
```
GET /v1/orders?cursor=eyJpZCI6MTAwfQ&limit=20

Response:
{
  "data": [...],
  "next_cursor": "eyJpZCI6MTIwfQ",
  "has_more": true
}
```
A cursor is an encoded state (typically the ID or timestamp of the last element). The database always performs an efficient range scan on an index.

**Cursor is better** for: real-time feeds (news feeds), large datasets (> 10k records), stable pagination.

**Offset is better** for: page-based navigation ("page 5 of 20"), small datasets, when users jump between pages.

---

### REST API: Error Format (RFC 7807)

The Problem Details standard for HTTP APIs. A unified error format — clients don't need to guess the structure.

```json
{
  "type": "https://api.example.com/errors/insufficient-funds",
  "title": "Insufficient Funds",
  "status": 422,
  "detail": "Account balance is 50.00, required 100.00",
  "instance": "/v1/payments/tx-123",
  "extensions": {
    "balance": 50.00,
    "required": 100.00,
    "currency": "USD"
  }
}
```

Fields:
- `type`: URI identifying the error type (machine-readable).
- `title`: human-readable name for the error type.
- `status`: HTTP status code.
- `detail`: specific description for this particular error instance.
- `instance`: URI of the specific request/resource.

---

### gRPC: Proto as a Contract

```protobuf
syntax = "proto3";

package orders.v1;

option go_package = "github.com/example/orders/api/v1;ordersv1";

service OrderService {
  rpc CreateOrder(CreateOrderRequest) returns (CreateOrderResponse);
  rpc GetOrder(GetOrderRequest) returns (Order);
  rpc ListOrders(ListOrdersRequest) returns (stream Order);  // server-streaming
  rpc WatchOrders(WatchOrdersRequest) returns (stream OrderEvent); // server-streaming
}

message CreateOrderRequest {
  string user_id = 1;
  repeated OrderItem items = 2;
  string idempotency_key = 3;  // always add this for mutating operations
}

message OrderItem {
  string product_id = 1;
  int32 quantity = 2;
  // reserved 3;  // if you remove a field — reserve its number
}
```

**Rules for backward/forward compatibility:**
- Adding a new field — safe (old clients ignore it).
- Removing a field — use `reserved` for the number and name.
- Never change the number of an existing field.
- Never change the type of an existing field.
- `optional` / `repeated` can be changed with caution.

**Streaming: when to use:**
- **Server-streaming**: the client requests, the server streams (data export, live event feed).
- **Client-streaming**: the client streams, the server responds with a single response (file upload, batch insert).
- **Bidirectional**: chat, real-time collaboration, live telemetry.

---

### API Gateway: BFF Pattern

Backend for Frontend (BFF) — a separate API Gateway for each client type.

```
                        ┌──────────────┐
Mobile App ────────────>│  Mobile BFF  │
                        └──────┬───────┘
                               │
                        ┌──────┼──────────────────────┐
                        │      │                       │
Web App ───────────────>│  Web BFF                     │──> OrderService
                        │                              │──> UserService
                        │                              │──> ProductService
Admin Panel ───────────>│  Admin BFF                   │──> PaymentService
                        └──────────────────────────────┘
```

**Why BFF instead of a single API Gateway:**
- Mobile needs less data (slow network, small screen) — the BFF aggregates and trims.
- Web needs more data and a richer API.
- Admin needs endpoints that must not be accessible to mobile clients.
- Each frontend team controls its own BFF.

---

### Go Example: REST API with Proper Error Handling, Pagination, and Versioning

```go
package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"time"
)

// --- Error types (RFC 7807) ---

type ProblemDetail struct {
	Type     string `json:"type"`
	Title    string `json:"title"`
	Status   int    `json:"status"`
	Detail   string `json:"detail,omitempty"`
	Instance string `json:"instance,omitempty"`
}

func (p ProblemDetail) Error() string { return p.Detail }

var (
	ErrNotFound = ProblemDetail{
		Type:  "https://api.example.com/errors/not-found",
		Title: "Resource Not Found",
	}
	ErrInvalidInput = ProblemDetail{
		Type:  "https://api.example.com/errors/invalid-input",
		Title: "Invalid Input",
	}
)

func writeProblem(w http.ResponseWriter, r *http.Request, pd ProblemDetail, status int, detail string) {
	pd.Status = status
	pd.Detail = detail
	pd.Instance = r.URL.Path

	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(pd)
}

// --- Pagination ---

type Cursor struct {
	ID        int64     `json:"id"`
	CreatedAt time.Time `json:"created_at"`
}

func encodeCursor(c Cursor) string {
	b, _ := json.Marshal(c)
	return base64.StdEncoding.EncodeToString(b)
}

func decodeCursor(s string) (Cursor, error) {
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return Cursor{}, fmt.Errorf("invalid cursor: %w", err)
	}
	var c Cursor
	if err := json.Unmarshal(b, &c); err != nil {
		return Cursor{}, fmt.Errorf("invalid cursor format: %w", err)
	}
	return c, nil
}

type PagedResponse[T any] struct {
	Data       []T    `json:"data"`
	NextCursor string `json:"next_cursor,omitempty"`
	HasMore    bool   `json:"has_more"`
	Total      *int64 `json:"total,omitempty"` // optional, expensive
}

// --- Order domain ---

type Order struct {
	ID        int64     `json:"id"`
	UserID    string    `json:"user_id"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
}

type OrderRepository interface {
	ListOrders(afterID int64, limit int) ([]Order, error)
	GetOrder(id int64) (*Order, error)
}

// --- Handler ---

type OrderHandler struct {
	repo   OrderRepository
	logger *slog.Logger
}

// GET /v1/orders?cursor=...&limit=20
func (h *OrderHandler) ListOrders(w http.ResponseWriter, r *http.Request) {
	const defaultLimit = 20
	const maxLimit = 100

	// Parse limit
	limit := defaultLimit
	if l := r.URL.Query().Get("limit"); l != "" {
		parsed, err := strconv.Atoi(l)
		if err != nil || parsed < 1 {
			writeProblem(w, r, ErrInvalidInput, http.StatusBadRequest,
				"limit must be a positive integer")
			return
		}
		if parsed > maxLimit {
			parsed = maxLimit
		}
		limit = parsed
	}

	// Parse cursor
	var afterID int64
	if c := r.URL.Query().Get("cursor"); c != "" {
		cursor, err := decodeCursor(c)
		if err != nil {
			writeProblem(w, r, ErrInvalidInput, http.StatusBadRequest,
				"invalid cursor value")
			return
		}
		afterID = cursor.ID
	}

	// Fetch limit+1 to determine hasMore
	orders, err := h.repo.ListOrders(afterID, limit+1)
	if err != nil {
		h.logger.Error("failed to list orders", "error", err)
		writeProblem(w, r, ProblemDetail{
			Type:  "https://api.example.com/errors/internal",
			Title: "Internal Server Error",
		}, http.StatusInternalServerError, "failed to retrieve orders")
		return
	}

	hasMore := len(orders) > limit
	if hasMore {
		orders = orders[:limit]
	}

	resp := PagedResponse[Order]{
		Data:    orders,
		HasMore: hasMore,
	}

	if hasMore && len(orders) > 0 {
		last := orders[len(orders)-1]
		resp.NextCursor = encodeCursor(Cursor{ID: last.ID, CreatedAt: last.CreatedAt})
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

// GET /v1/orders/{id}
func (h *OrderHandler) GetOrder(w http.ResponseWriter, r *http.Request) {
	idStr := r.PathValue("id") // Go 1.22+
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		writeProblem(w, r, ErrInvalidInput, http.StatusBadRequest,
			"order id must be an integer")
		return
	}

	order, err := h.repo.GetOrder(id)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			writeProblem(w, r, ErrNotFound, http.StatusNotFound,
				fmt.Sprintf("order %d not found", id))
			return
		}
		h.logger.Error("failed to get order", "id", id, "error", err)
		writeProblem(w, r, ProblemDetail{
			Type:  "https://api.example.com/errors/internal",
			Title: "Internal Server Error",
		}, http.StatusInternalServerError, "failed to retrieve order")
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(order)
}

func main() {
	mux := http.NewServeMux()
	handler := &OrderHandler{
		logger: slog.Default(),
	}

	// Versioned routes (Go 1.22+ routing)
	mux.HandleFunc("GET /v1/orders", handler.ListOrders)
	mux.HandleFunc("GET /v1/orders/{id}", handler.GetOrder)

	srv := &http.Server{
		Addr:         ":8080",
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	slog.Info("starting server", "addr", srv.Addr)
	if err := srv.ListenAndServe(); err != nil {
		slog.Error("server error", "error", err)
	}
}
```

---

## 5. Service Mesh

### The Problem

Every microservice must implement:
- Retry with exponential backoff
- Timeout management
- Circuit breaker
- mTLS (mutual TLS) for encryption and service authentication
- Distributed tracing (propagating trace headers)
- Metrics (latency, error rate, throughput)
- Load balancing
- Canary deployments

This is a repetitive cross-cutting concern. Every team implements it differently, spends time on it, and makes mistakes.

---

### Solution: Sidecar Proxy

A Service Mesh offloads these responsibilities to a separate process — a sidecar proxy — which runs alongside every service.

```
┌─────────────────────────────────────────────────────────────────┐
│  Pod / VM                                                       │
│                                                                 │
│  ┌─────────────┐      ┌──────────────────┐                     │
│  │   Your App  │─────>│  Sidecar Proxy   │                     │
│  │  (Go, port  │      │  (Envoy, port    │──── network ────>   │
│  │   8080)     │<─────│   15001)         │                     │
│  └─────────────┘      └──────────────────┘                     │
│                                │                               │
│                                │ telemetry, config             │
│                                ▼                               │
│                         Control Plane                          │
└─────────────────────────────────────────────────────────────────┘
```

The application knows nothing about retry, mTLS, or tracing — the sidecar handles it transparently.

---

### Istio

The most popular service mesh. Consists of two planes:

**Data Plane**: Envoy proxies (sidecar in every Pod).
**Control Plane**: istiod — manages configuration for all Envoy instances.

```
                    ┌──────────────────┐
                    │     istiod       │
                    │  (Control Plane) │
                    │                  │
                    │  - Pilot         │  ← Traffic management
                    │  - Citadel       │  ← Certificate management (mTLS)
                    │  - Galley        │  ← Config validation
                    └────────┬─────────┘
                             │ xDS protocol (gRPC)
            ┌────────────────┼────────────────┐
            ▼                ▼                ▼
      ┌─────────┐      ┌─────────┐      ┌─────────┐
      │ Envoy   │      │ Envoy   │      │ Envoy   │
      │ sidecar │      │ sidecar │      │ sidecar │
      ├─────────┤      ├─────────┤      ├─────────┤
      │ Service │      │ Service │      │ Service │
      │    A    │      │    B    │      │    C    │
      └─────────┘      └─────────┘      └─────────┘
```

**What Istio provides:**

| Feature | Description |
|---|---|
| **Traffic management** | Routing, load balancing, circuit breaking, fault injection |
| **Observability** | Metrics, distributed tracing (Jaeger/Zipkin), access logs |
| **Security** | mTLS between services, authorization policies |
| **Canary deployments** | Gradual traffic shifting to a new version |
| **Retries / Timeouts** | Configured in YAML, not in code |

Example Istio VirtualService for canary:

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: order-service
spec:
  hosts:
  - order-service
  http:
  - route:
    - destination:
        host: order-service
        subset: v1
      weight: 90
    - destination:
        host: order-service
        subset: v2   # canary
      weight: 10
```

---

### Linkerd

A lightweight alternative to Istio. Written in Rust (proxy) and Go (control plane).

| | Istio | Linkerd |
|---|---|---|
| **Proxy** | Envoy (C++) | linkerd2-proxy (Rust) |
| **Resource consumption** | High (~200MB RAM/pod) | Low (~10MB RAM/pod) |
| **Complexity** | High | Low |
| **Feature set** | Full | Basic (sufficient for most use cases) |
| **Protocols** | HTTP/1, HTTP/2, gRPC, TCP | HTTP/1, HTTP/2, gRPC |

---

### When You Need a Service Mesh — and When You Don't

**Need it:**
- > 20 services in production.
- mTLS between services is required (compliance, zero-trust network).
- Canary deployments without code changes are desired.
- Observability without code instrumentation is needed.
- Mature Kubernetes infrastructure is in place.

**Don't need it:**
- < 10 services.
- Retry, timeout, and circuit breaker can be embedded in code (libraries: `go-retryablehttp`, `gobreaker`).
- A Service Mesh adds operational complexity — you need a team that knows how to work with it.
- The latency overhead of the sidecar is significant for your use case (typically 1–5ms per hop).

---

## 6. Distributed Transactions in Microservices

This section is intentionally brief — see [Module 07: Distributed Systems Patterns](../07-distributed-patterns/readme.md) for a detailed treatment.

### Reminder: Why 2PC Is a Poor Fit

Two-Phase Commit requires all transaction participants to be available and to hold locks until the transaction completes. In microservices this:
- Creates tight coupling between services.
- If the coordinator crashes — participants are blocked indefinitely.
- High latency due to two round-trips and locking.

2PC is acceptable between two databases on the same network, but not between independent HTTP services.

---

### Saga as the Standard Approach

A Saga is a sequence of local transactions, each of which publishes an event or command for the next step.

```
OrderSaga:
  1. OrderService: CreateOrder         → publishes OrderCreated
  2. PaymentService: ProcessPayment    → publishes PaymentProcessed
  3. InventoryService: ReserveItems    → publishes ItemsReserved
  4. ShippingService: ScheduleShipping → publishes ShippingScheduled
```

When step N fails, **compensating transactions** are triggered in reverse order:

```
InventoryService: FAIL → publishes ReservationFailed
  ← PaymentService compensates: RefundPayment
  ← OrderService compensates: CancelOrder
```

Two coordination variants:
- **Choreography**: each service reacts to events directly. Simpler, but harder to trace the full flow.
- **Orchestration**: a Saga Orchestrator manages the flow by sending commands. Easier to debug, with an explicit control point.

For detailed Go examples, see [Module 07](../07-distributed-patterns/readme.md#2-saga-pattern).

---

## 7. Data Management in Microservices

### Database per Service: Details

Each service is the sole owner of its data. Other services can only access that data through the owner's API.

```
┌─────────────────────────────────────────────────────────────────┐
│  Data ownership rules:                                          │
│                                                                 │
│  UserService       owns: users, user_preferences, auth_tokens   │
│  OrderService      owns: orders, order_items, order_status      │
│  PaymentService    owns: transactions, refunds, payment_methods │
│  ProductService    owns: products, categories, pricing          │
│                                                                 │
│  OrderService needs a user's email?                            │
│  → GET /v1/users/{user_id}/contact    (via UserService API)    │
│  → Do NOT read directly from the users table                   │
└─────────────────────────────────────────────────────────────────┘
```

---

### The Problem: Cross-Service Queries

**Scenario**: display a list of orders with the user's name and product names. The data lives in three different databases.

**Solution 1: API Composition**

An aggregator service (or BFF) collects data from multiple services and joins it.

```go
func (h *Handler) GetOrderDetails(w http.ResponseWriter, r *http.Request) {
    orderID := r.PathValue("id")

    // Parallel calls
    var order *Order
    var user *User
    var products []*Product

    g, ctx := errgroup.WithContext(r.Context())

    g.Go(func() error {
        var err error
        order, err = h.orderClient.GetOrder(ctx, orderID)
        return err
    })

    // After getting the order — fetch user and products in parallel
    if err := g.Wait(); err != nil {
        // handle error
        return
    }

    g2, ctx2 := errgroup.WithContext(r.Context())
    g2.Go(func() error {
        var err error
        user, err = h.userClient.GetUser(ctx2, order.UserID)
        return err
    })
    g2.Go(func() error {
        var err error
        products, err = h.productClient.GetProducts(ctx2, order.ProductIDs)
        return err
    })

    if err := g2.Wait(); err != nil {
        // handle error
        return
    }

    // Compose response
    resp := composeOrderDetails(order, user, products)
    json.NewEncoder(w).Encode(resp)
}
```

Pros: simplicity, no data duplication.
Cons: latency accumulates, N+1 queries when listing.

**Solution 2: CQRS + Materialized View**

The Read Model (Query Side) builds a denormalized view from events emitted by different services.

```
Events:
  UserService    → UserCreated    { user_id, name, email }
  OrderService   → OrderCreated   { order_id, user_id, items }
  ProductService → ProductUpdated { product_id, name, price }

OrderReadModel (separate service/DB):
  Subscribes to all these events and builds:

  orders_view:
    order_id | user_name | user_email | item_names | total
    ─────────────────────────────────────────────────────
    123      | John Doe  | j@ex.com   | [iPhone]   | 999.00
```

Pros: fast read queries, no N+1.
Cons: eventual consistency (data may be slightly stale), maintenance complexity.

---

### Shared Database Anti-Pattern

```
❌ BAD:

OrderService  ──┐
UserService   ──┼──> Shared Database
PaymentService──┘

Problems:
- Schema changes require coordination across all teams
- Services are coupled through tables
- Different databases cannot be used for different tasks
- Schema migrations = deployment freeze for everyone
```

A shared database is a monolith in disguise. If services are separated but share a database, all the problems of a monolith remain.

**Exception**: during a transition period when migrating from a monolith, a shared database is temporarily acceptable as an intermediate step. The key word is *temporarily* — with a migration plan in place.

---

### Data Ownership: Who Is Responsible for What

| Data | Owner | Access for others |
|---|---|---|
| Users, profiles | UserService | GET /users/{id} |
| Auth tokens, sessions | AuthService | POST /auth/validate |
| Orders, order items | OrderService | GET /orders/{id} |
| Payments, refunds | PaymentService | GET /payments/{id} |
| Products, prices | ProductService | GET /products/{id}, bulk |
| Inventory levels | InventoryService | GET /inventory/{sku} |
| Email templates | NotificationService | Internal |

Rule: if multiple teams are arguing over who owns the data — that's a signal to revisit service boundaries (bounded context).

---

## 8. Deployment and DevOps

### Containerization: Docker

Each microservice is a Docker image. This guarantees an identical environment from development to production.

```dockerfile
# Multi-stage build for a minimal image
FROM golang:1.23-alpine AS builder

WORKDIR /app

# Cache dependencies in a separate layer
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o /bin/service ./cmd/service

# Final image
FROM scratch

COPY --from=builder /bin/service /service
# If TLS certs are needed
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

EXPOSE 8080

ENTRYPOINT ["/service"]
```

`scratch` is an empty base image. Final image size: 5–15 MB vs ~300 MB for ubuntu-based images.

---

### Kubernetes: Core Concepts

```
Kubernetes Cluster
│
├── Node (VM or physical server)
│   ├── Pod (smallest unit of deployment)
│   │   ├── Container (your service)
│   │   └── Container (sidecar, if needed)
│   └── ...
│
├── Deployment (manages Pod replicas)
├── Service (stable DNS and IP for Pods)
├── ConfigMap (config without secrets)
├── Secret (secrets: passwords, tokens, certificates)
├── Ingress (HTTP routing from outside the cluster)
└── HorizontalPodAutoscaler (autoscaling)
```

**Pod**: one or more containers sharing a network and storage. A Pod is ephemeral — it is restarted on failure.

**Deployment**: declares the desired state (3 replicas of a Pod). Kubernetes ensures the correct number of replicas is running.

**Service**: a stable endpoint (DNS name + ClusterIP) for a set of Pods. Balances traffic across Pods.

**ConfigMap / Secret**: injects configuration into a Pod via environment variables or volume mount.

---

### Kubernetes YAML for a Go Service

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
  namespace: production
  labels:
    app: order-service
    version: v1.2.3
spec:
  replicas: 3
  selector:
    matchLabels:
      app: order-service
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1        # At most 1 extra Pod during an update
      maxUnavailable: 0  # All replicas remain available at all times
  template:
    metadata:
      labels:
        app: order-service
        version: v1.2.3
    spec:
      containers:
      - name: order-service
        image: registry.example.com/order-service:v1.2.3
        ports:
        - containerPort: 8080
          name: http
        - containerPort: 9090
          name: metrics
        env:
        - name: DB_HOST
          valueFrom:
            configMapKeyRef:
              name: order-service-config
              key: db_host
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: order-service-secrets
              key: db_password
        - name: LOG_LEVEL
          value: "info"
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "256Mi"
        # Liveness: restart the Pod if it hangs
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
          failureThreshold: 3
        # Readiness: do not send traffic until ready
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 3
        # Graceful shutdown: allow time to finish in-flight requests
        lifecycle:
          preStop:
            exec:
              command: ["/bin/sleep", "5"]
      terminationGracePeriodSeconds: 30
---
# service.yaml
apiVersion: v1
kind: Service
metadata:
  name: order-service
  namespace: production
spec:
  selector:
    app: order-service
  ports:
  - name: http
    port: 80
    targetPort: 8080
  - name: metrics
    port: 9090
    targetPort: 9090
  type: ClusterIP  # Accessible only within the cluster
---
# hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: order-service
  namespace: production
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: order-service
  minReplicas: 3
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```

Health endpoints in Go:

```go
// /healthz — liveness: is the process alive?
// Returns 200 as long as the process is running.
// Do NOT check the database here — if the DB is down, the Pod should not be restarted.
mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
    w.Write([]byte("ok"))
})

// /readyz — readiness: is the service ready to accept traffic?
// Checks dependencies (DB, cache).
// If not ready — Kubernetes removes the Pod from load balancing.
mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
    if err := db.PingContext(r.Context()); err != nil {
        http.Error(w, "database unavailable", http.StatusServiceUnavailable)
        return
    }
    w.WriteHeader(http.StatusOK)
    w.Write([]byte("ok"))
})
```

---

### Deployment Strategies

**Rolling Update** (default in Kubernetes):
```
v1 v1 v1 v1    →    v1 v1 v1 v2    →    v1 v1 v2 v2    →    v2 v2 v2 v2
```
- Gradually replaces old Pods with new ones.
- Zero-downtime when probes are configured correctly.
- Hard to roll back if a problem is discovered minutes later.

**Blue-Green**:
```
Blue (v1): 4 replicas — receiving traffic
Green (v2): 4 replicas — deployed, being tested

Switch: change the selector in the Service
Rollback: switch back (seconds)
```
- Instant rollback.
- Requires double the resources.
- Good for databases with migrations (both environments must work with the same schema).

**Canary**:
```
v1: 90% of traffic
v2: 10% of traffic (only a subset of users)

Monitoring: error rate, latency, business metrics
If OK → gradually increase % for v2
If bad → roll back 100% to v1
```
- Minimal blast radius on failure.
- Requires a service mesh or Ingress with weighted routing.

---

### Feature Flags: Deploy ≠ Release

Deploy — the technical act of placing code in production.
Release — the business decision about who sees the new functionality.

```go
// Example using LaunchDarkly / Unleash / custom feature flag
func (h *Handler) CreateOrder(w http.ResponseWriter, r *http.Request) {
    userID := getUserID(r)

    // New recommendation algorithm enabled for only 5% of users
    if h.flags.IsEnabled("new-recommendation-engine", userID) {
        // new logic
    } else {
        // old logic
    }
}
```

**Advantages:**
- Deploy without risk: code is in production, but the feature is off.
- A/B testing: different versions for different user groups.
- Kill switch: instantly disable a problematic feature without a deploy.
- Gradual rollout: 1% → 5% → 20% → 100%.

---

## 9. Testing Microservices

### Testing Pyramid for Microservices

```
         ╱─────────────╲
        ╱    E2E Tests   ╲       ← Few, only critical paths
       ╱─────────────────╲
      ╱   Contract Tests   ╲     ← Verify API contracts between services
     ╱─────────────────────╲
    ╱  Integration Tests     ╲   ← Service + real DB/broker (testcontainers)
   ╱──────────────────────────╲
  ╱      Unit Tests            ╲ ← Business logic, fast, many
 ╱────────────────────────────────╲
```

---

### Unit Tests: Business Logic

Test pure business logic without external dependencies. Dependencies are provided through interfaces.

```go
// domain/order.go
type Order struct {
    ID     string
    Items  []Item
    Status OrderStatus
}

func (o *Order) Cancel() error {
    if o.Status == StatusShipped {
        return errors.New("cannot cancel shipped order")
    }
    if o.Status == StatusCancelled {
        return errors.New("order already cancelled")
    }
    o.Status = StatusCancelled
    return nil
}

// domain/order_test.go
func TestOrder_Cancel(t *testing.T) {
    tests := []struct {
        name    string
        status  OrderStatus
        wantErr bool
    }{
        {"pending order can be cancelled", StatusPending, false},
        {"shipped order cannot be cancelled", StatusShipped, true},
        {"already cancelled order", StatusCancelled, true},
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            order := &Order{Status: tt.status}
            err := order.Cancel()
            if (err != nil) != tt.wantErr {
                t.Errorf("Cancel() error = %v, wantErr %v", err, tt.wantErr)
            }
        })
    }
}
```

---

### Integration Tests: With a Real Database (testcontainers)

Test the service with a real database in a Docker container. Slower than unit tests, but verifies actual behavior.

```go
// internal/repository/order_repo_test.go
package repository_test

import (
    "context"
    "testing"

    "github.com/testcontainers/testcontainers-go"
    "github.com/testcontainers/testcontainers-go/modules/postgres"
)

func TestOrderRepository_Integration(t *testing.T) {
    if testing.Short() {
        t.Skip("skipping integration test in short mode")
    }

    ctx := context.Background()

    // Spin up PostgreSQL in Docker
    pgContainer, err := postgres.RunContainer(ctx,
        testcontainers.WithImage("postgres:16-alpine"),
        postgres.WithDatabase("testdb"),
        postgres.WithUsername("test"),
        postgres.WithPassword("test"),
    )
    if err != nil {
        t.Fatalf("failed to start postgres: %v", err)
    }
    defer pgContainer.Terminate(ctx)

    connStr, err := pgContainer.ConnectionString(ctx, "sslmode=disable")
    if err != nil {
        t.Fatalf("failed to get connection string: %v", err)
    }

    // Apply migrations
    db, err := openAndMigrate(connStr)
    if err != nil {
        t.Fatalf("failed to migrate: %v", err)
    }

    repo := NewOrderRepository(db)

    t.Run("create and retrieve order", func(t *testing.T) {
        order := &Order{
            UserID: "user-123",
            Status: StatusPending,
        }

        created, err := repo.CreateOrder(ctx, order)
        if err != nil {
            t.Fatalf("CreateOrder() error = %v", err)
        }
        if created.ID == "" {
            t.Error("expected non-empty ID")
        }

        retrieved, err := repo.GetOrder(ctx, created.ID)
        if err != nil {
            t.Fatalf("GetOrder() error = %v", err)
        }
        if retrieved.UserID != order.UserID {
            t.Errorf("UserID = %v, want %v", retrieved.UserID, order.UserID)
        }
    })
}
```

Running integration tests: `go test ./... -run Integration` or a separate build tag `//go:build integration`.

---

### Contract Tests: Pact

Contract tests verify that the consumer and provider of an API agree on the contract. If OrderService expects a certain format from UserService — that expectation is recorded in a pact file.

**Consumer (OrderService) defines expectations:**

```go
// consumer_test.go
func TestOrderService_GetUser_Contract(t *testing.T) {
    pact := dsl.Pact{
        Consumer: "OrderService",
        Provider: "UserService",
    }

    pact.AddInteraction().
        Given("user 123 exists").
        UponReceiving("a request for user 123").
        WithRequest(dsl.Request{
            Method: "GET",
            Path:   dsl.String("/v1/users/123"),
        }).
        WillRespondWith(dsl.Response{
            Status: 200,
            Body: dsl.Match(User{
                ID:    "123",
                Email: "test@example.com",
                Name:  "John Doe",
            }),
        })

    if err := pact.Verify(func() error {
        // Run OrderService, which calls UserService
        client := NewUserClient(pact.Server.URL)
        user, err := client.GetUser(context.Background(), "123")
        if err != nil {
            return err
        }
        // Verify we got what we expected
        if user.ID != "123" {
            return fmt.Errorf("expected user ID 123, got %s", user.ID)
        }
        return nil
    }); err != nil {
        t.Fatalf("pact verification failed: %v", err)
    }
}
```

**Provider (UserService) verifies the pact:**

```go
// provider_test.go
func TestUserService_Pact_Provider(t *testing.T) {
    pactVerify := provider.VerifyRequest{
        ProviderBaseURL:            "http://localhost:8080",
        BrokerURL:                  "https://pact-broker.example.com",
        ProviderName:               "UserService",
        PublishVerificationResults: true,
        ProviderVersion:            os.Getenv("GIT_COMMIT"),
    }

    if err := provider.VerifyProvider(t, pactVerify); err != nil {
        t.Fatalf("pact verification failed: %v", err)
    }
}
```

**protovalidate** — validation of proto messages using rules defined in the `.proto` file:

```protobuf
import "buf/validate/validate.proto";

message CreateOrderRequest {
  string user_id = 1 [(buf.validate.field).string.uuid = true];
  repeated OrderItem items = 2 [(buf.validate.field).repeated.min_items = 1];
  string idempotency_key = 3 [(buf.validate.field).string.len = 36];
}
```

---

### E2E Tests: Only Critical Paths

E2E tests verify the complete flow across all services in a staging environment. They are slow, brittle, and expensive to maintain.

```
Critical paths for E2E:
  ✓ User registers → receives email
  ✓ User creates an order → pays → receives confirmation
  ✓ User cancels an order → receives a refund

Do NOT cover with E2E:
  ✗ All edge cases (that's what unit tests are for)
  ✗ All parameter combinations (that's what integration tests are for)
  ✗ Performance (that's what load tests are for)
```

Tools: `k6` for APIs, `Playwright` for UI, `pytest` with `requests` for API workflows.

---

### Comparison Table: Test Types

| Type | Speed | Cost | Coverage | Quantity |
|---|---|---|---|---|
| **Unit** | < 1ms | Cheap | Business logic | Many (100s) |
| **Integration** | 1–30s | Medium | Service + DB | Moderate (10s) |
| **Contract** | 1–10s | Medium | API contracts | One per integration |
| **E2E** | 30s–5min | Expensive | Critical paths | Few (< 10) |

**Rule**: if something can be tested with a unit test — test it with a unit test. An E2E test is insurance for the most critical flows, not a replacement for the lower levels of the pyramid.

---

## Module Summary

| Topic | Key Takeaway |
|---|---|
| **Monolith vs Microservices** | Microservices are an organizational solution. Below 10 people and before product-market fit — use a monolith. |
| **Bounded Context** | One service = one BC. Service boundary = team boundary. |
| **Communication** | Sync (gRPC/REST) when you need a response right now. Async (Kafka/NATS) when you don't. |
| **API Design** | Cursor pagination. RFC 7807 errors. URL versioning. |
| **Service Mesh** | Needed after 20 services. Before that — use libraries in code. |
| **Transactions** | Saga + compensating transactions. 2PC — not for independent HTTP services. |
| **Data Management** | Database per service. Shared database — anti-pattern. API Composition or CQRS for cross-service queries. |
| **Deployment** | Rolling update for standard deploys. Blue-Green for critical ones. Canary for risky ones. |
| **Testing** | Pyramid: many unit → moderate integration → few contract → minimal E2E. |

---

**Next module**: [Module 09: Observability](../09-observability/readme.md) — metrics, tracing, and logging in distributed systems.
