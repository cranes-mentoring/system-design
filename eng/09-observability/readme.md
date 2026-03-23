# Module 09: Observability

> **Audience**: Backend developers who want to understand what is happening in their production system — not guess, but know.
>
> **What's inside**: Logs, Metrics, Traces, OpenTelemetry, Health Checks, Incident Management. A full stack from tools to processes.

---

## Table of Contents

1. [The Three Pillars of Observability](#1-the-three-pillars-of-observability)
2. [Logging](#2-logging)
3. [Metrics](#3-metrics)
4. [Distributed Tracing](#4-distributed-tracing)
5. [OpenTelemetry — The Unified Standard](#5-opentelemetry--the-unified-standard)
6. [Health Checks and Readiness Probes](#6-health-checks-and-readiness-probes)
7. [Incident Management](#7-incident-management)

---

## 1. The Three Pillars of Observability

### Monitoring vs Observability

These are not synonyms, and confusing them costs money.

**Monitoring** is knowing **what** broke. You defined metrics in advance, set thresholds, and received an alert: `error_rate > 5%`. Great. But why? Monitoring doesn't answer that.

**Observability** is the ability to understand **why** something broke by asking arbitrary questions of the system without prior preparation. You look at the trace for a specific request, see that `orders-service` spent 2.3s calling `inventory-service`, see `timeout waiting for DB connection` in the logs, and see in the metrics that the connection pool is exhausted. Question asked → answer received.

```
MONITORING:                          OBSERVABILITY:
"What broke?"                        "Why did it break?"

 CPU > 90%  ──→  ALERT               Request X → Service A → Service B
 Error rate ──→  ALERT                  └── 2300ms here
 Disk full  ──→  ALERT               Log: "pool exhausted"
                                     Metric: active_connections = 100/100
 Answer: something is wrong          Answer: connection pool exhausted
```

### Logs, Metrics, Traces

Three different tools solve different problems:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        OBSERVABILITY STACK                          │
│                                                                     │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────────────┐    │
│  │    LOGS      │   │   METRICS    │   │       TRACES         │    │
│  │              │   │              │   │                      │    │
│  │ What exactly │   │ How the      │   │ How a request flows  │    │
│  │ happened     │   │ system feels │   │ through services     │    │
│  │ and when     │   │ right now    │   │                      │    │
│  │              │   │              │   │                      │    │
│  │ Elasticsearch│   │  Prometheus  │   │  Jaeger / Tempo      │    │
│  │ Loki         │   │  VictoriaM.  │   │  Zipkin              │    │
│  └──────────────┘   └──────────────┘   └──────────────────────┘    │
│                                                                     │
│  Connected via: trace_id in logs, exemplars in metrics              │
└─────────────────────────────────────────────────────────────────────┘
```

### Table: What Each Tool Solves

| Question | Tool | Why |
|----------|------|-----|
| What percentage of requests failed in the last 5 minutes? | Metrics | Aggregated numbers are metrics |
| What exactly happened during a specific request from user X? | Logs | Detailed event context |
| Why did a request to /checkout take 3 seconds? | Traces | The call chain with timings is visible |
| How much memory is the service consuming right now? | Metrics (Gauge) | Current resource state |
| Which line of code threw an exception? | Logs | A stack trace is a log |
| Which microservice is the bottleneck? | Traces | Span duration per service |
| When did degradation begin? | Metrics | Time series |
| What was in the HTTP request from the user who got a 500? | Logs | Structured event record |
| Why did performance drop after a deployment? | Metrics + Traces | Comparing time series + request path |

### How They Are Connected

The three pillars are most valuable when they are **linked** to each other through a single `trace_id`:

```
Metric: http_request_duration{status="500"} spike at 14:23

       ↓ drill down by trace_id from exemplar

Trace: trace_id=abc123, duration=4200ms
  └─ orders-svc: 120ms
  └─ inventory-svc: 4050ms  ← anomaly
       └─ db query: 3980ms  ← here

       ↓ open logs by trace_id=abc123

Log: time=14:23:01 level=ERROR trace_id=abc123
     msg="query timeout" query="SELECT * FROM inventory WHERE..."
     duration=3980ms db_host=postgres-1
```

---

## 2. Logging

### Structured Logging: JSON Instead of Plain Text

Plain text logs were the norm 15 years ago. Today they are an anti-pattern.

**Plain text (bad):**
```
2024-01-15 14:23:01 ERROR Failed to process order 12345 for user 67890: timeout
```

How do you parse this? `grep`, `awk`, `sed`, regex. Fragile, slow, doesn't scale.

**Structured JSON (correct):**
```json
{
  "time": "2024-01-15T14:23:01.234Z",
  "level": "ERROR",
  "msg": "failed to process order",
  "trace_id": "abc123def456",
  "order_id": "12345",
  "user_id": "67890",
  "error": "context deadline exceeded",
  "duration_ms": 5002,
  "service": "orders-svc",
  "version": "v1.2.3"
}
```

Why JSON is mandatory:
- **Indexed** — Elasticsearch and Loki automatically create fields for filtering
- **Aggregatable** — `avg(duration_ms)` by `order_id` — one line in Kibana
- **Non-breaking** — add a field and no parser breaks
- **Correlation** — `trace_id` links the log to a trace

### Log Levels

| Level | When to Use | Example |
|-------|-------------|---------|
| `DEBUG` | Development details, not needed in production | "Executing query: SELECT ..." |
| `INFO` | Normal lifecycle events | "Server started on :8080", "Order created" |
| `WARN` | Something unexpected, but system is working | "Retry attempt 2/3", "Cache miss rate > 50%" |
| `ERROR` | Operation failed, requires attention | "Failed to save order", "Database connection lost" |
| `FATAL` | Service cannot continue, exit | "Failed to connect to DB at startup" |

**Rules:**
- `DEBUG` in production — only via dynamic switching, not always on
- `INFO` — every important business event (order created, payment processed)
- Don't log every HTTP request at `INFO` at 10k RPS — only slow requests or errors
- `ERROR` → should trigger an alert in most cases
- `FATAL` → immediate alert + pagerduty

### Correlation ID

Without a Correlation ID (also known as `trace_id`, `request_id`), debugging in a distributed system is guesswork.

**Problem:**
```
# 14:23:01 — hundreds of requests per second
ERROR failed to charge payment
ERROR order not found
WARN slow DB query
INFO payment processed
ERROR inventory update failed
```

Which of these logs belong to the same request? Unclear.

**Solution — Correlation ID:**
```json
{"trace_id":"abc123","msg":"order created","order_id":"42"}
{"trace_id":"abc123","msg":"checking inventory","item_id":"88"}
{"trace_id":"abc123","msg":"inventory reserved","item_id":"88"}
{"trace_id":"abc123","msg":"payment charged","amount":99.99}
{"trace_id":"abc123","msg":"order completed","order_id":"42"}
```

One `trace_id` — the complete history of a single request.

**How to propagate through the call chain:**

```
Client → API Gateway → Order Service → Payment Service → Notification Service
           generates      reads from     reads from         reads from
           X-Request-ID   header         context            context
           or trace_id    → context      → outgoing         → outgoing
                                           request            request
```

### Go Example: Structured Logging with `slog` + Middleware

```go
package main

import (
    "context"
    "log/slog"
    "net/http"
    "os"
    "time"

    "github.com/google/uuid"
)

// key for context
type contextKey string

const traceIDKey contextKey = "trace_id"

// Logger — global structured logger
var Logger = slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
    Level: slog.LevelInfo,
}))

// FromContext retrieves a logger with trace_id already added from context
func FromContext(ctx context.Context) *slog.Logger {
    if traceID, ok := ctx.Value(traceIDKey).(string); ok {
        return Logger.With("trace_id", traceID)
    }
    return Logger
}

// CorrelationMiddleware — HTTP middleware for propagating trace_id
func CorrelationMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // Take from header (from upstream) or generate a new one
        traceID := r.Header.Get("X-Trace-Id")
        if traceID == "" {
            traceID = uuid.New().String()
        }

        // Store in context
        ctx := context.WithValue(r.Context(), traceIDKey, traceID)

        // Forward to the client in the response
        w.Header().Set("X-Trace-Id", traceID)

        // Pass along with updated context
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}

// LoggingMiddleware — logs every HTTP request
func LoggingMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        lrw := &loggingResponseWriter{ResponseWriter: w, statusCode: http.StatusOK}

        next.ServeHTTP(lrw, r)

        log := FromContext(r.Context())
        log.Info("http request",
            "method", r.Method,
            "path", r.URL.Path,
            "status", lrw.statusCode,
            "duration_ms", time.Since(start).Milliseconds(),
            "user_agent", r.UserAgent(),
        )
    })
}

