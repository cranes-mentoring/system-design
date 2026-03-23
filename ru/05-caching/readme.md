# Модуль 05: Кеширование

Кеширование — это сохранение результата дорогой операции рядом с потребителем, чтобы повторный запрос был дешевле. Звучит просто. На практике — один из главных источников production-инцидентов. Этот модуль разбирает кеширование от уровней архитектуры до конкретных паттернов и ловушек.

---

## Содержание

1. [Зачем кеширование и где оно живёт](#1-зачем-кеширование-и-где-оно-живёт)
2. [Стратегии кеширования](#2-стратегии-кеширования)
3. [Политики вытеснения (Eviction Policies)](#3-политики-вытеснения-eviction-policies)
4. [Redis: архитектура и паттерны](#4-redis-архитектура-и-паттерны)
5. [CDN (Content Delivery Network)](#5-cdn-content-delivery-network)
6. [Проблемы кеширования](#6-проблемы-кеширования)
7. [Инвалидация кеша](#7-инвалидация-кеша)

---

## 1. Зачем кеширование и где оно живёт

### Проблема

База данных на IOPS упирается в диск. Сетевой запрос к соседнему сервису стоит миллисекунды. Сложный агрегирующий SQL может занимать сотни миллисекунд. Если сотни пользователей делают одинаковые запросы — ты платишь эту цену каждый раз.

Кеш решает это: вычислить один раз, отдавать быстро.

### Уровни кеширования

Кеш существует на каждом уровне стека. Разные уровни отличаются latency, объёмом и областью ответственности.

```
 Пользователь
      │
      ▼
┌─────────────────┐
│  Browser Cache  │  ← HTTP-заголовки, Service Worker
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│      CDN        │  ← Edge nodes, PoP по всему миру
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Load Balancer  │  ← Иногда кеширует, но редко
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

| Уровень | Latency | Типичный объём | Пример |
|---|---|---|---|
| CPU L1/L2/L3 | 1–40 нс | КБ — МБ | Кеш процессора, управляется CPU |
| In-process (heap) | 100–500 нс | МБ — ГБ | `sync.Map`, LRU в памяти процесса |
| Distributed cache | 0.5–2 мс | ГБ — ТБ | Redis, Memcached |
| CDN | 1–50 мс | ТБ | Cloudflare, Fastly, CloudFront |
| Browser cache | 0 мс (диск) | МБ | HTTP Cache-Control |
| Database buffer pool | 0.1–1 мс | ГБ | InnoDB buffer pool, PostgreSQL shared_buffers |

### Cache Hit Ratio

**Cache Hit Ratio (CHR)** — доля запросов, обслуженных из кеша:

```
CHR = Cache Hits / (Cache Hits + Cache Misses)
```

| CHR | Оценка |
|---|---|
| < 80% | Плохо — кеш почти не помогает |
| 80–90% | Приемлемо для старта |
| 90–95% | Хорошо |
| > 95% | Отлично — типичная цель для production |
| > 99% | Для read-heavy систем с горячими данными |

Низкий CHR — признак одной из проблем:
- Слишком маленький размер кеша (много вытеснений)
- Плохой TTL (данные протухают раньше повторного запроса)
- Высокая карdinality ключей (каждый запрос уникален)
- Cache penetration (запросы к несуществующим данным)

**Как мерить:** добавь счётчики `cache.hits` и `cache.misses` в метрики (Prometheus). Смотри не только суммарный CHR, но и по типам данных — разные сущности ведут себя по-разному.

---

## 2. Стратегии кеширования

### Cache-Aside (Lazy Loading)

Приложение само управляет кешем. Самый распространённый паттерн.

```
Приложение         Кеш          База данных
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
  (следующий запрос)
     │── GET key ───►│                │
     │◄── HIT ───────│                │
```

**Плюсы:**
- Кеш содержит только реально запрашиваемые данные
- Отказ кеша не роняет систему — идём в БД
- Разные данные можно кешировать по-разному

**Минусы:**
- Первый запрос всегда медленный (cold start)
- Race condition при конкурентных запросах: несколько goroutines могут одновременно пойти в БД
- Ответственность за кеш размазана по приложению

### Write-Through

Запись одновременно в кеш и в БД. Кеш всегда актуален.

```
Приложение         Кеш          База данных
     │               │                │
     │── SET key ───►│                │
     │               │── INSERT ─────►│
     │               │◄── OK ─────────│
     │◄── OK ────────│                │
```

**Когда подходит:**
- Данные часто читаются сразу после записи
- Нельзя допустить stale read
- Пишешь немного, читаешь много (write-few, read-many)

**Минусы:**
- Запись медленнее (два round-trip)
- Кеш заполняется данными, которые могут никогда не читаться

### Write-Behind (Write-Back)

Запись сначала в кеш, потом асинхронно в БД. Максимальная скорость записи.

```
Приложение         Кеш          База данных
     │               │                │
     │── SET key ───►│                │
     │◄── OK ────────│                │
     │               │                │
     │            (async, batch)       │
     │               │── INSERT ─────►│
     │               │◄── OK ─────────│
```

**Когда подходит:**
- Высоконагруженная запись (счётчики, аналитика)
- Допустима временная рассинхронизация
- Можно потерять несколько последних записей при падении

**Риски:**
- При краше кеша до flush — данные теряются
- Сложнее реализовать корректно
- Не подходит для финансовых данных

### Read-Through

Кеш сам идёт в БД при cache miss. Приложение работает только с кешем.

```
Приложение         Кеш          База данных
     │               │                │
     │── GET key ───►│                │
     │               │── SELECT ─────►│  (при miss)
     │               │◄── Data ───────│
     │◄── Data ──────│                │
```

**Отличие от Cache-Aside:** логика загрузки данных в кеш находится в кеш-библиотеке, а не в приложении. Пример — `github.com/dgraph-io/ristretto` с loader-функцией.

### Refresh-Ahead

Кеш обновляет данные в фоне до истечения TTL, если замечает, что ключ скоро протухнет.

```
TTL = 60s, refresh при остатке < 10s

t=0   ── SET key (TTL=60s)
t=50  ── GET key → HIT + запуск фонового обновления
t=51  ── Background: GET from DB + SET key (TTL=60s)
t=60  ── TTL истёк, но уже загружен свежий ключ
```

**Когда использовать:** данные обновляются предсказуемо, нельзя допустить cache miss под нагрузкой.

**Минус:** кеш может обновлять данные, которые больше не запрашиваются.

### Сравнение стратегий

| Стратегия | Consistency | Read Latency | Write Latency | Complexity | Data Loss Risk |
|---|---|---|---|---|---|
| Cache-Aside | Eventual | Высокая (miss) | Обычная | Низкая | Нет |
| Write-Through | Сильная | Низкая | Высокая | Средняя | Нет |
| Write-Behind | Eventual | Низкая | Минимальная | Высокая | Да |
| Read-Through | Eventual | Высокая (miss) | Обычная | Средняя | Нет |
| Refresh-Ahead | Eventual | Минимальная | Обычная | Высокая | Нет |

### Пример на Go: Cache-Aside с Redis

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

    // 1. Проверяем кеш
    data, err := r.redis.Get(ctx, key).Bytes()
    if err == nil {
        var user User
        if err := json.Unmarshal(data, &user); err == nil {
            return &user, nil // cache hit
        }
    }
    if !errors.Is(err, redis.Nil) {
        // Redis недоступен — логируем, но не падаем
        // Продолжаем работу с БД
        _ = err
    }

    // 2. Cache miss — идём в БД
    user, err := r.db.GetUser(ctx, id)
    if err != nil {
        return nil, fmt.Errorf("db.GetUser: %w", err)
    }

    // 3. Сохраняем в кеш
    b, _ := json.Marshal(user)
    r.redis.Set(ctx, key, b, r.ttl) // ошибку игнорируем — кеш опциональный

    return user, nil
}

func (r *UserRepository) UpdateUser(ctx context.Context, user *User) error {
    if err := r.db.UpdateUser(ctx, user); err != nil {
        return err
    }
    // Инвалидируем кеш после успешной записи в БД
    key := fmt.Sprintf("user:%d", user.ID)
    r.redis.Del(ctx, key)
    return nil
}
```

---

## 3. Политики вытеснения (Eviction Policies)

Когда кеш заполнен и нужно вместить новый элемент — что выбросить?

### LRU (Least Recently Used)

Выбрасывает элемент, к которому дольше всего не обращались. Реализуется через doubly linked list + hash map.

```
Состояние кеша (размер = 3):

Добавить A: [A]
Добавить B: [B, A]
Добавить C: [C, B, A]
GET B:      [B, C, A]  ← B переместился в начало
Добавить D: [D, B, C]  ← A вытеснен (самый старый)
```

**Когда использовать:** общий случай, работает хорошо для большинства access patterns. Стандартный выбор по умолчанию.

### LFU (Least Frequently Used)

Выбрасывает элемент с наименьшим числом обращений.

```
[A: 10 hits, B: 3 hits, C: 7 hits]
Добавить D → вытесняется B (меньше всего обращений)
```

**Когда использовать:** есть явные "горячие" данные, которые не должны вытесняться. Хуже справляется со сканированием (burst access patterns), так как элементы, которые были популярны, но устарели, будут долго оставаться в кеше.

### TTL-based

Элементы автоматически удаляются по истечении времени жизни, независимо от доступа.

**Когда использовать:** данные теряют актуальность со временем. Часто комбинируется с LRU.

### Random

Выбрасывает случайный элемент.

**Когда использовать:** редко — в системах, где access patterns полностью непредсказуемы, или как простейшая реализация. Redis поддерживает `allkeys-random`.

### Политики Redis

| Политика | Описание |
|---|---|
| `noeviction` | Возвращает ошибку при заполнении (default) |
| `allkeys-lru` | LRU среди всех ключей |
| `volatile-lru` | LRU среди ключей с TTL |
| `allkeys-lfu` | LFU среди всех ключей |
| `volatile-lfu` | LFU среди ключей с TTL |
| `allkeys-random` | Random среди всех |
| `volatile-ttl` | Вытесняет ключи с наименьшим TTL |

Для кеш-сценариев: `allkeys-lru` или `allkeys-lfu`. Для mixed-use (кеш + persistent данные): `volatile-lru`.

### Пример на Go: In-memory LRU Cache

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
    // Перемещаем в начало — это самый свежий элемент
    c.list.MoveToFront(el)
    return el.Value.(*entry).value, true
}

func (c *Cache) Set(key string, value any) {
    c.mu.Lock()
    defer c.mu.Unlock()

    // Обновляем существующий
    if el, ok := c.items[key]; ok {
        c.list.MoveToFront(el)
        el.Value.(*entry).value = value
        return
    }

    // Вытесняем LRU-элемент если кеш полон
    if c.list.Len() >= c.capacity {
        oldest := c.list.Back()
        if oldest != nil {
            c.list.Remove(oldest)
            delete(c.items, oldest.Value.(*entry).key)
        }
    }

    // Добавляем новый в начало
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

Для production используй `github.com/hashicorp/golang-lru/v2` или `github.com/dgraph-io/ristretto` — там есть thread-safety, метрики, поддержка TTL и учёт размера по весу.

---

## 4. Redis: архитектура и паттерны

Redis — in-memory data structure store. Не просто key-value: богатый набор структур данных делает его универсальным инструментом.

### Структуры данных

| Структура | Команды | Типичный use case |
|---|---|---|
| **String** | GET, SET, INCR, EXPIRE | Кеш объектов, счётчики, сессии |
| **Hash** | HGET, HSET, HGETALL | Объекты пользователей, конфиги |
| **List** | LPUSH, RPOP, LRANGE | Очереди задач, логи, activity feed |
| **Set** | SADD, SMEMBERS, SINTER | Уникальные теги, онлайн-пользователи |
| **Sorted Set** | ZADD, ZRANGE, ZRANK | Лидерборды, rate limiting, таймлайн |
| **Stream** | XADD, XREAD, XGROUP | Event sourcing, message queue с ACK |
| **HyperLogLog** | PFADD, PFCOUNT | Подсчёт уникальных посетителей (±0.81% погрешность) |
| **Bitmap** | SETBIT, GETBIT, BITCOUNT | Флаги активности, bloom filter |
| **Geo** | GEOADD, GEODIST, GEORADIUS | Поиск ближайших точек |

### Persistence: RDB vs AOF

**RDB (Redis Database Backup):**
- Полный snapshot состояния в бинарный файл
- Создаётся по расписанию (`save 900 1` — каждые 15 минут если была хоть одна запись)
- Быстрый рестарт (загружает один файл)
- **Риск:** потеря данных за период между снапшотами

**AOF (Append-Only File):**
- Логирует каждую команду записи
- Три режима: `always` (fsync на каждую команду), `everysec` (fsync раз в секунду), `no` (OS решает)
- Меньше потерь при краше
- **Минус:** большой файл, медленнее рестарт

| Параметр | RDB | AOF |
|---|---|---|
| Возможные потери | Минуты | 0–1 сек (everysec) |
| Скорость рестарта | Быстрая | Медленная (replay всего лога) |
| Размер файла | Маленький | Большой (нужна периодическая перезапись) |
| Подходит для | Кеш, допустимы потери | Персистентные данные |

**Рекомендация:** для кеша — только RDB или вообще без persistence. Для данных, которые нельзя потерять — AOF с `everysec` + RDB для быстрого рестарта.

### Redis Cluster

Горизонтальное шардирование через **hash slots**. Всего 16384 слота.

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

Шардирование ключа:
slot = CRC16(key) % 16384
```

**Hash tags:** `{user}.profile` и `{user}.sessions` попадут в один слот — позволяет делать транзакции между ключами.

**Failover:** при недоступности мастера реплика автоматически становится мастером через выбор большинства (cluster-require-full-coverage).

**Ограничения кластера:**
- Нельзя делать cross-slot операции (MGET с ключами из разных слотов)
- Lua scripts работают только в рамках одного слота
- Pub/Sub работает на одном узле

### Redis Sentinel

Решение для high availability **без** шардирования.

```
┌──────────┐    ┌──────────┐    ┌──────────┐
│Sentinel 1│    │Sentinel 2│    │Sentinel 3│
└──────┬───┘    └────┬─────┘    └───┬──────┘
       │             │              │
       └─────────────┼──────────────┘
                     │ мониторинг
              ┌──────┴──────┐
              │   Master    │
              └──────┬──────┘
                     │ репликация
              ┌──────┴──────┐
              │   Replica   │
              └─────────────┘
```

Sentinel'ы голосуют за failover (нужен кворум). При недоступности мастера реплика промотируется. Клиенты спрашивают Sentinel, кто сейчас мастер.

### Pub/Sub vs Streams

**Pub/Sub:**
```
Publisher → Channel → [Subscriber1, Subscriber2, ...]
```
- **Нет гарантии доставки** — если подписчик не подключён, сообщение теряется
- **Нет persistence** — нельзя прочитать старые сообщения
- Годится для: real-time уведомления, chat, broadcast событий где потери некритичны

**Streams:**
```
XADD stream * field value
XREAD COUNT 10 STREAMS stream 0
XGROUP CREATE stream my-group $ MKSTREAM
XREADGROUP GROUP my-group consumer1 COUNT 10 STREAMS stream >
XACK stream my-group message-id
```
- **Persistence** — сообщения хранятся
- **Consumer groups** — несколько воркеров делят нагрузку
- **ACK** — подтверждение обработки
- **Replay** — можно перечитать с любой позиции

Используй Streams когда нужна надёжность. Pub/Sub — для fire-and-forget нотификаций.

### Lua Scripts для атомарных операций

Redis выполняет Lua script атомарно — никакая другая команда не выполнится пока работает скрипт.

```go
// Пример: атомарное условное обновление
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

### Пример на Go: Rate Limiter (Sliding Window) с Lua

Sliding window rate limiter: не более N запросов за последние T секунд.

```go
package ratelimit

import (
    "context"
    "fmt"
    "time"

    "github.com/redis/go-redis/v9"
)

// Lua script: sliding window rate limiter
// KEYS[1] - ключ (например "ratelimit:user:42")
// ARGV[1] - текущее время в миллисекундах
// ARGV[2] - размер окна в миллисекундах
// ARGV[3] - максимальное количество запросов
// Возвращает: 1 если разрешено, 0 если превышен лимит
const slidingWindowScript = `
local key = KEYS[1]
local now = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local limit = tonumber(ARGV[3])

-- Удаляем устаревшие записи (старше окна)
redis.call('ZREMRANGEBYSCORE', key, 0, now - window)

-- Считаем текущее количество запросов в окне
local count = redis.call('ZCARD', key)

if count >= limit then
    return 0
end

-- Добавляем текущий запрос (score = timestamp, member = timestamp для уникальности)
redis.call('ZADD', key, now, now .. '-' .. math.random(1, 1000000))

-- Устанавливаем TTL чуть больше размера окна
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
        // Fail open: если Redis недоступен — пропускаем запрос
        return true, err
    }

    return result == 1, nil
}
```

### Пример на Go: Distributed Lock (RedLock)

Для одного инстанса Redis достаточно SET NX. Для надёжности на кластере — RedLock (majority quorum).

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

// Lua script для безопасного освобождения блокировки:
// освобождаем только если value совпадает (защита от чужого unlock)
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
    // Генерируем уникальный токен
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

// Extend продлевает TTL если мы ещё держим блокировку
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

// Использование:
//
// lock, err := distlock.Acquire(ctx, redisClient, "job:process:42", 30*time.Second)
// if errors.Is(err, distlock.ErrLockNotAcquired) {
//     return // другой воркер уже обрабатывает
// }
// defer lock.Release(ctx)
// // ... критическая секция
```

> **Важно:** RedLock (несколько независимых Redis инстансов) нужен только для fault-tolerant distributed locks. Для большинства задач хватает одного Redis с `SET NX`. Мартин Клепман и Антрес Мёдлер подробно разобрали [проблемы RedLock](https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html) — прочитай перед использованием.

---

## 5. CDN (Content Delivery Network)

### Как работает

CDN — сеть серверов (edge nodes, PoP — Point of Presence), географически распределённых рядом с пользователями. Вместо того чтобы каждый запрос шёл на origin-сервер, он обслуживается ближайшим edge node.

```
Пользователь (Москва)          CDN Edge (Москва)        Origin (US-East)
        │                              │                        │
        │── GET /image.jpg ───────────►│                        │
        │                              │  Cache HIT?            │
        │                              │── GET /image.jpg ─────►│  (только при miss)
        │                              │◄── 200 OK + image ─────│
        │◄── 200 OK + image ───────────│                        │
        │                              │  (кешируем для         │
        │                              │   следующих запросов)  │
```

**Pull CDN (наиболее распространён):** CDN сам тянет контент с origin при первом запросе и кеширует его на edge. Ты не делаешь ничего специального — просто ставишь CDN перед origin.

**Push CDN:** ты явно загружаешь файлы на CDN (через API). Полный контроль над тем, что закешировано. Подходит для больших статических файлов, которые редко меняются.

### Что кешировать

| Тип контента | Кешировать? | TTL | Примечания |
|---|---|---|---|
| Статика (JS, CSS, PNG) | Да | Дни — год | Используй versioned URLs |
| HTML страницы | Зависит | Секунды — часы | Осторожно с персонализацией |
| API responses (публичные) | Да | Секунды — минуты | Cache-Control: public |
| API responses (авторизованные) | Нет | — | Cache-Control: private |
| Видео/аудио | Да | Дни — год | Range requests |
| Real-time данные | Нет | — | WebSocket, SSE |

### Cache-Control Headers

```http
Cache-Control: max-age=3600, s-maxage=86400, stale-while-revalidate=60
```

| Директива | Действие |
|---|---|
| `max-age=N` | Кешировать на N секунд (браузер + CDN) |
| `s-maxage=N` | Кешировать на N секунд только shared кешами (CDN). Переопределяет max-age для CDN |
| `no-cache` | Кешировать, но всегда валидировать через origin перед отдачей |
| `no-store` | Не кешировать вообще |
| `private` | Кешировать только в браузере, не в CDN |
| `public` | Разрешить кеширование всеми |
| `must-revalidate` | Не отдавать stale контент, даже если origin недоступен |
| `stale-while-revalidate=N` | Отдавать устаревший контент пока обновляем в фоне (N секунд) |
| `stale-if-error=N` | Отдавать устаревший контент если origin вернул ошибку |

**Рецепт для статических ассетов с хешем в имени:**
```http
Cache-Control: public, max-age=31536000, immutable
```

**Рецепт для HTML:**
```http
Cache-Control: public, max-age=0, s-maxage=300, stale-while-revalidate=60
```

**Рецепт для API:**
```http
Cache-Control: public, max-age=60, stale-while-revalidate=30
```

### Cache Invalidation в CDN

**Versioned URLs** — самый надёжный способ:
```
/static/app.a3f9c21d.js   ← хеш содержимого в имени файла
/static/logo.v4.png       ← явная версия
```
При изменении файла меняется URL → старый файл можно хранить вечно, новый сразу доступен.

**Purge API** — явный запрос на удаление из кеша:
```bash
# Cloudflare
curl -X DELETE "https://api.cloudflare.com/client/v4/zones/{zone_id}/purge_cache" \
  -H "Authorization: Bearer {token}" \
  -d '{"files":["https://example.com/api/products"]}'
```

**Surrogate Keys (Cache Tags)** — теги на контенте позволяют инвалидировать группу ресурсов:
```http
# Ответ origin включает теги
Surrogate-Key: product-42 category-electronics

# Инвалидация всего, что связано с product-42
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

Каждый уровень уменьшает нагрузку на следующий. Цель — чтобы 95%+ запросов отвечал браузерный или CDN кеш.

### CDN Провайдеры

| Провайдер | Когда выбирать |
|---|---|
| **Cloudflare** | Стартовая точка для большинства. Бесплатный tier, DDoS защита, Workers для edge computing, простая настройка |
| **Fastly** | Нужны Surrogate Keys, низкий TTL (~секунды), Varnish-совместимый VCL, быстрая инвалидация |
| **AWS CloudFront** | Уже на AWS инфраструктуре, нужна интеграция с S3/ALB/Lambda@Edge |
| **Akamai** | Enterprise, сложные требования, глобальная сеть в труднодоступных регионах |

---

## 6. Проблемы кеширования

### Cache Stampede (Thundering Herd)

**Проблема:** популярный ключ истекает. Сотни запросов одновременно идут в БД.

```
t=0:   ключ "popular_feed" протухает
t=1:   1000 запросов → cache miss
t=2:   1000 запросов идут в БД одновременно
t=3:   БД падает под нагрузкой
```

**Решение 1: Mutex / Singleflight**

Только один поток идёт в БД, остальные ждут результата.

**Решение 2: Stale-While-Revalidate**

Отдавать устаревшие данные, пока один поток обновляет в фоне.

**Решение 3: Probabilistic Early Expiration (XFetch)**

Каждый запрос с некоторой вероятностью обновляет кеш до истечения TTL. Вероятность растёт по мере приближения к TTL:

```
P(обновить) = -β * fetch_time * ln(rand())  > TTL - current_time
```

### Cache Penetration

**Проблема:** запросы к несуществующим ключам всегда идут в БД (нечего кешировать).

```
GET /users/99999999  → cache miss → db miss → кешировать нечего
GET /users/99999999  → cache miss → db miss → ...  (бесконечно)
```

**Решение 1: Кешировать null**

```go
const nullSentinel = "__null__"

user, err := r.db.GetUser(ctx, id)
if errors.Is(err, ErrNotFound) {
    // Кешируем факт отсутствия с коротким TTL
    r.redis.Set(ctx, key, nullSentinel, 30*time.Second)
    return nil, ErrNotFound
}
```

**Решение 2: Bloom Filter**

Вероятностная структура данных — проверяем существование объекта перед запросом в БД. False positive возможны, false negative — нет.

```go
import "github.com/bits-and-blooms/bloom/v3"

// При старте: заполняем фильтр всеми существующими ID
filter := bloom.NewWithEstimates(1_000_000, 0.01) // 1M элементов, 1% FPR
for _, id := range allUserIDs {
    filter.Add([]byte(strconv.FormatInt(id, 10)))
}

// При запросе
if !filter.Test([]byte(strconv.FormatInt(userID, 10))) {
    return nil, ErrNotFound // точно не существует
}
// Может существовать — идём в кеш/БД
```

### Cache Avalanche

**Проблема:** большое количество ключей протухает одновременно (например, при старте сервиса все TTL установлены в одно время).

```
t=0:   Деплой, кеш пуст, 10000 ключей загружаются с TTL=1h
t=1h:  Все 10000 ключей истекают одновременно
t=1h+: Лавина запросов в БД
```

**Решение: Jitter в TTL**

```go
func ttlWithJitter(base time.Duration) time.Duration {
    // Добавляем случайное отклонение ±10%
    jitter := time.Duration(rand.Int63n(int64(base / 5)))
    if rand.Intn(2) == 0 {
        return base + jitter
    }
    return base - jitter
}

r.redis.Set(ctx, key, data, ttlWithJitter(time.Hour))
```

Также: постепенный прогрев кеша (cache warming) при деплое.

### Stale Data

**Trade-off:** чем дольше TTL, тем быстрее система, но тем старее данные.

Выбор TTL определяется бизнес-требованиями:
- Баланс счёта: TTL = 0 (нельзя кешировать)
- Профиль пользователя: TTL = 5–60 минут
- Список товаров: TTL = 5–30 минут
- Курсы валют: TTL = 1–5 минут
- Статические страницы: TTL = часы–дни

### Пример на Go: Защита от Cache Stampede с singleflight

`golang.org/x/sync/singleflight` — группирует одинаковые запросы, выполняет один, результат возвращает всем.

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

    // Быстрый путь: проверяем кеш
    data, err := c.redis.Get(ctx, key).Bytes()
    if err == nil {
        var p Product
        json.Unmarshal(data, &p)
        return &p, nil
    }

    // Cache miss — используем singleflight
    // Все конкурентные вызовы с одним key ждут одного результата
    result, err, _ := c.group.Do(key, func() (any, error) {
        // Эта функция выполнится только один раз для конкурентных запросов
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

Третий возвращаемый параметр `Do` — `shared bool` — показывает, был ли результат возвращён нескольким вызовам. Полезно для метрик.

---

## 7. Инвалидация кеша

> "There are only two hard things in Computer Science: cache invalidation and naming things."
> — Phil Karlton

Инвалидация сложна потому, что нет универсального ответа на вопрос "когда данные в кеше устарели?". Каждый подход имеет компромиссы.

### TTL-based (Time-To-Live)

Самый простой подход: данные автоматически устаревают через заданное время.

```go
r.redis.Set(ctx, key, data, 5*time.Minute)
```

**Плюсы:** простота, нет дополнительной инфраструктуры.
**Минусы:** данные могут быть stale до истечения TTL; при слишком коротком TTL — высокая нагрузка на БД.

### Явный Purge через API

При записи сразу удаляем или обновляем кеш.

```go
func (s *ProductService) UpdateProduct(ctx context.Context, p *Product) error {
    if err := s.db.Update(ctx, p); err != nil {
        return err
    }
    // Инвалидация конкретного ключа
    s.cache.Del(ctx, fmt.Sprintf("product:%d", p.ID))
    // Инвалидация связанных списков
    s.cache.Del(ctx, fmt.Sprintf("products:category:%d", p.CategoryID))
    return nil
}
```

**Проблема:** tight coupling между сервисами. Если сервис А обновил данные, сервис Б должен знать, что ему нужно инвалидировать. Масштабируется плохо.

### Versioned Keys

Не инвалидируем, а меняем ключ при изменении данных.

```go
// Версия хранится отдельно
version, _ := r.redis.Get(ctx, "product:42:version").Int()
key := fmt.Sprintf("product:42:v%d", version)

// При обновлении
r.redis.Incr(ctx, "product:42:version")
// Старый ключ умрёт по TTL, новый будет вычитан из БД
```

**Плюсы:** атомарность без локов. **Минусы:** растёт количество ключей, нужна cleanup-стратегия.

### Event-Driven Invalidation

Сервис-источник публикует событие "данные изменились". Подписчики инвалидируют свои кеши.

```
┌──────────────┐    publish     ┌─────────────────┐
│ Product Svc  │ ─────────────► │   Kafka/NATS    │
│ (обновил     │                │  topic:         │
│  продукт 42) │                │  product.updated│
└──────────────┘                └────────┬────────┘
                                         │ subscribe
                          ┌──────────────┴──────────────┐
                          ▼                              ▼
                 ┌────────────────┐           ┌────────────────┐
                 │  Search Svc    │           │  Order Svc     │
                 │  (инвалидирует │           │  (инвалидирует │
                 │   кеш поиска)  │           │   кеш заказов) │
                 └────────────────┘           └────────────────┘
```

**Пример на Go: инвалидация через NATS**

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

// Subscribe запускает обработку событий инвалидации
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

    // Ждём закрытия контекста
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
            "products:featured", // глобальные списки тоже инвалидируем
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

// PublishInvalidation публикует событие инвалидации
func (c *CacheInvalidator) PublishInvalidation(ctx context.Context, event InvalidationEvent) error {
    data, err := json.Marshal(event)
    if err != nil {
        return err
    }
    subject := fmt.Sprintf("cache.invalidate.%s", event.EntityType)
    return c.nc.Publish(subject, data)
}
```

### Сравнение подходов

| Подход | Свежесть данных | Сложность | Coupling | Подходит для |
|---|---|---|---|---|
| TTL-based | Eventual (TTL задержка) | Минимальная | Нет | Большинство кешей |
| Purge on write | Немедленная | Низкая | Высокий | Один сервис |
| Versioned keys | Немедленная | Средняя | Нет | Версионируемые данные |
| Event-driven | Почти немедленная | Высокая | Слабый | Микросервисы |

---

## Итог

| Тема | Главное |
|---|---|
| Стратегии | Cache-Aside — для большинства; Write-Through — если нельзя stale reads; Write-Behind — для write-heavy с допустимыми потерями |
| Eviction | LRU по умолчанию; LFU при явно горячих данных; TTL всегда добавляй |
| Redis | Богатые структуры данных — используй нужную; Streams > Pub/Sub для надёжности; Lua для атомарных операций |
| CDN | s-maxage для CDN TTL; versioned URLs для статики; Surrogate Keys для точечной инвалидации |
| Проблемы | singleflight от stampede; bloom filter / null cache от penetration; jitter от avalanche |
| Инвалидация | TTL + event-driven = баланс простоты и свежести; versioned keys без coupling |

Кеширование — это trade-off между свежестью данных, нагрузкой на БД и сложностью системы. Нет универсального решения — всегда оцениваешь конкретный use case.
