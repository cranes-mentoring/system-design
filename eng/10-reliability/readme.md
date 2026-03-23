# Module 10: Reliability and Fault Tolerance

> **Core principle:** Failure is inevitable. Design the system to withstand failures — don't assume they won't happen.

---

## Table of Contents

1. [Reliability Principles](#1-reliability-principles)
2. [Circuit Breaker](#2-circuit-breaker)
3. [Retry and Exponential Backoff](#3-retry-and-exponential-backoff)
4. [Rate Limiting](#4-rate-limiting)
5. [Timeout and Deadline Propagation](#5-timeout-and-deadline-propagation)
6. [Load Shedding](#6-load-shedding)
7. [Chaos Engineering](#7-chaos-engineering)
8. [Disaster Recovery](#8-disaster-recovery)

---

## 1. Reliability Principles

### Failure is Inevitable

Every component of a system will eventually fail: a disk will fill up, the network will drop packets, a dependent service will go down, an application will hit OOM. The question isn't "will it fail?" but "what will the system do when it does?"

The wrong approach is to build a system assuming it won't fail. The right approach is to design every component as if it is **already broken**, and everything else must deal with that.

```
Three maturity levels for handling failures:

Level 1 (bad):    Failure → Complete system failure
Level 2 (medium): Failure → Error for user, but system stays alive
Level 3 (good):   Failure → Degradation, but user still gets a result
```

### Blast Radius: Minimizing the Damage Zone

Blast radius is the scale of damage from a single incident. The goal is to contain the failure and prevent it from spreading.

**Techniques for reducing blast radius:**

| Technique | What it does | Example |
|-----------|-------------|---------|
| Bulkhead | Isolates resource pools | Separate thread pool for each downstream |
| Shard | Divides data/traffic into parts | Users A-M on one shard, N-Z on another |
| Cell-based architecture | Independent system cells | Each cell = 1% of users |
| Feature flags | Disabling functionality | Remove heavy recommendations under load |
| Circuit breaker | Stops cascade | Covered in detail in section 2 |

**Bulkhead pattern — example:**

```
WITHOUT bulkhead:                WITH bulkhead:

[All requests]                   [Critical requests] [Regular requests]
       ↓                                ↓                    ↓
[Shared thread pool]             [Pool A: 50 threads] [Pool B: 50 threads]
       ↓                                ↓                    ↓
ServiceB hangs →             ServiceB hangs →    Pool A exhausted,
all 100 threads occupied →   Pool A exhausted,   Pool B works normally
entire service stalled       critical requests wait,
                             but regular ones are unaffected
```

### Graceful Degradation

It is better to show the user stale cached data than to return a 500. It's better to show a top-10 list without personalization than to block the page.

```
Full functionality:          Degradation:             Minimum:
┌─────────────────────┐     ┌─────────────────────┐  ┌─────────────────────┐
│ Personalized        │     │ Popular products    │  │ Static              │
│ recommendations     │ --> │ from cache          │  │ maintenance page    │
│ Real-time prices    │     │ Cached prices       │  │ "We'll be back soon"│
│ Live stock count    │     │ Stock: "In stock"   │  │                     │
└─────────────────────┘     └─────────────────────┘  └─────────────────────┘
     Everything works       RecommendationService      Everything is down
                            or PricingService is down
```

**Implementation in code:**

```go
func (s *ProductService) GetProduct(ctx context.Context, id string) (*Product, error) {
    // Try to get live data
    product, err := s.db.GetProduct(ctx, id)
    if err == nil {
        return product, nil
    }

    // Degrade: fetch from cache
    cached, cacheErr := s.cache.Get(ctx, "product:"+id)
    if cacheErr == nil {
        // Mark that the data might be stale
        cached.Stale = true
        return cached, nil
    }

    // Complete failure — only now return an error
    return nil, fmt.Errorf("product %s unavailable: %w", id, err)
}
```

### Fail-Fast

If a dependency is dead — don't wait 30 seconds for a timeout. Fail quickly, free up resources, give the client a chance to try another instance or handle the error.

```
WITHOUT fail-fast:                WITH fail-fast:

t=0  Request to ServiceB           t=0  Request to ServiceB
t=0  ServiceB not responding       t=0  Circuit breaker OPEN
...  (30 seconds of waiting)       t=0  Immediate error return
t=30 Timeout                       t=0  Client uses fallback
t=30 Client receives error
     During this time: 30s * N RPS  During this time: 0s delay
     = N*30 hanging connections    = 0 hanging connections
```

### Design for Failure

Checklist when designing each new component:

- [ ] What happens if this service goes down? Who depends on it?
- [ ] Is there a timeout on all external calls?
- [ ] Is there retry with backoff?
- [ ] Is there a circuit breaker?
- [ ] Is there a fallback / cached response?
- [ ] What is the blast radius on failure?
- [ ] How is this behavior tested?

---

## 2. Circuit Breaker

### The Problem: Cascading Failures

One failed service can bring down the entire system through a chain of dependencies:

```
Cascade failure without circuit breaker:

t=0:  ServiceC starts slowing down (disk full)
      A → B → C (requests accumulate in B, waiting for C)

t=5s: B exhausts its thread pool, starts slowing down
      A → B (requests accumulate in A, waiting for B)

t=10s: A exhausts its thread pool
       Clients → A (everything hung)

t=15s: Entire system unavailable because of one disk in C
```

The circuit breaker breaks the chain: if C isn't responding, B doesn't wait — it immediately returns an error.

### State Machine

```
                    failure_count >= threshold
         ┌──────────────────────────────────────────┐
         │                                          │
         ▼                                          │
   ┌──────────┐   Successful request          ┌──────────┐
   │          │ ◄──────────────────────────── │          │
   │  CLOSED  │                               │   OPEN   │
   │          │ ──────────────────────────►   │          │
   └──────────┘   failure_count >= threshold  └──────────┘
         ▲                                          │
         │                                          │ timeout elapsed
         │   Success (probe request)                │
         │                                          ▼
         │                                  ┌──────────────┐
         └─────────────────────────────────  │  HALF-OPEN   │
                                             │              │
                   Failure (probe request)   └──────────────┘
                   ──────────────────────────────────────────►
                   (return to OPEN)
```

**Three states:**

| State | Behavior | Transition |
|-------|----------|-----------|
| **CLOSED** | Requests pass normally, failures are counted | → OPEN when failures ≥ threshold |
| **OPEN** | All requests immediately rejected (fail-fast) | → HALF-OPEN when timeout elapses |
| **HALF-OPEN** | Allow a limited number of probe requests | → CLOSED on success; → OPEN on failure |

### Circuit Breaker Parameters

| Parameter | Typical Value | Description |
|-----------|--------------|-------------|
| `failure_threshold` | 50% over 10s or 5 consecutive | How many errors open the breaker |
| `open_timeout` | 10–60s | How long the breaker stays open |
| `half_open_max_requests` | 1–5 | How many probe requests in HALF-OPEN |
| `min_requests` | 10–20 | Minimum requests needed to evaluate error % |

### Go Example: sony/gobreaker

```go
package circuitbreaker

import (
    "context"
    "errors"
    "fmt"
    "time"

    "github.com/sony/gobreaker"
)

// Wrapper over an HTTP client with circuit breaker
type ResilientClient struct {
    cb     *gobreaker.CircuitBreaker
    client HTTPClient
}

func NewResilientClient(name string, client HTTPClient) *ResilientClient {
    settings := gobreaker.Settings{
        Name: name,

        // Open breaker if over the last 10s:
        // - more than 5 requests AND more than 60% are errors
        ReadyToTrip: func(counts gobreaker.Counts) bool {
            failureRatio := float64(counts.TotalFailures) / float64(counts.Requests)
            return counts.Requests >= 5 && failureRatio >= 0.6
        },

        // Breaker stays open for 30s
        Timeout: 30 * time.Second,

        // Callback on state change
        OnStateChange: func(name string, from gobreaker.State, to gobreaker.State) {
            fmt.Printf("[CircuitBreaker] %s: %s → %s\n", name, from, to)
            // Here you can send a metric to Prometheus/Datadog
        },
    }

    return &ResilientClient{
        cb:     gobreaker.NewCircuitBreaker(settings),
        client: client,
    }
}

func (c *ResilientClient) Get(ctx context.Context, url string) ([]byte, error) {
    result, err := c.cb.Execute(func() (interface{}, error) {
        // This function only executes in CLOSED or HALF-OPEN state
        return c.client.Get(ctx, url)
    })

    if err != nil {
        // Distinguish: breaker is open vs real service error
        if errors.Is(err, gobreaker.ErrOpenState) {
            return nil, fmt.Errorf("circuit breaker open for %s: service unavailable", url)
        }
        return nil, fmt.Errorf("request failed: %w", err)
    }

    return result.([]byte), nil
}
```

**Minimal custom implementation:**

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
        // Check if timeout has elapsed
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

### Circuit Breaker in Action: ASCII Timeline

```
t=0   ServiceC working normally
      A──►B──►C  ✓  ✓  ✓  ✓  ✓

t=10  ServiceC starts failing (failure_threshold = 5)
      A──►B──►C  ✗  ✗  ✗  ✗  ✗
                    ↑
                Error counter reached threshold

t=10  Circuit Breaker B→C transitions to OPEN
      A──►B  ✗ (immediately, without waiting for C)
             ↑
         Return cached response or error

t=40  open_timeout elapsed (30s), transition to HALF-OPEN
      A──►B──►C  (probe request)
               ✓  → Transition to CLOSED
               ✗  → Return to OPEN for another 30s
```

---

## 3. Retry and Exponential Backoff

### When to Retry, When Not To

```
RETRY (transient errors):             DO NOT RETRY:
✓ 500 Internal Server Error           ✗ 400 Bad Request
✓ 503 Service Unavailable             ✗ 401 Unauthorized
✓ 429 Too Many Requests (with backoff)✗ 403 Forbidden
✓ Network timeout                     ✗ 404 Not Found
✓ Connection refused (transient)      ✗ 422 Unprocessable Entity
✓ gRPC: UNAVAILABLE, DEADLINE_EXCEEDED ✗ Business errors

IDEMPOTENCY:
✓ Safe to retry: GET, PUT, DELETE
⚠ Use caution: POST (needs idempotency key)
✗ Never retry without protection: "debit funds from account"
```

### Exponential Backoff

Formula:

```
delay = min(base * 2^attempt + jitter, max_delay)

Example: base=100ms, max_delay=30s
attempt=0: 100ms + jitter
attempt=1: 200ms + jitter
attempt=2: 400ms + jitter
attempt=3: 800ms + jitter
attempt=4: 1600ms + jitter
attempt=5: 3200ms + jitter (but no more than max_delay)
```

### Jitter: Why It's Needed

**Thundering herd problem**: if 1000 clients received an error simultaneously and retry after exactly 1 second — the service will receive 1000 requests in exactly 1 second. Error again. 1000 requests again in 2 seconds. And so on.

**Jitter** adds randomness, spreading retries over time:

```
WITHOUT jitter:               WITH jitter:
t=1.0s ▓▓▓▓▓▓▓▓▓▓ 1000 req   t=0.8s ▓▓ 80 req
                               t=0.9s ▓▓▓ 120 req
                               t=1.0s ▓▓▓▓ 200 req
t=2.0s ▓▓▓▓▓▓▓▓▓▓ 1000 req   t=1.1s ▓▓▓▓ 180 req
                               t=1.2s ▓▓▓ 150 req
                               ...
```

**Two types of jitter:**

```go
// Full jitter: random value from 0 to the full backoff
// Best for thundering herd
delay = random(0, base * 2^attempt)

// Equal jitter: half is deterministic, half is random
// Guarantees a minimum backoff
temp  = base * 2^attempt
delay = temp/2 + random(0, temp/2)
```

### Retry Budget

Retry budget — a service-level limit: no more than X% of all outgoing requests may be retries.

```
Without retry budget:
- Base traffic: 1000 RPS
- Retry (3 attempts): up to 3000 RPS additional
- Total: up to 4000 RPS on downstream

With retry budget (10%):
- Base traffic: 1000 RPS
- Retry: no more than 100 RPS (10%)
- Total: 1100 RPS — downstream is protected
```

### Go Example: Retry with Exponential Backoff and Jitter

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

// isRetryable determines whether an error should be retried
func isRetryable(err error) bool {
    var httpErr *HTTPError
    if errors.As(err, &httpErr) {
        // Retry only 5xx and 429
        return httpErr.StatusCode >= 500 || httpErr.StatusCode == 429
    }
    // Network errors — retry
    return true
}

// fullJitter returns a random delay from 0 to maxDelay
func fullJitter(attempt int, cfg Config) time.Duration {
    exp := math.Pow(cfg.Multiplier, float64(attempt))
    delay := float64(cfg.BaseDelay) * exp
    if delay > float64(cfg.MaxDelay) {
        delay = float64(cfg.MaxDelay)
    }
    // Full jitter: random value from 0 to delay
    return time.Duration(rand.Float64() * delay)
}

// Do executes fn with retries according to the given config
func Do(ctx context.Context, cfg Config, fn func(ctx context.Context) error) error {
    var lastErr error

    for attempt := 0; attempt < cfg.MaxAttempts; attempt++ {
        // Check context before each attempt
        if ctx.Err() != nil {
            return ctx.Err()
        }

        err := fn(ctx)
        if err == nil {
            return nil // Success
        }

        lastErr = err

        // Don't retry non-retryable errors
        if !isRetryable(err) {
            return err
        }

        // Last attempt — don't wait
        if attempt == cfg.MaxAttempts-1 {
            break
        }

        delay := fullJitter(attempt, cfg)

        // Wait respecting context
        select {
        case <-ctx.Done():
            return ctx.Err()
        case <-time.After(delay):
            // Continue
        }
    }

    return fmt.Errorf("all %d attempts failed: %w", cfg.MaxAttempts, lastErr)
}

// Example usage:
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

**Retry Budget at service level:**

```go
package retry

import (
    "sync/atomic"
    "time"
)

// Budget tracks the ratio of retries to regular requests
type Budget struct {
    totalRequests int64
    retryRequests int64
    maxRatio      float64 // e.g., 0.10 for 10%
    window        time.Duration
}

func NewBudget(maxRatio float64) *Budget {
    b := &Budget{maxRatio: maxRatio, window: time.Minute}

    // Reset counters every minute
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
        return false // Budget exhausted
    }

    atomic.AddInt64(&b.retryRequests, 1)
    return true
}
```

---

## 4. Rate Limiting

### Why Rate Limiting Is Needed

- **DDoS protection**: a single client can't take down the service
- **Noisy neighbor**: a single heavy client doesn't degrade others' experience
- **Abuse prevention**: blocking bot traffic, credential stuffing
- **Cost control**: protection against unintended loops (infinite retry)
- **SLA enforcement**: guarantees fair usage between clients

### Algorithms

#### Token Bucket

The most common algorithm. Tokens accumulate at `rate/sec` up to a maximum of `burst`. Each request consumes a token.

```
Token Bucket (rate=10/s, burst=20):

t=0:   [████████████████████] 20 tokens
       5 requests → [███████████████] 15 tokens

t=0.5: [████████████████] 15+5=16 tokens (5 accumulated over 0.5s)
       10 requests → [██████] 6 tokens

t=1:   [███████████] 6+10=16 tokens (10 accumulated over 1s)

Parameters:
  rate  = accumulation speed (10 tokens/sec)
  burst = maximum reserve (allows short-term spikes)
```

**Pros:** allows burst traffic. **Cons:** burst can overload downstream.

#### Leaky Bucket

Requests enter a queue; they exit the queue at a fixed rate.

```
Leaky Bucket (rate=10/s):

Incoming traffic:  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  (20 req/s)
                          ↓
                     [Queue: 10]
                          ↓
Outgoing traffic:  ▓▓▓▓▓▓▓▓▓▓  (strictly 10 req/s)
```

**Pros:** strictly constant outgoing flow. **Cons:** no burst, queue adds latency.

#### Fixed Window Counter

Count requests in fixed time windows (e.g., every minute).

```
Fixed Window (limit=100/min):

[00:00-01:00] ████████████████████ 100 req  → LIMIT REACHED
[01:00-02:00] (new window, counter reset)

Edge case problem:
[00:59] ████████████████████ 100 req (last second of window 1)
[01:00] ████████████████████ 100 req (first second of window 2)
→ In 2 seconds: 200 requests! Limit violated.
```

#### Sliding Window Log

Store a timestamp for each request. On each new request, remove stale entries and count.

```
Sliding Window Log (limit=100/min):

Current time: 01:00:30
Window: [00:00:30 - 01:00:30]

Log: [00:00:31, 00:01:05, ..., 01:00:28, 01:00:29]
     ^^^^^^^^^^^^^^^^^^^^      ^^^^^^^^^^^^^^^^^^^^
     Delete (older than 1 min) Count (101 entries → LIMIT)
```

**Pros:** precise. **Cons:** memory-intensive (stores every timestamp).

#### Sliding Window Counter

A compromise between Fixed Window and Sliding Window Log. Uses two counters: current and previous window.

```
Sliding Window Counter (limit=100/min):

Previous window: 80 requests
Current window (30% elapsed = 0.3 minutes): 40 requests

Estimate for sliding window:
  weighted = previous * (1 - 0.3) + current
           = 80 * 0.7 + 40
           = 56 + 40 = 96 requests

96 < 100 → allow the request
```

### Algorithm Comparison Table

| Algorithm | Accuracy | Memory | CPU | Burst | Complexity |
|-----------|----------|--------|-----|-------|------------|
| Token Bucket | High | O(1) | O(1) | Yes | Low |
| Leaky Bucket | High | O(n) | O(1) | No | Medium |
| Fixed Window | Low | O(1) | O(1) | Partial | Very low |
| Sliding Window Log | Very high | O(n) | O(n) | No | Medium |
| Sliding Window Counter | High | O(1) | O(1) | No | Medium |

**Recommendation:** Token Bucket for most cases, Sliding Window Counter for distributed rate limiting.

### Where to Place Rate Limiters

```
Internet
   │
   ▼
[API Gateway]  ← Rate limit by IP, API key (first line of defense)
   │
   ▼
[Middleware]   ← Rate limit by user, endpoint
   │
   ▼
[Service A]    ← Rate limit at business logic level
   │
   ├──► [Service B]  ← Rate limit on incoming calls (service protection)
   │
   └──► [Service C]
```

### Rate Limiting Headers

```http
HTTP/1.1 200 OK
X-RateLimit-Limit: 100        # Limit for this period
X-RateLimit-Remaining: 43     # Requests remaining
X-RateLimit-Reset: 1711180800 # Unix timestamp of window reset
Retry-After: 30               # Seconds until next request (only on 429)

HTTP/1.1 429 Too Many Requests
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 0
X-RateLimit-Reset: 1711180800
Retry-After: 30
Content-Type: application/json

{"error": "rate_limit_exceeded", "retry_after": 30}
```

### Go Example: Token Bucket Rate Limiter

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
    rate     float64 // tokens per second
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

// Allow checks whether a request can pass (consumes 1 token)
func (tb *TokenBucket) Allow() bool {
    return tb.AllowN(1)
}

// AllowN checks whether a request requiring n tokens can pass
func (tb *TokenBucket) AllowN(n float64) bool {
    tb.mu.Lock()
    defer tb.mu.Unlock()

    now := time.Now()
    elapsed := now.Sub(tb.lastTime).Seconds()
    tb.lastTime = now

    // Accumulate tokens proportional to elapsed time
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

// Middleware for HTTP server (per-IP rate limiting)
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

    // Clean up stale entries every minute
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
        ip := r.RemoteAddr // In production: X-Forwarded-For

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

When a service runs across multiple instances, a local rate limiter doesn't work — each instance only sees its share of the traffic. Solution: a centralized counter in Redis.

**Sliding Window Counter via Redis Lua:**

```lua
-- ratelimit.lua
-- KEYS[1] = counter key (e.g. "rl:user:123")
-- ARGV[1] = current timestamp (ms)
-- ARGV[2] = window size (ms), e.g. 60000 for 1 minute
-- ARGV[3] = limit

local key = KEYS[1]
local now = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local limit = tonumber(ARGV[3])
local window_start = now - window

-- Remove entries older than the window
redis.call('ZREMRANGEBYSCORE', key, '-inf', window_start)

-- Count the current number of requests in the window
local count = redis.call('ZCARD', key)

if count < limit then
    -- Add the current request (score = timestamp, member = unique ID)
    redis.call('ZADD', key, now, now .. '-' .. math.random())
    -- TTL = window size + small buffer
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
        // On Redis error — fail open (allow the request)
        // In production you may fail closed for critical endpoints
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
                // Log Redis error but don't block the user
                log.Printf("rate limiter error: %v", err)
            }

            // Always set headers
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

## 5. Timeout and Deadline Propagation

### Why a Timeout Is Required on Every External Call

```
WITHOUT timeout:

t=0    ServiceA calls ServiceB
t=5    ServiceB hangs (deadlock in DB)
t=∞    ServiceA keeps goroutine/thread open
       N hung goroutines accumulate
       ServiceA exhausts resources
       ServiceA crashes

WITH timeout (5s):

t=0    ServiceA calls ServiceB with timeout=5s
t=5    Timeout fires
t=5    ServiceA receives context.DeadlineExceeded
t=5    Goroutine is released
t=5    ServiceA returns error to client
       System stays alive
```

Rule: **never** call an external service, DB, or queue without an explicit timeout.

### context.WithTimeout in Go: Correct Usage

```go
package main

import (
    "context"
    "database/sql"
    "fmt"
    "net/http"
    "time"
)

// WRONG: timeout is not passed to downstream calls
func badGetUser(userID string) (*User, error) {
    ctx := context.Background() // infinite context!
    return db.QueryRowContext(ctx, "SELECT * FROM users WHERE id = $1", userID)
}

// CORRECT: timeout via context
func getUser(ctx context.Context, userID string) (*User, error) {
    // Add timeout only if there isn't one already (or if we want to shorten it)
    dbCtx, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
    defer cancel() // ALWAYS defer cancel() — prevents resource leaks

    var user User
    err := db.QueryRowContext(dbCtx,
        "SELECT id, name, email FROM users WHERE id = $1",
        userID,
    ).Scan(&user.ID, &user.Name, &user.Email)

    if err != nil {
        if ctx.Err() != nil {
            // Parent context cancelled — propagate as-is
            return nil, ctx.Err()
        }
        return nil, fmt.Errorf("query user %s: %w", userID, err)
    }

    return &user, nil
}

// HTTP handler — set timeout for the entire request
func userHandler(w http.ResponseWriter, r *http.Request) {
    // Timeout for the entire handler
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

Key idea: if an incoming request has 200ms remaining, don't start an operation that takes 500ms. It only wastes resources.

```
Correct deadline propagation:

Client ──[deadline: t+2s]──► ServiceA
                                 │
                          check: 1.8s remaining
                                 │
                         ┌───────┴────────┐
                         │               │
                  [timeout: 500ms]  [timeout: 500ms]
                         │               │
                       ServiceB        ServiceC
                         │               │
                    (responded in 400ms)(responded in 350ms)
                         │
                  [timeout: min(remaining, 800ms)]
                         │
                       ServiceD
```

```go
// Correct propagation: use ctx from the incoming request
// and add nested timeouts that don't exceed the remaining time

func processOrder(ctx context.Context, orderID string) (*Order, error) {
    // Step 1: Get user (at most 300ms)
    userCtx, cancel := context.WithTimeout(ctx, 300*time.Millisecond)
    defer cancel()

    user, err := userService.Get(userCtx, orderID)
    if err != nil {
        return nil, fmt.Errorf("get user: %w", err)
    }

    // Step 2: Check inventory (at most 300ms)
    // If ctx has less than 300ms remaining at this point, the smaller
    // deadline is used automatically
    invCtx, cancel2 := context.WithTimeout(ctx, 300*time.Millisecond)
    defer cancel2()

    available, err := inventoryService.Check(invCtx, orderID)
    if err != nil {
        return nil, fmt.Errorf("check inventory: %w", err)
    }

    // Step 3: Create order — check if it's worth starting
    if deadline, ok := ctx.Deadline(); ok {
        remaining := time.Until(deadline)
        if remaining < 100*time.Millisecond {
            // Less than 100ms remaining — don't start a long operation
            return nil, fmt.Errorf("insufficient time remaining: %v", remaining)
        }
    }

    return orderService.Create(ctx, user, available)
}
```

### gRPC Deadline: Automatic Propagation

In gRPC, deadlines are propagated automatically via metadata. The server must honor them:

```go
// Client: set deadline
ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
defer cancel()

// gRPC automatically adds grpc-timeout header
resp, err := client.GetUser(ctx, &pb.GetUserRequest{Id: userID})

// Server: use ctx from the framework — deadline is already in it
func (s *UserServer) GetUser(ctx context.Context, req *pb.GetUserRequest) (*pb.User, error) {
    // ctx.Deadline() returns the client's deadline
    // If the client gave 2s, and 500ms was spent before this call,
    // we have ~1.5s remaining

    user, err := s.repo.Find(ctx, req.Id) // pass ctx!
    if err != nil {
        if status.Code(err) == codes.DeadlineExceeded {
            return nil, status.Error(codes.DeadlineExceeded, "deadline exceeded")
        }
        return nil, status.Error(codes.Internal, err.Error())
    }

    return userToProto(user), nil
}
```

### Example: Call Chain with Deadline Propagation

```go
package main

import (
    "context"
    "fmt"
    "time"
)

// Simulates a slow downstream service
func callDownstream(ctx context.Context, name string, duration time.Duration) error {
    select {
    case <-time.After(duration):
        return nil
    case <-ctx.Done():
        return fmt.Errorf("%s: %w", name, ctx.Err())
    }
}

// Three sequential calls with a shared deadline
func handleRequest(ctx context.Context) error {
    // Step 1: Auth (100ms)
    authCtx, cancel := context.WithTimeout(ctx, 200*time.Millisecond)
    defer cancel()

    if err := callDownstream(authCtx, "auth-service", 100*time.Millisecond); err != nil {
        return fmt.Errorf("auth failed: %w", err)
    }
    fmt.Println("Auth OK")

    // Step 2: Data fetch (300ms)
    dataCtx, cancel2 := context.WithTimeout(ctx, 400*time.Millisecond)
    defer cancel2()

    if err := callDownstream(dataCtx, "data-service", 300*time.Millisecond); err != nil {
        return fmt.Errorf("data fetch failed: %w", err)
    }
    fmt.Println("Data OK")

    // Step 3: Write (200ms)
    writeCtx, cancel3 := context.WithTimeout(ctx, 300*time.Millisecond)
    defer cancel3()

    if err := callDownstream(writeCtx, "write-service", 200*time.Millisecond); err != nil {
        return fmt.Errorf("write failed: %w", err)
    }
    fmt.Println("Write OK")

    return nil
}

func main() {
    // Scenario 1: enough time (1.5s for a total of 600ms of work)
    ctx1, cancel1 := context.WithTimeout(context.Background(), 1500*time.Millisecond)
    defer cancel1()

    if err := handleRequest(ctx1); err != nil {
        fmt.Printf("Request failed: %v\n", err)
    } else {
        fmt.Println("Request succeeded")
    }

    // Scenario 2: not enough time (400ms, but 600ms needed)
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

### What Is Load Shedding and Why It's Needed

Load shedding is controlled dropping of load when a service is overloaded. Analogy: an electrical grid sheds load in specific districts to prevent the entire grid from collapsing.

```
WITHOUT load shedding (overload):    WITH load shedding:

100 req/s → Service (capacity=80)   100 req/s → Service (capacity=80)
                ↓                                   ↓
   Queue grows unboundedly              20 req/s immediately rejected (503)
                ↓                        80 req/s handled normally
   P99 latency: 30s                                ↓
   P50 latency: 15s                   P99 latency: 150ms
                ↓                     P50 latency: 50ms
   All 100 req get a bad                           ↓
   experience, some are lost          80% of users are satisfied
                                      20% get a fast error
                                      → can immediately retry or get fallback
```

Principle: **it's better to serve 80% of requests well than 100% poorly**.

### Adaptive Load Shedding

Instead of a fixed limit — dynamically detect overload from metrics:

```
Overload signals:
  - Number of in-flight requests > threshold
  - P99 latency > target
  - CPU > 80%
  - Queue length > N
  - Goroutine count > limit

Algorithm:
  if any_overload_signal():
      shedding_probability = calculate_shed_probability()
      if rand() < shedding_probability:
          return 503
```

### Priority-Based Load Shedding

Not all requests are equally important. When overloaded, drop low-priority ones first:

```
Priorities (high → low):
  P0: Health checks, internal critical paths
  P1: Paying users, SLA clients
  P2: Free users
  P3: Background jobs, analytics
  P4: Bots, scrapers, anonymous

At 110% load: shed P4
At 130% load: shed P4 + P3
At 150% load: shed P4 + P3 + P2
```

### Go Example: Load Shedding Middleware

```go
package loadshedding

import (
    "net/http"
    "sync/atomic"
)

// LoadShedder drops requests when the in-flight limit is exceeded
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

// AdaptiveLoadShedder: sheds load based on latency
type AdaptiveLoadShedder struct {
    targetLatency time.Duration
    maxLatency    time.Duration
    ewmaLatency   atomic.Int64 // nanoseconds, exponentially weighted
    alpha         float64      // EWMA coefficient (0.1 = slow update)
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

    // Linear shedding probability between target and max
    // P=0 at target, P=1 at max
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
        priority := getPriority(r) // from header or JWT claims
        current := pls.inflight.Load()
        capacity := pls.maxInflight

        // At 90%+ load — shed priority 3+
        // At 75%+ — shed priority 4+
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
    // For example, from the X-Priority header or based on the user's plan
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

### The Idea

Chaos Engineering is the practice of deliberately injecting failures into a production (or staging) system to discover weak points before a real incident does.

> "If it hurts, do it more often" — the only way to verify that failover works is to test it under load.

```
Traditional approach:          Chaos Engineering:
"We hope everything will       "We know what will break,
 survive an incident"           because we broke it ourselves"
        ↓                              ↓
 Incident happens              We find and fix weak points
 System behaves                before a production incident
 unpredictably
```

### Tools

| Tool | Description | Open Source |
|------|-------------|-------------|
| **Netflix Chaos Monkey** | Randomly kills VMs/containers | Yes |
| **Gremlin** | SaaS, rich set of attacks | No (free tier available) |
| **Litmus** | Chaos for Kubernetes | Yes (CNCF) |
| **Chaos Mesh** | Kubernetes-native chaos | Yes (CNCF) |
| **Pumba** | Chaos for Docker | Yes |
| **tc/iptables** | Manual network emulation | System |

### What to Test

```
Chaos categories:

1. RESOURCE FAILURES
   ├── Kill process (SIGKILL)
   ├── OOM killer
   ├── Disk full (dd if=/dev/zero of=bigfile)
   └── CPU spike (stress-ng)

2. NETWORK FAILURES
   ├── Packet loss       (tc qdisc add netem loss 30%)
   ├── Latency           (tc qdisc add netem delay 200ms 50ms)
   ├── Bandwidth limit   (tc qdisc add tbf rate 1mbit)
   ├── Partition         (iptables DROP between services)
   └── DNS failure       (corrupt /etc/resolv.conf)

3. APPLICATION FAILURES
   ├── Slow response     (sleep before response)
   ├── 500 errors        (inject error in handler)
   ├── Hung goroutines   (block mutex)
   └── Corrupted data    (return invalid JSON)

4. DEPENDENCY FAILURES
   ├── Database unavailable
   ├── Redis unavailable
   ├── Kafka partition leader election
   └── External API timeout
```

### Game Days: Planned Drills

A Game Day is an organized event where the team tests system behavior under artificial failures.

```
Game Day structure:

Preparation (2 weeks before):
  1. Define hypotheses: "if X fails, then Y will happen"
  2. Define blast radius: what we're targeting, what we're protecting
  3. Set up monitoring/alerting
  4. Prepare a rollback plan

Day of drill:
  T-0:00  Briefing, assign roles (attacker, observer, on-call)
  T-0:15  Start experiment in staging
  T-0:45  Analyze staging results
  T-1:00  (optional) Experiment in production with limited blast radius
  T-2:00  Rollback if needed
  T-2:30  Debrief: what broke, what held

After Game Day:
  - Action items with SLA for fixes
  - Update runbook
  - Add new tests
```

### How to Get Started

```
Chaos engineering maturity:

Level 1 (beginning):
  ┌─────────────────────────────────────────────────┐
  │ Staging only, during business hours only        │
  │ Only one experiment at a time                   │
  │ Always have a kill switch                       │
  └─────────────────────────────────────────────────┘

Level 2 (comfortable):
  ┌─────────────────────────────────────────────────┐
  │ Production, but canary (1-5% of traffic)        │
  │ Automatic stop on metric degradation            │
  │ Automated experiments on a schedule             │
  └─────────────────────────────────────────────────┘

Level 3 (mature):
  ┌─────────────────────────────────────────────────┐
  │ Continuous chaos in production                  │
  │ Chaos as part of CI/CD                          │
  │ Experiments run automatically at night          │
  └─────────────────────────────────────────────────┘
```

**First experiment (example):**

```bash
# Experiment: kill one service instance in staging
# Hypothesis: traffic failover will happen in < 5s, errors < 0.1%

# 1. Record baseline metrics
# 2. Kill one pod
kubectl delete pod my-service-7d8f9c-xxxxx -n staging

# 3. Observe in Grafana:
#    - Error rate
#    - Latency P99
#    - Health check success at load balancer

# 4. Record results
# 5. Restore (k8s does this automatically)
```

---

## 8. Disaster Recovery

### RPO and RTO

Two key DR parameters:

```
Incident timeline:

Last backup         Disaster       Recovery complete
    │                  │                │
    ▼                  ▼                ▼
────●──────────────────●────────────────●────► time
    │                  │                │
    │◄── RPO ─────────►│                │
    │  (how much data  │◄──── RTO ─────►│
    │   we can lose)   │  (how quickly  │
    │                  │   to recover)  │
```

**RPO (Recovery Point Objective):** maximum tolerable data loss.
- RPO = 0: zero data loss (synchronous replication)
- RPO = 1h: can lose up to 1 hour of data (hourly backup)
- RPO = 24h: can lose up to 24 hours (daily backup)

**RTO (Recovery Time Objective):** maximum tolerable recovery time.
- RTO = 0: instant switch (active-active)
- RTO = 15min: fast manual failover
- RTO = 4h: acceptable longer recovery

### DR Strategies

#### 1. Backup & Restore

The simplest and cheapest approach. Create regular backups; restore from them during DR.

```
PRIMARY REGION                    BACKUP STORAGE
                                  (S3, GCS, another region)
┌──────────────┐
│   Database   │──── backup ────► [dump_2026-03-23.tar.gz]
│              │◄─── restore ───  [dump_2026-03-22.tar.gz]
└──────────────┘                  [dump_2026-03-21.tar.gz]

RPO: time between backups (1h, 24h, etc.)
RTO: time to restore from backup (hours)
```

#### 2. Pilot Light

Minimal infrastructure in the DR region is always running. During DR — scale and redirect traffic.

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

RPO: seconds (replication is near real-time)
RTO: 15-60 minutes
```

#### 3. Warm Standby

The DR region runs at reduced scale (e.g., 25% of production). Can accept some traffic immediately.

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
  → Total: 5-15 minutes

RPO: seconds
RTO: 5-15 minutes
```

#### 4. Multi-Region Active-Active

Both regions serve production traffic simultaneously. DR = just redirect traffic.

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
  1. Update DNS/Anycast weights (Route 53 health check)
  → Total: seconds (automatic)

RPO: 0 (synchronous) or seconds (asynchronous)
RTO: seconds (automatic)
```

### Strategy Comparison Table

| Strategy | RPO | RTO | Cost | Complexity | When to Use |
|----------|-----|-----|------|------------|-------------|
| **Backup & Restore** | Hours–days | Hours | $ (minimal) | Low | Non-critical systems, dev/test |
| **Pilot Light** | Minutes–seconds | 15–60 min | $$ | Medium | Internal services, B2B |
| **Warm Standby** | Seconds | 5–15 min | $$$ | High | Production with SLA |
| **Active-Active** | 0–seconds | Seconds | $$$$ | Very high | Mission-critical, fintech |

### Regular DR Testing

A DR plan that isn't tested is an illusion. Real checks:

```
Monthly:
  □ Restore backup in an isolated environment
  □ Verify data is consistent
  □ Measure restore time (does it meet RTO?)

Quarterly:
  □ Full DR drill: switch traffic to DR region
  □ Verify team knows the procedures
  □ Update runbook based on results

After every incident:
  □ Post-mortem: what worked, what didn't
  □ Update DR plan
```

**Automated backup verification:**

```go
package dr

import (
    "context"
    "database/sql"
    "fmt"
    "time"
)

// BackupVerifier regularly verifies backup restorability
type BackupVerifier struct {
    primaryDB    *sql.DB
    backupBucket string
    testDB       *sql.DB // isolated test instance
}

// VerifyLatestBackup restores the latest backup and validates the data
func (bv *BackupVerifier) VerifyLatestBackup(ctx context.Context) error {
    start := time.Now()

    // 1. Get the latest backup
    backupPath, err := bv.getLatestBackup(ctx)
    if err != nil {
        return fmt.Errorf("get latest backup: %w", err)
    }

    // 2. Restore to test instance
    if err := bv.restore(ctx, backupPath, bv.testDB); err != nil {
        return fmt.Errorf("restore backup: %w", err)
    }

    // 3. Verify data consistency
    if err := bv.validateData(ctx); err != nil {
        return fmt.Errorf("data validation failed: %w", err)
    }

    // 4. Measure RTO
    elapsed := time.Since(start)
    fmt.Printf("[DR] Backup verified. Restore time: %v\n", elapsed)

    // 5. Record metric
    metrics.Record("dr.restore_time_seconds", elapsed.Seconds())

    // 6. Check that RTO is within target
    const targetRTO = 4 * time.Hour
    if elapsed > targetRTO {
        return fmt.Errorf("restore time %v exceeds target RTO %v", elapsed, targetRTO)
    }

    return nil
}

func (bv *BackupVerifier) validateData(ctx context.Context) error {
    // Compare key metrics between primary and restored backup
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

    // Allow up to 0.1% divergence (RPO)
    diff := abs(primaryCount-restoredCount) * 1000 / primaryCount
    if diff > 1 { // > 0.1%
        return fmt.Errorf("data divergence too large: primary=%d, restored=%d",
            primaryCount, restoredCount)
    }

    return nil
}
```

---

## Summary

Reliability is not a single technique but a layered defense:

```
User request
        │
        ▼
[Rate Limiting]          ← Protection against external overload
        │
        ▼
[Load Shedding]          ← Protection against internal overload
        │
        ▼
[Circuit Breaker]        ← Protection against cascading failures
        │
        ▼
[Timeout + Deadline]     ← Protection of resources from hanging
        │
        ▼
[Retry + Backoff]        ← Resilience to transient errors
        │
        ▼
[Graceful Degradation]   ← Partial response is better than 500
        │
        ▼
[Disaster Recovery]      ← Recovery after a catastrophe
```

**Key principles:**

1. Always set timeouts on external calls — no exceptions
2. Circuit breaker prevents cascading failures; retry handles transient errors
3. Jitter protects downstream from thundering herd
4. Rate limiting protects the service; load shedding preserves quality under overload
5. Chaos Engineering is the only way to verify that failover actually works
6. A DR plan without regular testing is worthless
7. Minimize blast radius: isolate failures using bulkhead and cell-based architecture

---

## Additional Resources

- [AWS Well-Architected Framework: Reliability Pillar](https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html)
- [Google SRE Book: Chapter 22 — Addressing Cascading Failures](https://sre.google/sre-book/cascading-failures/)
- [Netflix Tech Blog: Chaos Engineering](https://netflixtechblog.com/tagged/chaos-engineering)
- [sony/gobreaker](https://github.com/sony/gobreaker) — Circuit Breaker for Go
- [Principles of Chaos Engineering](https://principlesofchaos.org/)