type loggingResponseWriter struct {
    http.ResponseWriter
    statusCode int
}

func (lrw *loggingResponseWriter) WriteHeader(code int) {
    lrw.statusCode = code
    lrw.ResponseWriter.WriteHeader(code)
}

// Usage in business logic
func processOrder(ctx context.Context, orderID string) error {
    log := FromContext(ctx)

    log.Info("processing order", "order_id", orderID)

    if err := chargePayment(ctx, orderID); err != nil {
        // Error: add context, don't lose trace_id
        log.Error("payment failed",
            "order_id", orderID,
            "error", err.Error(),
        )
        return err
    }

    log.Info("order completed", "order_id", orderID)
    return nil
}

func main() {
    mux := http.NewServeMux()
    mux.HandleFunc("/orders", func(w http.ResponseWriter, r *http.Request) {
        log := FromContext(r.Context())
        log.Info("handling order request")
        // business logic
        w.WriteHeader(http.StatusOK)
    })

    // Chain: correlation → logging → handler
    handler := CorrelationMiddleware(LoggingMiddleware(mux))

    Logger.Info("server starting", "addr", ":8080")
    if err := http.ListenAndServe(":8080", handler); err != nil {
        Logger.Error("server failed", "error", err.Error())
        os.Exit(1)
    }
}
```

**stdout output:**
```json
{"time":"2024-01-15T14:23:01.234Z","level":"INFO","msg":"http request","trace_id":"abc123","method":"POST","path":"/orders","status":200,"duration_ms":45}
{"time":"2024-01-15T14:23:01.280Z","level":"INFO","msg":"order completed","trace_id":"abc123","order_id":"42"}
```

### Logging Stack

**EFK Stack (Elasticsearch + Fluentd + Kibana):**

```
┌─────────────┐    ┌─────────────┐    ┌───────────────┐    ┌─────────┐
│  App Pod    │───>│ Fluent Bit  │───>│ Fluentd       │───>│  Elastic│
│  (stdout)   │    │ (DaemonSet) │    │ (aggregator)  │    │  search │
└─────────────┘    └─────────────┘    └───────────────┘    └────┬────┘
                                                                 │
                                                          ┌──────▼──────┐
                                                          │   Kibana    │
                                                          │ (dashboards)│
                                                          └─────────────┘
```

- **Fluent Bit** — lightweight agent (DaemonSet in K8s), reads logs from the node
- **Fluentd** — aggregator, parsing, filtering, routing
- **Elasticsearch** — storage and indexing
- **Kibana** — visualization, search, alerts

**Loki + Grafana (lighter alternative):**

```
┌─────────────┐    ┌─────────────┐    ┌─────────┐    ┌─────────┐
│  App Pod    │───>│  Promtail   │───>│  Loki   │───>│ Grafana │
│  (stdout)   │    │  (agent)    │    │(storage │    │(search +│
└─────────────┘    └─────────────┘    │ index)  │    │dashbrd) │
                                      └─────────┘    └─────────┘
```

Loki doesn't index log content — only labels. This makes it cheaper than Elasticsearch, but less flexible for full-text search. The choice depends on log volume and budget.

### Best Practices

**Don't log PII (Personally Identifiable Information):**
```go
// BAD — card number in the log
log.Info("payment processed", "card_number", "4111111111111111")

// GOOD — only the last 4 digits
log.Info("payment processed", "card_last4", "1111", "payment_id", paymentID)
```

**Don't log in the hot path without sampling:**
```go
// BAD — 50k RPS × JSON marshal = CPU overhead
func handlePing(w http.ResponseWriter, r *http.Request) {
    log.Info("ping received") // every request
    w.WriteHeader(200)
}

// GOOD — /healthz is not logged at all
// or use sampling for high-frequency events

var sampleRate = 0.01 // 1% of requests

func shouldSample() bool {
    return rand.Float64() < sampleRate
}
```

**Levels in different environments:**
```go
level := slog.LevelInfo
if os.Getenv("ENV") == "development" {
    level = slog.LevelDebug
}
```

**Errors with context, not just `err.Error()`:**
```go
// BAD
log.Error("error", "err", err)

