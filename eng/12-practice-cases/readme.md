# Module 12: Practice Cases

The final module — six complete System Design cases. Each follows the framework from Module 01:
**Requirements → Estimation → Storage → HLD → API → Detailed Design → Trade-offs**.

Goal: don't just read — solve each case on your own before reading the solution.

---

## Table of Contents

1. [Case 1: URL Shortener (Bitly)](#case-1-url-shortener-bitly)
2. [Case 2: Messenger (WhatsApp/Telegram)](#case-2-messenger-whatsapptelegram)
3. [Case 3: News Feed (Twitter/Instagram)](#case-3-news-feed-twitterinstagram)
4. [Case 4: Distributed Rate Limiter](#case-4-distributed-rate-limiter)
5. [Case 5: Notification Service](#case-5-notification-service)
6. [Case 6: Distributed Task Scheduler (Cron)](#case-6-distributed-task-scheduler-cron)

---

## Case 1: URL Shortener (Bitly)

### 1.1 Requirements

**Functional:**
- Accept a long URL → return a short one (≤ 8 characters)
- Redirect from a short URL to the original
- Click analytics: by time, geo, referrer, device
- Custom alias (optional)
- TTL / expiration (optional)

**Non-functional:**
- Availability: 99.99% (≤ 52 min/year downtime)
- Latency redirect: P99 < 10 ms (with cache)
- Latency shorten: P99 < 100 ms
- Durability: no data loss
- Scale: 100M new URLs/month, read/write = 10:1

### 1.2 Estimation

```
Write QPS:
  100M URLs / month = 100_000_000 / (30 * 86400) ≈ 40 RPS

Read QPS (redirect):
  40 * 10 = 400 RPS  (peak × 5 = 2000 RPS)

Storage (5 years):
  100M * 12 * 5 = 6 billion records
  One record: ~500 bytes (URL up to 2KB + metadata)
  Total: 6B * 500B ≈ 3 TB

Analytics events:
  400 RPS * 86400 * 365 * 5 = ~63 billion events
  Event: ~200 bytes → ~12 TB (columnar: ~3 TB after compression)

Bandwidth:
  Write: 40 RPS * 2KB = 80 KB/s
  Read:  400 RPS * 100B (redirect) = 40 KB/s — minimal, everything in cache
```

### 1.3 API

```
POST /api/v1/shorten
Body:  { "url": "https://...", "alias": "my-link", "ttl_days": 30 }
Resp:  { "short_code": "aB3kR9", "short_url": "https://sho.rt/aB3kR9", "expires_at": "..." }

GET /{shortCode}
Resp:  HTTP 301/302 Location: <originalUrl>
       (301 = permanent, browser caches; 302 = temporary, every request goes through the service)

GET /api/v1/analytics/{shortCode}?from=2026-01-01&to=2026-03-01
Resp:  { "clicks": 4821, "by_country": {...}, "by_device": {...} }

DELETE /api/v1/links/{shortCode}          (authorization required)
```

> **301 vs 302:** 301 reduces load (browser caches), but breaks analytics. Bitly uses 302.

### 1.4 High-Level Design

```
                          ┌──────────────────────────────────────────────────┐
                          │                  Client                          │
                          └───────────────────┬──────────────────────────────┘
                                              │
                                    ┌─────────▼─────────┐
                                    │   API Gateway /    │
                                    │   Load Balancer    │
                                    └──────┬──────┬──────┘
                                           │      │
                          ┌────────────────▼──┐ ┌─▼────────────────────┐
                          │  Shorten Service  │ │  Redirect Service    │
                          │  (POST /shorten)  │ │  (GET /{shortCode})  │
                          └────────┬──────────┘ └──────────┬───────────┘
                                   │                        │
                          ┌────────▼──────────┐   ┌────────▼───────────┐
                          │  ID Generator     │   │  Redis Cache       │
                          │  (Counter/Hash)   │   │  shortCode→URL     │
                          └────────┬──────────┘   └────────┬───────────┘
                                   │                        │ miss
                          ┌────────▼────────────────────────▼───────────┐
                          │              PostgreSQL / Cassandra           │
                          │           short_code → original_url          │
                          └────────────────────────────────┬─────────────┘
                                                           │
                                                  ┌────────▼──────────┐
                                                  │  Kafka (clicks)   │
                                                  └────────┬──────────┘
                                                           │
                                                  ┌────────▼──────────┐
                                                  │  ClickHouse       │
                                                  │  (Analytics)      │
                                                  └───────────────────┘
```

### 1.5 Short Code Generation

**Option A: Counter-based + Base62**

A global counter (or distributed counter via Zookeeper/Redis), converted to Base62.

```go
const base62Chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

func toBase62(num uint64) string {
    if num == 0 {
        return string(base62Chars[0])
    }
    result := []byte{}
    for num > 0 {
        result = append([]byte{base62Chars[num%62]}, result...)
        num /= 62
    }
    return string(result)
}

// 62^6 = 56 billion unique codes of length 6
// 62^7 = 3.5 trillion — more than enough
```

**Problem:** single point of failure for the counter. Solution: **Range-based counter**.

```
┌─────────────────────────────────────────────────────────────┐
│  Counter Service (Zookeeper / distributed DB)               │
│                                                             │
│  Svc Instance A gets range [1_000_001 .. 2_000_000]        │
│  Svc Instance B gets range [2_000_001 .. 3_000_000]        │
│                                                             │
│  Each instance hands out IDs from its range locally        │
│  When exhausted — requests a new range                      │
└─────────────────────────────────────────────────────────────┘
```

**Option B: Hash-based**

```go
import (
    "crypto/md5"
    "encoding/hex"
)

func generateShortCode(longURL string) string {
    hash := md5.Sum([]byte(longURL))
    hex := hex.EncodeToString(hash[:])
    // take first 7 characters → convert to Base62
    return hex[:7] // simplified; in practice — Base62 encode of first 4 bytes
}
```

**Collisions in hash-based:** collision probability ≈ n²/2m, where m = 62^7 = 3.5T.
With 6B URLs: p ≈ (6×10⁹)² / (2 × 3.5×10¹²) ≈ 5×10⁶ collisions — unacceptable.
Solution: on collision, add salt (`url + timestamp + random`) and retry.

**Conclusion:** Counter-based is preferred — no collisions, predictable.

### 1.6 Caching

```
Pattern: Cache-Aside (Lazy Loading)

GET /{shortCode}:
  1. Check Redis: GET shortCode
  2. Hit  → return URL (95%+ of traffic)
  3. Miss → PostgreSQL → SET shortCode url EX 86400 → return URL

Eviction policy: allkeys-lru
Key TTL: 24 hours (hot URLs are refreshed constantly)

Cache size:
  Pareto principle: 20% of URLs generate 80% of traffic
  6B URLs * 20% * 500B ≈ 600 GB → 3-4 Redis nodes at 200 GB each
```

```go
func (s *RedirectService) Resolve(ctx context.Context, code string) (string, error) {
    // 1. Cache lookup
    url, err := s.redis.Get(ctx, "url:"+code).Result()
    if err == nil {
        return url, nil
    }

    // 2. DB fallback
    url, err = s.db.GetOriginalURL(ctx, code)
    if err != nil {
        return "", ErrNotFound
    }

    // 3. Populate cache
    s.redis.Set(ctx, "url:"+code, url, 24*time.Hour)
    return url, nil
}
```

### 1.7 Analytics: Async Pipeline

```
Redirect Service
      │
      │ (fire-and-forget, goroutine)
      ▼
Kafka topic: "click-events"
      │
      │  Consumer Group
      ▼
Flink / Kafka Streams
(enrichment: IP → geo, UA → device)
      │
      ▼
ClickHouse (columnar, ZSTD compression)
  clicks table: (short_code, ts, country, device, referrer)

Query example:
  SELECT country, count() FROM clicks
  WHERE short_code = 'aB3kR9'
    AND ts BETWEEN '2026-01-01' AND '2026-03-01'
  GROUP BY country
  ORDER BY count() DESC
```

### 1.8 Storage: When to Choose What

| Criterion | PostgreSQL | Cassandra |
|---|---|---|
| Data volume | < 1 TB | > 1 TB |
| Read pattern | By PK or index | By partition key |
| Consistency | Strong | Eventual (tunable) |
| Joins / transactions | Yes | No |
| Horizontal scale | More complex | Built-in |
| **For URL Shortener** | Up to 1-2B URLs | Beyond 2B URLs |

For most companies (up to 5-6B URLs over 5 years), PostgreSQL with sharding by `short_code % N` is sufficient. Cassandra is needed at global scale.

**Schema (PostgreSQL):**

```sql
CREATE TABLE urls (
    short_code  VARCHAR(8)   PRIMARY KEY,
    original    TEXT         NOT NULL,
    user_id     BIGINT,
    created_at  TIMESTAMPTZ  DEFAULT now(),
    expires_at  TIMESTAMPTZ,
    click_count BIGINT       DEFAULT 0
);

CREATE INDEX idx_urls_user ON urls(user_id);
CREATE INDEX idx_urls_expires ON urls(expires_at) WHERE expires_at IS NOT NULL;
```

### 1.9 Detailed Design

```
┌─────────┐  POST /shorten   ┌──────────────────┐
│ Client  │ ───────────────► │  API Gateway     │
│         │                  │  (rate limit,    │
│         │                  │   auth JWT)      │
└─────────┘                  └────────┬─────────┘
                                      │
                             ┌────────▼─────────────────────────────┐
                             │         Shorten Service               │
                             │                                       │
                             │  1. Validate URL (scheme, length)     │
                             │  2. Check duplicate (hash lookup)     │
                             │  3. Get next ID from Counter Svc      │
                             │  4. toBase62(id) → shortCode          │
                             │  5. Write to DB                       │
                             │  6. Cache shortCode → url             │
                             └────────┬─────────────────────────────┘
                                      │
              ┌───────────────────────┼───────────────────────┐
              │                       │                       │
    ┌─────────▼──────┐    ┌──────────▼────────┐   ┌─────────▼──────┐
    │ Counter Service│    │   PostgreSQL       │   │  Redis Cluster │
    │ (range-based)  │    │   (primary store)  │   │  (L1 cache)    │
    │ Zookeeper/etcd │    │   + read replicas  │   │  allkeys-lru   │
    └────────────────┘    └───────────────────┘   └────────────────┘

GET /{shortCode} flow:
  Client → CDN (miss) → Load Balancer → Redirect Service
    → Redis HIT  → HTTP 302, Location: original_url     (P99 < 5ms)
    → Redis MISS → PostgreSQL → cache populate → HTTP 302 (P99 < 30ms)
    → async → Kafka "click-events" → ClickHouse
```

### 1.10 Trade-offs

| Decision | Pros | Cons |
|---|---|---|
| 302 instead of 301 | Full click analytics | More load on the service |
| Counter vs Hash | No collisions, shorter | ID predictability (seq scan) |
| Redis Cache | P99 < 5ms for hot URLs | Stale data on update |
| Async analytics | Does not block redirect | At-least-once → deduplication needed |
| PostgreSQL vs Cassandra | Simpler, ACID | Scales horizontally less well |

---

## Case 2: Messenger (WhatsApp/Telegram)

### 2.1 Requirements

**Functional:**
- 1-to-1 chat and group chats (up to 1000 participants)
- User online/offline status
- Message history (indefinite)
- Push notifications for offline users
- Read receipts (✓✓)
- Media: photos, videos, files

**Non-functional:**
- 50M DAU, 40 messages/day/user
- Message delivery latency: < 100 ms (P99)
- Availability: 99.99%
- E2E encryption (simplified)
- History: store for 5 years

### 2.2 Estimation

```
Messaging QPS:
  50M users * 40 msg/day = 2B messages/day
  2B / 86400 ≈ 23_000 msg/sec  (peak ×3 = 70K msg/sec)

Storage (5 years):
  Message: ~200 bytes (text) + metadata ~100 bytes = 300 bytes
  2B * 300B * 365 * 5 = ~1.1 PB  (text only)
  Media: ~30% of messages contain media, avg 500KB
  2B * 0.3 * 500KB * 365 * 5 ≈ 548 PB  → object storage (S3)

WebSocket connections:
  50M DAU, avg 30% online simultaneously = 15M concurrent connections
  1 WS server: ~50K connections → 300 WS servers

Online presence updates:
  15M * heartbeat every 30s = 500K updates/sec → Redis
```

### 2.3 API

```
WebSocket (real-time):
  ws://chat.example.com/ws?token=<jwt>

  Client → Server frames:
    { "type": "message",    "to": "user_456", "content": "Hello", "id": "uuid" }
    { "type": "ack",        "message_id": "uuid" }
    { "type": "typing",     "chat_id": "chat_789" }
    { "type": "heartbeat" }

  Server → Client frames:
    { "type": "message",    "from": "user_123", "content": "Hello", "id": "uuid", "ts": 1710000000 }
    { "type": "delivered",  "message_id": "uuid" }
    { "type": "read",       "message_id": "uuid" }
    { "type": "presence",   "user_id": "user_123", "status": "online" }

REST (history, metadata):
  GET  /api/v1/chats/{chatId}/messages?before=<ts>&limit=50
  POST /api/v1/chats                          (create a group)
  PUT  /api/v1/chats/{chatId}/members         (add members)
  POST /api/v1/media/upload → presigned S3 URL
```

### 2.4 High-Level Design

```
                         ┌──────────┐
                         │  Client  │
                         └────┬─────┘
                              │ WebSocket / HTTPS
                    ┌─────────▼─────────────┐
                    │    API Gateway /       │
                    │    Load Balancer       │
                    │  (sticky sessions      │
                    │   by user_id hash)     │
                    └──┬──────────────────┬──┘
                       │                  │
            ┌──────────▼──────┐   ┌───────▼───────────┐
            │  WS Gateway     │   │  REST API         │
            │  (stateful)     │   │  (history, media) │
            │  15M conns      │   └───────┬───────────┘
            └──────┬──────────┘           │
                   │                      │
          ┌────────▼──────────────────────▼─────────────────┐
          │              Message Service                      │
          │   routing, fan-out, delivery, ack management     │
          └──┬─────────────────┬─────────────────────────────┘
             │                 │                    │
    ┌────────▼───────┐ ┌───────▼──────┐   ┌────────▼──────────┐
    │ Redis Cluster  │ │   Cassandra  │   │  Notification     │
    │ - online users │ │   (messages) │   │  Service          │
    │ - msg queues   │ │   (history)  │   │  (APNs / FCM)     │
    │ - pub/sub      │ └──────────────┘   └───────────────────┘
    └────────────────┘
```

### 2.5 Message Delivery Flow

**Scenario: User A (online) → User B (online)**

```
User A                WS Gateway A       Message Svc       WS Gateway B       User B
  │                        │                  │                  │               │
  │──send(msg, id=X)──────►│                  │                  │               │
  │                        │──store+route(X)──►│                  │               │
  │                        │                  │──fan-out(X)──────►│               │
  │                        │                  │                  │──deliver(X)──►│
  │                        │                  │◄─────ack(X)───────│               │
  │◄───delivered(X)────────│◄──delivered(X)───│                  │               │
  │                        │                  │                  │               │
  │                        │                  │                  │◄──read(X)─────│
  │◄───read(X)─────────────│◄──read(X)────────│                  │               │
```

**Scenario: User B (offline) → push notification**

```
Message Svc
    │
    ├── User B offline (Redis: presence key absent)
    │
    ├── Store message in Cassandra (status: pending)
    │
    └── → Notification Service
              │
              ├── FCM (Android)
              └── APNs (iOS)
                    │
                    └── User B opens app → WS connect
                              │
                              └── Pull pending messages (Cassandra)
                                        └── Send ack → mark delivered
```

### 2.6 Message Storage (Cassandra)

```sql
-- Partitioned by chat_id (even distribution)
-- Sorted by time within partition

CREATE TABLE messages (
    chat_id      UUID,
    bucket       INT,        -- UNIX_TIMESTAMP / 86400 (day-bucket)
    message_id   TIMEUUID,   -- built-in timestamp + uniqueness
    sender_id    UUID,
    content      TEXT,
    media_url    TEXT,
    msg_type     TINYINT,    -- 0=text, 1=image, 2=video, 3=file
    status       TINYINT,    -- 0=sent, 1=delivered, 2=read
    PRIMARY KEY ((chat_id, bucket), message_id)
) WITH CLUSTERING ORDER BY (message_id DESC)
  AND compaction = {'class': 'TimeWindowCompactionStrategy',
                    'compaction_window_size': '1',
                    'compaction_window_unit': 'DAYS'};
```

**Why bucket:**
- Without bucket, a single partition for an active chat grows indefinitely
- With bucket = one day → partition size is manageable
- When reading history: `WHERE chat_id = X AND bucket IN (today, yesterday, ...)`

### 2.7 Online Presence

```
Pattern: Heartbeat + Redis

Client → WS Gateway: heartbeat every 5 sec
WS Gateway:
  SETEX presence:{user_id} 15 "online"  // TTL = 3 heartbeats

Checking another user's status:
  GET presence:{user_id}  → nil = offline

Pub/Sub for presence change notifications:
  PUBLISH presence-channel '{"user_id": "123", "status": "online"}'
  Subscribers (WS Gateways) deliver presence events to corresponding clients
```

```go
func (h *HeartbeatHandler) Handle(ctx context.Context, userID string) {
    key := fmt.Sprintf("presence:%s", userID)
    h.redis.SetEX(ctx, key, "online", 15*time.Second)

    // Broadcast presence change if was offline
    wasOnline, _ := h.redis.Exists(ctx, key).Result()
    if wasOnline == 0 {
        h.pubsub.Publish(ctx, "presence", PresenceEvent{
            UserID: userID,
            Status: "online",
        })
    }
}
```

### 2.8 Push Notifications

```
Notification Service
    │
    ├── Priority queue (high/low priority)
    │
    ├── FCM Worker (Android)
    │     POST https://fcm.googleapis.com/v1/projects/{id}/messages:send
    │
    ├── APNs Worker (iOS)
    │     HTTP/2 + TLS to api.push.apple.com
    │
    └── Retry policy:
          exponential backoff: 1s, 2s, 4s, 8s, 16s
          max retries: 5
          dead letter queue after 5 failures
```

### 2.9 End-to-End Encryption (simplified)

```
Signal Protocol (simplified scheme):

1. Key generation (on client):
   - Identity Key Pair (long-term)
   - Signed Prekey (rotated weekly)
   - One-Time Prekeys (pool, single-use)

2. Publishing public keys to server (server stores them, never sees private keys)

3. Session init (X3DH - Extended Triple Diffie-Hellman):
   Sender retrieves Receiver's public keys from server
   Computes shared secret locally
   Server NEVER sees the shared secret

4. Double Ratchet: each message encrypted with a unique key
   Compromise of one key does not reveal others (forward secrecy)

5. Server stores: only encrypted blob + metadata
```

### 2.10 Group Chat: Fan-out Strategy

```
Fan-out on Write:
  On message send → write to each participant's inbox
  
  Pros: fast reads (each user reads their own inbox)
  Cons: N writes for N group members (1000 members → 1000 writes per message)

Fan-out on Read:
  Store one message, each user reads from shared location
  
  Pros: single write
  Cons: slower reads, harder to track read receipts

Hybrid approach (like Telegram):
  ┌───────────────────────────────────────────────┐
  │  Groups ≤ 100 members → Fan-out on Write      │
  │  Groups > 100 members → Fan-out on Read       │
  │                                               │
  │  In both cases: last_read_message_id          │
  │  stored separately per-user per-chat          │
  └───────────────────────────────────────────────┘
```

### 2.11 Trade-offs

| Decision | Rationale |
|---|---|
| WebSocket instead of long polling | 15M concurrent — polling would kill the server |
| Cassandra instead of PostgreSQL | Horizontal scale, time-series pattern |
| Fan-out on Write for small groups | Reads are faster, writes are infrequent and small |
| Fan-out on Read for large groups | 1000+ writes per message is unacceptable |
| Heartbeat TTL 15 sec | Balance: 5 sec tolerance + network delays |

---

## Case 3: News Feed (Twitter/Instagram)

### 3.1 Requirements

**Functional:**
- Post creation (text, photos, video)
- Subscription feed — posts from accounts the user follows
- Likes, comments, reposts
- Real-time feed updates (or near-real-time)
- Follow/unfollow
- Hashtag search

**Non-functional:**
- 300M MAU, 50M DAU
- Average user: 500 subscriptions
- Post creation: 5M/day (≈ 58 RPS, peak ×10 = 580 RPS)
- Feed reads: 300M DAU * 10 opens/day = 3B req/day ≈ 35K RPS (peak ×3 = 105K RPS)
- Feed latency: P99 < 200 ms
- Media: store indefinitely

### 3.2 Estimation

```
Post creation:
  5M posts/day * (avg 1KB text + metadata) = 5 GB/day text
  5M * 30% media * avg 2MB = 3 PB/day → S3 + CDN

Feed generation:
  35K read RPS — primary load
  500 subscriptions * 35K = 17.5M fan-out writes/sec with Write-based feed

Like events:
  300M DAU * 50 likes/day = 15B likes/day ≈ 170K like ops/sec (peak)
  Storage: counter per post in Redis + batch flush to DB

Storage (5 years):
  Posts:  5M/day * 365 * 5 * 1KB = ~9 TB
  Media:  ~5 PB (S3)
  Feed cache: Redis (pre-computed timelines)
```

### 3.3 Fan-out on Write vs Fan-out on Read

```
Fan-out on Write (Push model):
─────────────────────────────
User A (1M followers) publishes a post
→ Write post_id to each of 1M followers' feeds
→ 1M Redis LPUSH operations

Pros:
  + Feed reads are O(1) — simply read your own list
  + Low read latency

Cons:
  - Celebrity problem: 1M+ LPUSH on a single post
  - Huge write amplification
  - Storage: N followers * posts

Fan-out on Read (Pull model):
──────────────────────────────
When requesting the feed:
  Get list of followings
  Request latest posts from each
  Merge by timestamp

Pros:
  + No write amplification
  + Data always fresh

Cons:
  - Slow with 500 followings: 500 DB queries → merge
  - Not suitable for high read QPS

Hybrid approach (Twitter/Instagram):
──────────────────────────────────────
  Regular users (< 1M followers):
    → Fan-out on Write
    → post_id lands in pre-computed feed (Redis Sorted Set) of each follower

  Celebrities (> threshold, e.g., 500K followers):
    → Fan-out on Read
    → Posts stored only at celebrity's location
    → When requesting feed: merge pre-computed feed + celebrity posts
```

```
                    ┌─────────────────────────────────────────┐
                    │           User publishes a post          │
                    └─────────────────┬───────────────────────┘
                                      │
                           ┌──────────▼──────────┐
                           │  Fan-out Service     │
                           │  (async, workers)    │
                           └──────────┬───────────┘
                                      │
              ┌───────────────────────┼────────────────────────┐
              │ regular user          │                        │ celebrity
    ┌─────────▼──────────────┐       │              ┌─────────▼──────────────┐
    │ Redis Sorted Set        │       │              │ Post DB only           │
    │ feed:{follower_id}      │       │              │ No fan-out             │
    │ ZADD score=timestamp    │       │              │ Pull when reading feed │
    │ post_id                 │       │              └────────────────────────┘
    └─────────────────────────┘       │
                                      │
                             ┌────────▼───────────┐
                             │   Post DB          │
                             │   (Cassandra /     │
                             │    PostgreSQL)     │
                             └────────────────────┘
```

### 3.4 Timeline Service

```go
type FeedItem struct {
    PostID    string
    AuthorID  string
    Score     float64 // timestamp or rank score
    CreatedAt time.Time
}

func (s *TimelineService) GetFeed(ctx context.Context, userID string, limit int) ([]FeedItem, error) {
    // 1. Get pre-computed feed from Redis
    key := fmt.Sprintf("feed:%s", userID)
    results, err := s.redis.ZRevRangeWithScores(ctx, key, 0, int64(limit*2)).Result()
    if err != nil {
        return nil, err
    }

    // 2. Get celebrity IDs from followings
    celebrities, err := s.followSvc.GetCelebrityFollowings(ctx, userID)
    if err != nil {
        return nil, err
    }

    // 3. Pull celebrity posts
    var celPosts []FeedItem
    for _, celID := range celebrities {
        posts, _ := s.postDB.GetRecentPosts(ctx, celID, 20)
        celPosts = append(celPosts, posts...)
    }

    // 4. Merge + sort + deduplicate
    feed := mergeSortedFeeds(results, celPosts)
    return feed[:min(limit, len(feed))], nil
}
```

### 3.5 Ranking

```
Chronological feed (Twitter pre-2023):
  Score = unix_timestamp of post
  Simple, predictable
  Problem: user misses important posts

Algorithmic feed (Instagram, new Twitter):
  Score = f(recency, engagement, author_affinity, content_type)

  Example formula:
  score = (likes * 0.4 + comments * 0.3 + shares * 0.2 + views * 0.1)
          * recency_decay(age_hours)
          * affinity_boost(author_follower_relationship)

  recency_decay(h) = exp(-λ * h)  // λ ≈ 0.1 → half-life ~7 hours

  Implementation:
  - Offline: ML model (XGBoost / DNN) trained on engagement data
  - Online: scoring during feed assembly or pre-scored in Redis
```

### 3.6 Media Storage

```
Upload flow:
  Client → POST /api/v1/media/upload
        ← presigned S3 URL (expires in 5 min)
  Client → PUT <presigned URL> (directly to S3, bypassing backend)
        → S3 Event → Lambda/Worker
              → Resize images (thumbnail, medium, full)
              → Transcode video (HLS, multiple bitrates)
              → Invalidate CDN cache

CDN Architecture:
  ┌──────────┐     ┌──────────────────┐     ┌──────────┐
  │  Client  │────►│  CloudFront/CDN  │────►│  S3      │
  │          │     │  Edge (100+ PoP) │     │ (origin) │
  │          │◄────│  Cache: 7 days   │     │          │
  └──────────┘     └──────────────────┘     └──────────┘

URL structure:
  https://cdn.example.com/media/{hash}/{size}.jpg
  size: thumb_100, medium_600, original
```

### 3.7 High-Level Design

```
                        ┌──────────┐
                        │  Client  │
                        └────┬─────┘
                             │
                   ┌─────────▼─────────────────┐
                   │   API Gateway              │
                   │   (auth, rate limit, CDN)  │
                   └──┬──────────┬──────────────┘
                      │          │
          ┌───────────▼──┐  ┌────▼─────────────┐
          │ Post Service │  │ Timeline Service  │
          │ (create,like)│  │ (read feed)       │
          └───────┬──────┘  └────┬──────────────┘
                  │              │
     ┌────────────▼──┐   ┌───────▼──────────────────┐
     │  Post DB      │   │ Redis Cluster             │
     │  (Cassandra)  │   │ feed:{uid} Sorted Set     │
     │               │   │ post:{id} Hash (metadata) │
     └───────┬───────┘   │ like_count:{id} Counter   │
             │           └───────────────────────────┘
             │
    ┌────────▼───────────┐
    │  Fan-out Service   │
    │  (Kafka consumer,  │
    │   async workers)   │
    └────────────────────┘

Media path:
  Client → S3 (presigned upload) → Worker (resize/transcode) → CDN
```

### 3.8 Likes: High-Throughput Counter

```
Problem: 170K like ops/sec cannot be written directly to PostgreSQL

Solution: Redis Counter + Periodic Flush

INCR like_count:{post_id}           // O(1), atomic
SADD dirty_posts {post_id}          // mark as "dirty"

Background worker every 30 sec:
  SMEMBERS dirty_posts → batch update in PostgreSQL
  SREM dirty_posts {processed_ids}

Trade-off: up to 30 sec lag between Redis and DB
Loss on Redis crash: up to 30 sec of counter changes
Solution: Redis AOF + checkpoint
```

### 3.9 Trade-offs

| Decision | Rationale |
|---|---|
| Hybrid fan-out | Celebrity problem makes pure write inefficient |
| Pre-computed feed in Redis | 35K read RPS cannot be served by pull |
| CDN for media | P99 < 50ms for images only achievable at the edge |
| Redis counter for likes | 170K ops/sec — only possible in-memory |
| Async fan-out via Kafka | Absorbs spikes on popular post publish |

---

## Case 4: Distributed Rate Limiter

### 4.1 Requirements

- Global request limiting (not per-instance)
- Multi-region support
- Sub-millisecond overhead (< 1 ms added latency)
- Flexible rules: per-user, per-IP, per-API-key, per-endpoint
- Graceful degradation: if rate limiter is unavailable — fail open or fail closed (configurable)

**Non-functional:**
- 500K RPS through limiter
- 99.99% availability
- Consistency: small overshoot acceptable (eventual consistency)

### 4.2 Algorithms

```
Token Bucket:
─────────────
  capacity = 100 tokens
  refill_rate = 10 tokens/sec

  On request:
    tokens = min(capacity, tokens + elapsed * rate)
    if tokens >= 1:
      tokens -= 1
      allow
    else:
      deny

  Pros: allows burst (up to capacity), smooth limiting
  Cons: parameters need tuning per endpoint

Sliding Window Counter:
───────────────────────
  Split time into 1-sec slots
  Store count for current and previous slot
  
  rate = prev_count * (1 - elapsed/window) + curr_count

  Example: limit = 100 req/min
    curr_window (started 30 sec ago): 40 requests
    prev_window: 80 requests
    rate_estimate = 80 * 0.5 + 40 = 80 — under limit ✓

  Pros: more accurate than fixed window, prevents double-burst at boundaries
  Cons: approximate (not exact sliding window)

Fixed Window:
─────────────
  Simplest: counter per window (minute, hour)
  Problem: double-burst at window boundary (100 at end + 100 at start)
  Do not use in production without upgrading to sliding window
```

### 4.3 Redis Architecture

```
Redis Cluster (6 nodes: 3 master + 3 replica):

  ┌──────────────────────────────────────────────────────────────┐
  │                      Redis Cluster                           │
  │                                                              │
  │  Slot 0-5460      Slot 5461-10922    Slot 10923-16383       │
  │  ┌──────────┐     ┌──────────────┐   ┌──────────────────┐   │
  │  │ Master 1 │     │   Master 2   │   │    Master 3      │   │
  │  │ Replica 1│     │   Replica 2  │   │    Replica 3     │   │
  │  └──────────┘     └──────────────┘   └──────────────────┘   │
  └──────────────────────────────────────────────────────────────┘

Key structure:
  rl:{entity_type}:{entity_id}:{window}
  Example: rl:user:12345:1710000060
           rl:ip:1.2.3.4:1710000060
           rl:apikey:abc123:1710000060

Lua script for atomicity:
```

```lua
-- rate_limit.lua
local key = KEYS[1]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local now = tonumber(ARGV[3])

local count = redis.call('GET', key)
if count == false then
    count = 0
else
    count = tonumber(count)
end

if count >= limit then
    return {0, count, limit}  -- rejected
end

count = redis.call('INCR', key)
if count == 1 then
    redis.call('EXPIRE', key, window)
end

return {1, count, limit}  -- allowed
```

### 4.4 Full Go Implementation

```go
package ratelimiter

import (
    "context"
    "fmt"
    "time"

    "github.com/redis/go-redis/v9"
)

type RateLimiter struct {
    redis      redis.UniversalClient
    luaScript  *redis.Script
    failOpen   bool // true = allow if Redis down
}

var luaScript = redis.NewScript(`
local key = KEYS[1]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])

local count = redis.call('INCR', key)
if count == 1 then
    redis.call('EXPIRE', key, window)
end
if count > limit then
    return {0, count, limit}
end
return {1, count, limit}
`)

func NewRateLimiter(client redis.UniversalClient, failOpen bool) *RateLimiter {
    return &RateLimiter{
        redis:     client,
        luaScript: luaScript,
        failOpen:  failOpen,
    }
}

type Result struct {
    Allowed   bool
    Current   int64
    Limit     int64
    ResetAt   time.Time
}

func (r *RateLimiter) Allow(ctx context.Context, key string, limit int, window time.Duration) (*Result, error) {
    windowSec := int(window.Seconds())
    now := time.Now()
    // Window-aligned key: resets together with the window
    alignedNow := now.Unix() / int64(windowSec) * int64(windowSec)
    redisKey := fmt.Sprintf("rl:%s:%d", key, alignedNow)

    res, err := r.luaScript.Run(ctx, r.redis, []string{redisKey},
        limit, windowSec,
    ).Int64Slice()

    if err != nil {
        // Graceful degradation
        allowed := r.failOpen
        return &Result{Allowed: allowed, Current: 0, Limit: int64(limit)}, nil
    }

    resetAt := time.Unix(alignedNow+int64(windowSec), 0)
    return &Result{
        Allowed: res[0] == 1,
        Current: res[1],
        Limit:   res[2],
        ResetAt: resetAt,
    }, nil
}

// HTTP Middleware
func (r *RateLimiter) Middleware(limit int, window time.Duration) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
            // Composite key: IP + user_id + endpoint
            userID := req.Header.Get("X-User-ID")
            key := fmt.Sprintf("user:%s:endpoint:%s", userID, req.URL.Path)

            result, err := r.Allow(req.Context(), key, limit, window)
            if err != nil {
                http.Error(w, "rate limiter error", http.StatusInternalServerError)
                return
            }

            w.Header().Set("X-RateLimit-Limit", fmt.Sprintf("%d", result.Limit))
            w.Header().Set("X-RateLimit-Remaining", fmt.Sprintf("%d", result.Limit-result.Current))
            w.Header().Set("X-RateLimit-Reset", fmt.Sprintf("%d", result.ResetAt.Unix()))

            if !result.Allowed {
                w.Header().Set("Retry-After", fmt.Sprintf("%d", int(time.Until(result.ResetAt).Seconds())))
                http.Error(w, "rate limit exceeded", http.StatusTooManyRequests)
                return
            }

            next.ServeHTTP(w, req)
        })
    }
}
```

### 4.5 Multi-Region Sync

```
Problem: user makes requests to EU and US simultaneously
         Local Redis instances don't know about each other

Solution 1: Centralized Redis (one cluster for the whole world)
  Downside: cross-region latency (100-200ms) → overhead unacceptable

Solution 2: Local + Global sync (two levels)
  ┌────────────────────────────────────────────────────────────┐
  │                   Request Processing                        │
  │                                                            │
  │  1. Check LOCAL Redis (< 1ms)                              │
  │     local_count += 1                                       │
  │                                                            │
  │  2. Async: every 100ms sync with Global Redis              │
  │     global_count = INCRBY global_key local_delta           │
  │     If global_count > limit: activate global reject mode   │
  │                                                            │
  │  3. Soft limit: local = 80% of global limit                │
  │     Overshoot up to 20% is acceptable                      │
  └────────────────────────────────────────────────────────────┘

Solution 3: Approximate (Production-grade)
  Each region gets N/R tokens, where N=global limit, R=regions
  EU: 1000/3 ≈ 333 req/min
  US: 333 req/min
  AP: 333 req/min
  
  Rebalancing on imbalance: cron job every 5 min
```

### 4.6 Race Conditions

```
Problem without Lua:
  Goroutine 1: GET count=99  ← reads
  Goroutine 2: GET count=99  ← reads (before goroutine 1's SET)
  Goroutine 1: SET count=100 ← both allowed, even though limit is 100
  Goroutine 2: SET count=100 ← race condition!

Solution: Lua script executes atomically on Redis
  GET + INCR + EXPIRE = one transaction, no race condition

Alternative for token bucket: Redis transactions (MULTI/EXEC)
  WATCH tokens:{key}
  MULTI
    DECRBY tokens:{key} cost
    EXPIREAT tokens:{key} next_refill
  EXEC
  → if WATCH detected a change, EXEC returns nil → retry
```

### 4.7 Trade-offs

| Decision | Rationale |
|---|---|
| Lua script vs MULTI/EXEC | Lua is atomic and faster, no retry loop |
| Sliding window vs token bucket | Sliding window is more accurate for API rate limits |
| Fail open vs fail closed | Depends on API criticality; finance → fail closed |
| Local + Global sync | Balance between latency and accuracy in multi-region |

---

## Case 5: Notification Service

### 5.1 Requirements

**Functional:**
- Channels: email, SMS, push (iOS/Android), in-app notifications
- Priorities: critical (OTP, security), high (transactional), normal (marketing)
- Template engine: variables, localization
- Throttling: no more than X notifications/user/hour
- Retry on provider error
- Deduplication: one event does not trigger two notifications
- Tracking: delivered, opened, clicked
- Idempotency: repeat API call does not duplicate notification

**Non-functional:**
- 50M notifications/day ≈ 580 notif/sec (peak ×10 = 5800/sec)
- Critical: latency < 5 sec
- Marketing: latency < 30 min (batch)
- Availability: 99.9%

### 5.2 High-Level Design

```
                      ┌──────────────────────────────────────────┐
                      │           Notification API               │
                      │  POST /api/v1/notifications/send         │
                      │  (idempotency_key in header)             │
                      └──────────────────┬───────────────────────┘
                                         │
                      ┌──────────────────▼───────────────────────┐
                      │         Orchestration Service            │
                      │  - Deduplication check (Redis)           │
                      │  - User preferences lookup               │
                      │  - Throttle check                        │
                      │  - Template rendering                    │
                      │  - Route to correct queue                │
                      └──────┬────────────┬───────────┬──────────┘
                             │            │           │
              ┌──────────────▼──┐  ┌──────▼──────┐  ┌▼─────────────┐
              │ Priority Queue  │  │ High Queue  │  │ Normal Queue │
              │ (Kafka: high    │  │ (Kafka)     │  │ (Kafka)      │
              │  priority)      │  └──────┬──────┘  └─────┬────────┘
              └────────┬────────┘         │               │
                       │                  │               │
         ┌─────────────┼──────────────────┼───────────────┤
         │             │                  │               │
  ┌──────▼──────┐ ┌────▼──────┐ ┌────────▼──┐  ┌────────▼──────┐
  │ SMS Worker  │ │Email Worker│ │Push Worker│  │ In-App Worker │
  │ (Twilio/   │ │(SendGrid/ │ │(FCM/APNs) │  │               │
  │  AWS SNS)  │ │ SES)      │ │           │  │               │
  └──────┬──────┘ └────┬──────┘ └────────┬──┘  └────────┬──────┘
         │             │                 │               │
         └─────────────┴─────────────────┴───────────────┘
                                   │
                      ┌────────────▼───────────────┐
                      │       Status DB             │
                      │  (PostgreSQL: delivery      │
                      │   status, tracking)         │
                      └────────────────────────────┘
```

### 5.3 API

```
POST /api/v1/notifications/send
Headers:
  Idempotency-Key: <uuid>  (client-generated)
  Authorization: Bearer <token>

Body:
{
  "recipient": {
    "user_id": "user_12345",
    "channels": ["push", "email"],    // or ["auto"] — choose by user settings
    "email": "user@example.com",      // override from user profile
    "device_tokens": ["fcm:...", "apns:..."]
  },
  "notification": {
    "type": "order_shipped",
    "priority": "high",
    "template_id": "order_shipped_v2",
    "template_vars": {
      "order_id": "ORD-9876",
      "tracking_url": "https://..."
    }
  }
}

Response:
{
  "notification_id": "ntf_abc123",
  "status": "queued",
  "channels": {
    "push": "queued",
    "email": "queued"
  }
}

GET /api/v1/notifications/{notification_id}/status
Response:
{
  "notification_id": "ntf_abc123",
  "channels": {
    "push": { "status": "delivered", "delivered_at": "2026-03-23T10:00:00Z" },
    "email": { "status": "opened",   "opened_at": "2026-03-23T10:05:00Z" }
  }
}
```

### 5.4 Template Engine

```go
type Template struct {
    ID       string
    Channel  string // "email", "sms", "push"
    Lang     string // "en", "ru", "de"
    Subject  string // for email
    Body     string // text with {{variables}}
}

type TemplateEngine struct {
    store TemplateStore
    cache *sync.Map // template_id:lang → *template.Template
}

func (e *TemplateEngine) Render(templateID, lang string, vars map[string]string) (*RenderedNotification, error) {
    cacheKey := fmt.Sprintf("%s:%s", templateID, lang)

    // Cache lookup
    if cached, ok := e.cache.Load(cacheKey); ok {
        return e.execute(cached.(*template.Template), vars)
    }

    // Load from store
    tmpl, err := e.store.Get(templateID, lang)
    if err != nil {
        // Fallback to default language
        tmpl, err = e.store.Get(templateID, "en")
        if err != nil {
            return nil, fmt.Errorf("template not found: %s", templateID)
        }
    }

    // Parse and cache
    parsed, err := template.New(cacheKey).
        Funcs(template.FuncMap{
            "upper": strings.ToUpper,
            "date":  formatDate,
        }).
        Parse(tmpl.Body)
    if err != nil {
        return nil, err
    }
    e.cache.Store(cacheKey, parsed)

    return e.execute(parsed, vars)
}

func (e *TemplateEngine) execute(t *template.Template, vars map[string]string) (*RenderedNotification, error) {
    var buf bytes.Buffer
    if err := t.Execute(&buf, vars); err != nil {
        return nil, err
    }
    return &RenderedNotification{Body: buf.String()}, nil
}
```

### 5.5 Deduplication

```
Problem: an event may arrive twice (upstream retry, at-least-once delivery)

Solution: Idempotency Key in Redis

On receiving a request:
  key = "dedup:" + idempotency_key
  result = SET key "processing" NX EX 86400  // NX = set only if not exists

  If result == nil → already being processed or completed → return cached response
  If result == "OK"  → first time → process it

After processing:
  SET key {notification_id} EX 86400  // store result for repeated requests
```

```go
func (s *NotificationService) Send(ctx context.Context, req *SendRequest) (*SendResponse, error) {
    idempotencyKey := req.IdempotencyKey
    if idempotencyKey == "" {
        idempotencyKey = uuid.New().String() // generate if missing
    }

    dedupKey := "dedup:" + idempotencyKey

    // Try to acquire dedup lock
    ok, err := s.redis.SetNX(ctx, dedupKey, "processing", 24*time.Hour).Result()
    if err != nil {
        return nil, err
    }

    if !ok {
        // Already processed or in progress — return cached result
        cached, err := s.redis.Get(ctx, dedupKey).Result()
        if err != nil || cached == "processing" {
            return nil, ErrDuplicateRequest
        }
        return &SendResponse{NotificationID: cached, Status: "already_sent"}, nil
    }

    // Process notification
    notifID, err := s.process(ctx, req)
    if err != nil {
        s.redis.Del(ctx, dedupKey) // Release lock on failure
        return nil, err
    }

    // Store result for future idempotent requests
    s.redis.Set(ctx, dedupKey, notifID, 24*time.Hour)
    return &SendResponse{NotificationID: notifID, Status: "queued"}, nil
}
```

### 5.6 Rate Limiting per User (Throttling)

```
Goal: user does not receive > 10 notifications/hour from one service

Implementation: Sliding Window Counter in Redis

func (s *ThrottleChecker) IsAllowed(ctx context.Context, userID, notifType string) (bool, error) {
    key := fmt.Sprintf("throttle:%s:%s:%d", userID, notifType, time.Now().Unix()/3600)
    count, err := s.redis.Incr(ctx, key).Result()
    if count == 1 {
        s.redis.Expire(ctx, key, 2*time.Hour) // span 2 hours for sliding
    }
    if count > s.limits[notifType] {
        return false, nil  // throttled
    }
    return true, nil
}

Example limits:
  marketing:    2/hour,  10/day
  transactional: 20/hour, 100/day
  critical:     unlimited (OTP, security alerts)
```

### 5.7 Retry Policy

```go
type RetryConfig struct {
    MaxAttempts     int
    InitialInterval time.Duration
    Multiplier      float64
    MaxInterval     time.Duration
}

var defaultRetry = RetryConfig{
    MaxAttempts:     5,
    InitialInterval: 1 * time.Second,
    Multiplier:      2.0,
    MaxInterval:     30 * time.Second,
}

// Intervals: 1s, 2s, 4s, 8s, 16s → then Dead Letter Queue

func (w *EmailWorker) processWithRetry(ctx context.Context, msg *Notification) {
    backoff := w.retryConfig.InitialInterval
    for attempt := 1; attempt <= w.retryConfig.MaxAttempts; attempt++ {
        err := w.sendEmail(ctx, msg)
        if err == nil {
            w.markDelivered(msg.ID)
            return
        }

        // Permanent errors — do not retry
        if isPermanentError(err) { // e.g., invalid email address
            w.markFailed(msg.ID, "permanent_error: "+err.Error())
            return
        }

        // Transient errors — retry with backoff
        if attempt < w.retryConfig.MaxAttempts {
            time.Sleep(backoff)
            backoff = time.Duration(float64(backoff) * w.retryConfig.Multiplier)
            if backoff > w.retryConfig.MaxInterval {
                backoff = w.retryConfig.MaxInterval
            }
        }
    }

    // All attempts exhausted → Dead Letter Queue
    w.dlq.Publish(ctx, msg)
    w.markFailed(msg.ID, "max_retries_exceeded")
}
```

### 5.8 Delivery Tracking

```sql
CREATE TABLE notification_events (
    notification_id  UUID         NOT NULL,
    channel          VARCHAR(20)  NOT NULL,  -- email, sms, push
    event_type       VARCHAR(20)  NOT NULL,  -- queued, sent, delivered, opened, clicked, failed
    occurred_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    metadata         JSONB,                  -- {provider_id, error_code, device, ...}
    PRIMARY KEY (notification_id, channel, event_type, occurred_at)
);

-- Webhook from providers (SendGrid, Twilio) records events:
POST /webhooks/sendgrid
  → parse payload → INSERT INTO notification_events

-- Open tracking for email: pixel tracking
<img src="https://track.example.com/open/{notif_id}/{email_hash}" width="1" height="1">
GET /open/{notif_id}/{email_hash}  → INSERT event_type='opened' → 1x1 pixel response
```

### 5.9 Trade-offs

| Decision | Rationale |
|---|---|
| Kafka queues by priority | Critical notifications don't wait behind marketing bulk |
| Idempotency key in Redis for 24h | Storing longer is costly; 24h covers the retry window |
| Drop on throttle for marketing | Better to lose marketing than to spam |
| Webhook vs polling for status | Providers notify us; we don't spend RPS polling |
| DLQ for failed | Manual review + alert; OTP messages cannot be lost |

---

## Case 6: Distributed Task Scheduler (Cron)

### 6.1 Requirements

**Functional:**
- Run tasks on a cron schedule (standard cron syntax)
- At-least-once execution (task runs at minimum once)
- Exactly-once semantics via idempotent tasks
- Distributed: no SPOF
- Monitoring: last_run, next_run, success/failure status
- Support for millions of tasks

**Non-functional:**
- Trigger accuracy: ± 1 second
- Availability: 99.99%
- Scale: 10M tasks, 100K triggers/min (peak)

### 6.2 High-Level Design

```
                   ┌───────────────────────────────────────────────┐
                   │              Scheduler Cluster                 │
                   │                                               │
                   │  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
                   │  │ Sched-1  │  │ Sched-2  │  │ Sched-3  │   │
                   │  │(owner P1)│  │(owner P2)│  │(owner P3)│   │
                   │  └────┬─────┘  └────┬─────┘  └────┬─────┘   │
                   │       │             │              │          │
                   │       └─────────────┴──────────────┘          │
                   │                    │                          │
                   │           ┌────────▼────────┐                 │
                   │           │  etcd / Consul  │                 │
                   │           │ (leader election│                 │
                   │           │  partition map) │                 │
                   └───────────┴────────┬────────┴─────────────────┘
                                        │
                              ┌─────────▼──────────┐
                              │   Task Queue        │
                              │   (Kafka / Redis    │
                              │    Streams)         │
                              └─────────┬───────────┘
                                        │
                 ┌──────────────────────┼───────────────────────┐
                 │                      │                        │
          ┌──────▼──────┐       ┌───────▼──────┐        ┌───────▼──────┐
          │  Worker 1   │       │  Worker 2    │        │  Worker 3    │
          │  (executor) │       │  (executor)  │        │  (executor)  │
          └──────┬──────┘       └───────┬──────┘        └───────┬──────┘
                 │                      │                        │
                 └──────────────────────┴────────────────────────┘
                                        │
                              ┌─────────▼──────────────────┐
                              │        Task DB              │
                              │  (PostgreSQL / CockroachDB) │
                              │  tasks, schedules, runs     │
                              └────────────────────────────┘
```

### 6.3 Data Model

```sql
CREATE TABLE tasks (
    id            UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    name          VARCHAR(255) NOT NULL,
    cron_expr     VARCHAR(100) NOT NULL,     -- "0 */6 * * *"
    handler_type  VARCHAR(100) NOT NULL,     -- "http", "grpc", "lambda"
    handler_config JSONB       NOT NULL,     -- {"url": "...", "method": "POST"}
    partition_id  INT          NOT NULL,     -- for distribution among schedulers
    next_run_at   TIMESTAMPTZ NOT NULL,
    last_run_at   TIMESTAMPTZ,
    status        VARCHAR(20)  NOT NULL DEFAULT 'active',  -- active, paused, deleted
    max_retries   INT          DEFAULT 3,
    timeout_sec   INT          DEFAULT 300,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_tasks_next_run ON tasks(partition_id, next_run_at)
    WHERE status = 'active';

CREATE TABLE task_runs (
    id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id     UUID         NOT NULL REFERENCES tasks(id),
    triggered_at TIMESTAMPTZ NOT NULL,
    started_at  TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    status      VARCHAR(20)  NOT NULL DEFAULT 'pending',  -- pending, running, success, failed
    attempt     INT          NOT NULL DEFAULT 1,
    error       TEXT,
    worker_id   VARCHAR(100)
);

CREATE INDEX idx_runs_task_id ON task_runs(task_id, triggered_at DESC);
```

### 6.4 Partition-based Scheduling

```
Problem: 10M tasks cannot be polled by a single scheduler every second

Solution: partition tasks among scheduler instances

  task.partition_id = hash(task.id) % NUM_PARTITIONS

  Each scheduler owns its partitions:
  ┌─────────────────────────────────────────────┐
  │  etcd key: /scheduler/partitions            │
  │  Value: {                                   │
  │    "0-99":   "scheduler-host-1",            │
  │    "100-199": "scheduler-host-2",           │
  │    "200-299": "scheduler-host-3"            │
  │  }                                          │
  └─────────────────────────────────────────────┘

  Scheduler-1 every second:
    SELECT * FROM tasks
    WHERE partition_id BETWEEN 0 AND 99
      AND next_run_at <= NOW()
      AND status = 'active'
    FOR UPDATE SKIP LOCKED;  -- key: does not block others
```

```go
type Scheduler struct {
    db         *sql.DB
    queue      Queue
    partitions []int  // owned partitions
    stopCh     chan struct{}
}

func (s *Scheduler) Run(ctx context.Context) {
    ticker := time.NewTicker(1 * time.Second)
    defer ticker.Stop()

    for {
        select {
        case <-ticker.C:
            s.triggerDueTasks(ctx)
        case <-ctx.Done():
            return
        }
    }
}

func (s *Scheduler) triggerDueTasks(ctx context.Context) {
    tx, _ := s.db.BeginTx(ctx, nil)
    defer tx.Rollback()

    placeholders := make([]string, len(s.partitions))
    args := []interface{}{time.Now()}
    for i, p := range s.partitions {
        placeholders[i] = fmt.Sprintf("$%d", i+2)
        args = append(args, p)
    }

    query := fmt.Sprintf(`
        SELECT id, cron_expr, handler_type, handler_config, max_retries, timeout_sec
        FROM tasks
        WHERE next_run_at <= $1
          AND partition_id IN (%s)
          AND status = 'active'
        FOR UPDATE SKIP LOCKED
        LIMIT 1000
    `, strings.Join(placeholders, ","))

    rows, err := tx.QueryContext(ctx, query, args...)
    if err != nil {
        return
    }
    defer rows.Close()

    var toUpdate []TaskUpdate
    for rows.Next() {
        var task Task
        rows.Scan(&task.ID, &task.CronExpr, &task.HandlerType, &task.HandlerConfig,
            &task.MaxRetries, &task.TimeoutSec)

        // Publish to worker queue
        s.queue.Publish(ctx, &TaskMessage{
            TaskID:      task.ID,
            HandlerType: task.HandlerType,
            HandlerConfig: task.HandlerConfig,
            MaxRetries:  task.MaxRetries,
            TimeoutSec:  task.TimeoutSec,
        })

        // Calculate next run
        nextRun := calculateNextRun(task.CronExpr)
        toUpdate = append(toUpdate, TaskUpdate{ID: task.ID, NextRun: nextRun})
    }

    // Batch update next_run_at
    for _, u := range toUpdate {
        tx.ExecContext(ctx, `
            UPDATE tasks SET next_run_at = $1, last_run_at = NOW()
            WHERE id = $2
        `, u.NextRun, u.ID)
    }

    tx.Commit()
}
```

### 6.5 Leader Election via etcd

```go
import "go.etcd.io/etcd/client/v3/concurrency"

func (s *Scheduler) ElectLeader(ctx context.Context, etcdClient *clientv3.Client) {
    session, _ := concurrency.NewSession(etcdClient, concurrency.WithTTL(10))
    defer session.Close()

    election := concurrency.NewElection(session, "/scheduler/leader")

    for {
        // Blocking call: wait until we become the leader
        if err := election.Campaign(ctx, s.nodeID); err != nil {
            continue
        }

        log.Println("Became leader, acquiring partitions...")
        s.acquirePartitions(ctx, etcdClient)
        s.Run(ctx)

        // If context cancelled or leadership lost
        election.Resign(ctx)
    }
}

// Partition assignment: leader distributes partitions among all schedulers
func (s *Scheduler) acquirePartitions(ctx context.Context, client *clientv3.Client) {
    // Get list of live scheduler nodes
    resp, _ := client.Get(ctx, "/scheduler/nodes/", clientv3.WithPrefix())
    nodes := parseNodes(resp)

    // Distribute partitions evenly
    partitionMap := distributePartitions(300, nodes)  // 300 partitions

    // Write to etcd
    data, _ := json.Marshal(partitionMap)
    client.Put(ctx, "/scheduler/partitions", string(data))
}
```

### 6.6 Missed Schedules: Catch-up

```
Problem: scheduler was down from 02:00 to 04:00
  Task with schedule "0 * * * *" should have run at 02:00, 03:00, 04:00
  On restart: next_run_at = 02:00 (in the past)

Strategies:

1. Skip missed: recalculate next_run from NOW()
   Simplest approach: some tasks need to run strictly on schedule

2. Run once: execute once when a missed trigger is detected
   For tasks where completion matters (e.g., daily report)

3. Run all missed: execute every missed trigger
   For financial tasks (e.g., billing per hour)

Implementation of skip+run-once (most common requirement):
```

```go
func handleMissedSchedule(task *Task, now time.Time) (runNow bool, nextRun time.Time) {
    if task.NextRunAt.Before(now) {
        switch task.MissedPolicy {
        case "skip":
            // Recalculate from NOW(), do not run
            return false, calculateNextRun(task.CronExpr, now)
        case "run_once":
            // Run once, then recalculate from NOW()
            return true, calculateNextRun(task.CronExpr, now)
        case "run_all":
            // Run all missed triggers (be careful with bursts!)
            return true, calculateNextRun(task.CronExpr, task.NextRunAt)
        }
    }
    return false, task.NextRunAt
}
```

### 6.7 Task Idempotency

```
At-least-once means: a task MAY run twice

Causes:
  - Worker received task, executed it, but failed to ack before timeout
  - Scheduler decided task didn't complete → retry
  - Network partition

Solution: idempotent tasks

Pattern 1: Natural idempotency
  "Recalculate aggregates for yesterday" — result is the same on re-run
  "Update order status if PENDING" — UPDATE WHERE status = 'PENDING'

Pattern 2: Execution lock
  When a worker starts, it writes to task_runs:
    INSERT INTO task_runs (task_id, triggered_at, status)
    VALUES ($1, $2, 'running')
    ON CONFLICT (task_id, triggered_at) DO NOTHING
  
  If INSERT returns 0 rows → someone already running it → exit

  Uniqueness key: (task_id, triggered_at)
  Two runs of the same task at the same moment → conflict → one wins

Pattern 3: Idempotency key in HTTP requests of the task
  Worker adds a header:
    Idempotency-Key: {task_id}:{triggered_at_unix}
  
  The target service deduplicates by this key
```

```go
type Worker struct {
    db    *sql.DB
    queue Queue
}

func (w *Worker) Execute(ctx context.Context, msg *TaskMessage) error {
    // 1. Try to claim this execution (idempotency)
    _, err := w.db.ExecContext(ctx, `
        INSERT INTO task_runs (id, task_id, triggered_at, status, worker_id)
        VALUES ($1, $2, $3, 'running', $4)
        ON CONFLICT (task_id, triggered_at) DO NOTHING
    `, uuid.New(), msg.TaskID, msg.TriggeredAt, w.nodeID)

    rowsAffected := getRowsAffected(err)
    if rowsAffected == 0 {
        // Another worker already claimed this — skip
        return nil
    }

    runID := msg.RunID
    timeout := time.Duration(msg.TimeoutSec) * time.Second
    execCtx, cancel := context.WithTimeout(ctx, timeout)
    defer cancel()

    // 2. Execute the actual task
    execErr := w.dispatch(execCtx, msg)

    // 3. Update status
    status := "success"
    errMsg := ""
    if execErr != nil {
        status = "failed"
        errMsg = execErr.Error()
    }

    w.db.ExecContext(ctx, `
        UPDATE task_runs
        SET status = $1, finished_at = NOW(), error = $2
        WHERE id = $3
    `, status, errMsg, runID)

    return execErr
}
```

### 6.8 Monitoring and Alerts

```
Metrics (Prometheus):

  task_triggers_total{status="success|failed"} — counter
  task_execution_duration_seconds{handler_type} — histogram
  task_queue_depth{partition} — gauge
  task_missed_schedules_total — missed trigger counter

Alerts:

  # Task has not run for more than 2x its interval
  ALERT TaskMissed
    IF (time() - task_last_success_timestamp) > (2 * task_interval_seconds)
    FOR 5m
    LABELS {severity="warning"}

  # Worker queue is growing
  ALERT WorkerQueueBacklog
    IF task_queue_depth > 10000
    FOR 2m
    LABELS {severity="critical"}

Dashboard (Grafana):
  - Timeline: trigger rate, success rate, failure rate
  - P99 execution latency by handler type
  - Heatmap: tasks by time of day (load patterns)
  - Top-10 tasks by execution time
```

### 6.9 Trade-offs

| Decision | Rationale |
|---|---|
| Partition-based vs single leader | Single leader = SPOF + bottleneck at 10M tasks |
| `FOR UPDATE SKIP LOCKED` | Avoids lock contention between scheduler instances |
| At-least-once + idempotency | Exactly-once in distributed systems is too expensive |
| etcd for leader election | Raft consensus, battle-tested, TTL on leases |
| Miss policy is configurable | Different tasks have different missed-trigger semantics |
| PostgreSQL vs specialized (Temporal) | PostgreSQL is sufficient up to 10M tasks; Temporal for complex workflows |

---

## Final Summary: Patterns and Principles

### Patterns Found Across All Cases

| Pattern | Cases | Essence |
|---|---|---|
| Cache-Aside | URL Shortener, Messenger | Read cache, on miss — DB, then populate cache |
| Fan-out | Messenger, News Feed | Delivering data to N recipients |
| Async via Kafka | URL Shortener, Notification | Decouple write from processing |
| Idempotency Key | Notification, Task Scheduler | Repeated call = same result |
| Lua script for atomicity | Rate Limiter | Multiple Redis operations without race condition |
| Partition-based ownership | Task Scheduler, Messenger | Split data among instances |
| Dead Letter Queue | Notification, Task Scheduler | Don't lose data after exhausting retries |
| Heartbeat + TTL | Messenger, Task Scheduler | Failure detection via lease expiry |

### When to Choose What: Storage

| Storage | Use when |
|---|---|
| PostgreSQL | Complex queries, transactions, volume < 5 TB |
| Cassandra | Time-series, high write QPS, horizontal scale |
| Redis | Cache, counters, pub/sub, short-lived data |
| ClickHouse | Analytics, OLAP, columnar scans |
| S3 + CDN | Media files, static assets, objects > 1 MB |
| etcd | Configuration, leader election, distributed locks |

### System Design Interview Checklist

```
1. Requirements (5 min)
   □ Functional: what the system does
   □ Non-functional: scale, latency, availability, consistency

2. Estimation (3-5 min)
   □ QPS (read and write separately)
   □ Storage (data size * TTL)
   □ Bandwidth
   □ Connections (if real-time)

3. API Design (5 min)
   □ Endpoints, methods, parameters
   □ Protocol: REST / WebSocket / gRPC

4. High-Level Design (10 min)
   □ ASCII diagram with core components
   □ Flows for primary operations

5. Deep Dive (15-20 min)
   □ Hard problem #1 (usually scale or consistency)
   □ Hard problem #2 (failure handling or performance)
   □ Trade-offs, stated aloud

6. Trade-offs and Alternatives (5 min)
   □ What you'd do differently at a different scale
   □ What you sacrifice and what you gain
```

---

*Module 12 concludes the course. All six cases cover typical System Design interview problems at FAANG/MANGA-level companies. The key to success is not memorizing the solutions, but understanding why each decision was made the way it was.*
