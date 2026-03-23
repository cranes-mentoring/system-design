# Модуль 03: Базы данных

> **Цель модуля:** понять, как устроены реляционные и NoSQL базы данных изнутри, как принимать обоснованные решения при выборе БД, и как правильно работать с базами данных в Go-сервисах.

---

## Содержание

1. [SQL базы данных: PostgreSQL как основа](#1-sql-базы-данных-postgresql-как-основа)
2. [Индексы: как работают и когда замедляют](#2-индексы-как-работают-и-когда-замедляют)
3. [Транзакции и уровни изоляции](#3-транзакции-и-уровни-изоляции)
4. [Блокировки (Locks)](#4-блокировки-locks)
5. [NoSQL базы данных: когда и какие](#5-nosql-базы-данных-когда-и-какие)
6. [Как выбирать базу данных](#6-как-выбирать-базу-данных)
7. [Connection pooling и работа с БД в Go](#7-connection-pooling-и-работа-с-бд-в-go)

---

## 1. SQL базы данных: PostgreSQL как основа

### Почему PostgreSQL — стандарт для бэкенда

PostgreSQL — не просто «ещё одна реляционная БД». Это система, которая за 30+ лет эволюции стала де-факто стандартом для продакшн-бэкенда. Ключевые причины:

- **ACID из коробки** — транзакции, уровни изоляции, MVCC без дополнительных настроек
- **Богатая типизация** — `JSONB`, массивы, `hstore`, `UUID`, `ENUM`, диапазоны, геометрические типы
- **Расширяемость** — PostGIS (геоданные), TimescaleDB (time-series), pg_vector (embeddings)
- **Зрелый оптимизатор запросов** — cost-based planner с поддержкой статистики
- **Надёжность** — WAL, point-in-time recovery, streaming replication
- **Лицензия** — PostgreSQL License (MIT-подобная), без vendor lock-in

MySQL проигрывает по возможностям типизации и MVCC-реализации. SQLite — только для embedded-сценариев. Oracle/MSSQL — платные с vendor lock-in. **PostgreSQL — очевидный выбор.**

---

### Архитектура PostgreSQL

```
┌─────────────────────────────────────────────────────────────┐
│                    PostgreSQL Process Model                  │
│                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌───────────────┐ │
│  │   Backend 1  │    │   Backend 2  │    │   Backend N   │ │
│  │ (per client) │    │ (per client) │    │ (per client)  │ │
│  └──────┬───────┘    └──────┬───────┘    └───────┬───────┘ │
│         │                  │                     │         │
│  ┌──────▼──────────────────▼─────────────────────▼───────┐ │
│  │                   Shared Memory                        │ │
│  │  ┌───────────────┐  ┌──────────────┐  ┌────────────┐  │ │
│  │  │  Shared Buffer│  │   WAL Buffer │  │ Lock Table │  │ │
│  │  │  (shared_buf) │  │  (wal_buffers│  │            │  │ │
│  │  └───────────────┘  └──────────────┘  └────────────┘  │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                             │
│  ┌──────────────┐  ┌───────────────┐  ┌─────────────────┐  │
│  │  WAL Writer  │  │  Checkpointer │  │  Autovacuum     │  │
│  │  (фоновый)   │  │  (фоновый)    │  │  Launcher       │  │
│  └──────────────┘  └───────────────┘  └─────────────────┘  │
│                                                             │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                    Disk Storage                         │ │
│  │  ┌──────────────┐  ┌─────────────┐  ┌──────────────┐  │ │
│  │  │  Data Files  │  │  WAL Files  │  │  pg_clog/    │  │ │
│  │  │  (heap, idx) │  │  (pg_wal/)  │  │  pg_xact/    │  │ │
│  │  └──────────────┘  └─────────────┘  └──────────────┘  │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

**Ключевые компоненты:**

| Компонент | Роль |
|-----------|------|
| **Backend process** | Один процесс на клиентское соединение. Обрабатывает запросы, читает/пишет в shared buffer |
| **Shared Buffer** | Кэш страниц в памяти. По умолчанию 128MB — в продакшне ставим 25-40% RAM |
| **WAL (Write-Ahead Log)** | Журнал изменений. Сначала пишем в WAL, потом в данные. Основа durability и репликации |
| **WAL Writer** | Флашит WAL-буфер на диск асинхронно |
| **Checkpointer** | Периодически сбрасывает dirty pages из shared buffer на диск |
| **Autovacuum** | Очищает dead tuples после UPDATE/DELETE (следствие MVCC) |

**WAL и durability:** при `COMMIT` PostgreSQL гарантирует, что запись попала в WAL на диске (`fsync`). Даже при падении сервера данные восстановятся replay'ем WAL. Это и есть **D** из ACID.

---

### Типы данных: когда что использовать

#### JSONB vs нормализация vs массивы

```
Принцип выбора:

  Данные имеют фиксированную схему?
  ├── ДА → нормализация (таблицы + FK)
  └── НЕТ → данные меняются от записи к записи?
              ├── ДА, произвольная структура → JSONB
              └── ДА, но однотипные элементы → массивы PostgreSQL
```

**Когда JSONB:**
- Атрибуты товаров в каталоге (у телефона — `battery_mah`, у футболки — `sizes`)
- Настройки пользователя с произвольными ключами
- Данные от внешних API с нестабильной схемой
- Прототипирование (потом можно мигрировать)

```sql
-- Каталог товаров: у каждого товара своя схема атрибутов
CREATE TABLE products (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT NOT NULL,
    category    TEXT NOT NULL,
    price       NUMERIC(10,2) NOT NULL,
    attributes  JSONB NOT NULL DEFAULT '{}'
);

-- Телефон
INSERT INTO products (name, category, price, attributes) VALUES (
    'iPhone 16 Pro', 'phones', 99999.00,
    '{"battery_mah": 3274, "storage_gb": 256, "5g": true, "colors": ["black", "white"]}'
);

-- Футболка
INSERT INTO products (name, category, price, attributes) VALUES (
    'Basic Tee', 'clothing', 999.00,
    '{"sizes": ["XS","S","M","L","XL"], "material": "cotton", "gender": "unisex"}'
);

-- Поиск по JSONB-полю (требует GIN индекс)
SELECT name, attributes->>'battery_mah' AS battery
FROM products
WHERE category = 'phones'
  AND (attributes->>'battery_mah')::int > 3000;

-- GIN индекс для эффективного поиска
CREATE INDEX idx_products_attributes ON products USING GIN (attributes);

-- Оператор @> — проверка containment
SELECT name FROM products
WHERE attributes @> '{"5g": true}';
```

**Когда массивы PostgreSQL:**
- Теги, метки (фиксированный тип, набор значений)
- Список ID (но лучше нормализовать через junction table)
- Временны́е метки событий

```sql
CREATE TABLE articles (
    id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    tags  TEXT[] NOT NULL DEFAULT '{}'
);

-- GIN индекс для поиска по тегам
CREATE INDEX idx_articles_tags ON articles USING GIN (tags);

-- Статьи с тегом 'golang'
SELECT title FROM articles WHERE tags @> ARRAY['golang'];

-- Пересечение тегов
SELECT title FROM articles WHERE tags && ARRAY['golang', 'databases'];
```

**Когда нормализация:**
- Данные, по которым делаются JOIN-ы
- Данные, которые нужно изменять атомарно
- Когда важна referential integrity

---

### Пример на Go: подключение через pgx

```go
package db

import (
    "context"
    "fmt"
    "time"

    "github.com/jackc/pgx/v5"
    "github.com/jackc/pgx/v5/pgxpool"
)

// Config параметры пула соединений
type Config struct {
    DSN             string
    MaxConns        int32
    MinConns        int32
    MaxConnLifetime time.Duration
    MaxConnIdleTime time.Duration
}

// NewPool создаёт пул соединений pgxpool
func NewPool(ctx context.Context, cfg Config) (*pgxpool.Pool, error) {
    poolCfg, err := pgxpool.ParseConfig(cfg.DSN)
    if err != nil {
        return nil, fmt.Errorf("parse dsn: %w", err)
    }

    poolCfg.MaxConns = cfg.MaxConns
    poolCfg.MinConns = cfg.MinConns
    poolCfg.MaxConnLifetime = cfg.MaxConnLifetime
    poolCfg.MaxConnIdleTime = cfg.MaxConnIdleTime

    // Хук после создания соединения — можно установить session-параметры
    poolCfg.AfterConnect = func(ctx context.Context, conn *pgx.Conn) error {
        // Устанавливаем таймзону для сессии
        _, err := conn.Exec(ctx, "SET timezone = 'UTC'")
        return err
    }

    pool, err := pgxpool.NewWithConfig(ctx, poolCfg)
    if err != nil {
        return nil, fmt.Errorf("create pool: %w", err)
    }

    // Проверяем соединение
    if err := pool.Ping(ctx); err != nil {
        return nil, fmt.Errorf("ping db: %w", err)
    }

    return pool, nil
}

// Пример использования: CRUD с prepared statements
type UserRepository struct {
    pool *pgxpool.Pool
}

type User struct {
    ID        string
    Email     string
    CreatedAt time.Time
}

func NewUserRepository(pool *pgxpool.Pool) *UserRepository {
    return &UserRepository{pool: pool}
}

// GetByID — pgx кэширует prepared statement автоматически
func (r *UserRepository) GetByID(ctx context.Context, id string) (*User, error) {
    const query = `
        SELECT id, email, created_at
        FROM users
        WHERE id = $1
    `
    var u User
    err := r.pool.QueryRow(ctx, query, id).Scan(&u.ID, &u.Email, &u.CreatedAt)
    if err != nil {
        return nil, fmt.Errorf("get user %s: %w", id, err)
    }
    return &u, nil
}

// ListByEmails — batch запрос
func (r *UserRepository) ListByEmails(ctx context.Context, emails []string) ([]User, error) {
    const query = `
        SELECT id, email, created_at
        FROM users
        WHERE email = ANY($1)
        ORDER BY created_at DESC
    `
    rows, err := r.pool.Query(ctx, query, emails)
    if err != nil {
        return nil, fmt.Errorf("list users: %w", err)
    }
    defer rows.Close()

    var users []User
    for rows.Next() {
        var u User
        if err := rows.Scan(&u.ID, &u.Email, &u.CreatedAt); err != nil {
            return nil, fmt.Errorf("scan user: %w", err)
        }
        users = append(users, u)
    }
    return users, rows.Err()
}

// Create с возвратом сгенерированного ID
func (r *UserRepository) Create(ctx context.Context, email string) (*User, error) {
    const query = `
        INSERT INTO users (email, created_at)
        VALUES ($1, NOW())
        RETURNING id, email, created_at
    `
    var u User
    err := r.pool.QueryRow(ctx, query, email).Scan(&u.ID, &u.Email, &u.CreatedAt)
    if err != nil {
        return nil, fmt.Errorf("create user: %w", err)
    }
    return &u, nil
}
```

**Почему pgx, а не `database/sql`:**
- Нативная поддержка PostgreSQL-типов (массивы, JSONB, UUID без обёрток)
- Лучшая производительность (меньше аллокаций)
- `pgxpool` — встроенный пул с расширенными настройками
- Поддержка Copy Protocol для bulk-вставок
- Батчевые запросы (`SendBatch`)

---

## 2. Индексы: как работают и когда замедляют

### B-tree: структура и механика поиска

B-tree (Balanced Tree) — индекс по умолчанию в PostgreSQL. Понимание его структуры объясняет, почему одни запросы используют индекс, другие — нет.

```
B-tree для колонки age в таблице users:

                    ┌─────────┐
                    │  [35]   │   ← Root (уровень 3)
                    └────┬────┘
          ┌─────────────┘└─────────────┐
     ┌────▼────┐                  ┌────▼────┐
     │ [18,25] │                  │ [45,60] │  ← Internal nodes (уровень 2)
     └────┬────┘                  └────┬────┘
   ┌──────┼──────┐              ┌──────┼──────┐
┌──▼──┐ ┌─▼──┐ ┌─▼──┐       ┌──▼──┐ ┌─▼──┐ ┌─▼──┐
│15,17│ │18,24│ │25,34│      │35,44│ │45,59│ │60+ │  ← Leaf nodes (уровень 1)
└──┬──┘ └──┬──┘ └──┬──┘      └──┬──┘ └──┬──┘ └──┬──┘
   ↓       ↓       ↓             ↓       ↓       ↓
 heap    heap    heap           heap    heap    heap
pages   pages   pages          pages   pages   pages

Leaf nodes связаны двусвязным списком → эффективны range scans
```

**Оценка глубины B-tree:**
- Каждый page = 8KB
- На один node помещается ~200-400 ключей (зависит от размера ключа)
- Глубина = log₃₀₀(N) ≈ 3-4 уровня для таблиц до 100M строк
- **Вывод:** поиск по индексу = 3-4 disk I/O независимо от размера таблицы

**Когда B-tree НЕ используется:**
```sql
-- ❌ Функция над колонкой → индекс не используется
SELECT * FROM users WHERE LOWER(email) = 'user@example.com';

-- ✅ Решение: functional index
CREATE INDEX idx_users_email_lower ON users (LOWER(email));

-- ❌ LIKE с префиксным wildcard
SELECT * FROM users WHERE name LIKE '%smith';

-- ✅ Для суффиксного поиска нужен GIN/trgm индекс
CREATE EXTENSION pg_trgm;
CREATE INDEX idx_users_name_trgm ON users USING GIN (name gin_trgm_ops);

-- ❌ Неявное приведение типов
SELECT * FROM users WHERE id = 42;  -- id VARCHAR, 42 INTEGER → cast убивает индекс

-- ✅ Явное приведение или правильный тип
SELECT * FROM users WHERE id = '42';
```

---

### Типы индексов

| Тип | Алгоритм | Use case | Оператор |
|-----|----------|----------|----------|
| **B-tree** | Balanced Tree | =, <, >, BETWEEN, LIKE 'prefix%', ORDER BY | `<`, `>`, `=`, `BETWEEN` |
| **Hash** | Hash table | Только `=`, чуть быстрее B-tree при точных совпадениях | `=` |
| **GIN** | Inverted index | JSONB, массивы, full-text search | `@>`, `&&`, `@@` |
| **GiST** | Generalized Search Tree | Геоданные (PostGIS), диапазоны, nearest-neighbor | `&&`, `<<`, `@>` |
| **BRIN** | Block Range Index | Очень большие таблицы с коррелированными данными (logs, time-series) | `<`, `>`, `BETWEEN` |
| **SP-GiST** | Space-Partitioned GiST | IP-адреса, телефонные номера, точки | `<<`, `>>` |

**GIN — детально:**
```sql
-- Full-text search
CREATE INDEX idx_articles_fts ON articles
    USING GIN (to_tsvector('russian', title || ' ' || body));

SELECT title
FROM articles
WHERE to_tsvector('russian', title || ' ' || body) @@ to_tsquery('russian', 'база & данных');

-- JSONB containment
CREATE INDEX idx_products_attrs ON products USING GIN (attributes);

-- Поиск всех продуктов с определённым атрибутом
SELECT * FROM products WHERE attributes @> '{"in_stock": true}';
```

**BRIN — когда применять:**
```sql
-- Таблица логов: записи упорядочены по времени вставки
CREATE TABLE access_logs (
    id         BIGSERIAL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    user_id    UUID,
    endpoint   TEXT,
    status     INT
);

-- BRIN хранит только min/max для каждого диапазона страниц
-- Размер: ~100x меньше B-tree, эффективен для range scans по created_at
CREATE INDEX idx_logs_created_brin ON access_logs USING BRIN (created_at);

-- B-tree здесь был бы избыточен — данные и так физически упорядочены
```

---

### Составные индексы: порядок колонок имеет значение

```sql
-- Таблица заказов
CREATE TABLE orders (
    id         UUID PRIMARY KEY,
    user_id    UUID NOT NULL,
    status     TEXT NOT NULL,  -- 'pending', 'paid', 'shipped', 'done'
    created_at TIMESTAMPTZ NOT NULL
);

-- Составной индекс
CREATE INDEX idx_orders_user_status ON orders (user_id, status);
```

**Правило leftmost prefix:** составной индекс `(user_id, status)` используется для:
- `WHERE user_id = $1` ✅
- `WHERE user_id = $1 AND status = $2` ✅
- `WHERE user_id = $1 ORDER BY status` ✅
- `WHERE status = $1` ❌ (только status — не leftmost prefix)

```
Визуализация:

Индекс (user_id, status):

user_id=A, status='paid'   → TID(1,5)
user_id=A, status='pending'→ TID(2,1)
user_id=A, status='shipped'→ TID(3,8)
user_id=B, status='done'   → TID(1,2)
user_id=B, status='paid'   → TID(4,3)

Запрос WHERE user_id=A → читаем первые 3 строки подряд ✅
Запрос WHERE status='paid' → нужно сканировать весь индекс ❌
```

**Как выбрать порядок:**
1. Колонки с `=` — первыми
2. Высокая кардинальность — первой (если равнозначны по selectivity)
3. Колонки с range (`>`, `<`) — последними
4. Колонки из `ORDER BY` — последними

---

### Покрывающие индексы (INCLUDE)

```sql
-- Без INCLUDE: Index Scan → heap fetch для каждой строки
CREATE INDEX idx_orders_user ON orders (user_id);

-- С INCLUDE: Index Only Scan — heap не читается вообще
CREATE INDEX idx_orders_user_cover ON orders (user_id) INCLUDE (status, created_at);

-- Этот запрос теперь выполняется только по индексу:
SELECT status, created_at
FROM orders
WHERE user_id = $1
ORDER BY created_at DESC;
```

**Разница `(a, b)` vs `(a) INCLUDE (b)`:**
- `(a, b)` — `b` участвует в структуре B-tree, влияет на порядок, можно фильтровать по `b`
- `(a) INCLUDE (b)` — `b` хранится только в leaf nodes, не влияет на структуру, не для фильтрации

---

### Partial indexes

```sql
-- Индекс только по активным пользователям (99% запросов — по активным)
CREATE INDEX idx_users_active_email ON users (email)
WHERE deleted_at IS NULL;

-- Очередь задач: индекс только по необработанным
CREATE INDEX idx_jobs_pending ON jobs (created_at)
WHERE status = 'pending';

-- Уникальность только среди активных записей
CREATE UNIQUE INDEX idx_users_unique_active_email ON users (email)
WHERE deleted_at IS NULL;
```

Partial index меньше по размеру и быстрее обновляется, так как затрагивает только часть строк.

---

### EXPLAIN ANALYZE: читаем план запроса

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT u.id, u.email, COUNT(o.id) AS order_count
FROM users u
LEFT JOIN orders o ON o.user_id = u.id
WHERE u.created_at > NOW() - INTERVAL '30 days'
GROUP BY u.id, u.email
ORDER BY order_count DESC
LIMIT 100;
```

**Пример вывода и как читать:**

```
Limit  (cost=1842.50..1842.75 rows=100 width=48)
       (actual time=24.321..24.334 rows=100 loops=1)
  ->  Sort  (cost=1842.50..1852.50 rows=4000 width=48)
            (actual time=24.319..24.325 rows=100 loops=1)
        Sort Key: (count(o.id)) DESC
        Sort Method: top-N heapsort  Memory: 32kB
        ->  HashAggregate  (cost=1620.00..1660.00 rows=4000 width=48)
                           (actual time=22.1..23.8 rows=4000 loops=1)
              Group Key: u.id
              ->  Hash Left Join  (cost=850.00..1520.00 rows=20000 width=40)
                                  (actual time=8.5..19.2 rows=20000 loops=1)
                    Hash Cond: (o.user_id = u.id)
                    ->  Seq Scan on orders o  (cost=0.00..420.00 rows=20000 width=16)
                                              (actual time=0.1..4.2 rows=20000 loops=1)
                    ->  Hash  (cost=800.00..800.00 rows=4000 width=32)
                               (actual time=8.1..8.1 rows=4000 loops=1)
                          Buckets: 4096  Batches: 1  Memory Usage: 256kB
                          ->  Index Scan using idx_users_created ON users u
                                (cost=0.43..800.00 rows=4000 width=32)
                                (actual time=0.05..6.8 rows=4000 loops=1)
                                Index Cond: (created_at > (now() - '30 days'::interval))
Planning Time: 1.2 ms
Execution Time: 24.5 ms
```

**Ключевые метрики:**

| Термин | Что означает | На что смотреть |
|--------|-------------|-----------------|
| `cost=X..Y` | Оценка планировщика (условные единицы). X — startup cost, Y — total cost | Если сильно расходится с actual — устаревшая статистика |
| `actual time=X..Y` | Реальное время в ms. X — первая строка, Y — все строки | Y — это время, которое видит пользователь |
| `rows=N` | Оценка vs actual | Большое расхождение → `ANALYZE` таблицы |
| `loops=N` | Сколько раз выполнялся узел | В Nested Loop часто loops=1000, умножайте actual time на loops |
| **Seq Scan** | Полный перебор таблицы | Ок для маленьких таблиц (<1000 строк) или когда читаем >20% строк |
| **Index Scan** | Читает индекс + heap fetch для каждой строки | Оптимален при selectivity <5-10% |
| **Index Only Scan** | Только индекс, heap не читается | Идеал для покрывающих индексов |
| **Bitmap Scan** | Строит bitmap совпадений, потом читает heap пачками | Компромисс при 5-20% строк |
| **Nested Loop** | Для каждой строки внешнего набора → lookup во внутреннем | Быстр при малом числе строк; катастрофа при больших наборах |
| **Hash Join** | Строит hash table из меньшего набора | Хорош для больших наборов без индекса |
| **Merge Join** | Join отсортированных наборов | Эффективен, если данные уже отсортированы |
| `Buffers: hit=N read=M` | hit — из кэша, read — с диска | Много read при первом запуске, потом должно быть hit |

**Красные флаги в плане:**
```sql
-- 🚩 Seq Scan на большой таблице при фильтрации
Seq Scan on orders  (rows=5000000)
Filter: (status = 'pending')
Rows Removed by Filter: 4990000  ← читаем 5M, нужно 10K

-- 🚩 Nested Loop с большим loops
Nested Loop (loops=50000)
  ->  Index Scan on products (loops=50000)  ← 50000 * actual_time!

-- 🚩 Плохая оценка строк
Hash Join (estimated rows=10 vs actual rows=100000)
← планировщик не знает реального распределения → ANALYZE
```

---

### Anti-patterns с индексами

```sql
-- ❌ Индекс на каждую колонку — замедляет INSERT/UPDATE/DELETE
-- Каждый индекс нужно обновлять при изменении строки
CREATE INDEX ON orders (id);           -- уже есть PK
CREATE INDEX ON orders (user_id);
CREATE INDEX ON orders (status);
CREATE INDEX ON orders (created_at);
CREATE INDEX ON orders (updated_at);
CREATE INDEX ON orders (payment_id);
-- ... 15 индексов на одну таблицу

-- ✅ Составной индекс для реальных паттернов запросов
CREATE INDEX ON orders (user_id, status) INCLUDE (created_at);

-- Найти неиспользуемые индексы (после достаточного времени работы)
SELECT schemaname, tablename, indexname, idx_scan
FROM pg_stat_user_indexes
WHERE idx_scan = 0
ORDER BY pg_relation_size(indexrelid) DESC;

-- ❌ Индекс на колонку с низкой кардинальностью (boolean, enum с 3 значениями)
-- PostgreSQL часто выберет Seq Scan вместо него
CREATE INDEX ON orders (is_deleted);  -- 99% строк is_deleted=false

-- ✅ Partial index для таких случаев
CREATE INDEX ON orders (created_at) WHERE is_deleted = false;
```

---

## 3. Транзакции и уровни изоляции

### ACID на практике

**A — Atomicity (Атомарность):** транзакция либо выполняется целиком, либо откатывается полностью. Нет промежуточного состояния.

```sql
-- Перевод денег: либо оба UPDATE, либо ни один
BEGIN;
UPDATE accounts SET balance = balance - 1000 WHERE id = 'alice';
UPDATE accounts SET balance = balance + 1000 WHERE id = 'bob';
-- Если второй UPDATE упадёт → первый тоже откатится
COMMIT;
```

**C — Consistency (Согласованность):** транзакция переводит БД из одного consistent state в другой. Все constraints (FK, CHECK, UNIQUE) соблюдены.

**I — Isolation (Изолированность):** параллельные транзакции не видят незакоммиченные изменения друг друга (степень зависит от уровня изоляции).

**D — Durability (Долговечность):** после `COMMIT` данные записаны на диск (WAL), переживут сбой сервера.

---

### Проблемы конкурентного доступа

```
Transaction 1                    Transaction 2
─────────────────────────────────────────────────────

Dirty Read:
BEGIN                            BEGIN
                                 UPDATE bal = 500 WHERE id=1
READ bal → 500 (незакоммит!)
                                 ROLLBACK (возврат к 200)
ИСПОЛЬЗУЕТ 500 ← неверно!

Non-Repeatable Read:
BEGIN
READ bal → 200
                                 BEGIN
                                 UPDATE bal = 500; COMMIT
READ bal → 500 ← уже другое!
COMMIT

Phantom Read:
BEGIN
SELECT COUNT(*) → 10 rows
                                 BEGIN
                                 INSERT new_row; COMMIT
SELECT COUNT(*) → 11 rows ← фантом!
COMMIT

Serialization Anomaly (Write Skew):
BEGIN                            BEGIN
READ: doctors_on_call = 2        READ: doctors_on_call = 2
  (оба видят: можно уйти)          (оба видят: можно уйти)
UPDATE set on_call=false         UPDATE set on_call=false
COMMIT                           COMMIT
← Итог: 0 дежурных врачей! ← нарушена бизнес-инвариант
```

---

### Уровни изоляции

| Уровень | Dirty Read | Non-Repeatable Read | Phantom Read | Serialization Anomaly |
|---------|-----------|--------------------|--------------|-----------------------|
| **Read Uncommitted** | ✅ возможен | ✅ возможен | ✅ возможен | ✅ возможен |
| **Read Committed** | ❌ защита | ✅ возможен | ✅ возможен | ✅ возможен |
| **Repeatable Read** | ❌ защита | ❌ защита | ❌ защита (в PG) | ✅ возможен |
| **Serializable** | ❌ защита | ❌ защита | ❌ защита | ❌ защита |

> **Примечание:** PostgreSQL реализует Repeatable Read через MVCC таким образом, что Phantom Read тоже предотвращается — это лучше, чем требует стандарт SQL.

**PostgreSQL по умолчанию: Read Committed**

```sql
-- Что это значит на практике:
-- Каждый оператор видит снимок данных на момент своего начала,
-- НЕ на момент начала транзакции.

BEGIN; -- Уровень: Read Committed (default)

-- Снимок 1: видим данные на T1
SELECT balance FROM accounts WHERE id = 1; -- → 1000

-- Другая транзакция делает: UPDATE accounts SET balance=500 WHERE id=1; COMMIT;

-- Снимок 2: новый снимок для этого SELECT
SELECT balance FROM accounts WHERE id = 1; -- → 500 (уже видим коммит!)

COMMIT;
```

Это значит: **в рамках одной транзакции с Read Committed вы можете видеть разные значения одной строки**. Для большинства CRUD-операций это приемлемо. Для финансовых расчётов — нет.

---

### MVCC: изоляция без блокировок чтения

MVCC (Multi-Version Concurrency Control) — ключевое решение PostgreSQL для производительности.

```
Физическая структура heap page:

┌────────────────────────────────────────────────────────┐
│ Tuple 1: xmin=100, xmax=0,   data="alice, bal=1000"   │ ← активная
│ Tuple 2: xmin=101, xmax=103, data="alice, bal=800"    │ ← устаревшая
│ Tuple 3: xmin=103, xmax=0,   data="alice, bal=1200"   │ ← активная
└────────────────────────────────────────────────────────┘

xmin = транзакция, которая создала tuple
xmax = транзакция, которая удалила/обновила tuple (0 = живая)

UPDATE = INSERT новой версии + установка xmax старой
DELETE = установка xmax текущей транзакцией
```

**Как транзакция видит данные:**
1. При старте запрос получает `snapshot` — список активных транзакций
2. Tuple видим, если `xmin` завершён (committed) ДО snapshot И `xmax` не завершён
3. Читающая транзакция **не ставит блокировок** — пишущая её не блокирует

**Следствие: Autovacuum**

MVCC создаёт dead tuples — старые версии строк. Autovacuum их убирает:
```sql
-- Мониторинг bloat и vacuum
SELECT relname, n_dead_tup, n_live_tup,
       last_autovacuum, last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;
```

---

### Пример на Go: управление транзакциями с pgx

```go
package transaction

import (
    "context"
    "fmt"

    "github.com/jackc/pgx/v5"
    "github.com/jackc/pgx/v5/pgxpool"
)

// TransferMoney — атомарный перевод денег
func TransferMoney(ctx context.Context, pool *pgxpool.Pool, fromID, toID string, amount int64) error {
    return withTx(ctx, pool, pgx.TxOptions{
        IsoLevel: pgx.Serializable, // для финансовых операций
    }, func(tx pgx.Tx) error {
        // Блокируем строки в консистентном порядке (по ID) для предотвращения deadlock
        ids := []string{fromID, toID}
        if fromID > toID {
            ids = []string{toID, fromID}
        }

        var balFrom, balTo int64

        // Читаем с блокировкой
        err := tx.QueryRow(ctx,
            `SELECT balance FROM accounts WHERE id = $1 FOR UPDATE`, ids[0],
        ).Scan(&balFrom)
        if err != nil {
            return fmt.Errorf("lock account %s: %w", ids[0], err)
        }

        err = tx.QueryRow(ctx,
            `SELECT balance FROM accounts WHERE id = $1 FOR UPDATE`, ids[1],
        ).Scan(&balTo)
        if err != nil {
            return fmt.Errorf("lock account %s: %w", ids[1], err)
        }

        if fromID == ids[0] {
            balFrom, balTo = balFrom, balTo
        } else {
            balFrom, balTo = balTo, balFrom
        }

        if balFrom < amount {
            return fmt.Errorf("insufficient funds: have %d, need %d", balFrom, amount)
        }

        // Дебетуем
        _, err = tx.Exec(ctx,
            `UPDATE accounts SET balance = balance - $1 WHERE id = $2`,
            amount, fromID,
        )
        if err != nil {
            return fmt.Errorf("debit %s: %w", fromID, err)
        }

        // Кредитуем
        _, err = tx.Exec(ctx,
            `UPDATE accounts SET balance = balance + $1 WHERE id = $2`,
            amount, toID,
        )
        if err != nil {
            return fmt.Errorf("credit %s: %w", toID, err)
        }

        return nil
    })
}

// withTx — обёртка для транзакции с автоматическим rollback
func withTx(ctx context.Context, pool *pgxpool.Pool, opts pgx.TxOptions, fn func(pgx.Tx) error) error {
    tx, err := pool.BeginTx(ctx, opts)
    if err != nil {
        return fmt.Errorf("begin tx: %w", err)
    }

    defer func() {
        if p := recover(); p != nil {
            _ = tx.Rollback(ctx)
            panic(p)
        }
    }()

    if err := fn(tx); err != nil {
        if rbErr := tx.Rollback(ctx); rbErr != nil {
            return fmt.Errorf("rollback failed: %v (original: %w)", rbErr, err)
        }
        return err
    }

    return tx.Commit(ctx)
}
```

---

## 4. Блокировки (Locks)

### Row-level locks

```sql
-- FOR UPDATE: эксклюзивная блокировка строки
-- Другие транзакции не могут делать FOR UPDATE / FOR SHARE пока не снимем
BEGIN;
SELECT * FROM jobs WHERE id = $1 FOR UPDATE;
-- Теперь безопасно обновлять — никто другой не обработает эту задачу
UPDATE jobs SET status = 'processing', worker_id = $2 WHERE id = $1;
COMMIT;

-- FOR UPDATE SKIP LOCKED: для очередей задач
-- Не блокируется на занятых строках, пропускает их
SELECT id, payload
FROM jobs
WHERE status = 'pending'
ORDER BY created_at
LIMIT 10
FOR UPDATE SKIP LOCKED;

-- FOR SHARE: разделяемая блокировка (несколько транзакций могут держать одновременно)
-- Блокирует FOR UPDATE, но не блокирует другие FOR SHARE
SELECT * FROM users WHERE id = $1 FOR SHARE;
```

**Матрица совместимости блокировок:**

| | FOR UPDATE | FOR NO KEY UPDATE | FOR SHARE | FOR KEY SHARE |
|---|---|---|---|---|
| **FOR UPDATE** | ❌ | ❌ | ❌ | ❌ |
| **FOR NO KEY UPDATE** | ❌ | ❌ | ❌ | ✅ |
| **FOR SHARE** | ❌ | ❌ | ✅ | ✅ |
| **FOR KEY SHARE** | ❌ | ✅ | ✅ | ✅ |

---

### Advisory locks

Advisory locks — кастомные блокировки на уровне приложения. PostgreSQL только хранит их состояние, семантику определяете вы.

```sql
-- Сессионные advisory locks (живут до конца сессии или явного unlock)
SELECT pg_try_advisory_lock(12345);  -- false если уже заблокировано

-- Транзакционные advisory locks (снимаются при COMMIT/ROLLBACK)
SELECT pg_try_advisory_xact_lock(hashtext('job:processor:' || job_id::text));

-- Разблокировка
SELECT pg_advisory_unlock(12345);
```

**Типичные use cases:**
- Distributed mutex для cron-задач (один инстанс в кластере)
- Блокировка обработки конкретного объекта (без блокировки строки)
- Pessimistic lock для ресурсов вне БД

```go
// Go: distributed lock через advisory lock
func acquireJobLock(ctx context.Context, tx pgx.Tx, jobID int64) (bool, error) {
    var acquired bool
    err := tx.QueryRow(ctx,
        `SELECT pg_try_advisory_xact_lock($1)`, jobID,
    ).Scan(&acquired)
    return acquired, err
}
```

---

### Deadlocks

```
Deadlock:

Transaction 1                    Transaction 2
─────────────────────────────────────────────
LOCK account A (success)
                                 LOCK account B (success)
LOCK account B → waiting...
                                 LOCK account A → waiting...
↑ Circular dependency → deadlock!
```

**PostgreSQL обнаруживает deadlock** через граф ожидания (wait-for graph). При обнаружении цикла — прерывает одну транзакцию с ошибкой `ERROR: deadlock detected`.

**Как избежать deadlock:**

```sql
-- ❌ Проблема: транзакции блокируют в разном порядке
-- TX1: LOCK A, затем LOCK B
-- TX2: LOCK B, затем LOCK A

-- ✅ Решение: всегда блокировать в консистентном порядке
-- Сортируем IDs перед блокировкой
SELECT * FROM accounts
WHERE id = ANY($1::uuid[])
ORDER BY id  -- фиксированный порядок!
FOR UPDATE;
```

```go
// Go: блокировка нескольких строк в консистентном порядке
func lockAccounts(ctx context.Context, tx pgx.Tx, ids []string) error {
    // Сортируем для консистентного порядка блокировки
    sort.Strings(ids)

    _, err := tx.Exec(ctx, `
        SELECT id FROM accounts
        WHERE id = ANY($1)
        ORDER BY id
        FOR UPDATE
    `, ids)
    return err
}
```

---

### Оптимистическая vs пессимистическая блокировка

```
Пессимистическая: блокирую, потом читаю/пишу
────────────────────────────────────────────
TX1: SELECT FOR UPDATE → ждём освобождения
TX2: SELECT FOR UPDATE → блокируется на TX1
← Подходит: высокая конкуренция за одни строки

Оптимистическая: читаю без блокировки, проверяю при записи
────────────────────────────────────────────────────────────
TX1: READ version=5
TX2: READ version=5
TX1: UPDATE WHERE version=5, SET version=6 → success
TX2: UPDATE WHERE version=5, SET version=6 → 0 rows! → retry
← Подходит: низкая конкуренция, много reads, мало conflicts
```

**Пример оптимистической блокировки на Go:**

```go
type Product struct {
    ID      string
    Name    string
    Price   int64
    Version int64  // optimistic lock column
}

func (r *ProductRepository) UpdatePrice(ctx context.Context, productID string, newPrice int64) error {
    maxRetries := 3

    for attempt := 0; attempt < maxRetries; attempt++ {
        // Читаем текущую версию
        var p Product
        err := r.pool.QueryRow(ctx,
            `SELECT id, name, price, version FROM products WHERE id = $1`,
            productID,
        ).Scan(&p.ID, &p.Name, &p.Price, &p.Version)
        if err != nil {
            return fmt.Errorf("read product: %w", err)
        }

        // Обновляем с проверкой версии
        result, err := r.pool.Exec(ctx, `
            UPDATE products
            SET price = $1, version = version + 1
            WHERE id = $2 AND version = $3
        `, newPrice, productID, p.Version)
        if err != nil {
            return fmt.Errorf("update product: %w", err)
        }

        if result.RowsAffected() == 1 {
            return nil // успешно обновили
        }

        // version изменилась — другая транзакция обновила раньше нас
        // Повторяем попытку
        if attempt < maxRetries-1 {
            time.Sleep(time.Duration(attempt+1) * 10 * time.Millisecond) // backoff
        }
    }

    return fmt.Errorf("optimistic lock: max retries exceeded for product %s", productID)
}
```

**Пессимистическая блокировка с SELECT FOR UPDATE:**

```sql
-- Очередь задач: один воркер берёт задачу атомарно
BEGIN;

SELECT id, payload, attempts
FROM jobs
WHERE status = 'pending'
  AND scheduled_at <= NOW()
  AND attempts < 3
ORDER BY priority DESC, scheduled_at ASC
LIMIT 1
FOR UPDATE SKIP LOCKED;  -- SKIP LOCKED — не ждём, пропускаем занятые

UPDATE jobs
SET status = 'processing',
    worker_id = $1,
    started_at = NOW(),
    attempts = attempts + 1
WHERE id = $2;

COMMIT;
```

---

## 5. NoSQL базы данных: когда и какие

### Документные: MongoDB

**Структура данных:** документы (JSON/BSON), коллекции вместо таблиц, нет фиксированной схемы.

```
MongoDB Document:
{
  "_id": ObjectId("..."),
  "user_id": "usr_123",
  "items": [
    {"product_id": "p1", "name": "Widget", "qty": 2, "price": 9.99},
    {"product_id": "p2", "name": "Gadget", "qty": 1, "price": 49.99}
  ],
  "total": 69.97,
  "shipping": {
    "address": "123 Main St",
    "city": "NYC",
    "status": "shipped"
  },
  "tags": ["express", "gift"]
}
```

**Когда подходит:**
- Каталоги с разнородной схемой (атрибуты товаров)
- Прототипирование (схема не устоялась)
- Документы, которые читаются/пишутся целиком
- CMS, конфигурации, профили пользователей

**Когда НЕ подходит:**
- Нужны сложные транзакции (multi-collection ACID)
- Много `JOIN`-подобных операций между документами
- Сильносвязанные данные с referential integrity

---

### Key-Value: Redis

**Структура:** ключ → значение. Ключ всегда String, значение — String, List, Set, Sorted Set, Hash, Stream, и др. Всё в памяти, опционально persistence.

```
Redis Data Structures:

String:   SET session:abc123 "user_id:42"  EX 3600
Hash:     HSET user:42 name "Alice" email "alice@example.com"
List:     RPUSH notifications:42 "New message"
Set:      SADD online_users "user:42"
Sorted:   ZADD leaderboard 1500 "user:42"    ← score + member
Stream:   XADD events * type "click" url "/home"
```

**Типичные use cases:**

| Use case | Структура | Команды |
|----------|-----------|---------|
| Кэш | String | `SET key value EX ttl`, `GET` |
| Сессии | String/Hash | `SETEX`, `HGETALL` |
| Rate limiting | String | `INCR`, `EXPIRE` / sliding window с Lua |
| Pub/Sub | Pub/Sub | `PUBLISH`, `SUBSCRIBE` |
| Очередь задач | List | `RPUSH`, `BLPOP` |
| Лидерборд | Sorted Set | `ZADD`, `ZREVRANK` |
| Distributed lock | String | `SET key value NX EX timeout` |

```
Rate limiting в Redis (fixed window):

INCR ratelimit:user:42:2026032309   ← ключ включает час
EXPIRE ratelimit:user:42:2026032309 3600
→ если значение > 100: reject
```

---

### Wide-Column: Cassandra / ScyllaDB

**Модель данных:** строки хранятся по partition key. Внутри partition строки упорядочены по clustering key.

```
Таблица user_activity в Cassandra:

Partition Key: user_id
Clustering Key: event_time DESC

┌──────────────────────────────────────────────────────────┐
│ Partition: user_id = "u123"                              │
│ ┌─────────────────────────────────────────────────────┐  │
│ │ event_time          │ event_type │ metadata          │  │
│ ├─────────────────────────────────────────────────────┤  │
│ │ 2026-03-23 09:00:00 │ login      │ {ip: "1.2.3.4"}  │  │
│ │ 2026-03-23 08:45:00 │ click      │ {url: "/home"}   │  │
│ │ 2026-03-23 08:30:00 │ purchase   │ {order_id: "o1"} │  │
│ └─────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘

Partition: user_id = "u456"
  ...
```

**Ключевые свойства:**
- Запись всегда в одну partition → O(1) по partition key
- Нет JOIN-ов, нет транзакций между partitions
- Consistency настраивается: `QUORUM`, `ONE`, `ALL`
- Горизонтальное масштабирование — нативно (consistent hashing)

**Когда подходит:**
- Write-heavy нагрузки (IoT, события, метрики)
- Time-series данные
- Когда паттерн чтения известен заранее (моделирование по запросам)
- Нужна горизонтальная масштабируемость без шардирования вручную

**Когда НЕ подходит:**
- Произвольные запросы без partition key
- ACID-транзакции
- Частые UPDATE/DELETE (tombstones — проблема)

---

### Graph: Neo4j

**Модель:** узлы (nodes) + рёбра (edges/relationships) + свойства у обоих.

```
Социальный граф:

(Alice)-[:FOLLOWS]->(Bob)
(Bob)-[:FOLLOWS]->(Carol)
(Alice)-[:LIKES {since: "2024"}]->(Post#1)
(Post#1)-[:CREATED_BY]->(Bob)
(Alice)-[:FRIEND_OF {since: "2020"}]->(Dave)
```

```cypher
-- Найти все посты от людей, на которых подписана Alice (2 hop)
MATCH (alice:User {name: "Alice"})-[:FOLLOWS]->(followed:User)
      -[:CREATED]->(post:Post)
RETURN post.title, followed.name
ORDER BY post.created_at DESC
LIMIT 20;

-- Shortest path между двумя пользователями
MATCH p = shortestPath((alice:User {name: "Alice"})-[*]-(target:User {name: "Eve"}))
RETURN length(p), [n IN nodes(p) | n.name];
```

**Когда подходит:**
- Социальные графы, рекомендации
- Граф зависимостей (пакеты, микросервисы)
- Fraud detection (паттерны связей)
- Knowledge graphs

---

### Сравнительная таблица

| | PostgreSQL | MongoDB | Redis | Cassandra | Neo4j |
|--|--|--|--|--|--|
| **Модель данных** | Реляционная (таблицы) | Документы (JSON) | Key-Value / структуры | Wide-column | Граф |
| **Схема** | Фиксированная | Гибкая | Без схемы | Частично фиксированная | Гибкая |
| **Транзакции** | ACID, multi-row | ACID (single doc; multi-doc с 4.0) | Ограниченно (MULTI) | Lightweight transactions | ACID |
| **Consistency** | Strong | Configurable | Strong (single) / Eventually | Tunable (ONE→ALL) | Strong |
| **Масштабирование** | Вертикально + read replicas | Horizontal sharding | Cluster (Redis Cluster) | Horizontal (нативно) | Вертикально |
| **Запросы** | SQL (произвольные) | MQL (гибкие) | По ключу | По partition key | Cypher (graph traversal) |
| **Latency** | 1-10ms | 1-10ms | <1ms (in-memory) | 1-5ms | Зависит от depth |
| **Use case** | OLTP, основная БД | Каталоги, CMS, профили | Кэш, сессии, rate limit | IoT, time-series, events | Соцсети, рекомендации |

---

## 6. Как выбирать базу данных

### Decision tree

```
Нужно выбрать БД?
│
├── Данные сильно связаны (реляции, FK, JOIN-ы)?
│   └── ДА → SQL (PostgreSQL)
│
├── Нужны ACID-транзакции?
│   └── ДА → SQL (PostgreSQL) или MongoDB (4.0+)
│
├── Паттерн доступа известен заранее, write-heavy, нужен horizontal scale?
│   └── ДА → Cassandra / ScyllaDB
│
├── Главное — скорость чтения, данные помещаются в память?
│   └── ДА → Redis
│
├── Данные — граф с многоуровневыми связями?
│   └── ДА → Neo4j
│
├── Полнотекстовый поиск + агрегации по документам?
│   └── ДА → Elasticsearch / OpenSearch
│
├── Разнородная схема, документы читаются/пишутся целиком?
│   └── ДА → MongoDB
│
└── Нет специфичных требований → PostgreSQL
    (богатейший feature set, зрелость, экосистема)
```

**Вопросы, которые нужно задать:**

```
1. Паттерны доступа:
   - Read-heavy (>80% reads) → можно добавить read replicas / кэш
   - Write-heavy → нужен append-friendly storage (Cassandra, Kafka+OLAP)
   - Mixed → PostgreSQL справится до ~10K RPS

2. Размер данных:
   - <100GB → PostgreSQL без вопросов
   - >1TB → нужно думать о шардировании или Cassandra
   - In-memory → Redis

3. Consistency требования:
   - Финансы, inventory → Strong Consistency (SQL, Serializable)
   - Счётчики лайков, просмотры → Eventual Consistency (Redis, Cassandra)

4. Query flexibility:
   - Произвольные аналитические запросы → PostgreSQL или OLAP (ClickHouse)
   - Только по известным ключам → любая NoSQL

5. Транзакции:
   - Multi-entity consistency → SQL
   - Single-entity → любая

6. Team:
   - Знаете SQL? → PostgreSQL
   - Нет опыта с Cassandra? → не берите без необходимости
```

---

### Polyglot persistence

В реальных системах одна база данных редко закрывает все потребности. Типичная архитектура:

```
                    ┌─────────────────┐
                    │   API Gateway   │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
    ┌─────────▼──────┐ ┌─────▼──────┐ ┌────▼──────────┐
    │  User Service  │ │ Feed Service│ │ Search Service│
    └─────────┬──────┘ └─────┬──────┘ └────┬──────────┘
              │              │              │
    ┌─────────▼──────┐ ┌─────▼──────┐ ┌────▼──────────┐
    │  PostgreSQL    │ │  Cassandra │ │ Elasticsearch │
    │  (users, auth, │ │  (posts,   │ │  (full-text   │
    │   payments)    │ │   events)  │ │   search)     │
    └────────────────┘ └────────────┘ └───────────────┘
              │
    ┌─────────▼──────┐
    │     Redis      │
    │  (sessions,    │
    │   rate limits, │
    │   cache)       │
    └────────────────┘
```

**Правило:** добавляйте новую БД только когда PostgreSQL доказуемо не справляется с конкретным требованием. Каждая новая БД — это ops-нагрузка, обучение команды, eventual consistency проблемы.

---

### Реальные примеры: какие базы используют крупные компании

| Компания | PostgreSQL | Redis | Cassandra | MongoDB | Специализированные |
|----------|-----------|-------|-----------|---------|-------------------|
| **Uber** | ✅ (core data) | ✅ (caching) | ✅ (trips history) | — | Schemaless (MySQL-совместимый), DocStore |
| **Netflix** | — | ✅ | ✅ (EVCache, viewing history) | — | ClickHouse (analytics) |
| **Discord** | ✅ | ✅ | ✅ (messages) | — | ScyllaDB (migration from Cassandra) |
| **Instagram** | ✅ (primary) | ✅ | — | — | Шардированный PostgreSQL |
| **Notion** | ✅ | ✅ | — | — | PostgreSQL + RDS |
| **Shopify** | — | ✅ | — | — | MySQL + Redis |

**Discord и ScyllaDB:** Discord [опубликовал](https://discord.com/blog/how-discord-stores-trillions-of-messages) как перешли от MongoDB → Cassandra → ScyllaDB для хранения триллионов сообщений. Cassandra давала latency tail при compaction, ScyllaDB (C++ rewrite) решила проблему.

**Uber и Schemaless:** Uber построил собственную key-value систему поверх MySQL для горизонтального масштабирования. Позже перешли на собственный DocStore.

---

## 7. Connection pooling и работа с БД в Go

### Зачем нужен connection pool

Каждое соединение с PostgreSQL — это отдельный backend process на сервере (~5-10MB RAM). Установка TCP-соединения + auth + backend fork = ~1-5ms latency.

```
Без пула:
Запрос → TCP connect → auth → query → TCP disconnect
        ←─────── 5ms overhead ────────────────────→

С пулом:
Запрос → берём соединение из пула → query → возвращаем
        ←────── <0.1ms overhead ─────────────────→
```

**Максимум соединений PostgreSQL:**
```sql
-- Посмотреть лимит
SHOW max_connections;  -- обычно 100-200 по умолчанию

-- Текущие соединения
SELECT count(*) FROM pg_stat_activity;

-- По состояниям
SELECT state, count(*)
FROM pg_stat_activity
GROUP BY state;
-- idle         — соединение в пуле, ничего не делает
-- active       — выполняет запрос
-- idle in tx   — в транзакции, но не активен → ПРОБЛЕМА
```

**Правило thumb:** `max_connections PostgreSQL ≈ (кол-во CPU ядер) * 2 + кол-во дисков`

При 10 инстансах сервиса с пулом по 10 соединений = 100 соединений. Если инстансов 50 — нужен **PgBouncer**.

---

### database/sql: настройка пула

```go
package db

import (
    "database/sql"
    "fmt"
    "time"

    _ "github.com/jackc/pgx/v5/stdlib" // pgx как driver для database/sql
)

func NewSQLDB(dsn string) (*sql.DB, error) {
    db, err := sql.Open("pgx", dsn)
    if err != nil {
        return nil, fmt.Errorf("open db: %w", err)
    }

    // Максимум открытых соединений (включая idle)
    // Правило: (max_connections_postgres / кол-во_инстансов) - небольшой запас
    db.SetMaxOpenConns(25)

    // Максимум idle соединений в пуле
    // Должно быть ≤ MaxOpenConns
    // Для highload: = MaxOpenConns (чтобы не создавать соединения под нагрузкой)
    db.SetMaxIdleConns(25)

    // Время жизни соединения (с момента создания)
    // Позволяет ротировать соединения, полезно при изменении DNS (failover)
    db.SetConnMaxLifetime(5 * time.Minute)

    // Максимальное время idle (с последнего использования)
    // Освобождаем ресурсы при спаде нагрузки
    db.SetConnMaxIdleTime(1 * time.Minute)

    return db, nil
}
```

**Параметры и их влияние:**

| Параметр | Низкое значение | Высокое значение | Рекомендация |
|----------|----------------|-----------------|--------------|
| `MaxOpenConns` | Очередь запросов при нагрузке | Перегрузка PostgreSQL | 10-25 на инстанс |
| `MaxIdleConns` | Частое создание соединений | Много idle в БД | = MaxOpenConns |
| `ConnMaxLifetime` | Частое пересоздание | Проблемы с failover | 5-30 минут |
| `ConnMaxIdleTime` | Много idle connections | Overhead пересоздания | 1-5 минут |

---

### pgxpool: конфигурация

```go
package db

import (
    "context"
    "fmt"
    "time"

    "github.com/jackc/pgx/v5/pgxpool"
)

func NewPgxPool(ctx context.Context, dsn string) (*pgxpool.Pool, error) {
    cfg, err := pgxpool.ParseConfig(dsn)
    if err != nil {
        return nil, fmt.Errorf("parse config: %w", err)
    }

    // Максимум соединений в пуле
    cfg.MaxConns = 25

    // Минимум idle соединений (поддерживаются всегда)
    // Уменьшает latency первого запроса при прогреве
    cfg.MinConns = 5

    // Максимальное время жизни соединения
    cfg.MaxConnLifetime = 30 * time.Minute

    // Jitter для MaxConnLifetime (предотвращает thundering herd при истечении)
    cfg.MaxConnLifetimeJitter = 5 * time.Minute

    // Максимальное время idle
    cfg.MaxConnIdleTime = 5 * time.Minute

    // Timeout на получение соединения из пула
    // Если все соединения заняты — не ждём вечно
    cfg.HealthCheckPeriod = 1 * time.Minute

    // Connect timeout
    cfg.ConnConfig.ConnectTimeout = 5 * time.Second

    pool, err := pgxpool.NewWithConfig(ctx, cfg)
    if err != nil {
        return nil, fmt.Errorf("create pool: %w", err)
    }

    return pool, nil
}
```

---

### Пример: правильная настройка для highload-сервиса

```go
package main

import (
    "context"
    "log/slog"
    "os"
    "time"

    "github.com/jackc/pgx/v5/pgxpool"
)

// HighloadPoolConfig конфигурация для highload (>1000 RPS)
func HighloadPoolConfig(dsn string) *pgxpool.Config {
    cfg, _ := pgxpool.ParseConfig(dsn)

    // Scenario: 20 инстансов сервиса, PostgreSQL max_connections=200
    // 200 / 20 = 10 соединений на инстанс, оставляем запас для psql и мониторинга
    cfg.MaxConns = 8
    cfg.MinConns = 4  // держим соединения прогретыми

    cfg.MaxConnLifetime = 10 * time.Minute
    cfg.MaxConnLifetimeJitter = 2 * time.Minute
    cfg.MaxConnIdleTime = 3 * time.Minute

    // Health check — обнаруживаем мёртвые соединения быстро
    cfg.HealthCheckPeriod = 30 * time.Second

    // Before acquire — проверяем соединение перед выдачей из пула
    cfg.BeforeAcquire = func(ctx context.Context, conn *pgx.Conn) bool {
        return conn.Ping(ctx) == nil
    }

    return cfg
}

// Мониторинг состояния пула
func logPoolStats(pool *pgxpool.Pool) {
    stats := pool.Stat()
    slog.Info("pool stats",
        "total_conns", stats.TotalConns(),
        "idle_conns", stats.IdleConns(),
        "acquired_conns", stats.AcquiredConns(),
        "constructing_conns", stats.ConstructingConns(),
        "max_conns", stats.MaxConns(),
    )
}
```

---

### Типичные ошибки

#### Connection leak

```go
// ❌ НЕПРАВИЛЬНО: забыли закрыть rows
func getBadUsers(ctx context.Context, pool *pgxpool.Pool) ([]User, error) {
    rows, err := pool.Query(ctx, "SELECT id, email FROM users")
    if err != nil {
        return nil, err
    }
    // rows.Close() не вызывается!
    // Соединение вернётся в пул только при GC rows
    // → при нагрузке: все соединения заняты, новые запросы зависают

    var users []User
    for rows.Next() {
        // ...
    }
    return users, nil
}

// ✅ ПРАВИЛЬНО: defer rows.Close()
func getGoodUsers(ctx context.Context, pool *pgxpool.Pool) ([]User, error) {
    rows, err := pool.Query(ctx, "SELECT id, email FROM users")
    if err != nil {
        return nil, err
    }
    defer rows.Close() // ← всегда!

    var users []User
    for rows.Next() {
        var u User
        if err := rows.Scan(&u.ID, &u.Email); err != nil {
            return nil, err
        }
        users = append(users, u)
    }
    return users, rows.Err()
}
```

#### Транзакция без rollback

```go
// ❌ НЕПРАВИЛЬНО: нет defer tx.Rollback()
func badTransfer(ctx context.Context, pool *pgxpool.Pool) error {
    tx, _ := pool.Begin(ctx)

    _, err := tx.Exec(ctx, "UPDATE accounts SET balance = balance - 100 WHERE id = 1")
    if err != nil {
        return err // tx не закрыт! соединение утекло!
    }

    return tx.Commit(ctx)
}

// ✅ ПРАВИЛЬНО: defer tx.Rollback() — идемпотентен после Commit
func goodTransfer(ctx context.Context, pool *pgxpool.Pool) error {
    tx, err := pool.Begin(ctx)
    if err != nil {
        return err
    }
    defer tx.Rollback(ctx) // откатит только если не было Commit

    _, err = tx.Exec(ctx, "UPDATE accounts SET balance = balance - 100 WHERE id = 1")
    if err != nil {
        return err
    }

    return tx.Commit(ctx)
}
```

#### Слишком много idle connections

```go
// ❌ ПРОБЛЕМА: MaxIdleConns >> реальной нагрузки
// При спаде трафика держим 25 idle соединений → нагрузка на PostgreSQL

// ✅ РЕШЕНИЕ: ConnMaxIdleTime освобождает ненужные idle
db.SetConnMaxIdleTime(1 * time.Minute)

// Также: для нагрузок с большими спайками — PgBouncer между сервисом и БД
// PgBouncer держит маленький пул к PostgreSQL,
// клиентов принимает значительно больше
```

#### Отсутствие контекста с таймаутом

```go
// ❌ НЕПРАВИЛЬНО: запрос может висеть вечно
rows, err := pool.Query(context.Background(), "SELECT ...")

// ✅ ПРАВИЛЬНО: контекст с таймаутом
ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
defer cancel()

rows, err := pool.Query(ctx, "SELECT ...")
// При превышении таймаута: запрос отменяется на стороне PostgreSQL
```

#### Настройка PgBouncer для масштаба

```ini
# pgbouncer.ini — для highload с большим числом инстансов
[databases]
mydb = host=postgres-primary port=5432 dbname=mydb

[pgbouncer]
# Transaction pooling: соединение возвращается в пул после каждой транзакции
# Позволяет 1000 клиентов при 50 соединениях к PostgreSQL
pool_mode = transaction

# Соединений к PostgreSQL
max_client_conn = 1000
default_pool_size = 50
min_pool_size = 10
reserve_pool_size = 10

# Таймауты
server_idle_timeout = 600
client_idle_timeout = 0
query_timeout = 0  # устанавливайте на уровне приложения

# ВАЖНО: при transaction pooling НЕ работают:
# - SET (session-level)
# - LISTEN/NOTIFY
# - prepared statements (без специальных настроек)
# - advisory locks (сессионные)
```

---

## Итоги модуля

```
┌────────────────────────────────────────────────────────────────┐
│                    Ключевые takeaways                          │
├────────────────────────────────────────────────────────────────┤
│ PostgreSQL    │ Стандарт. MVCC даёт reads без блокировок.      │
│               │ WAL — основа durability и репликации.          │
├───────────────┼────────────────────────────────────────────────┤
│ Индексы       │ B-tree работает для 90% случаев.               │
│               │ Порядок колонок в составном — критичен.        │
│               │ EXPLAIN ANALYZE — обязательный инструмент.     │
│               │ Unused indexes замедляют writes.               │
├───────────────┼────────────────────────────────────────────────┤
│ Транзакции    │ Read Committed — дефолт и достаточен для CRUD. │
│               │ Финансы → Serializable + FOR UPDATE.           │
│               │ MVCC: читатели не блокируют писателей.         │
├───────────────┼────────────────────────────────────────────────┤
│ Блокировки    │ Оптимистическая лучше при низкой конкуренции.  │
│               │ FOR UPDATE SKIP LOCKED — паттерн для очередей. │
│               │ Deadlock = блокировки в разном порядке.        │
├───────────────┼────────────────────────────────────────────────┤
│ NoSQL         │ Redis — кэш и сессии, не основная БД.          │
│               │ Cassandra — write-heavy + горизонтальный scale.│
│               │ MongoDB — гибкая схема, прототипы.             │
├───────────────┼────────────────────────────────────────────────┤
│ Выбор БД      │ По умолчанию PostgreSQL до доказанной нужды.   │
│               │ Polyglot: каждая БД под свой use case.         │
├───────────────┼────────────────────────────────────────────────┤
│ Connection    │ defer rows.Close() и defer tx.Rollback().      │
│ pooling       │ MaxOpenConns = max_postgres / instances.       │
│               │ PgBouncer при > 100 инстансах.                 │
└───────────────┴────────────────────────────────────────────────┘
```

## Следующий модуль

**Модуль 04: Кэширование** — Redis углублённо, стратегии инвалидации, cache-aside vs write-through vs write-behind, проблема thundering herd, распределённый кэш.
