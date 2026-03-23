# Модуль 10: Надёжность и отказоустойчивость

> **Главный принцип:** Failure is inevitable. Проектируй систему так, чтобы она выдерживала отказы, а не рассчитывай, что они не случатся.

---

## Содержание

1. [Принципы надёжности](#1-принципы-надёжности)
2. [Circuit Breaker](#2-circuit-breaker)
3. [Retry и Exponential Backoff](#3-retry-и-exponential-backoff)
4. [Rate Limiting](#4-rate-limiting)
5. [Timeout и Deadline Propagation](#5-timeout-и-deadline-propagation)
6. [Load Shedding](#6-load-shedding)
7. [Chaos Engineering](#7-chaos-engineering)
8. [Disaster Recovery](#8-disaster-recovery)

---

## 1. Принципы надёжности

### Failure is inevitable

Любой компонент системы рано или поздно откажет: диск переполнится, сеть потеряет пакеты, зависимый сервис упадёт, приложение словит OOM. Вопрос не «упадёт ли?», а «что система сделает, когда это произойдёт?».

Ошибочный подход — строить систему в расчёте на её безотказность. Правильный — проектировать каждый компонент так, словно он **уже сломан**, а всё остальное должно с этим справляться.

```
Три уровня зрелости в работе с отказами:

Уровень 1 (плохо):  Failure → Полный отказ системы
Уровень 2 (средне): Failure → Ошибка для пользователя, но система жива
Уровень 3 (хорошо): Failure → Деградация, но пользователь видит результат
```

### Blast radius: минимизация зоны поражения

Blast radius — это масштаб ущерба от одного инцидента. Цель: локализовать отказ, не дать ему распространиться.

**Техники снижения blast radius:**

| Техника | Что делает | Пример |
|---|---|---|
| Bulkhead | Изолирует пулы ресурсов | Отдельные thread pool для каждого downstream |
| Shard | Делит данные/трафик на части | Пользователи A-M на одном шарде, N-Z на другом |
| Cell-based architecture | Независимые ячейки системы | Каждая ячейка = 1% пользователей |
| Feature flags | Отключение функциональности | Убрать тяжёлую рекомендацию при нагрузке |
| Circuit breaker | Останавливает cascade | Рассмотрим подробно в разделе 2 |

**Bulkhead pattern — пример:**

```
БЕЗ bulkhead:                    С bulkhead:

[Все запросы]                    [Критичные запросы] [Обычные запросы]
       ↓                                ↓                    ↓
[Общий thread pool]              [Pool A: 50 threads] [Pool B: 50 threads]
       ↓                                ↓                    ↓
ServiceB зависает →          ServiceB зависает →    Pool A исчерпан,
все 100 threads заняты →     Pool A исчерпан,       Pool B работает нормально
весь сервис встал            критичные запросы ждут,
                             но обычные не страдают
```

### Graceful degradation

Лучше показать пользователю устаревшие кешированные данные, чем вернуть 500. Лучше показать топ-10 без персонализации, чем заблокировать страницу.

```
Полная функциональность:     Деградация:              Минимум:
┌─────────────────────┐     ┌─────────────────────┐  ┌─────────────────────┐
│ Персонализированные │     │ Популярные товары   │  │ Статическая         │
│ рекомендации        │ --> │ из кеша             │  │ страница-заглушка   │
│ Реальные цены       │     │ Кешированные цены   │  │ "Скоро вернёмся"    │
│ Актуальный остаток  │     │ Остаток: "В наличии" │  │                     │
└─────────────────────┘     └─────────────────────┘  └─────────────────────┘
     Всё работает           RecommendationService      Всё упало
                            или PricingService упали
```

**Реализация в коде:**

```go
func (s *ProductService) GetProduct(ctx context.Context, id string) (*Product, error) {
    // Пробуем получить актуальные данные
    product, err := s.db.GetProduct(ctx, id)
    if err == nil {
        return product, nil
    }

    // Деградируем: берём из кеша
    cached, cacheErr := s.cache.Get(ctx, "product:"+id)
    if cacheErr == nil {
        // Помечаем, что данные могут быть устаревшими
        cached.Stale = true
        return cached, nil
    }

    // Полный отказ — только теперь возвращаем ошибку
    return nil, fmt.Errorf("product %s unavailable: %w", id, err)
}
```

### Fail-fast

Если зависимость мертва — не жди timeout в 30 секунд. Провались быстро, освободи ресурсы, дай клиенту шанс попробовать другой инстанс или обработать ошибку.

```
БЕЗ fail-fast:                   С fail-fast:

t=0  Запрос к ServiceB           t=0  Запрос к ServiceB
t=0  ServiceB не отвечает        t=0  Circuit breaker OPEN
...  (30 секунд ожидания)        t=0  Немедленный возврат ошибки
t=30 Timeout                     t=0  Клиент использует fallback
t=30 Клиент получает ошибку
     За это время: 30s * N RPS   За это время: 0s задержки
     = N*30 зависших соединений  = 0 зависших соединений
```

### Design for failure

Чеклист при проектировании каждого нового компонента:

- [ ] Что будет, если этот сервис упадёт? Кто от него зависит?
- [ ] Есть ли timeout на все внешние вызовы?
- [ ] Есть ли retry с backoff?
- [ ] Есть ли circuit breaker?
- [ ] Есть ли fallback / cached response?
- [ ] Каков blast radius при отказе?
- [ ] Как это поведение тестируется?

---

## 2. Circuit Breaker

### Проблема: каскадные отказы

Один упавший сервис может положить всю систему через цепочку зависимостей:

```
Cascade failure без circuit breaker:

t=0:  ServiceC начинает тормозить (disk full)
      A → B → C (запросы накапливаются в B, ждут C)

t=5s: B исчерпал thread pool, начинает тормозить
      A → B (запросы накапливаются в A, ждут B)

t=10s: A исчерпал thread pool
       Clients → A (всё зависло)

t=15s: Вся система недоступна из-за одного диска в C
```

Circuit breaker разрывает цепочку: если C не отвечает, B не ждёт, а сразу возвращает ошибку.

### State Machine

```
                    failure_count >= threshold
         ┌──────────────────────────────────────────┐
         │                                          │
         ▼                                          │
   ┌──────────┐   Успешный запрос            ┌──────────┐
   │          │ ◄──────────────────────────  │          │
   │  CLOSED  │                              │   OPEN   │
   │          │ ──────────────────────────►  │          │
   └──────────┘   failure_count >= threshold └──────────┘
         ▲                                          │
         │                                          │ timeout истёк
         │   Успех (probe запрос)                   │
         │                                          ▼
         │                                  ┌──────────────┐
         └─────────────────────────────────  │  HALF-OPEN   │
                                             │              │
                   Отказ (probe запрос)      └──────────────┘
                   ──────────────────────────────────────────►
                   (возврат в OPEN)
```

**Три состояния:**

| Состояние | Поведение | Переход |
|---|---|---|
| **CLOSED** | Запросы проходят нормально, считаем ошибки | → OPEN, если failures ≥ threshold |
| **OPEN** | Все запросы немедленно отклоняются (fail-fast) | → HALF-OPEN, когда истёк timeout |
| **HALF-OPEN** | Пропускаем ограниченное число probe-запросов | → CLOSED при успехе; → OPEN при ошибке |

### Параметры Circuit Breaker

| Параметр | Типичное значение | Описание |
|---|---|---|
| `failure_threshold` | 50% за 10s или 5 подряд | Сколько ошибок открывают breaker |
| `open_timeout` | 10–60s | Сколько breaker остаётся открытым |
| `half_open_max_requests` | 1–5 | Сколько probe-запросов в HALF-OPEN |
| `min_requests` | 10–20 | Минимум запросов для анализа % ошибок |

### Пример на Go: sony/gobreaker

```go
package circuitbreaker

import (
    "context"
    "errors"
    "fmt"
    "time"

    "github.com/sony/gobreaker"
)

// Обёртка над HTTP-клиентом с circuit breaker
type ResilientClient struct {
    cb     *gobreaker.CircuitBreaker
    client HTTPClient
}

func NewResilientClient(name string, client HTTPClient) *ResilientClient {
    settings := gobreaker.Settings{
        Name: name,

        // Открываем breaker, если за последние 10s:
        // - больше 5 запросов И более 60% — ошибки
        ReadyToTrip: func(counts gobreaker.Counts) bool {
            failureRatio := float64(counts.TotalFailures) / float64(counts.Requests)
            return counts.Requests >= 5 && failureRatio >= 0.6
        },

        // Breaker остаётся открытым 30s
        Timeout: 30 * time.Second,

        // Callback при изменении состояния
        OnStateChange: func(name string, from gobreaker.State, to gobreaker.State) {
            fmt.Printf("[CircuitBreaker] %s: %s → %s\n", name, from, to)
            // Здесь можно отправить метрику в Prometheus/Datadog
        },
    }

    return &ResilientClient{
        cb:     gobreaker.NewCircuitBreaker(settings),
        client: client,
    }
}

func (c *ResilientClient) Get(ctx context.Context, url string) ([]byte, error) {
    result, err := c.cb.Execute(func() (interface{}, error) {
        // Эта функция выполняется только в состоянии CLOSED или HALF-OPEN
        return c.client.Get(ctx, url)
    })

    if err != nil {
        // Различаем: breaker открыт или реальная ошибка сервиса
        if errors.Is(err, gobreaker.ErrOpenState) {
            return nil, fmt.Errorf("circuit breaker open for %s: service unavailable", url)
        }
        return nil, fmt.Errorf("request failed: %w", err)
    }

    return result.([]byte), nil
}
```

**Своя реализация (минимальная):**

```go
package circuitbreaker

import (
    "errors"
    "sync"
    "time"
)

type State int

const (
    StateClosed State = iota
    StateOpen
    StateHalfOpen
)

var ErrCircuitOpen = errors.New("circuit breaker is open")

type CircuitBreaker struct {
    mu sync.Mutex

    state            State
    failureCount     int
    successCount     int
    failureThreshold int
    openTimeout      time.Duration
    halfOpenMaxReqs  int
    lastFailureTime  time.Time
    halfOpenRequests int
}

func New(failureThreshold int, openTimeout time.Duration, halfOpenMaxReqs int) *CircuitBreaker {
    return &CircuitBreaker{
        state:            StateClosed,
        failureThreshold: failureThreshold,
        openTimeout:      openTimeout,
        halfOpenMaxReqs:  halfOpenMaxReqs,
    }
}

func (cb *CircuitBreaker) Allow() bool {
    cb.mu.Lock()
    defer cb.mu.Unlock()

    switch cb.state {
    case StateClosed:
        return true

    case StateOpen:
        // Проверяем, не истёк ли таймаут
        if time.Since(cb.lastFailureTime) > cb.openTimeout {
            cb.state = StateHalfOpen
            cb.halfOpenRequests = 0
            return true
        }
        return false

    case StateHalfOpen:
        if cb.halfOpenRequests < cb.halfOpenMaxReqs {
            cb.halfOpenRequests++
            return true
        }
        return false
    }

    return false
}

func (cb *CircuitBreaker) RecordSuccess() {
    cb.mu.Lock()
    defer cb.mu.Unlock()

    cb.failureCount = 0

    if cb.state == StateHalfOpen {
        cb.successCount++
        if cb.successCount >= cb.halfOpenMaxReqs {
            cb.state = StateClosed
            cb.successCount = 0
        }
    }
}

func (cb *CircuitBreaker) RecordFailure() {
    cb.mu.Lock()
    defer cb.mu.Unlock()

    cb.failureCount++
    cb.lastFailureTime = time.Now()

    if cb.failureCount >= cb.failureThreshold || cb.state == StateHalfOpen {
        cb.state = StateOpen
        cb.failureCount = 0
        cb.successCount = 0
    }
}

func (cb *CircuitBreaker) Execute(fn func() error) error {
    if !cb.Allow() {
        return ErrCircuitOpen
    }

    err := fn()
    if err != nil {
        cb.RecordFailure()
        return err
    }

    cb.RecordSuccess()
    return nil
}
```

### Circuit Breaker в действии: ASCII timeline

```
t=0   ServiceC работает нормально
      A──►B──►C  ✓  ✓  ✓  ✓  ✓

t=10  ServiceC начинает падать (failure_threshold = 5)
      A──►B──►C  ✗  ✗  ✗  ✗  ✗
                    ↑
                Счётчик ошибок достиг порога

t=10  Circuit Breaker B→C переходит в OPEN
      A──►B  ✗(немедленно, без ожидания C)
             ↑
         Возвращаем cached response или ошибку

t=40  Истёк open_timeout (30s), переход в HALF-OPEN
      A──►B──►C  (probe-запрос)
               ✓  → Переходим в CLOSED
               ✗  → Возвращаемся в OPEN на ещё 30s
```

---

## 3. Retry и Exponential Backoff

### Когда ретраить, когда нет

```
РЕТРАИТЬ (transient errors):          НЕ РЕТРАИТЬ:
✓ 500 Internal Server Error           ✗ 400 Bad Request
✓ 503 Service Unavailable             ✗ 401 Unauthorized
✓ 429 Too Many Requests (с backoff)   ✗ 403 Forbidden
✓ Network timeout                     ✗ 404 Not Found
✓ Connection refused (transient)      ✗ 422 Unprocessable Entity
✓ gRPC: UNAVAILABLE, DEADLINE_EXCEEDED ✗ Бизнес-ошибки

ИДЕМПОТЕНТНОСТЬ:
✓ Безопасно ретраить: GET, PUT, DELETE
⚠ Осторожно: POST (нужна идемпотентность-ключ)
✗ Никогда не ретраить без защиты: "снять деньги со счёта"
```

### Exponential Backoff

Формула:

```
delay = min(base * 2^attempt + jitter, max_delay)

Пример: base=100ms, max_delay=30s
attempt=0: 100ms + jitter
attempt=1: 200ms + jitter
attempt=2: 400ms + jitter
attempt=3: 800ms + jitter
attempt=4: 1600ms + jitter
attempt=5: 3200ms + jitter (но не более max_delay)
```

### Jitter: зачем нужен

**Thundering herd problem**: если 1000 клиентов получили ошибку одновременно и ретраят через ровно 1 секунду — сервис получит 1000 запросов ровно через 1 секунду. Опять ошибка. Опять 1000 запросов через 2 секунды. И так далее.

**Jitter** добавляет случайность, рассредотачивая retry во времени:

```
БЕЗ jitter:                   С jitter:
t=1.0s ▓▓▓▓▓▓▓▓▓▓ 1000 req   t=0.8s ▓▓ 80 req
                               t=0.9s ▓▓▓ 120 req
                               t=1.0s ▓▓▓▓ 200 req
t=2.0s ▓▓▓▓▓▓▓▓▓▓ 1000 req   t=1.1s ▓▓▓▓ 180 req
                               t=1.2s ▓▓▓ 150 req
                               ...
```

**Два вида jitter:**

```go
// Full jitter: случайное значение от 0 до полного backoff
// Лучше всего для thundering herd
delay = random(0, base * 2^attempt)

// Equal jitter: половина детерминирована, половина случайна
// Гарантирует минимальный backoff
temp  = base * 2^attempt
delay = temp/2 + random(0, temp/2)
```

### Retry Budget

Retry budget — ограничение на уровне всего сервиса: не более X% всех исходящих запросов могут быть retry.

```
Без retry budget:
- Базовый трафик: 1000 RPS
- Retry (3 попытки): до 3000 RPS дополнительно
- Итого: до 4000 RPS на downstream

С retry budget (10%):
- Базовый трафик: 1000 RPS
- Retry: не более 100 RPS (10%)
- Итого: 1100 RPS — downstream защищён
```

### Пример на Go: retry с exponential backoff и jitter

```go
package retry

import (
    "context"
    "errors"
    "math"
    "math/rand"
    "net/http"
    "time"
)

type Config struct {
    MaxAttempts int
    BaseDelay   time.Duration
    MaxDelay    time.Duration
    Multiplier  float64
}

var DefaultConfig = Config{
    MaxAttempts: 3,
    BaseDelay:   100 * time.Millisecond,
    MaxDelay:    30 * time.Second,
    Multiplier:  2.0,
}

// isRetryable определяет, стоит ли ретраить ошибку
func isRetryable(err error) bool {
    var httpErr *HTTPError
    if errors.As(err, &httpErr) {
        // Ретраим только 5xx и 429
        return httpErr.StatusCode >= 500 || httpErr.StatusCode == 429
    }
    // Сетевые ошибки — ретраим
    return true
}

// fullJitter возвращает случайную задержку от 0 до maxDelay
func fullJitter(attempt int, cfg Config) time.Duration {
    exp := math.Pow(cfg.Multiplier, float64(attempt))
    delay := float64(cfg.BaseDelay) * exp
    if delay > float64(cfg.MaxDelay) {
        delay = float64(cfg.MaxDelay)
    }
    // Full jitter: случайное значение от 0 до delay
    return time.Duration(rand.Float64() * delay)
}

// Do выполняет fn с retry по заданному конфигу
func Do(ctx context.Context, cfg Config, fn func(ctx context.Context) error) error {
    var lastErr error

    for attempt := 0; attempt < cfg.MaxAttempts; attempt++ {
        // Проверяем контекст перед каждой попыткой
        if ctx.Err() != nil {
            return ctx.Err()
        }

        err := fn(ctx)
        if err == nil {
            return nil // Успех
        }

        lastErr = err

        // Не ретраим не-retriable ошибки
        if !isRetryable(err) {
            return err
        }

        // Последняя попытка — не ждём
        if attempt == cfg.MaxAttempts-1 {
            break
        }

        delay := fullJitter(attempt, cfg)

        // Ждём с учётом контекста
        select {
        case <-ctx.Done():
            return ctx.Err()
        case <-time.After(delay):
            // Продолжаем
        }
    }

    return fmt.Errorf("all %d attempts failed: %w", cfg.MaxAttempts, lastErr)
}

// Пример использования:
func fetchUser(ctx context.Context, id string) (*User, error) {
    var user *User

    err := retry.Do(ctx, retry.DefaultConfig, func(ctx context.Context) error {
        resp, err := http.Get(fmt.Sprintf("http://user-service/users/%s", id))
        if err != nil {
            return err
        }
        defer resp.Body.Close()

        if resp.StatusCode >= 400 {
            return &HTTPError{StatusCode: resp.StatusCode}
        }

        return json.NewDecoder(resp.Body).Decode(&user)
    })

    return user, err
}
```

**Retry Budget на уровне сервиса:**

```go
package retry

import (
    "sync/atomic"
    "time"
)

// Budget отслеживает соотношение retry к обычным запросам
type Budget struct {
    totalRequests int64
    retryRequests int64
    maxRatio      float64 // например, 0.10 для 10%
    window        time.Duration
}

func NewBudget(maxRatio float64) *Budget {
    b := &Budget{maxRatio: maxRatio, window: time.Minute}

    // Сбрасываем счётчики раз в минуту
    go func() {
        for range time.Tick(b.window) {
            atomic.StoreInt64(&b.totalRequests, 0)
            atomic.StoreInt64(&b.retryRequests, 0)
        }
    }()

    return b
}

func (b *Budget) RecordRequest() {
    atomic.AddInt64(&b.totalRequests, 1)
}

func (b *Budget) AllowRetry() bool {
    total := atomic.LoadInt64(&b.totalRequests)
    retries := atomic.LoadInt64(&b.retryRequests)

    if total == 0 {
        return true
    }

    ratio := float64(retries) / float64(total)
    if ratio >= b.maxRatio {
        return false // Бюджет исчерпан
    }

    atomic.AddInt64(&b.retryRequests, 1)
    return true
}
```

---

## 4. Rate Limiting

### Зачем нужен rate limiting

- **Защита от DDoS**: один клиент не может положить сервис
- **Noisy neighbor**: один тяжёлый клиент не деградирует опыт остальных
- **Abuse prevention**: блокировка бот-трафика, credential stuffing
- **Cost control**: защита от непреднамеренных петель (бесконечный retry)
- **SLA enforcement**: гарантируем fair use между клиентами

### Алгоритмы

#### Token Bucket

Самый распространённый алгоритм. Токены накапливаются со скоростью `rate/sec` до максимума `burst`. Каждый запрос тратит токен.

```
Token Bucket (rate=10/s, burst=20):

t=0:   [████████████████████] 20 токенов
       5 запросов → [███████████████] 15 токенов

t=0.5: [████████████████] 15+5=16 токенов (накопилось 5 за 0.5s)
       10 запросов → [██████] 6 токенов

t=1:   [███████████] 6+10=16 токенов (накопилось 10 за 1s)

Параметры:
  rate  = скорость накопления (10 токенов/сек)
  burst = максимальный запас (позволяет кратковременные всплески)
```

**Плюсы:** позволяет burst трафик. **Минусы:** burst может перегрузить downstream.

#### Leaky Bucket

Запросы поступают в очередь, из очереди выходят с фиксированной скоростью.

```
Leaky Bucket (rate=10/s):

Входящий трафик:  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  (20 req/s)
                         ↓
                    [Очередь: 10]
                         ↓
Исходящий трафик: ▓▓▓▓▓▓▓▓▓▓  (строго 10 req/s)
```

**Плюсы:** строго постоянный выходящий поток. **Минусы:** нет burst, очередь добавляет latency.

#### Fixed Window Counter

Считаем запросы в фиксированных временных окнах (напр., каждую минуту).

```
Fixed Window (limit=100/min):

[00:00-01:00] ████████████████████ 100 req  → LIMIT REACHED
[01:00-02:00] (новое окно, счётчик сброшен)

Проблема edge case:
[00:59] ████████████████████ 100 req (последняя секунда окна 1)
[01:00] ████████████████████ 100 req (первая секунда окна 2)
→ За 2 секунды: 200 запросов! Лимит нарушен.
```

#### Sliding Window Log

Храним timestamp каждого запроса. При каждом новом запросе удаляем устаревшие записи и считаем.

```
Sliding Window Log (limit=100/min):

Текущее время: 01:00:30
Окно: [00:00:30 - 01:00:30]

Log: [00:00:31, 00:01:05, ..., 01:00:28, 01:00:29]
     ^^^^^^^^^^^^^^^^^^^^      ^^^^^^^^^^^^^^^^^^^^
     Удаляем (старше 1 min)    Считаем (101 записей → LIMIT)
```

**Плюсы:** точный. **Минусы:** memory-intensive (храним каждый timestamp).

#### Sliding Window Counter

Компромисс между Fixed Window и Sliding Window Log. Используем два счётчика: текущее и предыдущее окна.

```
Sliding Window Counter (limit=100/min):

Предыдущее окно: 80 запросов
Текущее окно (прошло 30% = 0.3 минуты): 40 запросов

Оценка для скользящего окна:
  weighted = previous * (1 - 0.3) + current
           = 80 * 0.7 + 40
           = 56 + 40 = 96 запросов

96 < 100 → запрос пропускаем
```

### Таблица сравнения алгоритмов

| Алгоритм | Точность | Memory | CPU | Burst | Сложность |
|---|---|---|---|---|---|
| Token Bucket | Высокая | O(1) | O(1) | Да | Низкая |
| Leaky Bucket | Высокая | O(n) | O(1) | Нет | Средняя |
| Fixed Window | Низкая | O(1) | O(1) | Частично | Очень низкая |
| Sliding Window Log | Очень высокая | O(n) | O(n) | Нет | Средняя |
| Sliding Window Counter | Высокая | O(1) | O(1) | Нет | Средняя |

**Рекомендация:** Token Bucket для большинства случаев, Sliding Window Counter для distributed rate limiting.

### Где размещать rate limiter

```
Internet
   │
   ▼
[API Gateway]  ← Rate limit по IP, API key (первый рубеж)
   │
   ▼
[Middleware]   ← Rate limit по пользователю, эндпоинту
   │
   ▼
[Service A]    ← Rate limit на уровне бизнес-логики
   │
   ├──► [Service B]  ← Rate limit на входящие вызовы (защита сервиса)
   │
   └──► [Service C]
```

### Rate Limiting Headers

```http
HTTP/1.1 200 OK
X-RateLimit-Limit: 100        # Лимит для данного периода
X-RateLimit-Remaining: 43     # Осталось запросов
X-RateLimit-Reset: 1711180800 # Unix timestamp сброса окна
Retry-After: 30               # Секунд до следующего запроса (только при 429)

HTTP/1.1 429 Too Many Requests
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 0
X-RateLimit-Reset: 1711180800
Retry-After: 30
Content-Type: application/json

{"error": "rate_limit_exceeded", "retry_after": 30}
```

### Пример на Go: Token Bucket Rate Limiter

```go
package ratelimit

import (
    "net/http"
    "sync"
    "time"
)

type TokenBucket struct {
    mu       sync.Mutex
    tokens   float64
    maxBurst float64
    rate     float64 // токенов в секунду
    lastTime time.Time
}

func NewTokenBucket(rate float64, burst float64) *TokenBucket {
    return &TokenBucket{
        tokens:   burst,
        maxBurst: burst,
        rate:     rate,
        lastTime: time.Now(),
    }
}

// Allow проверяет, можно ли пропустить запрос (тратит 1 токен)
func (tb *TokenBucket) Allow() bool {
    return tb.AllowN(1)
}

// AllowN проверяет, можно ли пропустить запрос, требующий n токенов
func (tb *TokenBucket) AllowN(n float64) bool {
    tb.mu.Lock()
    defer tb.mu.Unlock()

    now := time.Now()
    elapsed := now.Sub(tb.lastTime).Seconds()
    tb.lastTime = now

    // Накапливаем токены пропорционально прошедшему времени
    tb.tokens = min(tb.maxBurst, tb.tokens+elapsed*tb.rate)

    if tb.tokens < n {
        return false
    }

    tb.tokens -= n
    return true
}

func min(a, b float64) float64 {
    if a < b {
        return a
    }
    return b
}

// Middleware для HTTP сервера (per-IP rate limiting)
type IPRateLimiter struct {
    mu       sync.Mutex
    limiters map[string]*TokenBucket
    rate     float64
    burst    float64
}

func NewIPRateLimiter(rate, burst float64) *IPRateLimiter {
    rl := &IPRateLimiter{
        limiters: make(map[string]*TokenBucket),
        rate:     rate,
        burst:    burst,
    }

    // Чистим устаревшие записи раз в минуту
    go func() {
        for range time.Tick(time.Minute) {
            rl.mu.Lock()
            rl.limiters = make(map[string]*TokenBucket)
            rl.mu.Unlock()
        }
    }()

    return rl
}

func (rl *IPRateLimiter) getLimiter(ip string) *TokenBucket {
    rl.mu.Lock()
    defer rl.mu.Unlock()

    if lb, exists := rl.limiters[ip]; exists {
        return lb
    }

    lb := NewTokenBucket(rl.rate, rl.burst)
    rl.limiters[ip] = lb
    return lb
}

func (rl *IPRateLimiter) Middleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        ip := r.RemoteAddr // В production: X-Forwarded-For

        limiter := rl.getLimiter(ip)
        if !limiter.Allow() {
            w.Header().Set("Retry-After", "1")
            http.Error(w, `{"error":"rate_limit_exceeded"}`, http.StatusTooManyRequests)
            return
        }

        next.ServeHTTP(w, r)
    })
}
```

### Distributed Rate Limiting: Redis + Lua

Когда сервис запущен в нескольких инстансах, локальный rate limiter не работает — каждый инстанс видит только свою долю трафика. Решение: централизованный счётчик в Redis.

**Sliding Window Counter через Redis Lua:**

```lua
-- ratelimit.lua
-- KEYS[1] = ключ счётчика (напр. "rl:user:123")
-- ARGV[1] = текущий timestamp (ms)
-- ARGV[2] = размер окна (ms), напр. 60000 для 1 минуты
-- ARGV[3] = лимит

local key = KEYS[1]
local now = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local limit = tonumber(ARGV[3])
local window_start = now - window

-- Удаляем записи старше окна
redis.call('ZREMRANGEBYSCORE', key, '-inf', window_start)

-- Считаем текущее количество запросов в окне
local count = redis.call('ZCARD', key)

if count < limit then
    -- Добавляем текущий запрос (score = timestamp, member = уникальный ID)
    redis.call('ZADD', key, now, now .. '-' .. math.random())
    -- TTL = размер окна + небольшой запас
    redis.call('PEXPIRE', key, window + 1000)
    return {1, limit - count - 1}  -- {allowed, remaining}
else
    return {0, 0}  -- {denied, remaining}
end
```

```go
package ratelimit

import (
    "context"
    _ "embed"
    "fmt"
    "time"

    "github.com/redis/go-redis/v9"
)

//go:embed ratelimit.lua
var luaScript string

type RedisRateLimiter struct {
    client *redis.Client
    script *redis.Script
    limit  int
    window time.Duration
}

func NewRedisRateLimiter(client *redis.Client, limit int, window time.Duration) *RedisRateLimiter {
    return &RedisRateLimiter{
        client: client,
        script: redis.NewScript(luaScript),
        limit:  limit,
        window: window,
    }
}

type Result struct {
    Allowed   bool
    Remaining int
}

func (rl *RedisRateLimiter) Allow(ctx context.Context, key string) (Result, error) {
    now := time.Now().UnixMilli()
    windowMs := rl.window.Milliseconds()

    vals, err := rl.script.Run(ctx, rl.client,
        []string{fmt.Sprintf("rl:%s", key)},
        now,
        windowMs,
        rl.limit,
    ).Int64Slice()

    if err != nil {
        // При ошибке Redis — fail open (пропускаем запрос)
        // В production можно сделать fail closed для критичных эндпоинтов
        return Result{Allowed: true, Remaining: rl.limit}, err
    }

    return Result{
        Allowed:   vals[0] == 1,
        Remaining: int(vals[1]),
    }, nil
}

// HTTP Middleware
func (rl *RedisRateLimiter) Middleware(keyFn func(*http.Request) string) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            key := keyFn(r)
            result, err := rl.Allow(r.Context(), key)

            if err != nil {
                // Логируем ошибку Redis, но не блокируем пользователя
                log.Printf("rate limiter error: %v", err)
            }

            // Устанавливаем headers всегда
            w.Header().Set("X-RateLimit-Limit", fmt.Sprintf("%d", rl.limit))
            w.Header().Set("X-RateLimit-Remaining", fmt.Sprintf("%d", result.Remaining))
            reset := time.Now().Add(rl.window).Unix()
            w.Header().Set("X-RateLimit-Reset", fmt.Sprintf("%d", reset))

            if !result.Allowed {
                retryAfter := int(rl.window.Seconds())
                w.Header().Set("Retry-After", fmt.Sprintf("%d", retryAfter))
                http.Error(w, `{"error":"rate_limit_exceeded"}`, http.StatusTooManyRequests)
                return
            }

            next.ServeHTTP(w, r)
        })
    }
}
```

---

## 5. Timeout и Deadline Propagation

### Почему timeout обязателен на каждый внешний вызов

```
БЕЗ timeout:

t=0    ServiceA вызывает ServiceB
t=5    ServiceB завис (deadlock в БД)
t=∞    ServiceA держит goroutine/thread открытым
       Накапливается N зависших goroutine
       ServiceA исчерпывает ресурсы
       ServiceA падает

С timeout (5s):

t=0    ServiceA вызывает ServiceB с timeout=5s
t=5    Timeout срабатывает
t=5    ServiceA получает context.DeadlineExceeded
t=5    Goroutine освобождается
t=5    ServiceA возвращает ошибку клиенту
       Система остаётся живой
```

Правило: **никогда** не вызывай внешний сервис, БД, очередь без явного timeout.

### context.WithTimeout в Go: правильное использование

```go
package main

import (
    "context"
    "database/sql"
    "fmt"
    "net/http"
    "time"
)

// НЕПРАВИЛЬНО: timeout не передаётся в downstream вызовы
func badGetUser(userID string) (*User, error) {
    ctx := context.Background() // бесконечный контекст!
    return db.QueryRowContext(ctx, "SELECT * FROM users WHERE id = $1", userID)
}

// ПРАВИЛЬНО: timeout через контекст
func getUser(ctx context.Context, userID string) (*User, error) {
    // Добавляем timeout только если его ещё нет (или если хотим сократить)
    dbCtx, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
    defer cancel() // ВСЕГДА defer cancel() — предотвращает утечку ресурсов

    var user User
    err := db.QueryRowContext(dbCtx,
        "SELECT id, name, email FROM users WHERE id = $1",
        userID,
    ).Scan(&user.ID, &user.Name, &user.Email)

    if err != nil {
        if ctx.Err() != nil {
            // Контекст родителя отменён — пробрасываем как есть
            return nil, ctx.Err()
        }
        return nil, fmt.Errorf("query user %s: %w", userID, err)
    }

    return &user, nil
}

// HTTP handler — устанавливаем timeout для всего запроса
func userHandler(w http.ResponseWriter, r *http.Request) {
    // Timeout на весь обработчик
    ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
    defer cancel()

    userID := r.URL.Query().Get("id")
    user, err := getUser(ctx, userID)
    if err != nil {
        if ctx.Err() == context.DeadlineExceeded {
            http.Error(w, "request timeout", http.StatusGatewayTimeout)
            return
        }
        http.Error(w, "internal error", http.StatusInternalServerError)
        return
    }

    json.NewEncoder(w).Encode(user)
}
```

### Deadline Propagation

Ключевая идея: если у входящего запроса осталось 200ms, не начинай операцию, которая займёт 500ms. Это только зря потратит ресурсы.

```
Правильное прокидывание deadline:

Client ──[deadline: t+2s]──► ServiceA
                                 │
                          check: осталось 1.8s
                                 │
                         ┌───────┴────────┐
                         │               │
                  [timeout: 500ms]  [timeout: 500ms]
                         │               │
                       ServiceB        ServiceC
                         │               │
                    (ответил за 400ms)  (ответил за 350ms)
                         │
                  [timeout: min(оставшееся, 800ms)]
                         │
                       ServiceD
```

```go
// Правильная propagation: используем ctx из входящего запроса
// и добавляем вложенные timeout, не превышающие оставшееся время

func processOrder(ctx context.Context, orderID string) (*Order, error) {
    // Шаг 1: Получить пользователя (не более 300ms)
    userCtx, cancel := context.WithTimeout(ctx, 300*time.Millisecond)
    defer cancel()

    user, err := userService.Get(userCtx, orderID)
    if err != nil {
        return nil, fmt.Errorf("get user: %w", err)
    }

    // Шаг 2: Проверить инвентарь (не более 300ms)
    // Если к этому моменту в ctx осталось меньше 300ms — автоматически
    // используется меньший deadline
    invCtx, cancel2 := context.WithTimeout(ctx, 300*time.Millisecond)
    defer cancel2()

    available, err := inventoryService.Check(invCtx, orderID)
    if err != nil {
        return nil, fmt.Errorf("check inventory: %w", err)
    }

    // Шаг 3: Создать заказ — проверяем, есть ли смысл начинать
    if deadline, ok := ctx.Deadline(); ok {
        remaining := time.Until(deadline)
        if remaining < 100*time.Millisecond {
            // Осталось меньше 100ms — не начинаем долгую операцию
            return nil, fmt.Errorf("insufficient time remaining: %v", remaining)
        }
    }

    return orderService.Create(ctx, user, available)
}
```

### gRPC Deadline: автоматическое прокидывание

В gRPC deadline прокидывается автоматически через metadata. Сервер обязан его соблюдать:

```go
// Client: устанавливаем deadline
ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
defer cancel()

// gRPC автоматически добавит grpc-timeout header
resp, err := client.GetUser(ctx, &pb.GetUserRequest{Id: userID})

// Server: используем ctx от фреймворка — deadline уже в нём
func (s *UserServer) GetUser(ctx context.Context, req *pb.GetUserRequest) (*pb.User, error) {
    // ctx.Deadline() вернёт deadline от клиента
    // Если клиент дал 2s, и мы потратили 500ms до этого вызова,
    // у нас осталось ~1.5s

    user, err := s.repo.Find(ctx, req.Id) // передаём ctx!
    if err != nil {
        if status.Code(err) == codes.DeadlineExceeded {
            return nil, status.Error(codes.DeadlineExceeded, "deadline exceeded")
        }
        return nil, status.Error(codes.Internal, err.Error())
    }

    return userToProto(user), nil
}
```

### Пример: цепочка вызовов с deadline propagation

```go
package main

import (
    "context"
    "fmt"
    "time"
)

// Имитация медленного downstream сервиса
func callDownstream(ctx context.Context, name string, duration time.Duration) error {
    select {
    case <-time.After(duration):
        return nil
    case <-ctx.Done():
        return fmt.Errorf("%s: %w", name, ctx.Err())
    }
}

// Три последовательных вызова с общим deadline
func handleRequest(ctx context.Context) error {
    // Шаг 1: Auth (100ms)
    authCtx, cancel := context.WithTimeout(ctx, 200*time.Millisecond)
    defer cancel()

    if err := callDownstream(authCtx, "auth-service", 100*time.Millisecond); err != nil {
        return fmt.Errorf("auth failed: %w", err)
    }
    fmt.Println("Auth OK")

    // Шаг 2: Data fetch (300ms)
    dataCtx, cancel2 := context.WithTimeout(ctx, 400*time.Millisecond)
    defer cancel2()

    if err := callDownstream(dataCtx, "data-service", 300*time.Millisecond); err != nil {
        return fmt.Errorf("data fetch failed: %w", err)
    }
    fmt.Println("Data OK")

    // Шаг 3: Write (200ms)
    writeCtx, cancel3 := context.WithTimeout(ctx, 300*time.Millisecond)
    defer cancel3()

    if err := callDownstream(writeCtx, "write-service", 200*time.Millisecond); err != nil {
        return fmt.Errorf("write failed: %w", err)
    }
    fmt.Println("Write OK")

    return nil
}

func main() {
    // Сценарий 1: достаточно времени (1.5s для суммарно 600ms работы)
    ctx1, cancel1 := context.WithTimeout(context.Background(), 1500*time.Millisecond)
    defer cancel1()

    if err := handleRequest(ctx1); err != nil {
        fmt.Printf("Request failed: %v\n", err)
    } else {
        fmt.Println("Request succeeded")
    }

    // Сценарий 2: мало времени (400ms, но нужно 600ms)
    ctx2, cancel2 := context.WithTimeout(context.Background(), 400*time.Millisecond)
    defer cancel2()

    if err := handleRequest(ctx2); err != nil {
        fmt.Printf("Request failed (expected): %v\n", err)
    }
}
// Output:
// Auth OK
// Data OK
// Write OK
// Request succeeded
// Auth OK
// data fetch failed: data-service: context deadline exceeded
```

---

## 6. Load Shedding

### Что такое load shedding и зачем он нужен

Load shedding — это контролируемый сброс нагрузки при перегрузке сервиса. Аналогия: электросеть сбрасывает нагрузку в отдельных районах, чтобы не рухнула вся сеть.

```
БЕЗ load shedding (overload):     С load shedding:

100 req/s → Сервис (capacity=80)  100 req/s → Сервис (capacity=80)
                ↓                                   ↓
   Очередь растёт безгранично        20 req/s немедленно отклоняются (503)
                ↓                     80 req/s обрабатываются нормально
   P99 latency: 30s                              ↓
   P50 latency: 15s                 P99 latency: 150ms
                ↓                   P50 latency: 50ms
   Все 100 req получают плохой       ↓
   опыт, часть теряется             80% пользователей довольны
                                    20% получают быструю ошибку
                                    → могут немедленно retry или получить fallback
```

Принцип: **лучше обслужить 80% запросов хорошо, чем 100% плохо**.

### Адаптивный load shedding

Вместо фиксированного лимита — динамическое определение перегрузки по метрикам:

```
Сигналы перегрузки:
  - Количество in-flight запросов > threshold
  - P99 latency > target
  - CPU > 80%
  - Длина очереди > N
  - Goroutine count > limit

Алгоритм:
  if любой_сигнал_перегрузки():
      вероятность_отклонения = calculate_shed_probability()
      if rand() < вероятность_отклонения:
          return 503
```

### Priority-based load shedding

Не все запросы одинаково важны. При перегрузке сбрасываем сначала низкоприоритетные:

```
Приоритеты (высокий → низкий):
  P0: Health checks, internal critical paths
  P1: Платящие пользователи, SLA-клиенты
  P2: Бесплатные пользователи
  P3: Background jobs, аналитика
  P4: Боты, scraper, anonymous

При нагрузке 110%: отключаем P4
При нагрузке 130%: отключаем P4 + P3
При нагрузке 150%: отключаем P4 + P3 + P2
```

### Пример на Go: middleware для load shedding

```go
package loadshedding

import (
    "net/http"
    "sync/atomic"
)

// LoadShedder сбрасывает запросы при превышении лимита in-flight запросов
type LoadShedder struct {
    maxInflight int64
    inflight    atomic.Int64
}

func NewLoadShedder(maxInflight int64) *LoadShedder {
    return &LoadShedder{maxInflight: maxInflight}
}

func (ls *LoadShedder) Middleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        current := ls.inflight.Add(1)
        defer ls.inflight.Add(-1)

        if current > ls.maxInflight {
            w.Header().Set("Retry-After", "1")
            http.Error(w, `{"error":"server overloaded","code":"load_shed"}`,
                http.StatusServiceUnavailable)
            return
        }

        next.ServeHTTP(w, r)
    })
}

// AdaptiveLoadShedder: сбрасывает нагрузку на основе latency
type AdaptiveLoadShedder struct {
    targetLatency time.Duration
    maxLatency    time.Duration
    ewmaLatency   atomic.Int64 // nanoseconds, exponentially weighted
    alpha         float64      // EWMA coefficient (0.1 = медленное обновление)
    mu            sync.Mutex
}

func NewAdaptiveLoadShedder(target, max time.Duration) *AdaptiveLoadShedder {
    return &AdaptiveLoadShedder{
        targetLatency: target,
        maxLatency:    max,
        alpha:         0.1,
    }
}

func (als *AdaptiveLoadShedder) updateLatency(d time.Duration) {
    current := als.ewmaLatency.Load()
    // EWMA: new = alpha * sample + (1 - alpha) * current
    updated := int64(als.alpha*float64(d) + (1-als.alpha)*float64(current))
    als.ewmaLatency.Store(updated)
}

func (als *AdaptiveLoadShedder) shouldShed() bool {
    current := time.Duration(als.ewmaLatency.Load())
    if current <= als.targetLatency {
        return false
    }

    // Линейная вероятность сброса между target и max
    // P=0 при target, P=1 при max
    excess := float64(current - als.targetLatency)
    range_ := float64(als.maxLatency - als.targetLatency)
    probability := excess / range_

    if probability >= 1.0 {
        return true
    }

    return rand.Float64() < probability
}

func (als *AdaptiveLoadShedder) Middleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        if als.shouldShed() {
            w.Header().Set("Retry-After", "1")
            http.Error(w, `{"error":"server overloaded"}`, http.StatusServiceUnavailable)
            return
        }

        start := time.Now()
        rw := &responseWriter{ResponseWriter: w}
        next.ServeHTTP(rw, r)
        als.updateLatency(time.Since(start))
    })
}

// Priority-based load shedder
type PriorityLoadShedder struct {
    maxInflight int64
    inflight    atomic.Int64
}

func (pls *PriorityLoadShedder) Middleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        priority := getPriority(r) // из header или JWT claims
        current := pls.inflight.Load()
        capacity := pls.maxInflight

        // При 90%+ загрузки — сбрасываем приоритет 3+
        // При 75%+ — сбрасываем приоритет 4+
        loadRatio := float64(current) / float64(capacity)
        switch {
        case loadRatio >= 0.90 && priority >= 3:
            http.Error(w, `{"error":"overloaded"}`, http.StatusServiceUnavailable)
            return
        case loadRatio >= 0.75 && priority >= 4:
            http.Error(w, `{"error":"overloaded"}`, http.StatusServiceUnavailable)
            return
        }

        pls.inflight.Add(1)
        defer pls.inflight.Add(-1)
        next.ServeHTTP(w, r)
    })
}

func getPriority(r *http.Request) int {
    // Например, из заголовка X-Priority или на основе плана пользователя
    switch r.Header.Get("X-User-Plan") {
    case "enterprise":
        return 1
    case "pro":
        return 2
    case "free":
        return 3
    default:
        return 4 // anonymous
    }
}
```

---

## 7. Chaos Engineering

### Идея

Chaos Engineering — это практика намеренного внесения неисправностей в production-систему (или staging), чтобы обнаружить слабые места до того, как это сделает реальный инцидент.

> "If it hurts, do it more often" — единственный способ убедиться, что failover работает — это проверить его под нагрузкой.

```
Традиционный подход:          Chaos Engineering:
"Мы надеемся, что всё         "Мы знаем, что сломается,
 выдержит инцидент"            потому что сами его сломали"
        ↓                              ↓
 Инцидент случается           Находим и чиним слабые места
 Система ведёт себя           до production-инцидента
 непредсказуемо
```

### Инструменты

| Инструмент | Описание | Open Source |
|---|---|---|
| **Netflix Chaos Monkey** | Случайно убивает VM/контейнеры | Да |
| **Gremlin** | SaaS, богатый набор атак | Нет (есть Free tier) |
| **Litmus** | Chaos для Kubernetes | Да (CNCF) |
| **Chaos Mesh** | Kubernetes-native chaos | Да (CNCF) |
| **Pumba** | Chaos для Docker | Да |
| **tc/iptables** | Network emulation вручную | Системный |

### Что тестировать

```
Категории хаоса:

1. RESOURCE FAILURES
   ├── Убить процесс (SIGKILL)
   ├── OOM killer
   ├── Disk full (dd if=/dev/zero of=bigfile)
   └── CPU spike (stress-ng)

2. NETWORK FAILURES
   ├── Packet loss       (tc qdisc add netem loss 30%)
   ├── Latency           (tc qdisc add netem delay 200ms 50ms)
   ├── Bandwidth limit   (tc qdisc add tbf rate 1mbit)
   ├── Partition         (iptables DROP между сервисами)
   └── DNS failure       (убить /etc/resolv.conf)

3. APPLICATION FAILURES
   ├── Медленный ответ   (sleep перед response)
   ├── 500 ошибки        (inject error в handler)
   ├── Hung goroutines   (заблокировать mutex)
   └── Corrupted data    (вернуть невалидный JSON)

4. DEPENDENCY FAILURES
   ├── База данных недоступна
   ├── Redis недоступен
   ├── Kafka partition leader election
   └── External API timeout
```

### Game Days: плановые учения

Game Day — это организованное мероприятие, где команда тестирует поведение системы под искусственными отказами.

```
Структура Game Day:

Подготовка (2 недели до):
  1. Определить гипотезы: "если X упадёт, то Y произойдёт"
  2. Определить blast radius: что затронем, что защищаем
  3. Настроить monitoring/alerting
  4. Подготовить rollback plan

День учений:
  T-0:00  Briefing, назначение ролей (атакующий, наблюдатель, дежурный)
  T-0:15  Начало эксперимента в staging
  T-0:45  Анализ результатов staging
  T-1:00  (опционально) Эксперимент в production с ограниченным blast radius
  T-2:00  Rollback если нужен
  T-2:30  Debriefing: что сломалось, что устояло

После Game Day:
  - Action items с SLA на исправление
  - Обновить runbook
  - Добавить новые тесты
```

### Как начинать

```
Зрелость chaos engineering:

Уровень 1 (начало):
  ┌─────────────────────────────────────────────────┐
  │ Только staging, только в рабочие часы           │
  │ Только один эксперимент за раз                  │
  │ Всегда есть kill switch                         │
  └─────────────────────────────────────────────────┘

Уровень 2 (освоились):
  ┌─────────────────────────────────────────────────┐
  │ Production, но canary (1-5% трафика)            │
  │ Автоматическая остановка при деградации метрик  │
  │ Автоматизированные эксперименты по расписанию   │
  └─────────────────────────────────────────────────┘

Уровень 3 (зрелость):
  ┌─────────────────────────────────────────────────┐
  │ Continuous chaos в production                   │
  │ Chaos as part of CI/CD                          │
  │ Эксперименты запускаются автоматически ночью    │
  └─────────────────────────────────────────────────┘
```

**Первый эксперимент (пример):**

```bash
# Эксперимент: убить один инстанс сервиса в staging
# Гипотеза: traffic failover произойдёт за < 5s, ошибок < 0.1%

# 1. Зафиксировать baseline метрики
# 2. Убить один pod
kubectl delete pod my-service-7d8f9c-xxxxx -n staging

# 3. Наблюдать в Grafana:
#    - Error rate
#    - Latency P99
#    - Успешность health checks у load balancer

# 4. Записать результаты
# 5. Восстановить (k8s сделает это автоматически)
```

---

## 8. Disaster Recovery

### RPO и RTO

Два ключевых параметра DR:

```
Timeline инцидента:

Last backup         Disaster       Recovery complete
    │                  │                │
    ▼                  ▼                ▼
────●──────────────────●────────────────●────► время
    │                  │                │
    │◄── RPO ─────────►│                │
    │  (сколько данных │◄──── RTO ─────►│
    │   можем потерять)│  (как быстро   │
    │                  │   восстановить)│
```

**RPO (Recovery Point Objective):** максимально допустимая потеря данных.
- RPO = 0: нулевая потеря данных (синхронная репликация)
- RPO = 1h: можем потерять до 1 часа данных (hourly backup)
- RPO = 24h: можем потерять до 24 часов (daily backup)

**RTO (Recovery Time Objective):** максимальное допустимое время восстановления.
- RTO = 0: мгновенное переключение (active-active)
- RTO = 15min: быстрое ручное переключение
- RTO = 4h: допустимо длительное восстановление

### Стратегии DR

#### 1. Backup & Restore

Самый простой и дешёвый подход. Создаём регулярные резервные копии, при DR восстанавливаем из них.

```
PRIMARY REGION                    BACKUP STORAGE
                                  (S3, GCS, другой регион)
┌──────────────┐
│   Database   │──── backup ────► [dump_2026-03-23.tar.gz]
│              │◄─── restore ───  [dump_2026-03-22.tar.gz]
└──────────────┘                  [dump_2026-03-21.tar.gz]

RPO: время между backup (1h, 24h, etc.)
RTO: время восстановления из backup (часы)
```

#### 2. Pilot Light

Минимальная инфраструктура в DR-регионе всегда запущена. При DR — масштабируем и переключаем трафик.

```
PRIMARY REGION              DR REGION (Pilot Light)
┌─────────────────┐         ┌─────────────────────┐
│ App (10 nodes)  │         │ App (0 nodes ready) │
│ DB Primary ─────┼──────►  │ DB Replica (running)│
│ Cache (Redis)   │  repl.  │ Cache (stopped)     │
└─────────────────┘         └─────────────────────┘

DR Activation:
  1. Promote DB Replica → Primary
  2. Scale App nodes 0 → 10
  3. Start Cache
  4. Update DNS
  → Total: 15-60 minutes

RPO: секунды (репликация почти real-time)
RTO: 15-60 минут
```

#### 3. Warm Standby

DR-регион работает в уменьшенном масштабе (напр., 25% от production). Может принять небольшой трафик немедленно.

```
PRIMARY REGION              DR REGION (Warm Standby)
┌─────────────────┐         ┌─────────────────────┐
│ App (10 nodes)  │         │ App (2 nodes)       │
│ DB Primary ─────┼──────►  │ DB Replica (hot)    │
│ Cache (Redis)   │  repl.  │ Cache (warm)        │
│ Load Balancer   │         │ Load Balancer (ready)│
└─────────────────┘         └─────────────────────┘

DR Activation:
  1. Promote DB Replica
  2. Scale App 2 → 10 nodes
  3. Update DNS/Route 53 weights
  → Total: 5-15 минут

RPO: секунды
RTO: 5-15 минут
```

#### 4. Multi-Region Active-Active

Оба региона обслуживают production трафик одновременно. DR = просто перенаправить трафик.

```
REGION US-EAST              REGION EU-WEST
┌─────────────────┐         ┌─────────────────────┐
│ App (10 nodes)  │◄────────┤ App (10 nodes)      │
│                 │ sync/   │                     │
│ DB Primary ─────┼──────►  │ DB Primary ◄────────┼─┐
│                 │  async  │                     │ │
│ Cache (Redis)   │  repl.  │ Cache (Redis)       │ │
└─────────────────┘         └─────────────────────┘ │
         ▲                                           │
         └───────────────────────────────────────────┘
                      Bi-directional replication

DR Activation:
  1. Обновить DNS/Anycast веса (Route 53 health check)
  → Total: секунды (автоматически)

RPO: 0 (синхронная) или секунды (асинхронная)
RTO: секунды (автоматически)
```

### Таблица сравнения стратегий

| Стратегия | RPO | RTO | Стоимость | Сложность | Когда использовать |
|---|---|---|---|---|---|
| **Backup & Restore** | Часы–сутки | Часы | $ (минимальная) | Низкая | Некритичные системы, dev/test |
| **Pilot Light** | Минуты–секунды | 15–60 мин | $$ | Средняя | Внутренние сервисы, B2B |
| **Warm Standby** | Секунды | 5–15 мин | $$$ | Высокая | Production с SLA |
| **Active-Active** | 0–секунды | Секунды | $$$$ | Очень высокая | Mission-critical, финтех |

### Регулярное тестирование DR

DR-план, который не тестируется — это иллюзия. Реальные проверки:

```
Ежемесячно:
  □ Восстановить backup в изолированной среде
  □ Проверить, что данные консистентны
  □ Замерить время восстановления (соответствует ли RTO?)

Ежеквартально:
  □ Full DR drill: переключить трафик на DR-регион
  □ Проверить, что команда знает процедуры
  □ Обновить runbook по результатам

После каждого инцидента:
  □ Post-mortem: что сработало, что нет
  □ Обновить DR-план
```

**Автоматическая проверка backup:**

```go
package dr

import (
    "context"
    "database/sql"
    "fmt"
    "time"
)

// BackupVerifier регулярно проверяет восстанавливаемость backup
type BackupVerifier struct {
    primaryDB    *sql.DB
    backupBucket string
    testDB       *sql.DB // изолированный тестовый экземпляр
}

// VerifyLatestBackup восстанавливает последний backup и проверяет данные
func (bv *BackupVerifier) VerifyLatestBackup(ctx context.Context) error {
    start := time.Now()

    // 1. Получить последний backup
    backupPath, err := bv.getLatestBackup(ctx)
    if err != nil {
        return fmt.Errorf("get latest backup: %w", err)
    }

    // 2. Восстановить в тестовый экземпляр
    if err := bv.restore(ctx, backupPath, bv.testDB); err != nil {
        return fmt.Errorf("restore backup: %w", err)
    }

    // 3. Проверить консистентность данных
    if err := bv.validateData(ctx); err != nil {
        return fmt.Errorf("data validation failed: %w", err)
    }

    // 4. Замерить RTO
    elapsed := time.Since(start)
    fmt.Printf("[DR] Backup verified. Restore time: %v\n", elapsed)

    // 5. Отправить метрику
    metrics.Record("dr.restore_time_seconds", elapsed.Seconds())

    // 6. Проверить, что RTO в норме
    const targetRTO = 4 * time.Hour
    if elapsed > targetRTO {
        return fmt.Errorf("restore time %v exceeds target RTO %v", elapsed, targetRTO)
    }

    return nil
}

func (bv *BackupVerifier) validateData(ctx context.Context) error {
    // Сравниваем ключевые метрики между primary и восстановленным backup
    var primaryCount, restoredCount int64

    if err := bv.primaryDB.QueryRowContext(ctx,
        "SELECT COUNT(*) FROM orders WHERE created_at > NOW() - INTERVAL '7 days'",
    ).Scan(&primaryCount); err != nil {
        return err
    }

    if err := bv.testDB.QueryRowContext(ctx,
        "SELECT COUNT(*) FROM orders WHERE created_at > NOW() - INTERVAL '7 days'",
    ).Scan(&restoredCount); err != nil {
        return err
    }

    // Допускаем расхождение до 0.1% (RPO)
    diff := abs(primaryCount-restoredCount) * 1000 / primaryCount
    if diff > 1 { // > 0.1%
        return fmt.Errorf("data divergence too large: primary=%d, restored=%d",
            primaryCount, restoredCount)
    }

    return nil
}
```

---

## Итоги

Надёжность — это не одна техника, а слоёная защита:

```
Запрос пользователя
        │
        ▼
[Rate Limiting]          ← Защита от перегрузки снаружи
        │
        ▼
[Load Shedding]          ← Защита от перегрузки изнутри
        │
        ▼
[Circuit Breaker]        ← Защита от каскадных отказов
        │
        ▼
[Timeout + Deadline]     ← Защита ресурсов от зависания
        │
        ▼
[Retry + Backoff]        ← Устойчивость к transient errors
        │
        ▼
[Graceful Degradation]   ← Частичный ответ лучше, чем 500
        │
        ▼
[Disaster Recovery]      ← Восстановление после катастрофы
```

**Ключевые принципы:**

1. Всегда устанавливай timeout на внешние вызовы — без исключений
2. Circuit breaker предотвращает каскадные отказы, ретрай — transient errors
3. Jitter разгружает downstream от thundering herd
4. Rate limiting защищает сервис, load shedding сохраняет качество при перегрузке
5. Chaos Engineering — единственный способ убедиться, что failover реально работает
6. DR-план без регулярного тестирования не стоит ничего
7. Blast radius надо минимизировать: изолируй отказы через bulkhead и cell-based архитектуру

---

## Дополнительные материалы

- [AWS Well-Architected Framework: Reliability Pillar](https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html)
- [Google SRE Book: Chapter 22 — Addressing Cascading Failures](https://sre.google/sre-book/cascading-failures/)
- [Netflix Tech Blog: Chaos Engineering](https://netflixtechblog.com/tagged/chaos-engineering)
- [sony/gobreaker](https://github.com/sony/gobreaker) — Circuit Breaker для Go
- [Principles of Chaos Engineering](https://principlesofchaos.org/)