// GOOD — add context
log.Error("failed to fetch user",
    "user_id", userID,
    "attempt", attempt,
    "error", err.Error(),
)
```

---

## 3. Metrics

### Metric Types

**Counter** — a monotonically increasing counter. Never decreases (only resets to 0 on restart).

```
http_requests_total{method="GET", status="200"} 1847293
http_requests_total{method="POST", status="500"} 342
```

Used for: number of requests, errors, processed messages.

**Gauge** — an arbitrary value that can increase and decrease.

```
active_connections 42
memory_usage_bytes 104857600
queue_depth 15
```

Used for: current state (pool load, goroutine count, memory usage).

**Histogram** — distribution of values across buckets. Allows computing percentiles.

```
http_request_duration_seconds_bucket{le="0.005"} 24054
http_request_duration_seconds_bucket{le="0.01"}  33444
http_request_duration_seconds_bucket{le="0.025"} 100392
http_request_duration_seconds_bucket{le="0.05"}  129389
http_request_duration_seconds_bucket{le="+Inf"}  144320
http_request_duration_seconds_sum  53423.29
http_request_duration_seconds_count 144320
```

Used for: latency (p50, p95, p99), request/response sizes.

**Summary** — similar to Histogram, but percentiles are computed client-side (in the application), not server-side. Scales poorly across multiple instances — not recommended for most cases.

### RED Method

For **services** (HTTP API, gRPC):

| Metric | Description | Prometheus Example |
|--------|-------------|-------------------|
| **R**ate | Requests per second | `rate(http_requests_total[5m])` |
| **E**rrors | Error percentage | `rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m])` |
| **D**uration | Latency (p50, p95, p99) | `histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))` |

### USE Method

For **resources** (CPU, memory, disk, network):

| Metric | Description | Prometheus Example |
|--------|-------------|-------------------|
| **U**tilization | % of time the resource is busy | `rate(cpu_usage_seconds_total[5m])` |
| **S**aturation | Queue / resource wait | `node_load1` (queue depth) |
| **E**rrors | Resource errors | `node_network_errs_total` |

### Google SRE Golden Signals

Four metrics that cover 90% of production problems:

```
┌─────────────────────────────────────────────────────────────┐
│                    GOLDEN SIGNALS                           │
│                                                             │
│  1. LATENCY        Response time (separate success/error)   │
│     p50 / p95 / p99 — not average!                         │
│                                                             │
│  2. TRAFFIC        Load on the system                       │
│     RPS, QPS, messages/sec, bytes/sec                       │
│                                                             │
│  3. ERRORS         Percentage of failed requests            │
│     HTTP 5xx, gRPC status != OK, business errors           │
│                                                             │
│  4. SATURATION     How "full" the system is                 │
│     CPU %, memory %, connection pool %, queue depth         │
└─────────────────────────────────────────────────────────────┘
```

**Why p99, not average?** Averages hide the tails. If 99% of requests take 10ms and 1% take 10 seconds, the average is ~110ms. That looks fine on a graph, but 1% of users are having a terrible experience.

### Prometheus: Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    PROMETHEUS STACK                         │
│                                                             │
│  App Instance 1  ──┐                                        │
│  /metrics          │                                        │
│                    ├──→  Prometheus  ──→  Alertmanager      │
│  App Instance 2  ──┤    (pull model)         │             │
│  /metrics          │         │          PagerDuty/Slack     │
│                    │         ▼                               │
│  Node Exporter   ──┘     Storage           Grafana          │
│  /metrics             (local TSDB)      (dashboards)        │
└─────────────────────────────────────────────────────────────┘
```

**Pull model** — Prometheus fetches metrics from services on a schedule (every 15 seconds by default). This distinguishes it from push-based models (StatsD, Graphite). Advantages of pull:
- Prometheus knows when a service is unavailable (scrape failed)
- No need to open the firewall from the service outward
- Service discovery via K8s, Consul, EC2

**PromQL examples:**
```promql
# Error rate over the last 5 minutes
rate(http_requests_total{status=~"5.."}[5m])
  / rate(http_requests_total[5m]) * 100

# p99 latency
histogram_quantile(0.99,
  rate(http_request_duration_seconds_bucket[5m])
)

# Saturation: connection pool utilization
db_pool_active_connections / db_pool_max_connections * 100

# Requests per second by endpoint
sum by (path) (rate(http_requests_total[1m]))
```

### Go Example: HTTP Middleware with Prometheus

```go
package metrics

import (
    "net/http"
    "strconv"
    "time"

    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
    "github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
    // Counter — total number of requests
    httpRequestsTotal = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "http_requests_total",
            Help: "Total number of HTTP requests",
        },
        []string{"method", "path", "status"},
    )

    // Histogram — latency distribution
    httpRequestDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name: "http_request_duration_seconds",
            Help: "HTTP request duration in seconds",
            // Buckets: 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s
            Buckets: prometheus.DefBuckets,
        },
        []string{"method", "path"},
    )

    // Gauge — current number of requests being processed
    httpRequestsInFlight = promauto.NewGauge(
        prometheus.GaugeOpts{
            Name: "http_requests_in_flight",
            Help: "Current number of HTTP requests being processed",
        },
    )
)

// MetricsMiddleware — wraps a handler and collects RED metrics
func MetricsMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // Skip /metrics and /healthz — not business traffic
        if r.URL.Path == "/metrics" || r.URL.Path == "/healthz" {
            next.ServeHTTP(w, r)
            return
        }

        start := time.Now()
        httpRequestsInFlight.Inc()
        defer httpRequestsInFlight.Dec()

        lrw := &statusResponseWriter{ResponseWriter: w, status: http.StatusOK}
        next.ServeHTTP(lrw, r)

        duration := time.Since(start).Seconds()
        status := strconv.Itoa(lrw.status)

        httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, status).Inc()
        httpRequestDuration.WithLabelValues(r.Method, r.URL.Path).Observe(duration)
    })
}

type statusResponseWriter struct {
    http.ResponseWriter
    status int
}

func (w *statusResponseWriter) WriteHeader(status int) {
    w.status = status
    w.ResponseWriter.WriteHeader(status)
}

// RegisterMetricsEndpoint — registers /metrics for Prometheus scraping
func RegisterMetricsEndpoint(mux *http.ServeMux) {
    mux.Handle("/metrics", promhttp.Handler())
}

// Example of business metrics — in addition to RED
var (
    ordersCreated = promauto.NewCounter(prometheus.CounterOpts{
        Name: "orders_created_total",
        Help: "Total number of orders created",
    })

    orderValue = promauto.NewHistogram(prometheus.HistogramOpts{
        Name:    "order_value_dollars",
        Help:    "Distribution of order values in dollars",
        Buckets: []float64{10, 25, 50, 100, 250, 500, 1000, 5000},
    })
)

func RecordOrderCreated(valueUSD float64) {
    ordersCreated.Inc()
    orderValue.Observe(valueUSD)
}
```

### Alerting: Alert on SLOs, Not on CPU

**Bad alert:**
```yaml
# Fires when CPU > 80% — but CPU can be 80% and the service is working fine
alert: HighCPU
expr: cpu_usage > 0.8
for: 5m
```

**Good alert — on SLO:**
```yaml
# Fires when users are actually suffering
alert: HighErrorRate
expr: |
  rate(http_requests_total{status=~"5.."}[5m])
  / rate(http_requests_total[5m]) > 0.01
for: 5m
annotations:
  summary: "Error rate {{ $value | humanizePercentage }} > 1% SLO"

---

alert: HighLatencyP99
expr: |
  histogram_quantile(0.99,
    rate(http_request_duration_seconds_bucket[5m])
  ) > 1.0
for: 10m
annotations:
  summary: "p99 latency {{ $value }}s exceeds 1s SLO"
```

**Principle**: an alert should mean someone needs to wake up and fix something. An alert about CPU without service degradation is noise that destroys trust in alerting.

### Grafana: Key Dashboard Panels

