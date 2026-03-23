# Модуль 09: Наблюдаемость (Observability)

> **Для кого**: бэкенд-разработчики, которые хотят понять, что происходит с их системой в production — не угадывать, а знать.
>
> **Что внутри**: Logs, Metrics, Traces, OpenTelemetry, Health Checks, Incident Management. Полный стек от инструментов до процессов.

---

## Содержание

1. [Три столпа наблюдаемости](#1-три-столпа-наблюдаемости)
2. [Логирование](#2-логирование)
3. [Метрики](#3-метрики)
4. [Distributed Tracing](#4-distributed-tracing)
5. [OpenTelemetry — единый стандарт](#5-opentelemetry--единый-стандарт)
6. [Health Checks и Readiness Probes](#6-health-checks-и-readiness-probes)
7. [Incident Management](#7-incident-management)

---

## 1. Три столпа наблюдаемости

### Monitoring vs Observability

Это не синонимы, и путаница между ними стоит денег.

**Monitoring** — это знание о том, **что** сломалось. Ты заранее определил метрики, настроил пороги, получил алерт: `error_rate > 5%`. Отлично. Но почему? Мониторинг не отвечает.

**Observability** — это способность понять **почему** сломалось, задавая произвольные вопросы к системе без предварительной подготовки. Ты смотришь на трейс конкретного запроса, видишь, что `orders-service` потратил 2.3s на вызов `inventory-service`, видишь в логах `timeout waiting for DB connection`, видишь в метриках, что connection pool исчерпан. Вопрос задан → ответ получен.

```
MONITORING:                          OBSERVABILITY:
"Что сломалось?"                     "Почему сломалось?"

 CPU > 90%  ──→  ALERT               Запрос X → Service A → Service B
 Error rate ──→  ALERT                  └── 2300ms здесь
 Disk full  ──→  ALERT               Лог: "pool exhausted"
                                     Метрика: active_connections = 100/100
 Ответ: что-то не так               Ответ: исчерпан connection pool
```

### Logs, Metrics, Traces

Три разных инструмента решают разные задачи:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        OBSERVABILITY STACK                          │
│                                                                     │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────────────┐    │
│  │    LOGS      │   │   METRICS    │   │       TRACES         │    │
│  │              │   │              │   │                      │    │
│  │ Что именно   │   │ Как система  │   │ Как запрос проходит  │    │
│  │ произошло    │   │ себя чувст-  │   │ через сервисы        │    │
│  │ и когда      │   │ вует сейчас  │   │                      │    │
│  │              │   │              │   │                      │    │
│  │ Elasticsearch│   │  Prometheus  │   │  Jaeger / Tempo      │    │
│  │ Loki         │   │  VictoriaM.  │   │  Zipkin              │    │
│  └──────────────┘   └──────────────┘   └──────────────────────┘    │
│                                                                     │
│  Связаны через: trace_id в логах, exemplars в метриках              │
└─────────────────────────────────────────────────────────────────────┘
```

### Таблица: что какой инструмент решает

| Вопрос | Инструмент | Почему |
|--------|-----------|--------|
| Какой процент запросов завершился ошибкой за последние 5 минут? | Metrics | Агрегированные числа — это метрики |
| Что именно произошло при конкретном запросе пользователя X? | Logs | Детальный контекст события |
| Почему запрос к /checkout занял 3 секунды? | Traces | Видна цепочка вызовов с таймингами |
| Сколько памяти потребляет сервис прямо сейчас? | Metrics (Gauge) | Текущее состояние ресурса |
| Какая строка кода выбросила исключение? | Logs | Stack trace — это лог |
| Какой микросервис является bottleneck? | Traces | Span duration по сервисам |
| Когда начался деградейшн? | Metrics | Временной ряд |
| Что было в HTTP-запросе пользователя, который словил 500? | Logs | Структурированная запись события |
| Почему упала производительность после деплоя? | Metrics + Traces | Сравнение временных рядов + путь запроса |

### Как они связаны

Три столпа наиболее ценны, когда они **связаны** друг с другом через единый `trace_id`:

```
Метрика: http_request_duration{status="500"} spike в 14:23

       ↓ drill down по trace_id из exemplar

Трейс: trace_id=abc123, duration=4200ms
  └─ orders-svc: 120ms
  └─ inventory-svc: 4050ms  ← аномалия
       └─ db query: 3980ms  ← здесь

       ↓ открываем логи по trace_id=abc123

Лог: time=14:23:01 level=ERROR trace_id=abc123
     msg="query timeout" query="SELECT * FROM inventory WHERE..."
     duration=3980ms db_host=postgres-1
```

---

## 2. Логирование

### Structured Logging: JSON вместо plain text

Plain text логи были нормой 15 лет назад. Сейчас — это антипаттерн.

**Plain text (плохо):**
```
2024-01-15 14:23:01 ERROR Failed to process order 12345 for user 67890: timeout
```

Как это парсить? `grep`, `awk`, `sed`, регулярки. Хрупко, медленно, не масштабируется.

**Structured JSON (правильно):**
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

Почему JSON обязателен:
- **Индексируется** — Elasticsearch, Loki автоматически создают поля для фильтрации
- **Агрегируется** — `avg(duration_ms)` по `order_id` — одна строка в Kibana
- **Не ломается** — добавил поле, ни один парсер не сломался
- **Корреляция** — `trace_id` связывает лог с трейсом

### Уровни логирования

| Уровень | Когда использовать | Пример |
|---------|-------------------|--------|
| `DEBUG` | Детали для разработки, не нужны в production | "Executing query: SELECT ..." |
| `INFO` | Нормальные события жизненного цикла | "Server started on :8080", "Order created" |
| `WARN` | Что-то неожиданное, но система работает | "Retry attempt 2/3", "Cache miss rate > 50%" |
| `ERROR` | Операция завершилась неудачей, требует внимания | "Failed to save order", "Database connection lost" |
| `FATAL` | Сервис не может продолжить работу, exit | "Failed to connect to DB at startup" |

**Правила:**
- `DEBUG` в production — только через динамическое переключение, не всегда
- `INFO` — каждое важное бизнес-событие (order created, payment processed)
- Не логировать каждый HTTP-запрос на `INFO` при 10k RPS — только slow requests или errors
- `ERROR` → должен быть алерт в большинстве случаев
- `FATAL` → немедленный алерт + pagerduty

### Correlation ID

Без Correlation ID (он же `trace_id`, `request_id`) отладка в распределённой системе — это угадайка.

**Проблема:**
```
# 14:23:01 — сотни запросов в секунду
ERROR failed to charge payment
ERROR order not found
WARN slow DB query
INFO payment processed
ERROR inventory update failed
```

Какие из этих логов относятся к одному запросу? Непонятно.

**Решение — Correlation ID:**
```json
{"trace_id":"abc123","msg":"order created","order_id":"42"}
{"trace_id":"abc123","msg":"checking inventory","item_id":"88"}
{"trace_id":"abc123","msg":"inventory reserved","item_id":"88"}
{"trace_id":"abc123","msg":"payment charged","amount":99.99}
{"trace_id":"abc123","msg":"order completed","order_id":"42"}
```

Один `trace_id` — полная история одного запроса.

**Как прокидывать через цепочку вызовов:**

```
Client → API Gateway → Order Service → Payment Service → Notification Service
           генерирует     читает из      читает из          читает из
           X-Request-ID   заголовка      контекста          контекста
           или trace_id   → context      → исходящий        → исходящий
                                           запрос             запрос
```

### Пример на Go: structured logging с `slog` + middleware

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

// ключ для context
type contextKey string

const traceIDKey contextKey = "trace_id"

// Logger — глобальный структурированный логгер
var Logger = slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
    Level: slog.LevelInfo,
}))

// FromContext достаёт logger с уже добавленным trace_id из контекста
func FromContext(ctx context.Context) *slog.Logger {
    if traceID, ok := ctx.Value(traceIDKey).(string); ok {
        return Logger.With("trace_id", traceID)
    }
    return Logger
}

// CorrelationMiddleware — HTTP middleware для прокидывания trace_id
func CorrelationMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // Берём из заголовка (от upstream) или генерируем новый
        traceID := r.Header.Get("X-Trace-Id")
        if traceID == "" {
            traceID = uuid.New().String()
        }

        // Кладём в контекст
        ctx := context.WithValue(r.Context(), traceIDKey, traceID)

        // Пробрасываем в ответ для клиента
        w.Header().Set("X-Trace-Id", traceID)

        // Передаём дальше с обновлённым контекстом
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}

// LoggingMiddleware — логирует каждый HTTP-запрос
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

// Использование в бизнес-логике
func processOrder(ctx context.Context, orderID string) error {
    log := FromContext(ctx)

    log.Info("processing order", "order_id", orderID)

    if err := chargePayment(ctx, orderID); err != nil {
        // Ошибка: добавляем контекст, не теряем trace_id
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
        // бизнес-логика
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

**Вывод в stdout:**
```json
{"time":"2024-01-15T14:23:01.234Z","level":"INFO","msg":"http request","trace_id":"abc123","method":"POST","path":"/orders","status":200,"duration_ms":45}
{"time":"2024-01-15T14:23:01.280Z","level":"INFO","msg":"order completed","trace_id":"abc123","order_id":"42"}
```

### Стек логирования

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

- **Fluent Bit** — легковесный агент (DaemonSet в K8s), читает логи с узла
- **Fluentd** — агрегатор, парсинг, фильтрация, routing
- **Elasticsearch** — хранение и индексирование
- **Kibana** — визуализация, поиск, алерты

**Loki + Grafana (более лёгкая альтернатива):**

```
┌─────────────┐    ┌─────────────┐    ┌─────────┐    ┌─────────┐
│  App Pod    │───>│  Promtail   │───>│  Loki   │───>│ Grafana │
│  (stdout)   │    │ (агент)     │    │(хранение│    │(поиск + │
└─────────────┘    └─────────────┘    │ индексы)│    │дашборды)│
                                      └─────────┘    └─────────┘
```

Loki не индексирует содержимое логов — только метки (labels). Это делает его дешевле Elasticsearch, но менее гибким для full-text search. Выбор зависит от объёма логов и бюджета.

### Best Practices

**Не логировать PII (Personally Identifiable Information):**
```go
// ПЛОХО — номер карты в логе
log.Info("payment processed", "card_number", "4111111111111111")

// ХОРОШО — только последние 4 цифры
log.Info("payment processed", "card_last4", "1111", "payment_id", paymentID)
```

**Не логировать в hot path без sampling:**
```go
// ПЛОХО — 50k RPS × JSON marshal = CPU overhead
func handlePing(w http.ResponseWriter, r *http.Request) {
    log.Info("ping received") // каждый запрос
    w.WriteHeader(200)
}

// ХОРОШО — /healthz не логируем вообще
// или используем sampling для высокочастотных событий

var sampleRate = 0.01 // 1% запросов

func shouldSample() bool {
    return rand.Float64() < sampleRate
}
```

**Уровни в разных окружениях:**
```go
level := slog.LevelInfo
if os.Getenv("ENV") == "development" {
    level = slog.LevelDebug
}
```

**Ошибки с контекстом, не просто `err.Error()`:**
```go
// ПЛОХО
log.Error("error", "err", err)

// ХОРОШО — добавляем контекст
log.Error("failed to fetch user",
    "user_id", userID,
    "attempt", attempt,
    "error", err.Error(),
)
```

---

## 3. Метрики

### Типы метрик

**Counter** — монотонно возрастающий счётчик. Никогда не уменьшается (только при перезапуске → reset to 0).

```
http_requests_total{method="GET", status="200"} 1847293
http_requests_total{method="POST", status="500"} 342
```

Используется для: количество запросов, ошибок, обработанных сообщений.

**Gauge** — произвольное значение, которое может расти и падать.

```
active_connections 42
memory_usage_bytes 104857600
queue_depth 15
```

Используется для: текущее состояние (загруженность пула, количество горутин, использование памяти).

**Histogram** — распределение значений по бакетам. Позволяет считать перцентили.

```
http_request_duration_seconds_bucket{le="0.005"} 24054
http_request_duration_seconds_bucket{le="0.01"}  33444
http_request_duration_seconds_bucket{le="0.025"} 100392
http_request_duration_seconds_bucket{le="0.05"}  129389
http_request_duration_seconds_bucket{le="+Inf"}  144320
http_request_duration_seconds_sum  53423.29
http_request_duration_seconds_count 144320
```

Используется для: latency (p50, p95, p99), размер запросов/ответов.

**Summary** — похож на Histogram, но перцентили считаются на клиенте (в приложении), а не на сервере. Плохо масштабируется на несколько инстансов — не рекомендуется для большинства случаев.

### RED Method

Для **сервисов** (HTTP API, gRPC):

| Метрика | Описание | Prometheus пример |
|---------|----------|-------------------|
| **R**ate | Запросов в секунду | `rate(http_requests_total[5m])` |
| **E**rrors | Процент ошибок | `rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m])` |
| **D**uration | Latency (p50, p95, p99) | `histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))` |

### USE Method

Для **ресурсов** (CPU, memory, disk, network):

| Метрика | Описание | Prometheus пример |
|---------|----------|-------------------|
| **U**tilization | % времени, когда ресурс занят | `rate(cpu_usage_seconds_total[5m])` |
| **S**aturation | Очередь / ожидание ресурса | `node_load1` (queue depth) |
| **E**rrors | Ошибки ресурса | `node_network_errs_total` |

### Google SRE Golden Signals

Четыре метрики, которые покрывают 90% production-проблем:

```
┌─────────────────────────────────────────────────────────────┐
│                    GOLDEN SIGNALS                           │
│                                                             │
│  1. LATENCY        Время ответа (разделять success/error)   │
│     p50 / p95 / p99 — не среднее!                          │
│                                                             │
│  2. TRAFFIC        Нагрузка на систему                      │
│     RPS, QPS, messages/sec, bytes/sec                       │
│                                                             │
│  3. ERRORS         Процент неудачных запросов               │
│     HTTP 5xx, gRPC status != OK, бизнес-ошибки             │
│                                                             │
│  4. SATURATION     Насколько система «полна»                │
│     CPU %, memory %, connection pool %, queue depth        │
└─────────────────────────────────────────────────────────────┘
```

**Почему p99, а не среднее?** Среднее скрывает хвосты. Если 99% запросов занимают 10ms, а 1% — 10 секунд, среднее будет ~110ms. Это нормально выглядит на графике, но 1% пользователей получают ужасный опыт.

### Prometheus: архитектура

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

**Pull model** — Prometheus сам ходит к сервисам по расписанию (по умолчанию каждые 15 секунд). Это отличает его от push-модели (StatsD, Graphite). Преимущества pull:
- Prometheus знает, если сервис недоступен (scrape failed)
- Нет необходимости открывать firewall от сервиса наружу
- Service discovery через K8s, Consul, EC2

**PromQL примеры:**
```promql
# Error rate за последние 5 минут
rate(http_requests_total{status=~"5.."}[5m])
  / rate(http_requests_total[5m]) * 100

# p99 latency
histogram_quantile(0.99,
  rate(http_request_duration_seconds_bucket[5m])
)

# Saturation: connection pool utilization
db_pool_active_connections / db_pool_max_connections * 100

# Запросов в секунду по endpoint
sum by (path) (rate(http_requests_total[1m]))
```

### Пример на Go: HTTP middleware с Prometheus

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
    // Counter — общее количество запросов
    httpRequestsTotal = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "http_requests_total",
            Help: "Total number of HTTP requests",
        },
        []string{"method", "path", "status"},
    )

    // Histogram — распределение latency
    httpRequestDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name: "http_request_duration_seconds",
            Help: "HTTP request duration in seconds",
            // Бакеты: 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s
            Buckets: prometheus.DefBuckets,
        },
        []string{"method", "path"},
    )

    // Gauge — текущее количество обрабатываемых запросов
    httpRequestsInFlight = promauto.NewGauge(
        prometheus.GaugeOpts{
            Name: "http_requests_in_flight",
            Help: "Current number of HTTP requests being processed",
        },
    )
)

// MetricsMiddleware — оборачивает handler, собирает RED метрики
func MetricsMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // Пропускаем /metrics и /healthz — они не бизнес-трафик
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

// RegisterMetricsEndpoint — регистрирует /metrics для Prometheus scrape
func RegisterMetricsEndpoint(mux *http.ServeMux) {
    mux.Handle("/metrics", promhttp.Handler())
}

// Пример бизнес-метрик — дополнительно к RED
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

### Alerting: алертить на SLO, не на CPU

**Плохой алерт:**
```yaml
# Срабатывает при CPU > 80% — но CPU может быть 80% и сервис работает нормально
alert: HighCPU
expr: cpu_usage > 0.8
for: 5m
```

**Хороший алерт — на SLO:**
```yaml
# Срабатывает, когда пользователи реально страдают
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

**Принцип**: алерт должен означать, что кто-то должен проснуться и починить. Алерт на CPU без деградации сервиса — это шум, который убивает доверие к alerting.

### Grafana: ключевые панели дашборда

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

Полезные панели:
- **Single stat / Stat** — текущий RPS, error rate, p99
- **Time series** — динамика метрик во времени
- **Heatmap** — распределение latency по времени (видны паттерны)
- **Table** — топ endpoints по latency или error rate
- **Logs panel** — прямо в Grafana, если используешь Loki

---

## 4. Distributed Tracing

### Проблема

Запрос пришёл в систему, прошёл через 5 сервисов, пользователь получил ответ за 3.2 секунды. Где была задержка?

```
Client ──→ API Gateway ──→ Order Svc ──→ Inventory Svc ──→ Payment Svc
  t=0         t=20ms         t=50ms         t=80ms           t=2100ms

Ответ вернулся через 3200ms. Логи каждого сервиса показывают, что они отработали
быстро. Где потеря 3 секунд?

Без трейсинга: grep по логам с разными timestamp, ручное сопоставление.
С трейсингом: один трейс показывает 2100ms в Payment Svc → DB query timeout.
```

### Концепции

**Trace** — полная запись обработки одного запроса через всю систему. Уникальный `trace_id`.

**Span** — единица работы внутри трейса. Имеет:
- `span_id` — уникальный идентификатор
- `parent_span_id` — ссылка на родительский span (откуда был вызов)
- `trace_id` — какому трейсу принадлежит
- `operation_name` — что делали: `"HTTP POST /orders"`, `"db.query"`
- `start_time`, `end_time` — когда начали и закончили
- `attributes` — пары ключ-значение: `http.status_code=200`, `db.statement="SELECT..."`
- `events` — лог-события внутри span

**Span Context** — минимальный набор данных для продолжения трейса в другом процессе: `trace_id + span_id + flags`.

**Baggage** — произвольные пары ключ-значение, которые передаются через всю цепочку. Используй осторожно — добавляет overhead к каждому запросу.

### Визуализация трейса

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
       ├─ HTTP POST /charge [■■■■■■■■■■■■] 1200ms  ← внешний API
       │
       └─ db.query (save_transaction) [■■] 55ms
```

Сразу видно: bottleneck — внешний payment API (1200ms).

### OpenTelemetry

OpenTelemetry (OTEL) — это стандарт и SDK для генерации и экспорта телеметрии (traces, metrics, logs). Vendor-neutral: написал один раз, отправляешь в Jaeger, Datadog, New Relic — без изменения кода.

**Propagation: W3C Trace Context**

Стандарт HTTP-заголовков для передачи span context между сервисами:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             │  │                                │                │
             │  trace_id (16 bytes, hex)         span_id          flags
             version                             (8 bytes, hex)   (sampled=1)

tracestate: vendor1=value1,vendor2=value2  (опциональный, vendor-специфичный)
```

### Sampling: head-based vs tail-based

**Head-based sampling** — решение принимается в начале трейса (на первом span):

```
Incoming request
      │
      ▼
   Sample?  ──→ [Random 10%] ──→ YES → весь трейс записывается
                                  NO → трейс игнорируется полностью
```

Pros: низкий overhead, простота.
Cons: не знаешь заранее, будет ли трейс интересным. Ошибки (1% запросов) могут не попасть в выборку.

**Tail-based sampling** — решение принимается после завершения трейса:

```
Все spans собираются в буфер (OTEL Collector)
      │
      ▼
Трейс завершён → Анализ:
  - есть ошибка? → ЗАПИСАТЬ
  - latency > 1s? → ЗАПИСАТЬ
  - normal request → DROP (90% отбрасывается)
```

Pros: гарантированно сохраняешь все аномальные трейсы.
Cons: требует держать все spans в памяти до завершения трейса, сложнее в настройке, нужен OTEL Collector.

**Рекомендация:**
- Стартуй с head-based 10-20%
- При проблемах с объёмом → tail-based в OTEL Collector
- Для критических операций (payment, auth) — всегда 100% sampling

### Пример на Go: OpenTelemetry SDK + HTTP middleware + gRPC interceptor

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

// InitTracer — инициализация OTEL TracerProvider
// Вызывается один раз при старте приложения
func InitTracer(ctx context.Context, serviceName, serviceVersion, otlpEndpoint string) (func(context.Context) error, error) {
    // Экспортёр: отправляем трейсы в OTEL Collector по HTTP
    exporter, err := otlptracehttp.New(ctx,
        otlptracehttp.WithEndpoint(otlpEndpoint),
        otlptracehttp.WithInsecure(),
    )
    if err != nil {
        return nil, fmt.Errorf("create OTLP exporter: %w", err)
    }

    // Resource — описание сервиса (появится в каждом span)
    res, err := resource.New(ctx,
        resource.WithAttributes(
            semconv.ServiceName(serviceName),
            semconv.ServiceVersion(serviceVersion),
        ),
    )
    if err != nil {
        return nil, fmt.Errorf("create resource: %w", err)
    }

    // TracerProvider с batch exporter (эффективнее, чем sync)
    tp := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(exporter),
        sdktrace.WithResource(res),
        // Head-based sampling: 10% трафика
        sdktrace.WithSampler(sdktrace.TraceIDRatioBased(0.1)),
    )

    // Регистрируем как глобальный провайдер
    otel.SetTracerProvider(tp)

    // Настраиваем propagation: W3C Trace Context + Baggage
    otel.SetTextMapPropagator(
        propagation.NewCompositeTextMapPropagator(
            propagation.TraceContext{},
            propagation.Baggage{},
        ),
    )

    return tp.Shutdown, nil
}

var tracer = otel.Tracer("orders-service")

// TracingMiddleware — HTTP middleware для автоматического создания spans
func TracingMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // Извлекаем span context из входящих заголовков (W3C traceparent)
        ctx := otel.GetTextMapPropagator().Extract(r.Context(), propagation.HeaderCarrier(r.Header))

        // Создаём span для этого HTTP-запроса
        ctx, span := tracer.Start(ctx, fmt.Sprintf("%s %s", r.Method, r.URL.Path),
            trace.WithSpanKind(trace.SpanKindServer),
            trace.WithAttributes(
                semconv.HTTPMethod(r.Method),
                semconv.HTTPURL(r.URL.String()),
                semconv.HTTPRoute(r.URL.Path),
            ),
        )
        defer span.End()

        lrw := &tracingResponseWriter{ResponseWriter: w, status: http.StatusOK}
        next.ServeHTTP(lrw, r.WithContext(ctx))

        // Добавляем результат в span
        span.SetAttributes(semconv.HTTPStatusCode(lrw.status))
        if lrw.status >= 500 {
            span.SetStatus(codes.Error, fmt.Sprintf("HTTP %d", lrw.status))
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

// TraceHTTPClient — оборачивает http.Client для автоматического propagation
func TraceHTTPClient() *http.Client {
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

    // Инжектируем span context в заголовки исходящего запроса
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

// UnaryServerInterceptor — gRPC interceptor для входящих запросов
func UnaryServerInterceptor() grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
        // Для gRPC propagation через metadata, не headers
        // otelgrpc.UnaryServerInterceptor() из go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc
        // делает это автоматически — используй его в production

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

// Пример использования в бизнес-логике
func processOrderWithTracing(ctx context.Context, orderID string) error {
    // Дочерний span для конкретной операции
    ctx, span := tracer.Start(ctx, "process_order",
        trace.WithAttributes(attribute.String("order.id", orderID)),
    )
    defer span.End()

    // Добавляем события в span
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

**Инициализация в `main.go`:**
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

### Jaeger и Tempo

**Jaeger** — open-source backend от Uber, часть CNCF. Хранит трейсы, предоставляет UI для поиска и визуализации.

**Grafana Tempo** — более новый backend, оптимизированный для хранения больших объёмов трейсов. Интегрируется с Grafana, поддерживает exemplars (связь метрик с трейсами).

```
OTEL SDK → OTEL Collector → Jaeger / Tempo → Grafana / Jaeger UI
```

---

## 5. OpenTelemetry — единый стандарт

### История: CNCF merger

До 2019 существовали два конкурирующих стандарта:
- **OpenTracing** — стандарт для distributed tracing (без реализации)
- **OpenCensus** — SDK от Google для traces и metrics

Они решали похожие задачи, но были несовместимы. В 2019 году CNCF объединила их в **OpenTelemetry** — единый стандарт для traces, metrics и logs.

### Архитектура OpenTelemetry

```
┌─────────────────────────────────────────────────────────────────┐
│                     APPLICATION                                 │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                   OTEL SDK                               │   │
│  │                                                          │   │
│  │  Auto-instrumentation   +   Manual instrumentation       │   │
│  │  (HTTP, gRPC, DB libs)      (бизнес-логика)             │   │
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

### OTEL Collector: зачем нужен

Можно отправлять трейсы напрямую в Jaeger из приложения. Но Collector даёт:
- **Батчинг** — не каждый span отдельным запросом
- **Retry** — если backend недоступен, spans буферизируются
- **Sampling** — tail-based sampling здесь, не в приложении
- **Fan-out** — отправить трейсы в Jaeger, а метрики в Prometheus одновременно
- **Vendor decoupling** — меняешь backend, меняешь конфиг Collector, не трогаешь приложение

### Пример конфигурации OTEL Collector

```yaml
# otel-collector-config.yaml

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

  # Принимаем метрики от Prometheus-совместимых сервисов
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

  # Фильтруем health-check спаны — не нужны в хранилище
  filter:
    error_mode: ignore
    traces:
      span:
        - 'attributes["http.route"] == "/healthz"'
        - 'attributes["http.route"] == "/readyz"'

  # Tail-based sampling: сохраняем ошибки и медленные запросы
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

  # Добавляем атрибуты окружения
  resource:
    attributes:
      - key: deployment.environment
        value: production
        action: upsert

exporters:
  # Трейсы → Jaeger
  otlp/jaeger:
    endpoint: jaeger:4317
    tls:
      insecure: true

  # Трейсы → Grafana Tempo
  otlp/tempo:
    endpoint: tempo:4317
    tls:
      insecure: true

  # Метрики → Prometheus (Collector как Prometheus-экспортёр)
  prometheus:
    endpoint: "0.0.0.0:8889"

  # Логи → Loki
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

### Auto-instrumentation в Go

OTEL предоставляет contrib-библиотеки, которые автоматически инструментируют популярные фреймворки:

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

// HTTP server — автоматически создаёт spans для каждого запроса
handler := otelhttp.NewHandler(mux, "orders-service")

// gRPC — автоматический tracing входящих и исходящих вызовов
grpcServer := grpc.NewServer(
    grpc.UnaryInterceptor(otelgrpc.UnaryServerInterceptor()),
    grpc.StreamInterceptor(otelgrpc.StreamServerInterceptor()),
)

// database/sql — spans для каждого SQL-запроса
db, err := otelsql.Open("postgres", dsn, otelsql.WithAttributes(
    semconv.DBSystemPostgreSQL,
))
```

### Связь между тремя столпами через Exemplars

Exemplar — это ссылка из точки на графике метрики на конкретный трейс:

```
Grafana: вижу spike на http_request_duration_seconds (p99 = 3.2s) в 14:23

  └──→ кликаю на точку на графике

  └──→ Exemplar: trace_id=abc123def456

  └──→ открывается Jaeger/Tempo с этим трейсом

  └──→ вижу конкретный запрос с 3.2s duration
       └──→ Payment Service: 2.8s
            └──→ вижу атрибуты span: payment_provider=stripe, timeout=true
```

Prometheus поддерживает exemplars начиная с версии 2.26. В Go:

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

## 6. Health Checks и Readiness Probes

### Liveness vs Readiness vs Startup

Kubernetes использует три типа проб для управления жизненным циклом Pod:

```
┌────────────────────────────────────────────────────────────────┐
│                  POD LIFECYCLE PROBES                          │
│                                                                │
│  STARTUP PROBE                                                 │
│  ├── Цель: сервис ещё стартует (тяжёлая инициализация)        │
│  ├── Если fail: Pod перезапускается                            │
│  └── Проверяется только до первого success                     │
│                                                                │
│  LIVENESS PROBE                                                │
│  ├── Цель: сервис живой (не deadlock, не hung)                 │
│  ├── Если fail: Pod перезапускается                            │
│  └── Проверяется всю жизнь Pod                                 │
│                                                                │
│  READINESS PROBE                                               │
│  ├── Цель: сервис готов принимать трафик                       │
│  ├── Если fail: Pod удаляется из Service Endpoints            │
│  └── Трафик не идёт до success                                 │
└────────────────────────────────────────────────────────────────┘
```

**Критически важное правило:**

- `/liveness` (`/healthz`) — **минимальная** проверка: "я не завис". Не проверяй зависимости (БД, Redis) — если БД недоступна, не надо перезапускать Pod, надо ждать восстановления БД.
- `/readiness` (`/readyz`) — проверяй **все зависимости**: БД доступна, кеш подключён, внешние API отвечают. Если не готов — убирайся из rotation.

**Антипаттерн:**
```go
// ПЛОХО — liveness проверяет БД
// Если БД упала → все Pods перезапускаются → thundering herd при восстановлении
func livenessHandler(w http.ResponseWriter, r *http.Request) {
    if err := db.PingContext(r.Context()); err != nil {
        w.WriteHeader(http.StatusServiceUnavailable)
        return
    }
    w.WriteHeader(http.StatusOK)
}
```

### Пример на Go: `/healthz` и `/readyz`

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
    ready atomic.Bool  // выставляется после инициализации
}

type HealthResponse struct {
    Status  string            `json:"status"`
    Checks  map[string]string `json:"checks,omitempty"`
    Version string            `json:"version"`
}

// LivenessHandler — минимальная проверка: процесс жив
// Kubernetes перезапустит Pod если endpoint не отвечает
func (c *Checker) LivenessHandler(w http.ResponseWriter, r *http.Request) {
    // Только: "я отвечаю на HTTP-запросы"
    // Никаких проверок БД, Redis, внешних сервисов
    resp := HealthResponse{
        Status:  "ok",
        Version: "v1.2.3",
    }
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(http.StatusOK)
    json.NewEncoder(w).Encode(resp)
}

// ReadinessHandler — полная проверка готовности принимать трафик
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

    // Проверка PostgreSQL
    if err := c.db.PingContext(ctx); err != nil {
        checks["postgres"] = "fail: " + err.Error()
        allOk = false
    } else {
        checks["postgres"] = "ok"
    }

    // Проверка Redis
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

// MarkReady — вызывается после успешной инициализации всех компонентов
func (c *Checker) MarkReady() {
    c.ready.Store(true)
}

type RedisClient interface {
    Ping(ctx context.Context) error
}
```

**Регистрация в main:**
```go
func main() {
    db := connectDB()
    rdb := connectRedis()

    checker := &health.Checker{DB: db, Redis: rdb}

    mux := http.NewServeMux()
    mux.HandleFunc("/healthz", checker.LivenessHandler)   // liveness
    mux.HandleFunc("/readyz", checker.ReadinessHandler)   // readiness
    mux.Handle("/metrics", promhttp.Handler())

    // Инициализация async-зависимостей
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

**Вывод readiness при всех зависимостях в норме:**
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

### Kubernetes Probe конфигурация

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

        # Startup probe: даём 60 секунд на запуск
        # Проверяем каждые 5 секунд, максимум 12 попыток = 60s
        startupProbe:
          httpGet:
            path: /healthz
            port: 8080
          failureThreshold: 12
          periodSeconds: 5
          timeoutSeconds: 2

        # Liveness probe: перезапуск если зависает
        # Только после успешного startupProbe
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 0   # startupProbe уже отработал
          periodSeconds: 15
          timeoutSeconds: 3
          failureThreshold: 3      # 3 провала подряд → restart

        # Readiness probe: убирает из Service Endpoints если не готов
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

**Что происходит при деплое:**

```
1. Новый Pod стартует
2. startupProbe проверяет /healthz каждые 5s
3. После первого success → startupProbe деактивируется
4. readinessProbe начинает проверять /readyz
5. После success → Pod добавляется в Endpoints → трафик идёт
6. livenessProbe работает всё время
7. При rolling update: старый Pod получает трафик пока новый не ready
```

---

## 7. Incident Management

### On-Call: ротация и runbooks

**On-call ротация** — система дежурств, при которой один инженер назначен получать алерты в определённое время.

```
Неделя 1: Иван    (основной) + Мария   (резерв)
Неделя 2: Мария   (основной) + Сергей  (резерв)
Неделя 3: Сергей  (основной) + Иван    (резерв)
```

Принципы здоровой ротации:
- **Не больше 2 будильников в ночь** — иначе выгорание за месяц
- **Рабочий алерт → починка → сон продолжается** — алерт должен иметь runbook
- **Справедливая нагрузка** — учёт ночных и выходных дежурств при планировании
- **Handoff** — передача контекста активных инцидентов при смене

**Runbook** — документ, описывающий как реагировать на конкретный алерт. Структура:

```markdown
# Runbook: HighErrorRate — Orders Service

## Severity: P1
## Алерт: error_rate > 1% на протяжении 5 минут

## Диагностика (5 минут)

1. Открыть Grafana → Orders Service Dashboard
2. Проверить error rate по endpoint: найти конкретный path
3. Открыть Jaeger → поиск по `service=orders-svc AND error=true`
4. Проверить логи: `kubectl logs -l app=orders-svc --since=10m | grep ERROR`

## Возможные причины и действия

### БД недоступна
- Признак: error "connection refused" / "timeout"
- Действие: `kubectl get pods -n postgres`, проверить PgBouncer
- Эскалация: DBA on-call если PostgreSQL pod в CrashLoop

### Внешний API (Payment)
- Признак: error от payment-svc, span `HTTP POST /charge` > 5s
- Действие: открыть статус-страницу провайдера
- Mitigation: включить circuit breaker: `kubectl set env deploy/orders-svc PAYMENT_CIRCUIT_BREAKER=open`

### Деградация из-за деплоя
- Признак: ошибки начались после деплоя (check Deployments timeline)
- Действие: rollback: `kubectl rollout undo deployment/orders-svc`

## Эскалация
- 15 минут без прогресса → page tech lead
- Затронуты платежи → немедленно page CTO
```

### Alerting: severity levels и routing

```
┌────────────────────────────────────────────────────────────────┐
│                    SEVERITY MATRIX                             │
│                                                                │
│  P0 — CRITICAL                                                 │
│  ├── Полный outage, продажи стоят, данные теряются            │
│  ├── Немедленная реакция 24/7                                  │
│  └── Routing: PagerDuty → звонок → SMS → резерв              │
│                                                                │
│  P1 — HIGH                                                     │
│  ├── Значительная деградация, часть пользователей страдает    │
│  ├── Реакция в течение 15 минут                               │
│  └── Routing: PagerDuty → уведомление → звонок если 15m нет  │
│                                                                │
│  P2 — MEDIUM                                                   │
│  ├── Деградация заметна, но система работает                  │
│  ├── Реакция в рабочее время                                  │
│  └── Routing: Slack #alerts-p2, тикет в Jira                 │
│                                                                │
│  P3 — LOW                                                      │
│  ├── Аномалии, которые стоит изучить                          │
│  ├── Реакция в рамках sprint planning                         │
│  └── Routing: Slack #alerts-p3, автоматический тикет         │
└────────────────────────────────────────────────────────────────┘
```

**Пример конфигурации Alertmanager:**
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
      continue: true  # также отправить в Slack

    # P0/P1 → также в Slack
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

### Post-Mortem: blameless, timeline, action items

**Blameless post-mortem** — анализ инцидента без поиска виноватых. Цель — понять системные причины, не наказать человека.

**Почему blameless работает:** если люди боятся наказания, они скрывают информацию. Полная картина инцидента возможна только если все честны о своих действиях.

**Структура post-mortem:**

```markdown
# Post-Mortem: Orders Service Outage — 2024-01-15

## Severity: P1
## Duration: 14:23 — 14:58 (35 минут)
## Impact: ~15,000 пользователей не смогли оформить заказ, ~$45,000 потерянная выручка

## Summary
В 14:23 error rate orders-service поднялся до 100%. Причина: истощение
connection pool PostgreSQL из-за медленных запросов после деплоя новой
версии (v1.3.0), содержавшей N+1 query в методе getOrderWithItems().

## Timeline

| Время | Событие |
|-------|---------|
| 14:15 | Деплой orders-service v1.3.0 завершён |
| 14:23 | Алерт: HighErrorRate P1 срабатывает |
| 14:25 | On-call (Иван) принял алерт |
| 14:28 | Открыт Jaeger, найден медленный span: db.query 8s |
| 14:33 | Изучение кода: обнаружен N+1 query в v1.3.0 |
| 14:35 | Решение: rollback до v1.2.3 |
| 14:38 | Rollback запущен |
| 14:42 | Rollback завершён, error rate упал до 0% |
| 14:58 | Инцидент закрыт, мониторинг стабилен |

## Root Cause
N+1 query: при запросе заказа с 50 позициями выполнялось 51 SQL-запрос
вместо 1 (JOIN). При нагрузке 200 RPS connection pool (max_connections=50)
исчерпывался за ~3 секунды.

## Contributing factors
- Нет автоматической проверки query count в тестах
- Code review не поймал N+1 (нет SQL query analyzer в CI)
- Staging имеет малый объём данных → N+1 не проявился

## Action Items

| Действие | Владелец | Срок | Приоритет |
|---------|---------|------|-----------|
| Добавить pganalyze/go-sqlmock query count assertions в тесты | Сергей | 2024-01-22 | P1 |
| Настроить автоматические EXPLAIN ANALYZE для медленных запросов | Мария | 2024-01-29 | P2 |
| Увеличить staging data volume до 10% production | DevOps | 2024-02-05 | P2 |
| Добавить алерт на db_pool_utilization > 80% | Иван | 2024-01-19 | P1 |

## What went well
- Алерт сработал быстро (3 минуты после начала инцидента)
- Трейсинг позволил быстро найти root cause (5 минут)
- Rollback прошёл без проблем
```

### Error Budget и реакция на его исчерпание

**SLO** (Service Level Objective) — цель надёжности. Например: 99.9% запросов успешны.

**Error budget** — допустимый объём ошибок. При SLO 99.9% за 30 дней:
- 30 дней × 24h × 60m = 43,200 минут
- 0.1% × 43,200 = 43.2 минуты downtime в месяц

```
Error Budget = 100% - SLO% = 0.1%

┌────────────────────────────────────────────────────────────┐
│               ERROR BUDGET STATUS (January)                │
│                                                            │
│  Всего: 43.2 минуты                                        │
│  Использовано: 38.5 минуты (89%)                           │
│                                                            │
│  [████████████████████████████████████░░░░] 89%           │
│                                                            │
│  Осталось: 4.7 минуты до конца месяца                      │
└────────────────────────────────────────────────────────────┘
```

**Реакция на исчерпание error budget:**

```
Бюджет > 50% остатка:
  → Нормальный процесс. Feature development продолжается.

Бюджет 25-50% остатка:
  → Обсуждение на planning. Reliability работы приоритизируются.
  → Tech debt + потенциальные риски в backlog.

Бюджет < 25% остатка:
  → Feature freeze на рискованные изменения.
  → Команда фокусируется на reliability tasks.

Бюджет исчерпан (0%):
  → Только критические bugfixes и hotfixes.
  → Полный freeze новых фич до нового периода.
  → Post-mortem: почему дошли до 0%?
```

**Ключевой принцип**: error budget — это договор между product и engineering. Product хочет фичи (риск → меньше бюджет). Engineering хочет надёжность (меньше риска → больше бюджет). Error budget делает этот компромисс видимым и измеримым.

---

## Итоговая архитектура Observability Stack

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

## Чек-лист: что должно быть в production

### Логирование
- [ ] Structured JSON logging (`slog` или `zerolog`)
- [ ] Correlation ID / Trace ID в каждом логе
- [ ] Уровни логирования настроены (INFO в prod, DEBUG через env)
- [ ] PII не попадает в логи
- [ ] Логи централизованы (Loki / EFK)
- [ ] Retention policy настроен (30-90 дней)

### Метрики
- [ ] RED метрики для каждого HTTP/gRPC endpoint
- [ ] USE метрики для ресурсов (CPU, memory, connection pools)
- [ ] `/metrics` endpoint с Prometheus-совместимым форматом
- [ ] Grafana дашборды с Golden Signals
- [ ] Алерты на SLO нарушения, не на системные метрики
- [ ] Alertmanager с routing по severity

### Tracing
- [ ] OTEL SDK инициализирован при старте
- [ ] HTTP middleware создаёт span для каждого запроса
- [ ] W3C Trace Context propagation настроен
- [ ] gRPC interceptors для трейсинга
- [ ] Sampling strategy выбрана (start with 10% head-based)
- [ ] Trace ID в структурированных логах

### Health Checks
- [ ] `/healthz` liveness endpoint (только "я жив")
- [ ] `/readyz` readiness endpoint (все зависимости)
- [ ] Kubernetes probes настроены (startup + liveness + readiness)
- [ ] MarkReady() вызывается после инициализации

### Incident Management
- [ ] On-call ротация настроена в PagerDuty / OpsGenie
- [ ] Runbooks для каждого P0/P1 алерта
- [ ] Post-mortem процесс blameless
- [ ] SLO определены, error budget tracked
- [ ] Escalation paths задокументированы

---

## Что дальше

- **Модуль 10**: Security — аутентификация, авторизация, secrets management
- **Модуль 11**: Performance — профилирование Go-приложений, оптимизация
- **Модуль 12**: CI/CD и DevOps практики

---

*Модуль 09 из курса System Design для бэкенд-разработчиков*
