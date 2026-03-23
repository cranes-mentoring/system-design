# Модуль 12: Практические кейсы

Финальный модуль — шесть полных кейсов по System Design. Каждый проходит по фреймворку из модуля 01:
**Requirements → Estimation → Storage → HLD → API → Detailed Design → Trade-offs**.

Цель: не просто прочитать, а прорешать самостоятельно перед чтением решения.

---

## Содержание

1. [Кейс 1: URL Shortener (Bitly)](#кейс-1-url-shortener-bitly)
2. [Кейс 2: Мессенджер (WhatsApp/Telegram)](#кейс-2-мессенджер-whatsapptelegram)
3. [Кейс 3: News Feed (Twitter/Instagram)](#кейс-3-news-feed-twitterinstagram)
4. [Кейс 4: Distributed Rate Limiter](#кейс-4-distributed-rate-limiter)
5. [Кейс 5: Notification Service](#кейс-5-notification-service)
6. [Кейс 6: Distributed Task Scheduler (Cron)](#кейс-6-distributed-task-scheduler-cron)

---

## Кейс 1: URL Shortener (Bitly)

### 1.1 Requirements

**Functional:**
- Принять длинный URL → вернуть короткий (≤ 8 символов)
- Перенаправить по короткому URL на оригинальный
- Аналитика кликов: по времени, гео, referrer, device
- Custom alias (опционально)
- TTL / expiration (опционально)

**Non-functional:**
- Availability: 99.99% (≤ 52 мин/год простоя)
- Latency redirect: P99 < 10 ms (с кешем)
- Latency shorten: P99 < 100 ms
- Durability: данные не теряются
- Масштаб: 100M новых URLs/месяц, read/write = 10:1

### 1.2 Estimation

```
Write QPS:
  100M URLs / месяц = 100_000_000 / (30 * 86400) ≈ 40 RPS

Read QPS (redirect):
  40 * 10 = 400 RPS  (peak × 5 = 2000 RPS)

Storage (5 лет):
  100M * 12 * 5 = 6 млрд записей
  Одна запись: ~500 байт (URL до 2KB + метаданные)
  Итого: 6B * 500B ≈ 3 TB

Analytics events:
  400 RPS * 86400 * 365 * 5 = ~63 млрд событий
  Event: ~200 байт → ~12 TB (Columnar: ~3 TB после сжатия)

Bandwidth:
  Write: 40 RPS * 2KB = 80 KB/s
  Read:  400 RPS * 100B (redirect) = 40 KB/s — минимально, всё в кеше
```

### 1.3 API

```
POST /api/v1/shorten
Body:  { "url": "https://...", "alias": "my-link", "ttl_days": 30 }
Resp:  { "short_code": "aB3kR9", "short_url": "https://sho.rt/aB3kR9", "expires_at": "..." }

GET /{shortCode}
Resp:  HTTP 301/302 Location: <originalUrl>
       (301 = permanent, браузер кеширует; 302 = temporary, каждый раз через сервис)

GET /api/v1/analytics/{shortCode}?from=2026-01-01&to=2026-03-01
Resp:  { "clicks": 4821, "by_country": {...}, "by_device": {...} }

DELETE /api/v1/links/{shortCode}          (авторизация обязательна)
```

> **301 vs 302:** 301 снижает нагрузку (браузер кеширует), но ломает аналитику. Bitly использует 302.

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

### 1.5 Генерация short code

**Вариант A: Counter-based + Base62**

Глобальный счётчик (или distributed counter через Zookeeper/Redis), конвертируем в Base62.

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

// 62^6 = 56 млрд уникальных кодов длиной 6 символов
// 62^7 = 3.5 трлн — более чем достаточно
```

**Проблема:** единая точка отказа счётчика. Решение: **Range-based counter**.

```
┌─────────────────────────────────────────────────────────────┐
│  Counter Service (Zookeeper / distributed DB)               │
│                                                             │
│  Svc Instance A получает range [1_000_001 .. 2_000_000]     │
│  Svc Instance B получает range [2_000_001 .. 3_000_000]     │
│                                                             │
│  Каждый инстанс раздаёт ID из своего range локально         │
│  При исчерпании — запрашивает новый range                   │
└─────────────────────────────────────────────────────────────┘
```

**Вариант B: Hash-based**

```go
import (
    "crypto/md5"
    "encoding/hex"
)

func generateShortCode(longURL string) string {
    hash := md5.Sum([]byte(longURL))
    hex := hex.EncodeToString(hash[:])
    // берём первые 7 символов → конвертируем в Base62
    return hex[:7] // упрощённо; реально — Base62 encode первых 4 байт
}
```

**Коллизии при hash-based:** вероятность коллизии ≈ n²/2m, где m = 62^7 = 3.5T.
При 6B URLs: p ≈ (6×10⁹)² / (2 × 3.5×10¹²) ≈ 5×10⁶ коллизий — неприемлемо.
Решение: при коллизии добавить соль (`url + timestamp + random`) и повторить.

**Итог:** Counter-based предпочтительнее — нет коллизий, предсказуемо.

### 1.6 Кеширование

```
Паттерн: Cache-Aside (Lazy Loading)

GET /{shortCode}:
  1. Проверить Redis: GET shortCode
  2. Hit  → вернуть URL (95%+ трафика)
  3. Miss → PostgreSQL → SET shortCode url EX 86400 → вернуть URL

Eviction policy: allkeys-lru
TTL ключа: 24 часа (hot URLs обновляются постоянно)

Размер кеша:
  Закон Парето: 20% URLs дают 80% трафика
  6B URLs * 20% * 500B ≈ 600 GB → 3-4 Redis ноды по 200 GB
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

### 1.7 Аналитика: async pipeline

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

### 1.8 Storage: когда что выбрать

| Критерий | PostgreSQL | Cassandra |
|---|---|---|
| Объём данных | < 1 TB | > 1 TB |
| Read pattern | По PK или index | По partition key |
| Consistency | Strong | Eventual (tunable) |
| Joins / transactions | Да | Нет |
| Horizontal scale | Сложнее | Встроенный |
| **Для URL Shortener** | До 1-2B URLs | Свыше 2B URLs |

Для большинства компаний (до 5-6B URLs за 5 лет) PostgreSQL с шардингом по `short_code % N` достаточен. Cassandra нужна при глобальном масштабе.

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

| Решение | Плюсы | Минусы |
|---|---|---|
| 302 вместо 301 | Полная аналитика кликов | Больше нагрузки на сервис |
| Counter vs Hash | Нет коллизий, короче | Предсказуемость ID (seq scan) |
| Redis Cache | P99 < 5ms для hot URLs | Stale данные при обновлении |
| Async analytics | Не блокирует redirect | At-least-once → дедупликация |
| PostgreSQL vs Cassandra | Проще, ACID | Хуже масштабируется горизонтально |

---

## Кейс 2: Мессенджер (WhatsApp/Telegram)

### 2.1 Requirements

**Functional:**
- 1-to-1 чат и групповые чаты (до 1000 участников)
- Online/offline статус пользователя
- История сообщений (бессрочно)
- Push notifications для offline пользователей
- Read receipts (✓✓)
- Media: фото, видео, файлы

**Non-functional:**
- 50M DAU, 40 сообщений/день/пользователь
- Message delivery latency: < 100 ms (P99)
- Availability: 99.99%
- E2E encryption (упрощённо)
- History: хранить 5 лет

### 2.2 Estimation

```
Messaging QPS:
  50M users * 40 msg/day = 2B сообщений/день
  2B / 86400 ≈ 23_000 msg/sec  (peak ×3 = 70K msg/sec)

Storage (5 лет):
  Сообщение: ~200 байт (text) + метаданные ~100 байт = 300 байт
  2B * 300B * 365 * 5 = ~1.1 PB  (text only)
  Media: ~30% сообщений содержат медиа, avg 500KB
  2B * 0.3 * 500KB * 365 * 5 ≈ 548 PB  → object storage (S3)

WebSocket connections:
  50M DAU, avg 30% online одновременно = 15M concurrent connections
  1 WS сервер: ~50K соединений → 300 WS серверов

Online presence updates:
  15M * heartbeat 30s = 500K updates/sec → Redis
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
  POST /api/v1/chats                          (создать группу)
  PUT  /api/v1/chats/{chatId}/members         (добавить участников)
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

**Сценарий: User A (online) → User B (online)**

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

**Сценарий: User B (offline) → push notification**

```
Message Svc
    │
    ├── User B offline (Redis: presence key отсутствует)
    │
    ├── Store message в Cassandra (статус: pending)
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
-- Партиционирование по chat_id (равномерное распределение)
-- Сортировка по времени внутри partition

CREATE TABLE messages (
    chat_id      UUID,
    bucket       INT,        -- UNIX_TIMESTAMP / 86400 (день-бакет)
    message_id   TIMEUUID,   -- встроенный timestamp + uniqueness
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

**Почему bucket:**
- Без bucket одна partition для активного чата растёт бесконечно
- С bucket = один день → partition ≤ 40 сообщений * 1000 участников * 86400 / 1000 ≈ управляемо
- При чтении истории: `WHERE chat_id = X AND bucket IN (today, yesterday, ...)`

### 2.7 Online Presence

```
Паттерн: Heartbeat + Redis

Client → WS Gateway: heartbeat каждые 5 сек
WS Gateway:
  SETEX presence:{user_id} 15 "online"  // TTL = 3 heartbeats

Проверка статуса другого пользователя:
  GET presence:{user_id}  → nil = offline

Pub/Sub для уведомления о смене статуса:
  PUBLISH presence-channel '{"user_id": "123", "status": "online"}'
  Подписчики (WS Gateways) доставляют presence events соответствующим клиентам
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
    ├── Priority queue (высокий/низкий приоритет)
    │
    ├── FCM Worker (Android)
    │     POST https://fcm.googleapis.com/v1/projects/{id}/messages:send
    │
    ├── APNs Worker (iOS)
    │     HTTP/2 + TLS к api.push.apple.com
    │
    └── Retry policy:
          exponential backoff: 1s, 2s, 4s, 8s, 16s
          max retries: 5
          dead letter queue после 5 неудач
```

### 2.9 End-to-End Encryption (упрощённо)

```
Signal Protocol (упрощённая схема):

1. Key generation (на клиенте):
   - Identity Key Pair (долгосрочный)
   - Signed Prekey (меняется еженедельно)
   - One-Time Prekeys (пул, одноразовые)

2. Публикация публичных ключей на сервер (сервер хранит, не видит приватные)

3. Session init (X3DH - Extended Triple Diffie-Hellman):
   Sender берёт публичные ключи Receiver с сервера
   Вычисляет shared secret локально
   Сервер НИКОГДА не видит shared secret

4. Double Ratchet: каждое сообщение зашифровано уникальным ключом
   Компрометация одного ключа не раскрывает остальные (forward secrecy)

5. Сервер хранит: только зашифрованный blob + метаданные
```

### 2.10 Group Chat: Fan-out Strategy

```
Fan-out on Write:
  При отправке сообщения → записать в inbox каждого участника
  
  Pros: быстрое чтение (каждый читает своё)
  Cons: N записей для N участников группы (при 1000 участников — 1000 записей)

Fan-out on Read:
  Хранить одно сообщение, каждый читает из общего места
  
  Pros: одна запись
  Cons: медленнее чтение, сложнее трекать read receipts

Гибридный подход (как Telegram):
  ┌───────────────────────────────────────────────┐
  │  Группы ≤ 100 участников → Fan-out on Write   │
  │  Группы > 100 участников → Fan-out on Read    │
  │                                               │
  │  В обоих случаях: last_read_message_id        │
  │  хранится отдельно per-user per-chat          │
  └───────────────────────────────────────────────┘
```

### 2.11 Trade-offs

| Решение | Обоснование |
|---|---|
| WebSocket вместо long polling | 15M concurrent — polling убьёт сервер |
| Cassandra вместо PostgreSQL | Горизонтальный масштаб, time-series паттерн |
| Fan-out on Write для малых групп | Читать быстрее, пишем редко и немного |
| Fan-out on Read для больших групп | 1000+ записей на сообщение неприемлемо |
| Heartbeat TTL 15 сек | Баланс: 5 сек погрешности + сетевые задержки |

---

## Кейс 3: News Feed (Twitter/Instagram)

### 3.1 Requirements

**Functional:**
- Создание постов (текст, фото, видео)
- Лента подписок (Feed) — посты от тех, на кого подписан
- Лайки, комментарии, репосты
- Real-time обновления ленты (или near-real-time)
- Follow/unfollow
- Поиск по хэштегам

**Non-functional:**
- 300M MAU, 50M DAU
- Средний пользователь: 500 подписок
- Создание постов: 5M/день (≈ 58 RPS, peak ×10 = 580 RPS)
- Чтение ленты: 300M DAU * 10 open/day = 3B req/day ≈ 35K RPS (peak ×3 = 105K RPS)
- Latency feed: P99 < 200 ms
- Media: хранить бессрочно

### 3.2 Estimation

```
Post creation:
  5M posts/day * (avg 1KB text + metadata) = 5 GB/day text
  5M * 30% медиа * avg 2MB = 3 PB/day → S3 + CDN

Feed generation:
  35K read RPS — основная нагрузка
  500 подписок * 35K = 17.5M fan-out writes/sec при Write-based feed

Like events:
  300M DAU * 50 likes/day = 15B likes/day ≈ 170K like ops/sec (peak)
  Хранение: counter per post в Redis + batch flush в DB

Storage (5 лет):
  Posts:  5M/day * 365 * 5 * 1KB = ~9 TB
  Media:  ~5 PB (S3)
  Feed cache: Redis (pre-computed timelines)
```

### 3.3 Fan-out on Write vs Fan-out on Read

```
Fan-out on Write (Push model):
─────────────────────────────
User A (1M followers) публикует пост
→ Записать post_id в feed каждого из 1M followers
→ 1M Redis LPUSH операций

Pros:
  + Feed читается за O(1) — просто читаем свой список
  + Низкая latency при чтении

Cons:
  - Celebrity problem: 1M+ LPUSH при одном посте
  - Write amplification огромный
  - Хранилище: N followers * posts

Fan-out on Read (Pull model):
──────────────────────────────
При запросе ленты:
  Получить список подписок (followings)
  Запросить последние посты каждого
  Merge по timestamp

Pros:
  + Нет write amplification
  + Всегда свежие данные

Cons:
  - Медленно при 500 подписках: 500 запросов к DB → merge
  - Не подходит для высокого read QPS

Гибридный подход (Twitter/Instagram):
──────────────────────────────────────
  Обычные пользователи (< 1M followers):
    → Fan-out on Write
    → Post_id попадает в pre-computed feed (Redis Sorted Set) каждого follower

  Celebrity (> порог, напр. 500K followers):
    → Fan-out on Read
    → Посты хранятся только у celebrity
    → При запросе feed: merge pre-computed feed + celebrity posts
```

```
                    ┌─────────────────────────────────────────┐
                    │           User публикует пост            │
                    └─────────────────┬───────────────────────┘
                                      │
                           ┌──────────▼──────────┐
                           │  Fan-out Service     │
                           │  (async, workers)    │
                           └──────────┬───────────┘
                                      │
              ┌───────────────────────┼────────────────────────┐
              │ обычный user          │                        │ celebrity
    ┌─────────▼──────────────┐       │              ┌─────────▼──────────────┐
    │ Redis Sorted Set        │       │              │ Только в Post DB       │
    │ feed:{follower_id}      │       │              │ Нет fan-out            │
    │ ZADD score=timestamp    │       │              │ Pull при чтении ленты  │
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
    Score     float64 // timestamp или rank score
    CreatedAt time.Time
}

func (s *TimelineService) GetFeed(ctx context.Context, userID string, limit int) ([]FeedItem, error) {
    // 1. Получить pre-computed feed из Redis
    key := fmt.Sprintf("feed:%s", userID)
    results, err := s.redis.ZRevRangeWithScores(ctx, key, 0, int64(limit*2)).Result()
    if err != nil {
        return nil, err
    }

    // 2. Получить celebrity IDs из followings
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
Хронологическая лента (Twitter до 2023):
  Score = unix_timestamp поста
  Простота, предсказуемость
  Проблема: пользователь пропускает важные посты

Алгоритмическая лента (Instagram, новый Twitter):
  Score = f(recency, engagement, author_affinity, content_type)

  Пример формулы:
  score = (likes * 0.4 + comments * 0.3 + shares * 0.2 + views * 0.1)
          * recency_decay(age_hours)
          * affinity_boost(author_follower_relationship)

  recency_decay(h) = exp(-λ * h)  // λ ≈ 0.1 → половинное время ~7 часов

  Реализация:
  - Offline: ML модель (XGBoost / DNN) обучается на engagement данных
  - Online: scoring при сборке ленты или pre-scored в Redis
```

### 3.6 Media Storage

```
Upload flow:
  Client → POST /api/v1/media/upload
        ← presigned S3 URL (expires in 5 min)
  Client → PUT <presigned URL> (прямо в S3, минуя backend)
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

URL структура:
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

### 3.8 Likes: High-throughput counter

```
Проблема: 170K like ops/sec нельзя писать напрямую в PostgreSQL

Решение: Redis Counter + Periodic Flush

INCR like_count:{post_id}           // O(1), атомарно
SADD dirty_posts {post_id}          // отмечаем "грязный"

Фоновый воркер каждые 30 сек:
  SMEMBERS dirty_posts → batch update в PostgreSQL
  SREM dirty_posts {processed_ids}

Trade-off: up to 30 сек lag между Redis и DB
Потеря при краше Redis: до 30 сек counter changes
Решение: Redis AOF + checkpoint
```

### 3.9 Trade-offs

| Решение | Обоснование |
|---|---|
| Гибридный fan-out | Celebrity problem делает pure write неэффективным |
| Pre-computed feed в Redis | 35K read RPS нельзя обслуживать pull-ом |
| CDN для медиа | P99 < 50ms для изображений только с edge |
| Redis counter для лайков | 170K ops/sec — только in-memory |
| Async fan-out через Kafka | Spike при публикации popular поста |

---

## Кейс 4: Distributed Rate Limiter

### 4.1 Requirements

- Глобальное ограничение запросов (не per-instance)
- Multi-region поддержка
- Sub-millisecond overhead (< 1 ms добавленная latency)
- Гибкие правила: per-user, per-IP, per-API-key, per-endpoint
- Graceful degradation: если rate limiter недоступен — fail open или fail closed (конфигурабельно)

**Non-functional:**
- 500K RPS через limiter
- 99.99% availability
- Консистентность: допустима небольшая overshoot (eventual consistency)

### 4.2 Алгоритмы

```
Token Bucket:
─────────────
  capacity = 100 tokens
  refill_rate = 10 tokens/sec

  При запросе:
    tokens = min(capacity, tokens + elapsed * rate)
    if tokens >= 1:
      tokens -= 1
      allow
    else:
      deny

  Плюсы: допускает burst (до capacity), гладкое ограничение
  Минусы: параметры нужно тюнить под каждый endpoint

Sliding Window Counter:
───────────────────────
  Разбить время на 1-сек слоты
  Хранить count для текущего и предыдущего слота
  
  rate = prev_count * (1 - elapsed/window) + curr_count

  Пример: limit = 100 req/min
    curr_window (начался 30 сек назад): 40 запросов
    prev_window: 80 запросов
    rate_estimate = 80 * 0.5 + 40 = 80 — под лимитом ✓

  Плюсы: точнее fixed window, не даёт double-burst на границах
  Минусы: приблизительно (не точный sliding window)

Fixed Window:
─────────────
  Простейший: counter per window (минута, час)
  Проблема: double-burst на границе окна (100 в конце + 100 в начале)
  Не использовать в production без патча до sliding window
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
  Пример: rl:user:12345:1710000060
           rl:ip:1.2.3.4:1710000060
           rl:apikey:abc123:1710000060

Lua script для атомарности:
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

### 4.4 Полная реализация на Go

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
    // Window-aligned key: сбрасывается вместе с окном
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
Проблема: пользователь делает запросы в EU и US одновременно
         Локальные Redis не знают друг о друге

Решение 1: Centralized Redis (один кластер на весь мир)
  Минус: cross-region latency (100-200ms) → overhead неприемлем

Решение 2: Local + Global sync (два уровня)
  ┌────────────────────────────────────────────────────────────┐
  │                   Request Processing                        │
  │                                                            │
  │  1. Проверить LOCAL Redis (< 1ms)                          │
  │     local_count += 1                                       │
  │                                                            │
  │  2. Async: каждые 100ms синхронизировать с Global Redis    │
  │     global_count = INCRBY global_key local_delta           │
  │     Если global_count > limit: activate global reject mode  │
  │                                                            │
  │  3. Soft limit: local = 80% от global limit               │
  │     Overshoot до 20% допустим                              │
  └────────────────────────────────────────────────────────────┘

Решение 3: Approximate (Production-grade)
  Каждый регион получает N/R токенов, где N=global limit, R=regions
  EU: 1000/3 ≈ 333 req/min
  US: 333 req/min
  AP: 333 req/min
  
  Перераспределение при дисбалансе: cron job каждые 5 мин
```

### 4.6 Race Conditions

```
Проблема без Lua:
  Горутина 1: GET count=99  ← читает
  Горутина 2: GET count=99  ← читает (до SET горутины 1)
  Горутина 1: SET count=100 ← оба разрешены, хотя лимит 100
  Горутина 2: SET count=100 ← race condition!

Решение: Lua script выполняется атомарно на Redis
  GET + INCR + EXPIRE = одна транзакция, нет race condition

Альтернатива для token bucket: Redis сделки (MULTI/EXEC)
  WATCH tokens:{key}
  MULTI
    DECRBY tokens:{key} cost
    EXPIREAT tokens:{key} next_refill
  EXEC
  → если WATCH обнаружил изменение, EXEC вернёт nil → retry
```

### 4.7 Trade-offs

| Решение | Обоснование |
|---|---|
| Lua script vs MULTI/EXEC | Lua атомарен и быстрее, нет retry loop |
| Sliding window vs token bucket | Sliding window точнее для API rate limits |
| Fail open vs fail closed | Зависит от API критичности; финансы → fail closed |
| Local + Global sync | Баланс latency и точности при multi-region |

---

## Кейс 5: Notification Service

### 5.1 Requirements

**Functional:**
- Каналы: email, SMS, push (iOS/Android), in-app уведомления
- Приоритеты: critical (OTP, security), high (transactional), normal (marketing)
- Template engine: переменные, локализация
- Throttling: не более X уведомлений/пользователь/час
- Retry при ошибке провайдера
- Deduplication: одно событие не вызывает два уведомления
- Tracking: delivered, opened, clicked
- Idempotency: повторный вызов API не дублирует уведомление

**Non-functional:**
- 50M уведомлений/день ≈ 580 notif/sec (peak ×10 = 5800/sec)
- Critical: latency < 5 sec
- Marketing: latency < 30 min (batch)
- Availability: 99.9%

### 5.2 High-Level Design

```
                      ┌──────────────────────────────────────────┐
                      │           Notification API               │
                      │  POST /api/v1/notifications/send         │
                      │  (idempotency_key в заголовке)           │
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
    "channels": ["push", "email"],    // или ["auto"] — выбрать по настройкам
    "email": "user@example.com",      // override из user profile
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
    Subject  string // для email
    Body     string // текст с {{variables}}
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
Проблема: event может прийти дважды (retry upstream, at-least-once delivery)

Решение: Idempotency Key в Redis

При получении запроса:
  key = "dedup:" + idempotency_key
  result = SET key "processing" NX EX 86400  // NX = set only if not exists

  Если result == nil → уже обрабатывается или обработано → return cached response
  Если result == "OK"  → первый раз → обрабатываем

После обработки:
  SET key {notification_id} EX 86400  // сохраняем результат для повторных запросов
```

```go
func (s *NotificationService) Send(ctx context.Context, req *SendRequest) (*SendResponse, error) {
    idempotencyKey := req.IdempotencyKey
    if idempotencyKey == "" {
        idempotencyKey = uuid.New().String() // генерируем если нет
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
Цель: пользователь не получает > 10 уведомлений/час от одного сервиса

Реализация: Sliding Window Counter в Redis

func (s *ThrottleChecker) IsAllowed(ctx context.Context, userID, notifType string) (bool, error) {
    key := fmt.Sprintf("throttle:%s:%s:%d", userID, notifType, time.Now().Unix()/3600)
    count, err := s.redis.Incr(ctx, key).Result()
    if count == 1 {
        s.redis.Expire(ctx, key, 2*time.Hour) // перекрываем 2 часа для sliding
    }
    if count > s.limits[notifType] {
        return false, nil  // throttled
    }
    return true, nil
}

Пример лимитов:
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

// Intervals: 1s, 2s, 4s, 8s, 16s → затем Dead Letter Queue

func (w *EmailWorker) processWithRetry(ctx context.Context, msg *Notification) {
    backoff := w.retryConfig.InitialInterval
    for attempt := 1; attempt <= w.retryConfig.MaxAttempts; attempt++ {
        err := w.sendEmail(ctx, msg)
        if err == nil {
            w.markDelivered(msg.ID)
            return
        }

        // Permanent errors — не ретраить
        if isPermanentError(err) { // e.g., invalid email address
            w.markFailed(msg.ID, "permanent_error: "+err.Error())
            return
        }

        // Transient errors — ретраить с backoff
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

-- Webhook от провайдеров (SendGrid, Twilio) записывает события:
POST /webhooks/sendgrid
  → парсим payload → INSERT INTO notification_events

-- Open tracking для email: pixel tracking
<img src="https://track.example.com/open/{notif_id}/{email_hash}" width="1" height="1">
GET /open/{notif_id}/{email_hash}  → INSERT event_type='opened' → 1x1 pixel response
```

### 5.9 Trade-offs

| Решение | Обоснование |
|---|---|
| Kafka очереди по приоритету | Critical не ждёт маркетинговый bulk |
| Idempotency key в Redis на 24ч | Дольше хранить дорого, 24ч покрывает retry окно |
| Fail на throttle для marketing | Лучше потерять маркетинг, чем спамить |
| Webhook vs polling для статуса | Провайдеры сами нас оповещают, не тратим RPS |
| DLQ для failed | Ручной разбор + alert, нельзя терять OTP |

---

## Кейс 6: Distributed Task Scheduler (Cron)

### 6.1 Requirements

**Functional:**
- Запуск задач по cron-расписанию (стандартный cron syntax)
- At-least-once execution (задача выполнится минимум раз)
- Exactly-once semantics через idempotent задачи
- Distributed: нет SPOF
- Мониторинг: last_run, next_run, success/failure status
- Поддержка миллионов задач

**Non-functional:**
- Точность запуска: ± 1 секунда
- Availability: 99.99%
- Масштаб: 10M задач, 100K triggers/min (peak)

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
    partition_id  INT          NOT NULL,     -- для распределения между scheduler-ами
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
Проблема: 10M задач нельзя опросить одним scheduler-ом каждую секунду

Решение: партиционирование задач между scheduler инстансами

  task.partition_id = hash(task.id) % NUM_PARTITIONS

  Каждый scheduler owner-ит свои партиции:
  ┌─────────────────────────────────────────────┐
  │  etcd key: /scheduler/partitions            │
  │  Value: {                                   │
  │    "0-99":   "scheduler-host-1",            │
  │    "100-199": "scheduler-host-2",           │
  │    "200-299": "scheduler-host-3"            │
  │  }                                          │
  └─────────────────────────────────────────────┘

  Scheduler-1 каждую секунду:
    SELECT * FROM tasks
    WHERE partition_id BETWEEN 0 AND 99
      AND next_run_at <= NOW()
      AND status = 'active'
    FOR UPDATE SKIP LOCKED;  -- ключевое: не блокируем других
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

### 6.5 Leader Election через etcd

```go
import "go.etcd.io/etcd/client/v3/concurrency"

func (s *Scheduler) ElectLeader(ctx context.Context, etcdClient *clientv3.Client) {
    session, _ := concurrency.NewSession(etcdClient, concurrency.WithTTL(10))
    defer session.Close()

    election := concurrency.NewElection(session, "/scheduler/leader")

    for {
        // Блокирующий вызов: ждём, пока не станем лидером
        if err := election.Campaign(ctx, s.nodeID); err != nil {
            continue
        }

        log.Println("Became leader, acquiring partitions...")
        s.acquirePartitions(ctx, etcdClient)
        s.Run(ctx)

        // Если контекст отменён или потеряли лидерство
        election.Resign(ctx)
    }
}

// Partition assignment: лидер распределяет партиции между всеми scheduler-ами
func (s *Scheduler) acquirePartitions(ctx context.Context, client *clientv3.Client) {
    // Получить список живых scheduler нод
    resp, _ := client.Get(ctx, "/scheduler/nodes/", clientv3.WithPrefix())
    nodes := parseNodes(resp)

    // Равномерно распределить партиции
    partitionMap := distributePartitions(300, nodes)  // 300 партиций

    // Записать в etcd
    data, _ := json.Marshal(partitionMap)
    client.Put(ctx, "/scheduler/partitions", string(data))
}
```

### 6.6 Missed Schedules: Catch-up

```
Проблема: scheduler был down с 02:00 до 04:00
  Задача с расписанием "0 * * * *" должна была выполниться в 02:00, 03:00, 04:00
  При рестарте: next_run_at = 02:00 (в прошлом)

Стратегии:

1. Skip missed: пересчитать next_run от NOW()
   Простейший подход: некоторые задачи нужны строго по расписанию

2. Run once: выполнить один раз при обнаружении пропуска
   Для задач, где важна сама выполненность (e.g., daily report)

3. Run all missed: выполнить каждое пропущенное
   Для финансовых задач (e.g., billing per hour)

Реализация skip+run-once (наиболее частое требование):
```

```go
func handleMissedSchedule(task *Task, now time.Time) (runNow bool, nextRun time.Time) {
    if task.NextRunAt.Before(now) {
        switch task.MissedPolicy {
        case "skip":
            // Пересчитать с NOW(), не запускать
            return false, calculateNextRun(task.CronExpr, now)
        case "run_once":
            // Запустить один раз, затем пересчитать от NOW()
            return true, calculateNextRun(task.CronExpr, now)
        case "run_all":
            // Запустить все пропущенные (осторожно с burst!)
            return true, calculateNextRun(task.CronExpr, task.NextRunAt)
        }
    }
    return false, task.NextRunAt
}
```

### 6.7 Idempotency задач

```
At-least-once означает: задача МОЖЕТ запуститься дважды

Причины:
  - Worker получил задачу, выполнил, но не успел ack до таймаута
  - Scheduler решил, что задача не выполнилась → retry
  - Network partition

Решение: идемпотентные задачи

Паттерн 1: Natural idempotency
  "Пересчитать агрегаты за вчера" — результат одинаков при повторном запуске
  "Обновить статус заказа если он PENDING" — UPDATE WHERE status = 'PENDING'

Паттерн 2: Execution lock
  При старте воркер записывает в task_runs:
    INSERT INTO task_runs (task_id, triggered_at, status)
    VALUES ($1, $2, 'running')
    ON CONFLICT (task_id, triggered_at) DO NOTHING
  
  Если INSERT вернул 0 rows → кто-то уже выполняет → выйти

  Ключ уникальности: (task_id, triggered_at)
  Два запуска одной задачи в один момент времени — конфликт → один побеждает

Паттерн 3: Idempotency key в HTTP запросах задачи
  Worker добавляет заголовок:
    Idempotency-Key: {task_id}:{triggered_at_unix}
  
  Целевой сервис дедуплицирует по этому ключу
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

### 6.8 Мониторинг и алерты

```
Метрики (Prometheus):

  task_triggers_total{status="success|failed"} — счётчик
  task_execution_duration_seconds{handler_type} — histogram
  task_queue_depth{partition} — gauge
  task_missed_schedules_total — счётчик пропусков

Алерты:

  # Задача не выполнялась больше 2x своего интервала
  ALERT TaskMissed
    IF (time() - task_last_success_timestamp) > (2 * task_interval_seconds)
    FOR 5m
    LABELS {severity="warning"}

  # Очередь воркеров растёт
  ALERT WorkerQueueBacklog
    IF task_queue_depth > 10000
    FOR 2m
    LABELS {severity="critical"}

Dashboard (Grafana):
  - Timeline: trigger rate, success rate, failure rate
  - P99 execution latency по handler type
  - Heatmap: задачи по времени суток (паттерны нагрузки)
  - Top-10 задач по execution time
```

### 6.9 Trade-offs

| Решение | Обоснование |
|---|---|
| Partition-based vs single leader | Single leader = SPOF + bottleneck при 10M задач |
| `FOR UPDATE SKIP LOCKED` | Избегаем lock contention между scheduler инстансами |
| At-least-once + idempotency | Exactly-once распределённо — слишком дорого |
| etcd для leader election | Raft consensus, battle-tested, TTL на leases |
| Miss policy конфигурабельна | Разные задачи имеют разную семантику пропуска |
| PostgreSQL vs специализированные (Temporal) | PostgreSQL достаточен до 10M задач; Temporal для сложных workflow |

---

## Итоговая сводка: паттерны и принципы

### Паттерны, встречающиеся во всех кейсах

| Паттерн | Кейсы | Суть |
|---|---|---|
| Cache-Aside | URL Shortener, Messenger | Читать кеш, при miss — DB, затем заполнить кеш |
| Fan-out | Messenger, News Feed | Доставка данных N получателям |
| Async via Kafka | URL Shortener, Notification | Развязать запись и обработку |
| Idempotency Key | Notification, Task Scheduler | Повторный вызов = тот же результат |
| Lua script для атомарности | Rate Limiter | Несколько Redis операций без race condition |
| Partition-based ownership | Task Scheduler, Messenger | Разделить данные между инстансами |
| Dead Letter Queue | Notification, Task Scheduler | Не теряем данные при исчерпании retry |
| Heartbeat + TTL | Messenger, Task Scheduler | Обнаружение отказов через истечение аренды |

### Когда что выбирать: хранилища

| Хранилище | Используй когда |
|---|---|
| PostgreSQL | Сложные запросы, транзакции, объём < 5 TB |
| Cassandra | Time-series, высокий write QPS, горизонтальный масштаб |
| Redis | Cache, counters, pub/sub, short-lived data |
| ClickHouse | Аналитика, OLAP, columnar scans |
| S3 + CDN | Медиафайлы, статика, объекты > 1 MB |
| etcd | Конфигурация, leader election, distributed locks |

### Чеклист для System Design интервью

```
1. Requirements (5 мин)
   □ Functional: что система делает
   □ Non-functional: scale, latency, availability, consistency

2. Estimation (3-5 мин)
   □ QPS (read и write раздельно)
   □ Storage (data size * TTL)
   □ Bandwidth
   □ Connections (если realtime)

3. API Design (5 мин)
   □ Endpoints, методы, параметры
   □ Протокол: REST / WebSocket / gRPC

4. High-Level Design (10 мин)
   □ ASCII-диаграмма с основными компонентами
   □ Flows для основных операций

5. Deep Dive (15-20 мин)
   □ Сложное место #1 (обычно scale или consistency)
   □ Сложное место #2 (failure handling или perf)
   □ Trade-offs вслух

6. Trade-offs и альтернативы (5 мин)
   □ Что бы сделали иначе при другом масштабе
   □ Что жертвуем ради чего
```

---

*Модуль 12 завершает курс. Все шесть кейсов охватывают типичные задачи на System Design интервью в компаниях уровня FAANG/MANGA. Ключ к успеху — не запомнить решения, а понять, почему каждое решение принято именно так.*