```
┌────────────────────────────────────────────────────────┐
│                SERVICE DASHBOARD                       │
│                                                        │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────┐  │
│  │   RPS        │  │  Error Rate  │  │  p99 Latency│  │
│  │  [sparkline] │  │  [sparkline] │  │  [sparkline]│  │
│  │   1247/s     │  │    0.3%      │  │    245ms    │  │
│  └──────────────┘  └──────────────┘  └─────────────┘  │
│                                                        │
│  ┌────────────────────────────────────────────────┐    │
│  │  Latency Percentiles (p50/p95/p99) — time series│   │
│  │  ▁▁▂▂▁▁▃▃▂▂▁▁▁▁▂▂▄▄▂▂▁▁▁▁▁▁                   │   │
│  └────────────────────────────────────────────────┘    │
│                                                        │
│  ┌────────────────────────────────────────────────┐    │
│  │  Request Rate by Endpoint — stacked area        │   │
│  │  /orders ████████████████                       │   │
│  │  /users  ████████                               │   │
│  │  /search ██████                                 │   │
│  └────────────────────────────────────────────────┘    │
│                                                        │
│  ┌────────────────────────────────────────────────┐    │
│  │  Error Rate by Endpoint — heatmap               │   │
│  └────────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────────┘
```

Useful panels:
- **Single stat / Stat** — current RPS, error rate, p99
- **Time series** — metric trends over time
- **Heatmap** — latency distribution over time (patterns are visible)
- **Table** — top endpoints by latency or error rate
- **Logs panel** — directly in Grafana when using Loki

---

## 4. Distributed Tracing

### The Problem

A request arrived at the system, passed through 5 services, and the user received a response in 3.2 seconds. Where was the delay?

```
Client ──→ API Gateway ──→ Order Svc ──→ Inventory Svc ──→ Payment Svc
  t=0         t=20ms         t=50ms         t=80ms           t=2100ms

Response came back after 3200ms. Logs from each service show they responded
quickly. Where are the missing 3 seconds?

Without tracing: grep through logs with different timestamps, manual correlation.
With tracing: one trace shows 2100ms in Payment Svc → DB query timeout.
```

### Concepts

**Trace** — a complete record of processing a single request through the entire system. Has a unique `trace_id`.

**Span** — a unit of work within a trace. Has:
- `span_id` — unique identifier
- `parent_span_id` — reference to the parent span (where the call came from)
- `trace_id` — which trace it belongs to
- `operation_name` — what was done: `"HTTP POST /orders"`, `"db.query"`
- `start_time`, `end_time` — when it started and ended
- `attributes` — key-value pairs: `http.status_code=200`, `db.statement="SELECT..."`
- `events` — log events inside the span

**Span Context** — the minimal set of data needed to continue a trace in another process: `trace_id + span_id + flags`.

**Baggage** — arbitrary key-value pairs propagated through the entire chain. Use with caution — adds overhead to every request.

### Trace Visualization

```
trace_id: abc123    duration: 3200ms

API Gateway [■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■] 3200ms
  │
  ├─ Order Service [■■■■■■■■■■■■■■■] 1500ms
  │    │
  │    ├─ db.query (get_order) [■■] 45ms
  │    │
  │    └─ Inventory Service [■■■■■] 600ms
  │         │
  │         └─ db.query (check_stock) [■■■] 80ms
  │
  └─ Payment Service [■■■■■■■■■■■■■■■■■■■] 1600ms
       │
       ├─ HTTP POST /charge [■■■■■■■■■■■■] 1200ms  ← external API
       │
       └─ db.query (save_transaction) [■■] 55ms
```

Immediately visible: the bottleneck is the external payment API (1200ms).

### OpenTelemetry

OpenTelemetry (OTEL) is a standard and SDK for generating and exporting telemetry (traces, metrics, logs). Vendor-neutral: write once, send to Jaeger, Datadog, New Relic — without changing code.

**Propagation: W3C Trace Context**

Standard HTTP headers for passing span context between services:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             │  │                                │                │
             │  trace_id (16 bytes, hex)         span_id          flags
             version                             (8 bytes, hex)   (sampled=1)

tracestate: vendor1=value1,vendor2=value2  (optional, vendor-specific)
```

### Sampling: Head-Based vs Tail-Based

**Head-based sampling** — the decision is made at the start of the trace (on the first span):

```
Incoming request
      │
      ▼
   Sample?  ──→ [Random 10%] ──→ YES → entire trace is recorded
                                  NO → trace is ignored entirely
```

Pros: low overhead, simplicity.
Cons: you don't know in advance whether the trace will be interesting. Errors (1% of requests) may not make it into the sample.

**Tail-based sampling** — the decision is made after the trace completes:

```
All spans collected in a buffer (OTEL Collector)
      │
      ▼
Trace complete → Analysis:
  - has error? → KEEP
  - latency > 1s? → KEEP
  - normal request → DROP (90% discarded)
```

Pros: guarantees all anomalous traces are saved.
Cons: requires keeping all spans in memory until the trace completes, more complex to configure, needs OTEL Collector.

**Recommendation:**
- Start with head-based at 10-20%
- If volume becomes a problem → switch to tail-based in OTEL Collector
- For critical operations (payment, auth) — always 100% sampling

### Go Example: OpenTelemetry SDK + HTTP Middleware + gRPC Interceptor

```go
package telemetry

import (
    "context"
    "fmt"
    "net/http"
    "time"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/codes"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
    "go.opentelemetry.io/otel/propagation"
    "go.opentelemetry.io/otel/sdk/resource"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.21.0"
    "go.opentelemetry.io/otel/trace"
    "google.golang.org/grpc"
    "google.golang.org/grpc/status"
)

// InitTracer — initializes the OTEL TracerProvider
// Called once at application startup
func InitTracer(ctx context.Context, serviceName, serviceVersion, otlpEndpoint string) (func(context.Context) error, error) {
    // Exporter: sends traces to OTEL Collector via HTTP
    exporter, err := otlptracehttp.New(ctx,
        otlptracehttp.WithEndpoint(otlpEndpoint),
        otlptracehttp.WithInsecure(),
    )
    if err != nil {
        return nil, fmt.Errorf("create OTLP exporter: %w", err)
    }

    // Resource — service description (appears in every span)
    res, err := resource.New(ctx,
        resource.WithAttributes(
            semconv.ServiceName(serviceName),
            semconv.ServiceVersion(serviceVersion),
        ),
    )
    if err != nil {
        return nil, fmt.Errorf("create resource: %w", err)
    }

    // TracerProvider with batch exporter (more efficient than sync)
    tp := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(exporter),
        sdktrace.WithResource(res),
        // Head-based sampling: 10% of traffic
        sdktrace.WithSampler(sdktrace.TraceIDRatioBased(0.1)),
    )

    // Register as global provider
    otel.SetTracerProvider(tp)

    // Register W3C Trace Context propagator
    otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
        propagation.TraceContext{},
        propagation.Baggage{},
    ))

    // Return shutdown function
    return tp.Shutdown, nil
}

var tracer = otel.Tracer("orders-service")

