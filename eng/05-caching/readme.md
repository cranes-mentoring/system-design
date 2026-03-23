# Module 05: Caching

Caching is about storing the result of an expensive operation close to the consumer so that subsequent requests are cheaper. Sounds simple. In practice, it is one of the leading causes of production incidents. This module covers caching from architectural layers down to specific patterns and pitfalls.

---

## Table of Contents

1. [Why Caching and Where It Lives](#1-why-caching-and-where-it-lives)
2. [Caching Strategies](#2-caching-strategies)
3. [Eviction Policies](#3-eviction-policies)
4. [Redis: Architecture and Patterns](#4-redis-architecture-and-patterns)
5. [CDN (Content Delivery Network)](#5-cdn-content-delivery-network)
6. [Caching Problems](#6-caching-problems)
7. [Cache Invalidation](#7-cache-invalidation)

---

## 1. Why Caching and Where It Lives

### The Problem

A database hits its IOPS ceiling against the disk. A network call to a neighboring service costs milliseconds. A complex aggregating SQL query can take hundreds of milliseconds. If hundreds of users are making identical requests, you pay that price every single time.

Caching solves this: compute once, serve fast.

### Caching Layers

A cache exists at every layer of the stack. Different layers differ in latency, capacity, and area of responsibility.

```
  User
    │
    ▼
┌─────────────────┐
│  Browser Cache  │  ← HTTP headers, Service Worker
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│      CDN        │  ← Edge nodes, PoPs worldwide
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Load Balancer  │  ← Sometimes caches, but rarely
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  App Server     │
│  ┌───────────┐  │  ← In-process cache (sync.Map, groupcache)
│  │ L1 Cache  │  │
│  └───────────┘  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Distributed     │  ← Redis, Memcached
│ Cache           │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   Database      │  ← Query cache, buffer pool
└─────────────────┘
```

| Layer | Latency | Typical Capacity | Example |
|---|---|---|---|
| CPU L1/L2/L3 | 1–40 ns | KB — MB | Processor cache, managed by the CPU |
| In-process (heap) | 100–500 ns | MB — GB | `sync.Map`, in-process LRU |
| Distributed cache | 0.5–2 ms | GB — TB | Redis, Memcached |
| CDN | 1–50 ms | TB | Cloudflare, Fastly, CloudFront |
| Browser cache | 0 ms (disk) | MB | HTTP Cache-Control |
| Database buffer pool | 0.1–1 ms | GB | InnoDB buffer pool, PostgreSQL shared_buffers |

### Cache Hit Ratio

**Cache Hit Ratio (CHR)** — the fraction of requests served from the cache:

```
CHR = Cache Hits / (Cache Hits + Cache Misses)
```

| CHR | Assessment |
|---|---|
| < 80% | Poor — the cache barely helps |
| 80–90% | Acceptable as a starting point |
| 90–95% | Good |
| > 95% | Excellent — typical production target |
| > 99% | For read-heavy systems with hot data |

A low CHR is a sign of one of the following problems:
- Cache size is too small (too many evictions)
- Bad TTL (data expires before a repeat request arrives)
- High key cardinality (every request is unique)
- Cache penetration (requests for non-existent data)

**How to measure:** add `cache.hits` and `cache.misses` counters to your metrics (Prometheus). Look not only at the overall CHR, but also break it down by data type — different entities behave differently.

---

## 2. Caching Strategies

### Cache-Aside (Lazy Loading)

The application manages the cache itself. The most common pattern.

```
Application        Cache          Database
     │               │                │
     │── GET key ───►│                │
     │               │                │
     │◄── MISS ──────│                │
     │               │                │
     │─────────────────── SELECT ────►│
     │◄────────────────── Data ───────│
     │               │                │
     │── SET key ───►│                │
     │               │                │
     │◄── OK ────────│                │
     │               │                │
  (next request)
     │── GET key ───►│                │
     │◄── HIT ───────│                │
```

**Pros:**
- The cache only contains data that is actually requested
- A cache failure does not bring down the system — we fall back to the DB
- Different data can be cached differently

**Cons:**
- The first request is always slow (cold start)
- Race condition on concurrent requests: multiple goroutines may simultaneously go to the DB
- Responsibility for the cache is spread throughout the application

### Write-Through

Writes go simultaneously to the cache and the DB. The cache is always up to date.

```
Application        Cache          Database
     │               │                │
     │── SET key ───►│                │
     │               │── INSERT ─────►│
     │               │◄── OK ─────────│
     │◄── OK ────────│                │
```

**When to use:**
- Data is frequently read right after being written
- Stale reads are not acceptable
- Write-few, read-many workloads

**Cons:**
- Writes are slower (two round-trips)
- The cache fills with data that may never be read

### Write-Behind (Write-Back)

Write first to the cache, then asynchronously to the DB. Maximum write throughput.

```
Application        Cache          Database
     │               │                │
     │── SET key ───►│                │
     │◄── OK ────────│                │
     │               │                │
     │            (async, batch)       │
     │               │── INSERT ─────►│
     │               │◄── OK ─────────│
```

**When to use:**
- Write-heavy workloads (counters, analytics)
- Temporary desynchronization is acceptable
- You can tolerate losing a few recent writes on failure

**Risks:**
- If the cache crashes before flushing — data is lost
- More complex to implement correctly
- Not suitable for financial data

### Read-Through

The cache itself goes to the DB on a cache miss. The application only talks to the cache.

```
Application        Cache          Database
     │               │                │
     │── GET key ───►│                │
     │               │── SELECT ─────►│  (on miss)
     │               │◄── Data ───────│
     │◄── Data ──────│                │
```

**Difference from Cache-Aside:** the data-loading logic lives inside the cache library, not the application. Example: `github.com/dgraph-io/ristretto` with a loader function.

### Refresh-Ahead

The cache proactively refreshes data in the background before the TTL expires, once it detects that a key is about to become stale.

```
TTL = 60s, refresh when remaining TTL < 10s

t=0   ── SET key (TTL=60s)
t=50  ── GET key → HIT + trigger background refresh
t=51  ── Background: GET from DB + SET key (TTL=60s)
t=60  ── TTL expired, but fresh key is already loaded
```

**When to use:** data is updated predictably and cache misses under load are unacceptable.

**Downside:** the cache may refresh data that is no longer being requested.

### Strategy Comparison

| Strategy | Consistency | Read Latency | Write Latency | Complexity | Data Loss Risk |
|---|---|---|---|---|---|
| Cache-Aside | Eventual | High (on miss) | Normal | Low | No |
| Write-Through | Strong | Low | High | Medium | No |
| Write-Behind | Eventual | Low | Minimal | High | Yes |
| Read-Through | Eventual | High (on miss) | Normal | Medium | No |
| Refresh-Ahead | Eventual | Minimal | Normal | High | No |

### Go Example: Cache-Aside with Redis

```go
package cache

import (
    "context"
    "encoding/json"
    "errors"
    "fmt"
    "time"

    "github.com/redis/go-redis/v9"
)

type UserRepository struct {
    db    DB
    redis *redis.Client
    ttl   time.Duration
}

type User struct {
    ID    int64  `json:"id"`
    Name  string `json:"name"`
    Email string `json:"email"`
}

func (r *UserRepository) GetUser(ctx context.Context, id int64) (*User, error) {
    key := fmt.Sprintf("user:%d", id)

    // 1. Check the cache
    data, err := r.redis.Get(ctx, key).Bytes()
    if err == nil {
        var user User
        if err := json.Unmarshal(data, &user); err == nil {
            return &user, nil // cache hit
        }
    }
    if !errors.Is(err, redis.Nil) {
        // Redis is unavailable — log it, but don't crash
        // Continue to the DB
        _ = err
    }

    // 2. Cache miss — go to the DB
    user, err := r.db.GetUser(ctx, id)
    if err != nil {
        return nil, fmt.Errorf("db.GetUser: %w", err)
    }

    // 3. Store in cache
    b, _ := json.Marshal(user)
    r.redis.Set(ctx, key, b, r.ttl) // ignore error — cache is optional

    return user, nil
}

func (r *UserRepository) UpdateUser(ctx context.Context, user *User) error {
    if err := r.db.UpdateUser(ctx, user); err != nil {
        return err
    }
    // Invalidate the cache after a successful DB write
    key := fmt.Sprintf("user:%d", user.ID)
    r.redis.Del(ctx, key)
    return nil
}
```

---

## 3. Eviction Policies

When the cache is full and a new item needs to fit — what do you evict?

### LRU (Least Recently Used)

Evicts the item that has not been accessed for the longest time. Implemented via a doubly linked list + hash map.

```
Cache state (capacity = 3):

Add A: [A]
Add B: [B, A]
Add C: [C, B, A]
GET B: [B, C, A]  ← B moved to the front
Add D: [D, B, C]  ← A evicted (oldest)
```

**When to use:** the general case — works well for most access patterns. The standard default choice.

### LFU (Least Frequently Used)

Evicts the item with the fewest accesses.

```
[A: 10 hits, B: 3 hits, C: 7 hits]
Add D → B is evicted (fewest accesses)
```

**When to use:** there are clearly "hot" items that must not be evicted. Handles burst access patterns worse than LRU because items that were once popular but have gone stale will remain in the cache for a long time.

### TTL-based

Items are automatically removed when their time-to-live expires, regardless of access.

**When to use:** data loses relevance over time. Often combined with LRU.

### Random

Evicts a random item.

**When to use:** rarely — in systems where access patterns are completely unpredictable, or as the simplest possible implementation. Redis supports `allkeys-random`.

### Redis Eviction Policies

| Policy | Description |
|---|---|
| `noeviction` | Returns an error when full (default) |
| `allkeys-lru` | LRU across all keys |
| `volatile-lru` | LRU among keys that have a TTL set |
| `allkeys-lfu` | LFU across all keys |
| `volatile-lfu` | LFU among keys that have a TTL set |
| `allkeys-random` | Random among all keys |
| `volatile-ttl` | Evicts keys with the smallest TTL |

For pure cache use cases: `allkeys-lru` or `allkeys-lfu`. For mixed use (cache + persistent data): `volatile-lru`.

### Go Example: In-memory LRU Cache

```go
package lru

import (
    "container/list"
    "sync"
)

type entry struct {
    key   string
    value any
}

type Cache struct {
    capacity int
    mu       sync.Mutex
    list     *list.List
    items    map[string]*list.Element
}

func New(capacity int) *Cache {
    return &Cache{
        capacity: capacity,
        list:     list.New(),
        items:    make(map[string]*list.Element, capacity),
    }
}

func (c *Cache) Get(key string) (any, bool) {
    c.mu.Lock()
    defer c.mu.Unlock()

    el, ok := c.items[key]
    if !ok {
        return nil, false
    }
    // Move to front — this is the most recently used item
    c.list.MoveToFront(el)
    return el.Value.(*entry).value, true
}

func (c *Cache) Set(key string, value any) {
    c.mu.Lock()
    defer c.mu.Unlock()

    // Update existing
    if el, ok := c.items[key]; ok {
        c.list.MoveToFront(el)
        el.Value.(*entry).value = value
        return
    }

    // Evict the LRU item if the cache is full
    if c.list.Len() >= c.capacity {
        oldest := c.list.Back()
        if oldest != nil {
            c.list.Remove(oldest)
            delete(c.items, oldest.Value.(*entry).key)
        }
    }

    // Add new item to the front
    e := &entry{key: key, value: value}
    el := c.list.PushFront(e)
    c.items[key] = el
}

func (c *Cache) Delete(key string) {
    c.mu.Lock()
    defer c.mu.Unlock()

    if el, ok := c.items[key]; ok {
        c.list.Remove(el)
        delete(c.items, key)
    }
}

func (c *Cache) Len() int {
    c.mu.Lock()
    defer c.mu.Unlock()
    return c.list.Len()
}
```

For production, use `github.com/hashicorp/golang-lru/v2` or `github.com/dgraph-io/ristretto` — they provide thread safety, metrics, TTL support, and size-weighted eviction.

---

## 4. Redis: Architecture and Patterns

Redis is an in-memory data structure store. Not just a key-value store: its rich set of data structures makes it a versatile tool.

### Data Structures

| Structure | Commands | Typical Use Case |
|---|---|---|
| **String** | GET, SET, INCR, EXPIRE | Object cache, counters, sessions |
| **Hash** | HGET, HSET, HGETALL | User objects, configs |
| **List** | LPUSH, RPOP, LRANGE | Task queues, logs, activity feeds |
| **Set** | SADD, SMEMBERS, SINTER | Unique tags, online users |
| **Sorted Set** | ZADD, ZRANGE, ZRANK | Leaderboards, rate limiting, timelines |
| **Stream** | XADD, XREAD, XGROUP | Event sourcing, message queue with ACK |
| **HyperLogLog** | PFADD, PFCOUNT | Counting unique visitors (±0.81% error) |
| **Bitmap** | SETBIT, GETBIT, BITCOUNT | Activity flags, bloom filter |
| **Geo** | GEOADD, GEODIST, GEORADIUS | Nearest-location search |

### Persistence: RDB vs AOF

**RDB (Redis Database Backup):**
- Full snapshot of state written to a binary file
- Created on a schedule (`save 900 1` — every 15 minutes if at least one write occurred)
- Fast restart (loads a single file)
- **Risk:** data loss for the period between snapshots

**AOF (Append-Only File):**
- Logs every write command
- Three modes: `always` (fsync on every command), `everysec` (fsync once per second), `no` (OS decides)
- Less data loss on crash
- **Downside:** large file, slower restart

| Parameter | RDB | AOF |
|---|---|---|
| Potential loss | Minutes | 0–1 sec (everysec) |
| Restart speed | Fast | Slow (replays the entire log) |
| File size | Small | Large (requires periodic rewriting) |
| Suitable for | Cache, losses are acceptable | Persistent data |

**Recommendation:** for a pure cache — RDB only or no persistence at all. For data that cannot be lost — AOF with `everysec` + RDB for fast restarts.

### Redis Cluster

Horizontal sharding via **hash slots**. There are 16,384 slots in total.

```
┌──────────────────────────────────────────┐
│             Redis Cluster                │
│                                          │
│  ┌─────────────┐  ┌─────────────┐        │
│  │  Master 1   │  │  Master 2   │  ...   │
│  │ slots 0-5460│  │slots 5461-  │        │
│  │             │  │    10922    │        │
│  └──────┬──────┘  └──────┬──────┘        │
│         │                │               │
│  ┌──────┴──────┐  ┌──────┴──────┐        │
│  │  Replica 1  │  │  Replica 2  │        │
│  └─────────────┘  └─────────────┘        │
└──────────────────────────────────────────┘

Key sharding:
slot = CRC16(key) % 16384
```

**Hash tags:** `{user}.profile` and `{user}.sessions` will land in the same slot — enabling transactions across keys.

**Failover:** when a master becomes unavailable, a replica is automatically promoted via majority vote (cluster-require-full-coverage).

**Cluster limitations:**
- Cross-slot operations are not allowed (MGET with keys from different slots)
- Lua scripts only work within a single slot
- Pub/Sub works on a single node

### Redis Sentinel

A high-availability solution **without** sharding.

```
┌──────────┐    ┌──────────┐    ┌──────────┐
│Sentinel 1│    │Sentinel 2│    │Sentinel 3│
└──────┬───┘    └────┬─────┘    └───┬──────┘
       │             │              │
       └─────────────┼──────────────┘
                     │ monitoring
              ┌──────┴──────┐
              │   Master    │
              └──────┬──────┘
                     │ replication
              ┌──────┴──────┐
              │   Replica   │
              └─────────────┘
```

Sentinels vote on failover (a quorum is required). When the master is unavailable, a replica is promoted. Clients ask Sentinel who the current master is.

### Pub/Sub vs Streams

**Pub/Sub:**
```
Publisher → Channel → [Subscriber1, Subscriber2, ...]
```
- **No delivery guarantee** — if the subscriber is not connected, the message is lost
- **No persistence** — old messages cannot be read back
- Suitable for: real-time notifications, chat, broadcasting events where loss is acceptable

**Streams:**
```
XADD stream * field value
XREAD COUNT 10 STREAMS stream 0
XGROUP CREATE stream my-group $ MKSTREAM
XREADGROUP GROUP my-group consumer1 COUNT 10 STREAMS stream >
XACK stream my-group message-id
```
- **Persistence** — messages are stored
- **Consumer groups** — multiple workers share the load
- **ACK** — processing acknowledgement
- **Replay** — can re-read from any position

Use Streams when reliability is required. Pub/Sub is for fire-and-forget notifications.

### Lua Scripts for Atomic Operations

Redis executes Lua scripts atomically — no other command runs while the script is executing.

```go
// Example: atomic conditional update
const script = `
local current = redis.call('GET', KEYS[1])
if current == false then
    return 0
end
if tonumber(current) >= tonumber(ARGV[1]) then
    redis.call('DECRBY', KEYS[1], ARGV[1])
    return 1
end
return 0
`

result, err := client.Eval(ctx, script, []string{"balance:user:42"}, 100).Int()
```

### Go Example: Rate Limiter (Sliding Window) with Lua

Sliding window rate limiter: no more than N requests in the last T seconds.

```go
package ratelimit

import (
    "context"
    "fmt"
    "time"

    "github.com/redis/go-redis/v9"
)

// Lua script: sliding window rate limiter
// KEYS[1] - key (e.g. "ratelimit:user:42")
// ARGV[1] - current time in milliseconds
// ARGV[2] - window size in milliseconds
// ARGV[3] - maximum number of requests
// Returns: 1 if allowed, 0 if limit exceeded
const slidingWindowScript = `
local key = KEYS[1]
local now = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local limit = tonumber(ARGV[3])

-- Remove stale entries (older than the window)
redis.call('ZREMRANGEBYSCORE', key, 0, now - window)

-- Count the current number of requests in the window
local count = redis.call('ZCARD', key)

if count >= limit then
    return 0
end

-- Add the current request (score = timestamp, member = timestamp for uniqueness)
redis.call('ZADD', key, now, now .. '-' .. math.random(1, 1000000))

-- Set TTL slightly larger than the window size
redis.call('PEXPIRE', key, window + 1000)

return 1
`

type RateLimiter struct {
    client *redis.Client
    script *redis.Script
    window time.Duration
    limit  int
}

func NewRateLimiter(client *redis.Client, window time.Duration, limit int) *RateLimiter {
    return &RateLimiter{
        client: client,
        script: redis.NewScript(slidingWindowScript),
        window: window,
        limit:  limit,
    }
}

func (r *RateLimiter) Allow(ctx context.Context, key string) (bool, error) {
    now := time.Now().UnixMilli()
    windowMs := r.window.Milliseconds()

    result, err := r.script.Run(ctx, r.client,
        []string{fmt.Sprintf("ratelimit:%s", key)},
        now, windowMs, r.limit,
    ).Int()
    if err != nil {
        // Fail open: if Redis is unavailable — allow the request
        return true, err
    }

    return result == 1, nil
}
```

### Go Example: Distributed Lock (RedLock)

For a single Redis instance, `SET NX` is sufficient. For fault-tolerant distributed locks across a cluster — RedLock (majority quorum).

```go
package distlock

import (
    "context"
    "crypto/rand"
    "encoding/hex"
    "errors"
    "time"

    "github.com/redis/go-redis/v9"
)

var ErrLockNotAcquired = errors.New("lock not acquired")

// Lua script for safely releasing the lock:
// only release if the value matches (prevents unlocking by another holder)
const unlockScript = `
if redis.call('GET', KEYS[1]) == ARGV[1] then
    return redis.call('DEL', KEYS[1])
else
    return 0
end
`

type Lock struct {
    client *redis.Client
    key    string
    value  string
    ttl    time.Duration
}

func Acquire(ctx context.Context, client *redis.Client, key string, ttl time.Duration) (*Lock, error) {
    // Generate a unique token
    b := make([]byte, 16)
    rand.Read(b)
    value := hex.EncodeToString(b)

    // SET key value NX PX ttl
    ok, err := client.SetNX(ctx, key, value, ttl).Result()
    if err != nil {
        return nil, err
    }
    if !ok {
        return nil, ErrLockNotAcquired
    }

    return &Lock{client: client, key: key, value: value, ttl: ttl}, nil
}

func (l *Lock) Release(ctx context.Context) error {
    result, err := l.client.Eval(ctx, unlockScript, []string{l.key}, l.value).Int()
    if err != nil {
        return err
    }
    if result == 0 {
        return errors.New("lock already expired or released by someone else")
    }
    return nil
}

// Extend renews the TTL if we still hold the lock
func (l *Lock) Extend(ctx context.Context) error {
    const extendScript = `
if redis.call('GET', KEYS[1]) == ARGV[1] then
    return redis.call('PEXPIRE', KEYS[1], ARGV[2])
else
    return 0
end
`
    result, err := l.client.Eval(ctx, extendScript,
        []string{l.key},
        l.value,
        l.ttl.Milliseconds(),
    ).Int()
    if err != nil {
        return err
    }
    if result == 0 {
        return errors.New("lock expired, cannot extend")
    }
    return nil
}

// Usage:
//
// lock, err := distlock.Acquire(ctx, redisClient, "job:process:42", 30*time.Second)
// if errors.Is(err, distlock.ErrLockNotAcquired) {
//     return // another worker is already processing
// }
// defer lock.Release(ctx)
// // ... critical section
```

> **Important:** RedLock (multiple independent Redis instances) is only needed for fault-tolerant distributed locks. For most use cases, a single Redis instance with `SET NX` is sufficient. Martin Kleppmann and Antirez have thoroughly analyzed the [problems with RedLock](https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html) — read it before using.

---

## 5. CDN (Content Delivery Network)

### How It Works

A CDN is a network of servers (edge nodes, PoPs — Points of Presence) geographically distributed close to users. Instead of every request going to the origin server, it is served by the nearest edge node.

```
User (Moscow)               CDN Edge (Moscow)       Origin (US-East)
        │                              │                        │
        │── GET /image.jpg ───────────►│                        │
        │                              │  Cache HIT?            │
        │                              │── GET /image.jpg ─────►│  (only on miss)
        │                              │◄── 200 OK + image ─────│
        │◄── 200 OK + image ───────────│                        │
        │                              │  (cached for           │
        │                              │   subsequent requests) │
```

**Pull CDN (most common):** the CDN itself fetches content from the origin on the first request and caches it at the edge. You do nothing special — just put the CDN in front of your origin.

**Push CDN:** you explicitly upload files to the CDN (via API). Full control over what is cached. Suitable for large static files that rarely change.

### What to Cache

| Content Type | Cache? | TTL | Notes |
|---|---|---|---|
| Static assets (JS, CSS, PNG) | Yes | Days — year | Use versioned URLs |
| HTML pages | Depends | Seconds — hours | Be careful with personalization |
| API responses (public) | Yes | Seconds — minutes | Cache-Control: public |
| API responses (authenticated) | No | — | Cache-Control: private |
| Video/audio | Yes | Days — year | Range requests |
| Real-time data | No | — | WebSocket, SSE |

### Cache-Control Headers

```http
Cache-Control: max-age=3600, s-maxage=86400, stale-while-revalidate=60
```

| Directive | Behavior |
|---|---|
| `max-age=N` | Cache for N seconds (browser + CDN) |
| `s-maxage=N` | Cache for N seconds in shared caches only (CDN). Overrides max-age for CDN |
| `no-cache` | Cache, but always revalidate with origin before serving |
| `no-store` | Do not cache at all |
| `private` | Cache in browser only, not in CDN |
| `public` | Allow caching by everyone |
| `must-revalidate` | Do not serve stale content, even if origin is unavailable |
| `stale-while-revalidate=N` | Serve stale content while refreshing in the background (for N seconds) |
| `stale-if-error=N` | Serve stale content if origin returns an error |

**Recipe for static assets with a hash in the filename:**
```http
Cache-Control: public, max-age=31536000, immutable
```

**Recipe for HTML:**
```http
Cache-Control: public, max-age=0, s-maxage=300, stale-while-revalidate=60
```

**Recipe for API:**
```http
Cache-Control: public, max-age=60, stale-while-revalidate=30
```

### Cache Invalidation in CDN

**Versioned URLs** — the most reliable approach:
```
/static/app.a3f9c21d.js   ← content hash in the filename
/static/logo.v4.png       ← explicit version
```
When a file changes, its URL changes → the old file can be cached forever, the new one is immediately available.

**Purge API** — an explicit request to remove from the cache:
```bash
# Cloudflare
curl -X DELETE "https://api.cloudflare.com/client/v4/zones/{zone_id}/purge_cache" \
  -H "Authorization: Bearer {token}" \
  -d '{"files":["https://example.com/api/products"]}'
```

**Surrogate Keys (Cache Tags)** — tags on content allow invalidating a group of resources:
```http
# Origin response includes tags
Surrogate-Key: product-42 category-electronics

# Invalidate everything related to product-42
curl -X POST "https://api.fastly.com/service/{id}/purge/product-42"
```

### Multi-tier Caching

```
Browser Cache (private)
      │ Cache miss
      ▼
   CDN Edge
      │ Cache miss
      ▼
 Application Cache (Redis)
      │ Cache miss
      ▼
   Database
```

Each layer reduces load on the next. The goal is for 95%+ of requests to be answered by the browser or CDN cache.

### CDN Providers

| Provider | When to Choose |
|---|---|
| **Cloudflare** | The default starting point for most projects. Free tier, DDoS protection, Workers for edge computing, simple setup |
| **Fastly** | Need Surrogate Keys, low TTL (~seconds), Varnish-compatible VCL, fast invalidation |
| **AWS CloudFront** | Already on AWS infrastructure, need integration with S3/ALB/Lambda@Edge |
| **Akamai** | Enterprise, complex requirements, global network with coverage in hard-to-reach regions |

---

## 6. Caching Problems

### Cache Stampede (Thundering Herd)

**Problem:** a popular key expires. Hundreds of requests simultaneously go to the DB.

```
t=0:   key "popular_feed" expires
t=1:   1000 requests → cache miss
t=2:   1000 requests hit the DB simultaneously
t=3:   DB crashes under load
```

**Solution 1: Mutex / Singleflight**

Only one goroutine goes to the DB; the rest wait for the result.

**Solution 2: Stale-While-Revalidate**

Serve stale data while one goroutine refreshes in the background.

**Solution 3: Probabilistic Early Expiration (XFetch)**

Each request has a certain probability of refreshing the cache before the TTL expires. The probability increases as TTL approaches:

```
P(refresh) = -β * fetch_time * ln(rand())  > TTL - current_time
```

### Cache Penetration

**Problem:** requests for non-existent keys always go to the DB (there is nothing to cache).

```
GET /users/99999999  → cache miss → db miss → nothing to cache
GET /users/99999999  → cache miss → db miss → ...  (indefinitely)
```

**Solution 1: Cache null**

```go
const nullSentinel = "__null__"

user, err := r.db.GetUser(ctx, id)
if errors.Is(err, ErrNotFound) {
    // Cache the fact of absence with a short TTL
    r.redis.Set(ctx, key, nullSentinel, 30*time.Second)
    return nil, ErrNotFound
}
```

**Solution 2: Bloom Filter**

A probabilistic data structure — check for object existence before querying the DB. False positives are possible, false negatives are not.

```go
import "github.com/bits-and-blooms/bloom/v3"

// At startup: populate the filter with all existing IDs
filter := bloom.NewWithEstimates(1_000_000, 0.01) // 1M elements, 1% FPR
for _, id := range allUserIDs {
    filter.Add([]byte(strconv.FormatInt(id, 10)))
}

// On request
if !filter.Test([]byte(strconv.FormatInt(userID, 10))) {
    return nil, ErrNotFound // definitely does not exist
}
// May exist — go to cache/DB
```

### Cache Avalanche

**Problem:** a large number of keys expire simultaneously (e.g., at service startup all TTLs are set at the same time).

```
t=0:   Deploy, cache is empty, 10,000 keys loaded with TTL=1h
t=1h:  All 10,000 keys expire simultaneously
t=1h+: Avalanche of requests hits the DB
```

**Solution: Jitter in TTL**

```go
func ttlWithJitter(base time.Duration) time.Duration {
    // Add a random offset of ±10%
    jitter := time.Duration(rand.Int63n(int64(base / 5)))
    if rand.Intn(2) == 0 {
        return base + jitter
    }
    return base - jitter
}

r.redis.Set(ctx, key, data, ttlWithJitter(time.Hour))
```

Also: gradual cache warming (cache warming) on deployment.

### Stale Data

**Trade-off:** the longer the TTL, the faster the system, but the older the data.

TTL selection is driven by business requirements:
- Account balance: TTL = 0 (cannot be cached)
- User profile: TTL = 5–60 minutes
- Product listing: TTL = 5–30 minutes
- Exchange rates: TTL = 1–5 minutes
- Static pages: TTL = hours–days

### Go Example: Protection Against Cache Stampede with singleflight

`golang.org/x/sync/singleflight` — groups identical concurrent requests, executes one, and returns the result to all callers.

```go
package cache

import (
    "context"
    "encoding/json"
    "fmt"
    "time"

    "github.com/redis/go-redis/v9"
    "golang.org/x/sync/singleflight"
)

type SafeCache struct {
    redis  *redis.Client
    db     DB
    group  singleflight.Group
    ttl    time.Duration
}

func (c *SafeCache) GetProduct(ctx context.Context, id int64) (*Product, error) {
    key := fmt.Sprintf("product:%d", id)

    // Fast path: check the cache
    data, err := c.redis.Get(ctx, key).Bytes()
    if err == nil {
        var p Product
        json.Unmarshal(data, &p)
        return &p, nil
    }

    // Cache miss — use singleflight
    // All concurrent calls with the same key wait for a single result
    result, err, _ := c.group.Do(key, func() (any, error) {
        // This function executes only once for concurrent requests
        product, err := c.db.GetProduct(ctx, id)
        if err != nil {
            return nil, err
        }

        b, _ := json.Marshal(product)
        c.redis.Set(ctx, key, b, c.ttl)
        return product, nil
    })

    if err != nil {
        return nil, err
    }

    return result.(*Product), nil
}
```

The third return value of `Do` — `shared bool` — indicates whether the result was returned to multiple callers. Useful for metrics.

---

## 7. Cache Invalidation

> "There are only two hard things in Computer Science: cache invalidation and naming things."
> — Phil Karlton

Invalidation is hard because there is no universal answer to the question "when has the data in the cache gone stale?" Every approach has trade-offs.

### TTL-based (Time-To-Live)

The simplest approach: data automatically expires after a set period.

```go
r.redis.Set(ctx, key, data, 5*time.Minute)
```

**Pros:** simplicity, no additional infrastructure.
**Cons:** data may be stale until TTL expires; a TTL that is too short increases DB load.

### Explicit Purge via API

On write, immediately delete or update the cache.

```go
func (s *ProductService) UpdateProduct(ctx context.Context, p *Product) error {
    if err := s.db.Update(ctx, p); err != nil {
        return err
    }
    // Invalidate the specific key
    s.cache.Del(ctx, fmt.Sprintf("product:%d", p.ID))
    // Invalidate related lists
    s.cache.Del(ctx, fmt.Sprintf("products:category:%d", p.CategoryID))
    return nil
}
```

**Problem:** tight coupling between services. If service A updates data, service B must know it needs to invalidate. Scales poorly.

### Versioned Keys

Instead of invalidating, change the key when data changes.

```go
// Version is stored separately
version, _ := r.redis.Get(ctx, "product:42:version").Int()
key := fmt.Sprintf("product:42:v%d", version)

// On update
r.redis.Incr(ctx, "product:42:version")
// The old key will expire via TTL, the new one will be read from DB
```

**Pros:** atomicity without locks. **Cons:** key count grows, a cleanup strategy is needed.

### Event-Driven Invalidation

The data-source service publishes a "data changed" event. Subscribers invalidate their caches.

```
┌──────────────┐    publish     ┌─────────────────┐
│ Product Svc  │ ─────────────► │   Kafka/NATS    │
│ (updated     │                │  topic:         │
│  product 42) │                │  product.updated│
└──────────────┘                └────────┬────────┘
                                         │ subscribe
                          ┌──────────────┴──────────────┐
                          ▼                              ▼
                 ┌────────────────┐           ┌────────────────┐
                 │  Search Svc    │           │  Order Svc     │
                 │  (invalidates  │           │  (invalidates  │
                 │  search cache) │           │  order cache)  │
                 └────────────────┘           └────────────────┘
```

**Go Example: Invalidation via NATS**

```go
package invalidation

import (
    "context"
    "encoding/json"
    "fmt"
    "log/slog"

    "github.com/nats-io/nats.go"
    "github.com/redis/go-redis/v9"
)

type InvalidationEvent struct {
    EntityType string `json:"entity_type"` // "product", "user", "category"
    EntityID   int64  `json:"entity_id"`
    Action     string `json:"action"` // "updated", "deleted"
}

type CacheInvalidator struct {
    redis  *redis.Client
    nc     *nats.Conn
    logger *slog.Logger
}

func NewCacheInvalidator(redis *redis.Client, nc *nats.Conn) *CacheInvalidator {
    return &CacheInvalidator{redis: redis, nc: nc}
}

// Subscribe starts processing invalidation events
func (c *CacheInvalidator) Subscribe(ctx context.Context) error {
    sub, err := c.nc.Subscribe("cache.invalidate.*", func(msg *nats.Msg) {
        var event InvalidationEvent
        if err := json.Unmarshal(msg.Data, &event); err != nil {
            c.logger.Error("failed to unmarshal event", "err", err)
            return
        }
        if err := c.handleEvent(ctx, event); err != nil {
            c.logger.Error("failed to handle invalidation event",
                "entity_type", event.EntityType,
                "entity_id", event.EntityID,
                "err", err,
            )
        }
    })
    if err != nil {
        return err
    }

    // Wait for context cancellation
    <-ctx.Done()
    sub.Unsubscribe()
    return nil
}

func (c *CacheInvalidator) handleEvent(ctx context.Context, event InvalidationEvent) error {
    keys := c.keysForEvent(event)
    if len(keys) == 0 {
        return nil
    }

    deleted, err := c.redis.Del(ctx, keys...).Result()
    c.logger.Info("cache invalidated",
        "entity_type", event.EntityType,
        "entity_id", event.EntityID,
        "keys_deleted", deleted,
    )
    return err
}

func (c *CacheInvalidator) keysForEvent(event InvalidationEvent) []string {
    switch event.EntityType {
    case "product":
        return []string{
            fmt.Sprintf("product:%d", event.EntityID),
            fmt.Sprintf("product:%d:details", event.EntityID),
            "products:featured", // also invalidate global lists
        }
    case "user":
        return []string{
            fmt.Sprintf("user:%d", event.EntityID),
            fmt.Sprintf("user:%d:profile", event.EntityID),
        }
    default:
        return nil
    }
}

// PublishInvalidation publishes an invalidation event
func (c *CacheInvalidator) PublishInvalidation(ctx context.Context, event InvalidationEvent) error {
    data, err := json.Marshal(event)
    if err != nil {
        return err
    }
    subject := fmt.Sprintf("cache.invalidate.%s", event.EntityType)
    return c.nc.Publish(subject, data)
}
```

### Approach Comparison

| Approach | Data Freshness | Complexity | Coupling | Best For |
|---|---|---|---|---|
| TTL-based | Eventual (TTL delay) | Minimal | None | Most caches |
| Purge on write | Immediate | Low | High | Single service |
| Versioned keys | Immediate | Medium | None | Versioned data |
| Event-driven | Near-immediate | High | Loose | Microservices |

---

## Summary

| Topic | Key Takeaway |
|---|---|
| Strategies | Cache-Aside for most cases; Write-Through if stale reads are unacceptable; Write-Behind for write-heavy workloads with tolerable loss |
| Eviction | LRU by default; LFU when there is clearly hot data; always set a TTL |
| Redis | Rich data structures — use the right one; Streams > Pub/Sub for reliability; Lua for atomic operations |
| CDN | s-maxage for CDN TTL; versioned URLs for static assets; Surrogate Keys for targeted invalidation |
| Problems | singleflight against stampede; bloom filter / null cache against penetration; jitter against avalanche |
| Invalidation | TTL + event-driven = balance of simplicity and freshness; versioned keys without coupling |

Caching is a trade-off between data freshness, DB load, and system complexity. There is no universal solution — always evaluate the specific use case.