// TracingMiddleware — HTTP middleware that creates a span for each request
func TracingMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // Extract span context from incoming headers (W3C Trace Context)
        ctx := otel.GetTextMapPropagator().Extract(r.Context(), propagation.HeaderCarrier(r.Header))

        // Create a new span
        ctx, span := tracer.Start(ctx, fmt.Sprintf("%s %s", r.Method, r.URL.Path),
            trace.WithSpanKind(trace.SpanKindServer),
            trace.WithAttributes(
                semconv.HTTPMethod(r.Method),
                semconv.HTTPRoute(r.URL.Path),
                semconv.HTTPScheme("http"),
            ),
        )
        defer span.End()

        lrw := &tracingResponseWriter{ResponseWriter: w, status: http.StatusOK}
        next.ServeHTTP(lrw, r.WithContext(ctx))

        span.SetAttributes(semconv.HTTPStatusCode(lrw.status))
        if lrw.status >= 500 {
            span.SetStatus(codes.Error, "server error")
        }
    })
}

type tracingResponseWriter struct {
    http.ResponseWriter
    status int
}

func (w *tracingResponseWriter) WriteHeader(status int) {
    w.status = status
    w.ResponseWriter.WriteHeader(status)
}

// NewTracingHTTPClient — creates an HTTP client with automatic span injection
func NewTracingHTTPClient() *http.Client {
    return &http.Client{
        Transport: &tracingTransport{base: http.DefaultTransport},
        Timeout:   30 * time.Second,
    }
}

type tracingTransport struct {
    base http.RoundTripper
}

func (t *tracingTransport) RoundTrip(r *http.Request) (*http.Response, error) {
    ctx, span := tracer.Start(r.Context(), fmt.Sprintf("HTTP %s %s", r.Method, r.URL.Host),
        trace.WithSpanKind(trace.SpanKindClient),
        trace.WithAttributes(
            semconv.HTTPMethod(r.Method),
            semconv.HTTPURL(r.URL.String()),
        ),
    )
    defer span.End()

    // Inject span context into outgoing request headers
    otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(r.Header))

    resp, err := t.base.RoundTrip(r.WithContext(ctx))
    if err != nil {
        span.RecordError(err)
        span.SetStatus(codes.Error, err.Error())
        return nil, err
    }

    span.SetAttributes(semconv.HTTPStatusCode(resp.StatusCode))
    return resp, nil
}

// UnaryServerInterceptor — gRPC interceptor for incoming requests
func UnaryServerInterceptor() grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
        // For gRPC, propagation goes through metadata, not headers
        // otelgrpc.UnaryServerInterceptor() from go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc
        // does this automatically — use it in production

        ctx, span := tracer.Start(ctx, info.FullMethod,
            trace.WithSpanKind(trace.SpanKindServer),
            trace.WithAttributes(
                attribute.String("rpc.system", "grpc"),
                attribute.String("rpc.method", info.FullMethod),
            ),
        )
        defer span.End()

        resp, err := handler(ctx, req)
        if err != nil {
            span.RecordError(err)
            if s, ok := status.FromError(err); ok {
                span.SetAttributes(attribute.String("rpc.grpc.status_code", s.Code().String()))
            }
            span.SetStatus(codes.Error, err.Error())
        }

        return resp, err
    }
}

// Example usage in business logic
func processOrderWithTracing(ctx context.Context, orderID string) error {
    // Child span for a specific operation
    ctx, span := tracer.Start(ctx, "process_order",
        trace.WithAttributes(attribute.String("order.id", orderID)),
    )
    defer span.End()

    // Add events to span
    span.AddEvent("fetching inventory")

    if err := checkInventory(ctx, orderID); err != nil {
        span.RecordError(err)
        span.SetStatus(codes.Error, "inventory check failed")
        return err
    }

    span.AddEvent("inventory confirmed")
    span.SetAttributes(attribute.Bool("order.fulfilled", true))

    return nil
}
```

**Initialization in `main.go`:**
```go
func main() {
    ctx := context.Background()

    shutdown, err := telemetry.InitTracer(ctx,
        "orders-service",
        "v1.2.3",
        "otel-collector:4318",  // OTEL Collector endpoint
    )
    if err != nil {
        log.Fatal("init tracer:", err)
    }
    defer shutdown(ctx)

    // Chain middlewares: tracing → correlation → logging → metrics → handler
    handler := telemetry.TracingMiddleware(
        CorrelationMiddleware(
            LoggingMiddleware(
                metrics.MetricsMiddleware(mux),
            ),
        ),
    )

    http.ListenAndServe(":8080", handler)
}
```

### Jaeger and Tempo

**Jaeger** — open-source backend from Uber, part of CNCF. Stores traces and provides a UI for searching and visualizing them.

**Grafana Tempo** — a newer backend optimized for storing large volumes of traces. Integrates with Grafana, supports exemplars (linking metrics to traces).

```
OTEL SDK → OTEL Collector → Jaeger / Tempo → Grafana / Jaeger UI
```

---

## 5. OpenTelemetry — The Unified Standard

### History: CNCF Merger

Before 2019 there were two competing standards:
- **OpenTracing** — a standard for distributed tracing (without implementation)
- **OpenCensus** — a Google SDK for traces and metrics

They solved similar problems but were incompatible. In 2019, CNCF merged them into **OpenTelemetry** — a unified standard for traces, metrics, and logs.

### OpenTelemetry Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     APPLICATION                                 │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                   OTEL SDK                               │   │
│  │                                                          │   │
│  │  Auto-instrumentation   +   Manual instrumentation       │   │
│  │  (HTTP, gRPC, DB libs)      (business logic)            │   │
│  │                                                          │   │
│  │  Traces ──┐                                              │   │
│  │  Metrics ─┼──→  Exporters  ──→  OTLP (gRPC/HTTP)        │   │
│  │  Logs   ──┘                                              │   │
│  └──────────────────────────────────────────────────────────┘   │
└────────────────────────────────┬────────────────────────────────┘
                                 │ OTLP
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                    OTEL COLLECTOR                               │
│                                                                 │
│  Receivers   →   Processors   →   Exporters                    │
│  (OTLP,          (batch,           (Jaeger,                    │
│   Jaeger,         filter,           Prometheus,                │
│   Zipkin,         sample,           Datadog,                   │
│   Prometheus)     transform)        Tempo, S3...)              │
└─────────────────────────────────────────────────────────────────┘
```

### OTEL Collector: Why You Need It

You can send traces directly from the application to Jaeger. But the Collector provides:
- **Batching** — not every span as a separate request
- **Retry** — spans are buffered if the backend is unavailable
- **Sampling** — tail-based sampling here, not in the application
- **Fan-out** — send traces to Jaeger and metrics to Prometheus simultaneously
- **Vendor decoupling** — change the backend by changing the Collector config, without touching the application

### Example OTEL Collector Configuration

```yaml
# otel-collector-config.yaml

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

  # Accept metrics from Prometheus-compatible services
  prometheus:
    config:
      scrape_configs:
        - job_name: 'otel-collector'
          static_configs:
            - targets: ['localhost:8888']

processors:
  batch:
    timeout: 5s
    send_batch_size: 512

  # Filter out health-check spans — not needed in storage
  filter:
    error_mode: ignore
    traces:
      span:
        - 'attributes["http.route"] == "/healthz"'
        - 'attributes["http.route"] == "/readyz"'

  # Tail-based sampling: keep errors and slow requests
  tail_sampling:
    decision_wait: 10s
    num_traces: 100000
    policies:
      - name: errors
        type: status_code
        status_code: {status_codes: [ERROR]}
      - name: slow-requests
        type: latency
        latency: {threshold_ms: 1000}
      - name: sample-rest
        type: probabilistic
        probabilistic: {sampling_percentage: 10}

  # Add environment attributes
  resource:
    attributes:
      - key: deployment.environment
        value: production
        action: upsert

exporters:
  # Traces → Jaeger
  otlp/jaeger:
    endpoint: jaeger:4317
    tls:
      insecure: true

  # Traces → Grafana Tempo
  otlp/tempo:
    endpoint: tempo:4317
    tls:
      insecure: true

  # Metrics → Prometheus (Collector as Prometheus exporter)
  prometheus:
    endpoint: "0.0.0.0:8889"

  # Logs → Loki
  loki:
    endpoint: http://loki:3100/loki/api/v1/push

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch, filter, tail_sampling, resource]
      exporters: [otlp/jaeger, otlp/tempo]

    metrics:
      receivers: [otlp, prometheus]
      processors: [batch, resource]
      exporters: [prometheus]

    logs:
      receivers: [otlp]
      processors: [batch, resource]
      exporters: [loki]
```

### Auto-Instrumentation in Go

OTEL provides contrib libraries that automatically instrument popular frameworks:

```go
import (
    // HTTP server
    "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
    // gRPC
    "go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
    // database/sql
    "go.opentelemetry.io/contrib/instrumentation/database/sql/otelsql"
    // Redis
    "go.opentelemetry.io/contrib/instrumentation/github.com/go-redis/redis/otelredis"
)

// HTTP server — automatically creates spans for each request
handler := otelhttp.NewHandler(mux, "orders-service")

// gRPC — automatic tracing of incoming and outgoing calls
grpcServer := grpc.NewServer(
    grpc.UnaryInterceptor(otelgrpc.UnaryServerInterceptor()),
    grpc.StreamInterceptor(otelgrpc.StreamServerInterceptor()),
)

// database/sql — spans for each SQL query
db, err := otelsql.Open("postgres", dsn, otelsql.WithAttributes(
    semconv.DBSystemPostgreSQL,
))
```

### Connecting the Three Pillars via Exemplars

An Exemplar is a link from a point on a metrics graph to a specific trace:

```
Grafana: I see a spike in http_request_duration_seconds (p99 = 3.2s) at 14:23

  └──→ click on the point on the graph

  └──→ Exemplar: trace_id=abc123def456

  └──→ opens Jaeger/Tempo with this trace

  └──→ I see the specific request with 3.2s duration
       └──→ Payment Service: 2.8s
            └──→ I see span attributes: payment_provider=stripe, timeout=true
```

Prometheus supports exemplars starting from version 2.26. In Go:

```go
httpRequestDuration.With(prometheus.Labels{
    "method": r.Method,
    "path":   r.URL.Path,
}).ObserveWithExemplar(
    duration,
    prometheus.Labels{"trace_id": traceID},
)
```

---

## 6. Health Checks and Readiness Probes

### Liveness vs Readiness vs Startup

Kubernetes uses three types of probes to manage the Pod lifecycle:

```
┌────────────────────────────────────────────────────────────────┐
│                  POD LIFECYCLE PROBES                          │
│                                                                │
│  STARTUP PROBE                                                 │
│  ├── Goal: service is still starting (heavy initialization)   │
│  ├── On fail: Pod restarts                                     │
│  └── Checked only until first success                          │
│                                                                │
│  LIVENESS PROBE                                                │
│  ├── Goal: service is alive (no deadlock, not hung)           │
│  ├── On fail: Pod restarts                                     │
│  └── Checked throughout the Pod's lifetime                     │
│                                                                │
│  READINESS PROBE                                               │
│  ├── Goal: service is ready to accept traffic                  │
│  ├── On fail: Pod is removed from Service Endpoints           │
│  └── Traffic does not flow until success                       │
└────────────────────────────────────────────────────────────────┘
```

**Critically important rule:**

- `/liveness` (`/healthz`) — **minimal** check: "I'm not hung". Don't check dependencies (DB, Redis) — if the DB is unavailable, don't restart the Pod, wait for the DB to recover.
- `/readiness` (`/readyz`) — check **all dependencies**: DB is available, cache is connected, external APIs are responding. If not ready — remove yourself from rotation.

**Anti-pattern:**
```go
// BAD — liveness checks the DB
// If DB goes down → all Pods restart → thundering herd on recovery
func livenessHandler(w http.ResponseWriter, r *http.Request) {
    if err := db.PingContext(r.Context()); err != nil {
        w.WriteHeader(http.StatusServiceUnavailable)
        return
    }
    w.WriteHeader(http.StatusOK)
}
```

### Go Example: `/healthz` and `/readyz`

```go
package health

import (
    "context"
    "database/sql"
    "encoding/json"
    "net/http"
    "sync/atomic"
    "time"
)

type Checker struct {
    db    *sql.DB
    redis RedisClient
    ready atomic.Bool  // set after initialization
}

type HealthResponse struct {
    Status  string            `json:"status"`
    Checks  map[string]string `json:"checks,omitempty"`
    Version string            `json:"version"`
}

// LivenessHandler — minimal check: process is alive
// Kubernetes restarts the Pod if the endpoint does not respond
func (c *Checker) LivenessHandler(w http.ResponseWriter, r *http.Request) {
    // Only: "I am responding to HTTP requests"
    // No DB, Redis, or external service checks
    resp := HealthResponse{
        Status:  "ok",
        Version: "v1.2.3",
    }
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(http.StatusOK)
    json.NewEncoder(w).Encode(resp)
}

// ReadinessHandler — full check for readiness to accept traffic
func (c *Checker) ReadinessHandler(w http.ResponseWriter, r *http.Request) {
    if !c.ready.Load() {
        w.Header().Set("Content-Type", "application/json")
        w.WriteHeader(http.StatusServiceUnavailable)
        json.NewEncoder(w).Encode(HealthResponse{
            Status: "not_ready",
            Checks: map[string]string{"init": "in_progress"},
        })
        return
    }

    ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
    defer cancel()

    checks := make(map[string]string)
    allOk := true

    // PostgreSQL check
    if err := c.db.PingContext(ctx); err != nil {
        checks["postgres"] = "fail: " + err.Error()
        allOk = false
    } else {
        checks["postgres"] = "ok"
    }

    // Redis check
    if err := c.redis.Ping(ctx); err != nil {
        checks["redis"] = "fail: " + err.Error()
        allOk = false
    } else {
        checks["redis"] = "ok"
    }

    resp := HealthResponse{
        Checks:  checks,
        Version: "v1.2.3",
    }

    if allOk {
        resp.Status = "ok"
        w.Header().Set("Content-Type", "application/json")
        w.WriteHeader(http.StatusOK)
    } else {
        resp.Status = "degraded"
        w.Header().Set("Content-Type", "application/json")
        w.WriteHeader(http.StatusServiceUnavailable)
    }

    json.NewEncoder(w).Encode(resp)
}

// MarkReady — called after successful initialization of all components
func (c *Checker) MarkReady() {
    c.ready.Store(true)
}

type RedisClient interface {
    Ping(ctx context.Context) error
}
```

**Registration in main:**
```go
func main() {
    db := connectDB()
    rdb := connectRedis()

    checker := &health.Checker{DB: db, Redis: rdb}

    mux := http.NewServeMux()
    mux.HandleFunc("/healthz", checker.LivenessHandler)   // liveness
    mux.HandleFunc("/readyz", checker.ReadinessHandler)   // readiness
    mux.Handle("/metrics", promhttp.Handler())

    // Async initialization of dependencies
    go func() {
        if err := warmupCache(db); err != nil {
            log.Fatal("cache warmup failed:", err)
        }
        checker.MarkReady()
        slog.Info("service is ready")
    }()

    http.ListenAndServe(":8080", mux)
}
```

**Readiness output when all dependencies are healthy:**
```json
{
  "status": "ok",
  "checks": {
    "postgres": "ok",
    "redis": "ok"
  },
  "version": "v1.2.3"
}
```

### Kubernetes Probe Configuration

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-service
spec:
  template:
    spec:
      containers:
      - name: orders-service
        image: orders-service:v1.2.3
        ports:
        - containerPort: 8080

        # Startup probe: give 60 seconds to start
        # Check every 5 seconds, max 12 attempts = 60s
        startupProbe:
          httpGet:
            path: /healthz
            port: 8080
          failureThreshold: 12
          periodSeconds: 5
          timeoutSeconds: 2

        # Liveness probe: restart if hung
        # Only after successful startupProbe
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 0   # startupProbe already ran
          periodSeconds: 15
          timeoutSeconds: 3
          failureThreshold: 3      # 3 consecutive failures → restart

        # Readiness probe: removes from Service Endpoints if not ready
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
          successThreshold: 1

        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
```

**What happens during a deployment:**

```
1. New Pod starts
2. startupProbe checks /healthz every 5s
3. After first success → startupProbe deactivates
4. readinessProbe starts checking /readyz
5. After success → Pod is added to Endpoints → traffic flows
6. livenessProbe runs continuously
7. During rolling update: old Pod receives traffic until new one is ready
```

---

## 7. Incident Management

### On-Call: Rotation and Runbooks

**On-call rotation** — a duty system in which one engineer is assigned to receive alerts at a specific time.

```
Week 1: Ivan    (primary) + Maria   (backup)
Week 2: Maria   (primary) + Sergey  (backup)
Week 3: Sergey  (primary) + Ivan    (backup)
```

Principles of a healthy rotation:
- **No more than 2 wake-ups per night** — otherwise burnout within a month
- **Alert → fix → back to sleep** — every alert must have a runbook
- **Fair load distribution** — account for night and weekend shifts in planning
- **Handoff** — transfer context of active incidents when rotating

**Runbook** — a document describing how to respond to a specific alert. Structure:

```markdown
# Runbook: HighErrorRate — Orders Service

## Severity: P1
## Alert: error_rate > 1% for 5 minutes

## Diagnosis (5 minutes)

1. Open Grafana → Orders Service Dashboard
2. Check error rate by endpoint: find the specific path
3. Open Jaeger → search by `service=orders-svc AND error=true`
4. Check logs: `kubectl logs -l app=orders-svc --since=10m | grep ERROR`

## Possible Causes and Actions

### DB Unavailable
- Symptom: error "connection refused" / "timeout"
- Action: `kubectl get pods -n postgres`, check PgBouncer
- Escalation: DBA on-call if PostgreSQL pod is in CrashLoop

### External API (Payment)
- Symptom: error from payment-svc, span `HTTP POST /charge` > 5s
- Action: check the provider's status page
- Mitigation: enable circuit breaker: `kubectl set env deploy/orders-svc PAYMENT_CIRCUIT_BREAKER=open`

### Degradation Due to Deployment
- Symptom: errors started after a deployment (check Deployments timeline)
- Action: rollback: `kubectl rollout undo deployment/orders-svc`

## Escalation
- 15 minutes without progress → page tech lead
- Payments affected → immediately page CTO
```

### Alerting: Severity Levels and Routing

```
┌────────────────────────────────────────────────────────────────┐
│                    SEVERITY MATRIX                             │
│                                                                │
│  P0 — CRITICAL                                                 │
│  ├── Full outage, sales stopped, data being lost              │
│  ├── Immediate response 24/7                                   │
│  └── Routing: PagerDuty → call → SMS → backup                │
│                                                                │
│  P1 — HIGH                                                     │
│  ├── Significant degradation, some users are affected         │
│  ├── Response within 15 minutes                               │
│  └── Routing: PagerDuty → notification → call if 15m no ack  │
│                                                                │
│  P2 — MEDIUM                                                   │
│  ├── Degradation is noticeable, but system is working         │
│  ├── Response during business hours                           │
│  └── Routing: Slack #alerts-p2, ticket in Jira               │
│                                                                │
│  P3 — LOW                                                      │
│  ├── Anomalies worth investigating                             │
│  ├── Response within sprint planning                          │
│  └── Routing: Slack #alerts-p3, automated ticket             │
└────────────────────────────────────────────────────────────────┘
```

**Example Alertmanager configuration:**
```yaml
# alertmanager.yml
global:
  slack_api_url: 'https://hooks.slack.com/...'
  pagerduty_url: 'https://events.pagerduty.com/...'

route:
  group_by: ['alertname', 'service']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
  receiver: slack-default

  routes:
    # P0/P1 → PagerDuty
    - match:
        severity: critical
      receiver: pagerduty-critical
      continue: true  # also send to Slack

    # P0/P1 → also to Slack
    - match_re:
        severity: critical|high
      receiver: slack-critical

    # P2 → Slack
    - match:
        severity: medium
      receiver: slack-p2

receivers:
  - name: pagerduty-critical
    pagerduty_configs:
      - routing_key: '<PD_ROUTING_KEY>'
        severity: critical
        description: '{{ .CommonAnnotations.summary }}'

  - name: slack-critical
    slack_configs:
      - channel: '#incidents'
        text: |
          *{{ .GroupLabels.alertname }}* — {{ .CommonAnnotations.summary }}
          Severity: {{ .CommonLabels.severity }}
          Service: {{ .CommonLabels.service }}
          <{{ .GeneratorURL }}|View in Prometheus>

  - name: slack-p2
    slack_configs:
      - channel: '#alerts-p2'
        send_resolved: true
```

### Post-Mortem: Blameless, Timeline, Action Items

**Blameless post-mortem** — an incident analysis without assigning blame. The goal is to understand systemic causes, not punish a person.

**Why blameless works:** if people fear punishment, they hide information. A complete picture of an incident is only possible if everyone is honest about their actions.

**Post-mortem structure:**

```markdown
# Post-Mortem: Orders Service Outage — 2024-01-15

## Severity: P1
## Duration: 14:23 — 14:58 (35 minutes)
## Impact: ~15,000 users could not place an order, ~$45,000 in lost revenue

## Summary
At 14:23, the error rate on orders-service rose to 100%. Cause: PostgreSQL
connection pool exhaustion due to slow queries after deploying a new
version (v1.3.0), which contained an N+1 query in the getOrderWithItems() method.

## Timeline

| Time | Event |
|------|-------|
| 14:15 | Deployment of orders-service v1.3.0 completed |
| 14:23 | Alert: HighErrorRate P1 fires |
| 14:25 | On-call (Ivan) acknowledged the alert |
| 14:28 | Opened Jaeger, found slow span: db.query 8s |
| 14:33 | Code review: N+1 query found in v1.3.0 |
| 14:35 | Decision: rollback to v1.2.3 |
| 14:38 | Rollback initiated |
| 14:42 | Rollback complete, error rate dropped to 0% |
| 14:58 | Incident closed, monitoring stable |

## Root Cause
N+1 query: when fetching an order with 50 line items, 51 SQL queries were
executed instead of 1 (JOIN). Under 200 RPS load, the connection pool
(max_connections=50) was exhausted in ~3 seconds.

## Contributing Factors
- No automated query count checks in tests
- Code review missed the N+1 (no SQL query analyzer in CI)
- Staging has a small data volume → N+1 didn't appear there

## Action Items

| Action | Owner | Due Date | Priority |
|--------|-------|----------|----------|
| Add pganalyze/go-sqlmock query count assertions to tests | Sergey | 2024-01-22 | P1 |
| Configure automatic EXPLAIN ANALYZE for slow queries | Maria | 2024-01-29 | P2 |
| Increase staging data volume to 10% of production | DevOps | 2024-02-05 | P2 |
| Add alert on db_pool_utilization > 80% | Ivan | 2024-01-19 | P1 |

## What Went Well
- Alert fired quickly (3 minutes after incident began)
- Tracing allowed finding the root cause quickly (5 minutes)
- Rollback completed without issues
```

### Error Budget and Response to Exhaustion

**SLO** (Service Level Objective) — a reliability target. For example: 99.9% of requests succeed.

**Error budget** — the allowable volume of errors. With an SLO of 99.9% over 30 days:
- 30 days × 24h × 60m = 43,200 minutes
- 0.1% × 43,200 = 43.2 minutes of downtime per month

```
Error Budget = 100% - SLO% = 0.1%

┌────────────────────────────────────────────────────────────┐
│               ERROR BUDGET STATUS (January)                │
│                                                            │
│  Total: 43.2 minutes                                       │
│  Used: 38.5 minutes (89%)                                  │
│                                                            │
│  [████████████████████████████████████░░░░] 89%           │
│                                                            │
│  Remaining: 4.7 minutes until end of month                 │
└────────────────────────────────────────────────────────────┘
```

**Response to error budget exhaustion:**

```
Budget > 50% remaining:
  → Normal process. Feature development continues.

Budget 25-50% remaining:
  → Discussion at planning. Reliability work is prioritized.
  → Tech debt + potential risks added to backlog.

Budget < 25% remaining:
  → Feature freeze on risky changes.
  → Team focuses on reliability tasks.

Budget exhausted (0%):
  → Only critical bugfixes and hotfixes.
  → Full freeze on new features until next period.
  → Post-mortem: why did we reach 0%?
```

**Key principle**: the error budget is a contract between product and engineering. Product wants features (risk → lower budget). Engineering wants reliability (less risk → more budget). The error budget makes this trade-off visible and measurable.

---

## Final Observability Stack Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     PRODUCTION OBSERVABILITY STACK                      │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                    APPLICATION LAYER                             │   │
│  │                                                                  │   │
│  │  Go Service                                                      │   │
│  │  ├── slog (structured JSON logs → stdout)                        │   │
│  │  ├── prometheus/client_golang (metrics → /metrics)              │   │
│  │  └── OTEL SDK (traces + metrics → OTLP)                        │   │
│  └───────────────┬──────────────────┬───────────────────────────────┘   │
│                  │ stdout           │ OTLP + /metrics scrape            │
│                  ▼                  ▼                                   │
│  ┌─────────────────┐    ┌─────────────────────────────────────────┐    │
│  │  Fluent Bit     │    │          OTEL Collector                  │    │
│  │  (log shipping) │    │  Processors: batch, filter, sampling    │    │
│  └───────┬─────────┘    └──────────┬──────────────┬───────────────┘    │
│          │                         │              │                     │
│          ▼                         ▼              ▼                     │
│  ┌───────────────┐    ┌────────────────┐   ┌───────────────┐           │
│  │     Loki      │    │ Jaeger / Tempo │   │  Prometheus   │           │
│  │  (log store)  │    │ (trace store)  │   │ (metric store)│           │
│  └───────┬───────┘    └───────┬────────┘   └───────┬───────┘           │
│          │                    │                    │                    │
│          └────────────────────┼────────────────────┘                   │
│                               ▼                                        │
│                    ┌──────────────────┐                                │
│                    │     Grafana      │                                │
│                    │                  │                                │
│                    │  Dashboards      │                                │
│                    │  Alerting        │                                │
│                    │  Log search      │                                │
│                    │  Trace viewer    │                                │
│                    └────────┬─────────┘                               │
│                             │ alerts                                   │
│                             ▼                                          │
│                    ┌──────────────────┐                                │
│                    │  Alertmanager    │──→ PagerDuty / Slack           │
│                    └──────────────────┘                                │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Checklist: What Must Be in Production

### Logging
- [ ] Structured JSON logging (`slog` or `zerolog`)
- [ ] Correlation ID / Trace ID in every log entry
- [ ] Log levels configured (INFO in prod, DEBUG via env)
- [ ] PII does not appear in logs
- [ ] Logs are centralized (Loki / EFK)
- [ ] Retention policy configured (30-90 days)

### Metrics
- [ ] RED metrics for every HTTP/gRPC endpoint
- [ ] USE metrics for resources (CPU, memory, connection pools)
- [ ] `/metrics` endpoint in Prometheus-compatible format
- [ ] Grafana dashboards with Golden Signals
- [ ] Alerts on SLO violations, not on system metrics
- [ ] Alertmanager with routing by severity

### Tracing
- [ ] OTEL SDK initialized at startup
- [ ] HTTP middleware creates a span for each request
- [ ] W3C Trace Context propagation configured
- [ ] gRPC interceptors for tracing
- [ ] Sampling strategy chosen (start with 10% head-based)
- [ ] Trace ID in structured logs

### Health Checks
- [ ] `/healthz` liveness endpoint (only "I'm alive")
- [ ] `/readyz` readiness endpoint (all dependencies)
- [ ] Kubernetes probes configured (startup + liveness + readiness)
- [ ] MarkReady() called after initialization

### Incident Management
- [ ] On-call rotation configured in PagerDuty / OpsGenie
- [ ] Runbooks for every P0/P1 alert
- [ ] Blameless post-mortem process
- [ ] SLOs defined, error budget tracked
- [ ] Escalation paths documented

---

## What's Next

- **Module 10**: Security — authentication, authorization, secrets management
- **Module 11**: Performance — profiling Go applications, optimization
- **Module 12**: CI/CD and DevOps practices

---

*Module 09 of the System Design course for backend developers*
