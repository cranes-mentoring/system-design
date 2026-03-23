# Module 03: Databases

> **Module goal:** understand how relational and NoSQL databases work internally, how to make informed decisions when choosing a database, and how to work with databases correctly in Go services.

---

## Table of Contents

1. [SQL Databases: PostgreSQL as a Foundation](#1-sql-databases-postgresql-as-a-foundation)
2. [Indexes: How They Work and When They Slow Things Down](#2-indexes-how-they-work-and-when-they-slow-things-down)
3. [Transactions and Isolation Levels](#3-transactions-and-isolation-levels)
4. [Locks](#4-locks)
5. [NoSQL Databases: When and Which](#5-nosql-databases-when-and-which)
6. [How to Choose a Database](#6-how-to-choose-a-database)
7. [Connection Pooling and Working with DBs in Go](#7-connection-pooling-and-working-with-dbs-in-go)

---

## 1. SQL Databases: PostgreSQL as a Foundation

### Why PostgreSQL is the Backend Standard

PostgreSQL is not just "another relational DB." It is a system that, over 30+ years of evolution, has become the de-facto standard for production backends. Key reasons:

- **ACID out of the box** — transactions, isolation levels, MVCC without extra configuration
- **Rich type system** — `JSONB`, arrays, `hstore`, `UUID`, `ENUM`, ranges, geometric types
- **Extensibility** — PostGIS (geodata), TimescaleDB (time-series), pg_vector (embeddings)
- **Mature query optimizer** — cost-based planner with statistics support
- **Reliability** — WAL, point-in-time recovery, streaming replication
- **License** — PostgreSQL License (MIT-like), no vendor lock-in

MySQL falls short on type system features and MVCC implementation. SQLite is only for embedded scenarios. Oracle/MSSQL are commercial with vendor lock-in. **PostgreSQL is the obvious choice.**

---

### PostgreSQL Architecture

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
│  │  (background)│  │  (background) │  │  Launcher       │  │
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

**Key components:**

| Component | Role |
|-----------|------|
| **Backend process** | One process per client connection. Processes queries, reads/writes to shared buffer |
| **Shared Buffer** | Page cache in memory. Default 128MB — in production set to 25-40% RAM |
| **WAL (Write-Ahead Log)** | Change journal. We write to WAL first, then to data files. Foundation of durability and replication |
| **WAL Writer** | Flushes the WAL buffer to disk asynchronously |
| **Checkpointer** | Periodically flushes dirty pages from shared buffer to disk |
| **Autovacuum** | Cleans dead tuples after UPDATE/DELETE (consequence of MVCC) |

**WAL and durability:** on `COMMIT`, PostgreSQL guarantees the write made it to WAL on disk (`fsync`). Even after a server crash, data will be recovered by replaying the WAL. This is the **D** in ACID.

---

### Data Types: When to Use What

#### JSONB vs Normalization vs Arrays

```
Selection principle:

  Does the data have a fixed schema?
  ├── YES → normalization (tables + FK)
  └── NO → does data structure vary record by record?
              ├── YES, arbitrary structure → JSONB
              └── YES, but uniform elements → PostgreSQL arrays
```

**When to use JSONB:**
- Product attributes in a catalog (phone has `battery_mah`, T-shirt has `sizes`)
- User settings with arbitrary keys
- Data from external APIs with unstable schemas
- Prototyping (can migrate later)

```sql
-- Product catalog: each product has its own attribute schema
CREATE TABLE products (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT NOT NULL,
    category    TEXT NOT NULL,
    price       NUMERIC(10,2) NOT NULL,
    attributes  JSONB NOT NULL DEFAULT '{}'
);

-- Phone
INSERT INTO products (name, category, price, attributes) VALUES (
    'iPhone 16 Pro', 'phones', 99999.00,
    '{"battery_mah": 3274, "storage_gb": 256, "5g": true, "colors": ["black", "white"]}'
);

-- T-shirt
INSERT INTO products (name, category, price, attributes) VALUES (
    'Basic Tee', 'clothing', 999.00,
    '{"sizes": ["XS","S","M","L","XL"], "material": "cotton", "gender": "unisex"}'
);

-- Search by JSONB field (requires GIN index)
SELECT name, attributes->>'battery_mah' AS battery
FROM products
WHERE category = 'phones'
  AND (attributes->>'battery_mah')::int > 3000;

-- GIN index for efficient search
CREATE INDEX idx_products_attributes ON products USING GIN (attributes);

-- @> operator — containment check
SELECT name FROM products
WHERE attributes @> '{"5g": true}';
```

**When to use PostgreSQL arrays:**
- Tags, labels (fixed type, set of values)
- List of IDs (though normalizing via junction table is better)
- Event timestamps

```sql
CREATE TABLE articles (
    id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    tags  TEXT[] NOT NULL DEFAULT '{}'
);

-- GIN index for tag search
CREATE INDEX idx_articles_tags ON articles USING GIN (tags);

-- Articles with the 'golang' tag
SELECT title FROM articles WHERE tags @> ARRAY['golang'];

-- Tag intersection
SELECT title FROM articles WHERE tags && ARRAY['golang', 'databases'];
```

**When to use normalization:**
- Data that is used in JOINs
- Data that needs to be changed atomically
- When referential integrity matters

---

### Go Example: Connecting via pgx

```go
package db

import (
    "context"
    "fmt"
    "time"

    "github.com/jackc/pgx/v5"
    "github.com/jackc/pgx/v5/pgxpool"
)

// Config connection pool parameters
type Config struct {
    DSN             string
    MaxConns        int32
    MinConns        int32
    MaxConnLifetime time.Duration
    MaxConnIdleTime time.Duration
}

// NewPool creates a pgxpool connection pool
func NewPool(ctx context.Context, cfg Config) (*pgxpool.Pool, error) {
    poolCfg, err := pgxpool.ParseConfig(cfg.DSN)
    if err != nil {
        return nil, fmt.Errorf("parse dsn: %w", err)
    }

    poolCfg.MaxConns = cfg.MaxConns
    poolCfg.MinConns = cfg.MinConns
    poolCfg.MaxConnLifetime = cfg.MaxConnLifetime
    poolCfg.MaxConnIdleTime = cfg.MaxConnIdleTime

    // Hook after connection creation — can set session parameters
    poolCfg.AfterConnect = func(ctx context.Context, conn *pgx.Conn) error {
        // Set timezone for the session
        _, err := conn.Exec(ctx, "SET timezone = 'UTC'")
        return err
    }

    pool, err := pgxpool.NewWithConfig(ctx, poolCfg)
    if err != nil {
        return nil, fmt.Errorf("create pool: %w", err)
    }

    // Verify connection
    if err := pool.Ping(ctx); err != nil {
        return nil, fmt.Errorf("ping db: %w", err)
    }

    return pool, nil
}

// Example usage: CRUD with prepared statements
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

// GetByID — pgx caches prepared statements automatically
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

// ListByEmails — batch query
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

// Create with generated ID return
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

**Why pgx instead of `database/sql`:**
- Native support for PostgreSQL types (arrays, JSONB, UUID without wrappers)
- Better performance (fewer allocations)
- `pgxpool` — built-in pool with extended settings
- Supports Copy Protocol for bulk inserts
- Batch queries (`SendBatch`)

---

## 2. Indexes: How They Work and When They Slow Things Down

### B-tree: Structure and Search Mechanics

B-tree (Balanced Tree) is the default index in PostgreSQL. Understanding its structure explains why some queries use an index and others don't.

```
B-tree for the age column in the users table:

                    ┌─────────┐
                    │  [35]   │   ← Root (level 3)
                    └────┬────┘
          ┌─────────────┘└─────────────┐
     ┌────▼────┐                  ┌────▼────┐
     │ [18,25] │                  │ [45,60] │  ← Internal nodes (level 2)
     └────┬────┘                  └────┬────┘
   ┌──────┼──────┐              ┌──────┼──────┐
┌──▼──┐ ┌─▼──┐ ┌─▼──┐       ┌──▼──┐ ┌─▼──┐ ┌─▼──┐
│15,17│ │18,24│ │25,34│      │35,44│ │45,59│ │60+ │  ← Leaf nodes (level 1)
└──┬──┘ └──┬──┘ └──┬──┘      └──┬──┘ └──┬──┘ └──┬──┘
   ↓       ↓       ↓             ↓       ↓       ↓
 heap    heap    heap           heap    heap    heap
pages   pages   pages          pages   pages   pages

Leaf nodes are linked by a doubly-linked list → efficient range scans
```

**Estimating B-tree depth:**
- Each page = 8KB
- One node holds ~200-400 keys (depends on key size)
- Depth = log₃₀₀(N) ≈ 3-4 levels for tables up to 100M rows
- **Conclusion:** index lookup = 3-4 disk I/Os regardless of table size

**When B-tree is NOT used:**
```sql
-- ❌ Function on column → index not used
SELECT * FROM users WHERE LOWER(email) = 'user@example.com';

-- ✅ Solution: functional index
CREATE INDEX idx_users_email_lower ON users (LOWER(email));

-- ❌ LIKE with prefix wildcard
SELECT * FROM users WHERE name LIKE '%smith';

-- ✅ For suffix search, a GIN/trgm index is needed
CREATE EXTENSION pg_trgm;
CREATE INDEX idx_users_name_trgm ON users USING GIN (name gin_trgm_ops);

-- ❌ Implicit type casting
SELECT * FROM users WHERE id = 42;  -- id VARCHAR, 42 INTEGER → cast kills index

-- ✅ Explicit cast or correct type
SELECT * FROM users WHERE id = '42';
```

---

### Index Types

| Type | Algorithm | Use case | Operators |
|------|-----------|----------|-----------|
| **B-tree** | Balanced Tree | =, <, >, BETWEEN, LIKE 'prefix%', ORDER BY | `<`, `>`, `=`, `BETWEEN` |
| **Hash** | Hash table | Only `=`, slightly faster than B-tree for exact matches | `=` |
| **GIN** | Inverted index | JSONB, arrays, full-text search | `@>`, `&&`, `@@` |
| **GiST** | Generalized Search Tree | Geodata (PostGIS), ranges, nearest-neighbor | `&&`, `<<`, `@>` |
| **BRIN** | Block Range Index | Very large tables with correlated data (logs, time-series) | `<`, `>`, `BETWEEN` |
| **SP-GiST** | Space-Partitioned GiST | IP addresses, phone numbers, points | `<<`, `>>` |

**GIN — in detail:**
```sql
-- Full-text search
CREATE INDEX idx_articles_fts ON articles
    USING GIN (to_tsvector('english', title || ' ' || body));

SELECT title
FROM articles
WHERE to_tsvector('english', title || ' ' || body) @@ to_tsquery('english', 'database & design');

-- JSONB containment
CREATE INDEX idx_products_attrs ON products USING GIN (attributes);

-- Find all products with a certain attribute
SELECT * FROM products WHERE attributes @> '{"in_stock": true}';
```

**BRIN — when to use:**
```sql
-- Logs table: records ordered by insert time
CREATE TABLE access_logs (
    id         BIGSERIAL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    user_id    UUID,
    endpoint   TEXT,
    status     INT
);

-- BRIN stores only min/max for each range of pages
-- Size: ~100x smaller than B-tree, efficient for range scans on created_at
CREATE INDEX idx_logs_created_brin ON access_logs USING BRIN (created_at);

-- B-tree would be excessive here — data is already physically ordered
```

---

### Composite Indexes: Column Order Matters

```sql
-- Orders table
CREATE TABLE orders (
    id         UUID PRIMARY KEY,
    user_id    UUID NOT NULL,
    status     TEXT NOT NULL,  -- 'pending', 'paid', 'shipped', 'done'
    created_at TIMESTAMPTZ NOT NULL
);

-- Composite index
CREATE INDEX idx_orders_user_status ON orders (user_id, status);
```

**Leftmost prefix rule:** a composite index `(user_id, status)` is used for:
- `WHERE user_id = $1` ✅
- `WHERE user_id = $1 AND status = $2` ✅
- `WHERE user_id = $1 ORDER BY status` ✅
- `WHERE status = $1` ❌ (status only — not a leftmost prefix)

```
Visualization:

Index (user_id, status):

user_id=A, status='paid'    → TID(1,5)
user_id=A, status='pending' → TID(2,1)
user_id=A, status='shipped' → TID(3,8)
user_id=B, status='done'    → TID(1,2)
user_id=B, status='paid'    → TID(4,3)

Query WHERE user_id=A → read first 3 rows consecutively ✅
Query WHERE status='paid' → must scan the entire index ❌
```

**How to choose the order:**
1. Columns with `=` — first
2. High cardinality — first (if equal selectivity)
3. Columns with range (`>`, `<`) — last
4. Columns from `ORDER BY` — last

---

### Covering Indexes (INCLUDE)

```sql
-- Without INCLUDE: Index Scan → heap fetch for each row
CREATE INDEX idx_orders_user ON orders (user_id);

-- With INCLUDE: Index Only Scan — heap is not read at all
CREATE INDEX idx_orders_user_cover ON orders (user_id) INCLUDE (status, created_at);

-- This query now executes purely from the index:
SELECT status, created_at
FROM orders
WHERE user_id = $1
ORDER BY created_at DESC;
```

**Difference between `(a, b)` and `(a) INCLUDE (b)`:**
- `(a, b)` — `b` participates in B-tree structure, affects ordering, can filter by `b`
- `(a) INCLUDE (b)` — `b` is stored only in leaf nodes, doesn't affect structure, not for filtering

---

### Partial Indexes

```sql
-- Index only for active users (99% of queries are for active users)
CREATE INDEX idx_users_active_email ON users (email)
WHERE deleted_at IS NULL;

-- Job queue: index only for unprocessed jobs
CREATE INDEX idx_jobs_pending ON jobs (created_at)
WHERE status = 'pending';

-- Uniqueness only among active records
CREATE UNIQUE INDEX idx_users_unique_active_email ON users (email)
WHERE deleted_at IS NULL;
```

A partial index is smaller and updates faster since it covers only a subset of rows.

---

### EXPLAIN ANALYZE: Reading a Query Plan

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

**Example output and how to read it:**

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

**Key metrics:**

| Term | Meaning | What to watch |
|------|---------|---------------|
| `cost=X..Y` | Planner estimate (arbitrary units). X — startup cost, Y — total cost | If it diverges greatly from actual — stale statistics |
| `actual time=X..Y` | Real time in ms. X — first row, Y — all rows | Y is the time the user perceives |
| `rows=N` | Estimate vs actual | Large discrepancy → `ANALYZE` the table |
| `loops=N` | How many times the node was executed | In Nested Loop loops=1000 is common — multiply actual time by loops |
| **Seq Scan** | Full table scan | OK for small tables (<1000 rows) or when reading >20% of rows |
| **Index Scan** | Reads index + heap fetch per row | Optimal when selectivity <5-10% |
| **Index Only Scan** | Index only, heap not read | Ideal for covering indexes |
| **Bitmap Scan** | Builds a bitmap of matches, then reads heap in chunks | Compromise when 5-20% of rows match |
| **Nested Loop** | For each outer row → lookup in inner | Fast for small sets; catastrophic for large |
| **Hash Join** | Builds a hash table from the smaller set | Good for large sets without an index |
| **Merge Join** | Join of sorted sets | Efficient when data is already sorted |
| `Buffers: hit=N read=M` | hit — from cache, read — from disk | Many reads on first run, should be hit afterwards |

**Red flags in the plan:**
```sql
-- 🚩 Seq Scan on a large table with filtering
Seq Scan on orders  (rows=5000000)
Filter: (status = 'pending')
Rows Removed by Filter: 4990000  ← reading 5M, need 10K

-- 🚩 Nested Loop with high loops count
Nested Loop (loops=50000)
  ->  Index Scan on products (loops=50000)  ← 50000 * actual_time!

-- 🚩 Bad row estimate
Hash Join (estimated rows=10 vs actual rows=100000)
← planner doesn't know actual distribution → ANALYZE
```

---

### Anti-patterns with Indexes

```sql
-- ❌ Index on every column — slows down INSERT/UPDATE/DELETE
-- Each index must be updated on row changes
CREATE INDEX ON orders (id);           -- already has PK
CREATE INDEX ON orders (user_id);
CREATE INDEX ON orders (status);
CREATE INDEX ON orders (created_at);
CREATE INDEX ON orders (updated_at);
CREATE INDEX ON orders (payment_id);
-- ... 15 indexes on one table

-- ✅ Composite index for real query patterns
CREATE INDEX ON orders (user_id, status) INCLUDE (created_at);

-- Find unused indexes (after sufficient running time)
SELECT schemaname, tablename, indexname, idx_scan
FROM pg_stat_user_indexes
WHERE idx_scan = 0
ORDER BY pg_relation_size(indexrelid) DESC;

-- ❌ Index on low-cardinality column (boolean, enum with 3 values)
-- PostgreSQL will often choose Seq Scan instead
CREATE INDEX ON orders (is_deleted);  -- 99% of rows is_deleted=false

-- ✅ Partial index for such cases
CREATE INDEX ON orders (created_at) WHERE is_deleted = false;
```

---

## 3. Transactions and Isolation Levels

### ACID in Practice

**A — Atomicity:** a transaction either executes completely or rolls back entirely. No intermediate state.

```sql
-- Money transfer: either both UPDATEs or neither
BEGIN;
UPDATE accounts SET balance = balance - 1000 WHERE id = 'alice';
UPDATE accounts SET balance = balance + 1000 WHERE id = 'bob';
-- If the second UPDATE fails → the first one rolls back too
COMMIT;
```

**C — Consistency:** a transaction transitions the DB from one consistent state to another. All constraints (FK, CHECK, UNIQUE) are satisfied.

**I — Isolation:** concurrent transactions don't see each other's uncommitted changes (degree depends on isolation level).

**D — Durability:** after `COMMIT`, data is written to disk (WAL) and survives a server crash.

---

### Concurrency Problems

```
Transaction 1                    Transaction 2
─────────────────────────────────────────────────────

Dirty Read:
BEGIN                            BEGIN
                                 UPDATE bal = 500 WHERE id=1
READ bal → 500 (uncommitted!)
                                 ROLLBACK (reverts to 200)
USES 500 ← incorrect!

Non-Repeatable Read:
BEGIN
READ bal → 200
                                 BEGIN
                                 UPDATE bal = 500; COMMIT
READ bal → 500 ← it changed!
COMMIT

Phantom Read:
BEGIN
SELECT COUNT(*) → 10 rows
                                 BEGIN
                                 INSERT new_row; COMMIT
SELECT COUNT(*) → 11 rows ← phantom!
COMMIT

Serialization Anomaly (Write Skew):
BEGIN                            BEGIN
READ: doctors_on_call = 2        READ: doctors_on_call = 2
  (both see: OK to leave)          (both see: OK to leave)
UPDATE set on_call=false         UPDATE set on_call=false
COMMIT                           COMMIT
← Result: 0 on-call doctors! ← business invariant violated
```

---

### Isolation Levels

| Level | Dirty Read | Non-Repeatable Read | Phantom Read | Serialization Anomaly |
|-------|-----------|--------------------|--------------|-----------------------|
| **Read Uncommitted** | ✅ possible | ✅ possible | ✅ possible | ✅ possible |
| **Read Committed** | ❌ protected | ✅ possible | ✅ possible | ✅ possible |
| **Repeatable Read** | ❌ protected | ❌ protected | ❌ protected (in PG) | ✅ possible |
| **Serializable** | ❌ protected | ❌ protected | ❌ protected | ❌ protected |

> **Note:** PostgreSQL implements Repeatable Read via MVCC in a way that also prevents Phantom Reads — this is stronger than the SQL standard requires.

**PostgreSQL default: Read Committed**

```sql
-- What this means in practice:
-- Each statement sees a snapshot of data as of its own start time,
-- NOT as of the start of the transaction.

BEGIN; -- Level: Read Committed (default)

-- Snapshot 1: see data at T1
SELECT balance FROM accounts WHERE id = 1; -- → 1000

-- Another transaction does: UPDATE accounts SET balance=500 WHERE id=1; COMMIT;

-- Snapshot 2: new snapshot for this SELECT
SELECT balance FROM accounts WHERE id = 1; -- → 500 (we already see the commit!)

COMMIT;
```

This means: **within a single Read Committed transaction, you may see different values for the same row**. For most CRUD operations this is acceptable. For financial calculations — it is not.

---

### MVCC: Isolation Without Read Locks

MVCC (Multi-Version Concurrency Control) is PostgreSQL's key mechanism for performance.

```
Physical structure of a heap page:

┌────────────────────────────────────────────────────────┐
│ Tuple 1: xmin=100, xmax=0,   data="alice, bal=1000"   │ ← active
│ Tuple 2: xmin=101, xmax=103, data="alice, bal=800"    │ ← obsolete
│ Tuple 3: xmin=103, xmax=0,   data="alice, bal=1200"   │ ← active
└────────────────────────────────────────────────────────┘

xmin = transaction that created the tuple
xmax = transaction that deleted/updated the tuple (0 = alive)

UPDATE = INSERT new version + set xmax on old version
DELETE = set xmax with current transaction
```

**How a transaction sees data:**
1. At start, a query gets a `snapshot` — a list of active transactions
2. A tuple is visible if `xmin` is committed BEFORE the snapshot AND `xmax` is not committed
3. A reading transaction **acquires no locks** — a writing transaction does not block it

**Consequence: Autovacuum**

MVCC creates dead tuples — old versions of rows. Autovacuum removes them:
```sql
-- Monitor bloat and vacuum
SELECT relname, n_dead_tup, n_live_tup,
       last_autovacuum, last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;
```

---

### Go Example: Transaction Management with pgx

```go
package transaction

import (
    "context"
    "fmt"

    "github.com/jackc/pgx/v5"
    "github.com/jackc/pgx/v5/pgxpool"
)

// TransferMoney — atomic money transfer
func TransferMoney(ctx context.Context, pool *pgxpool.Pool, fromID, toID string, amount int64) error {
    return withTx(ctx, pool, pgx.TxOptions{
        IsoLevel: pgx.Serializable, // for financial operations
    }, func(tx pgx.Tx) error {
        // Lock rows in a consistent order (by ID) to prevent deadlocks
        ids := []string{fromID, toID}
        if fromID > toID {
            ids = []string{toID, fromID}
        }

        var balFrom, balTo int64

        // Read with lock
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

        // Debit
        _, err = tx.Exec(ctx,
            `UPDATE accounts SET balance = balance - $1 WHERE id = $2`,
            amount, fromID,
        )
        if err != nil {
            return fmt.Errorf("debit %s: %w", fromID, err)
        }

        // Credit
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

// withTx — transaction wrapper with automatic rollback
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

## 4. Locks

### Row-level Locks

```sql
-- FOR UPDATE: exclusive row lock
-- Other transactions cannot do FOR UPDATE / FOR SHARE until it's released
BEGIN;
SELECT * FROM jobs WHERE id = $1 FOR UPDATE;
-- Now safe to update — no one else will process this job
UPDATE jobs SET status = 'processing', worker_id = $2 WHERE id = $1;
COMMIT;

-- FOR UPDATE SKIP LOCKED: for job queues
-- Doesn't block on locked rows, skips them
SELECT id, payload
FROM jobs
WHERE status = 'pending'
ORDER BY created_at
LIMIT 10
FOR UPDATE SKIP LOCKED;

-- FOR SHARE: shared lock (multiple transactions can hold simultaneously)
-- Blocks FOR UPDATE, but doesn't block other FOR SHARE
SELECT * FROM users WHERE id = $1 FOR SHARE;
```

**Lock compatibility matrix:**

| | FOR UPDATE | FOR NO KEY UPDATE | FOR SHARE | FOR KEY SHARE |
|---|---|---|---|---|
| **FOR UPDATE** | ❌ | ❌ | ❌ | ❌ |
| **FOR NO KEY UPDATE** | ❌ | ❌ | ❌ | ✅ |
| **FOR SHARE** | ❌ | ❌ | ✅ | ✅ |
| **FOR KEY SHARE** | ❌ | ✅ | ✅ | ✅ |

---

### Advisory Locks

Advisory locks are custom application-level locks. PostgreSQL only stores their state; you define the semantics.

```sql
-- Session advisory locks (live until end of session or explicit unlock)
SELECT pg_try_advisory_lock(12345);  -- false if already locked

-- Transactional advisory locks (released on COMMIT/ROLLBACK)
SELECT pg_try_advisory_xact_lock(hashtext('job:processor:' || job_id::text));
```

```go
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

**PostgreSQL detects deadlocks** via a wait-for graph. When a cycle is detected, it aborts one transaction with `ERROR: deadlock detected`.

**How to avoid deadlocks:**

```sql
-- ❌ Problem: transactions lock in different orders
-- TX1: LOCK A, then LOCK B
-- TX2: LOCK B, then LOCK A

-- ✅ Solution: always lock in a consistent order
-- Sort IDs before locking
SELECT * FROM accounts
WHERE id = ANY($1::uuid[])
ORDER BY id  -- fixed order!
FOR UPDATE;
```

```go
// Go: lock multiple rows in a consistent order
func lockAccounts(ctx context.Context, tx pgx.Tx, ids []string) error {
    // Sort for consistent locking order
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

### Optimistic vs Pessimistic Locking

```
Pessimistic: lock first, then read/write
────────────────────────────────────────
TX1: SELECT FOR UPDATE → wait for release
TX2: SELECT FOR UPDATE → blocks on TX1
← Suitable for: high contention on the same rows

Optimistic: read without lock, check on write
─────────────────────────────────────────────
TX1: READ version=5
TX2: READ version=5
TX1: UPDATE WHERE version=5, SET version=6 → success
TX2: UPDATE WHERE version=5, SET version=6 → 0 rows! → retry
← Suitable for: low contention, many reads, few conflicts
```

**Optimistic locking example in Go:**

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
        // Read the current version
        var p Product
        err := r.pool.QueryRow(ctx,
            `SELECT id, name, price, version FROM products WHERE id = $1`,
            productID,
        ).Scan(&p.ID, &p.Name, &p.Price, &p.Version)
        if err != nil {
            return fmt.Errorf("read product: %w", err)
        }

        // Update with version check
        result, err := r.pool.Exec(ctx, `
            UPDATE products
            SET price = $1, version = version + 1
            WHERE id = $2 AND version = $3
        `, newPrice, productID, p.Version)
        if err != nil {
            return fmt.Errorf("update product: %w", err)
        }

        if result.RowsAffected() == 1 {
            return nil // successfully updated
        }

        // version changed — another transaction updated before us
        // Retry
        if attempt < maxRetries-1 {
            time.Sleep(time.Duration(attempt+1) * 10 * time.Millisecond) // backoff
        }
    }

    return fmt.Errorf("optimistic lock: max retries exceeded for product %s", productID)
}
```

**Pessimistic locking with SELECT FOR UPDATE:**

```sql
-- Job queue: one worker atomically claims a job
BEGIN;

SELECT id, payload, attempts
FROM jobs
WHERE status = 'pending'
  AND scheduled_at <= NOW()
  AND attempts < 3
ORDER BY priority DESC, scheduled_at ASC
LIMIT 1
FOR UPDATE SKIP LOCKED;  -- SKIP LOCKED — don't wait, skip locked rows

UPDATE jobs
SET status = 'processing',
    worker_id = $1,
    started_at = NOW(),
    attempts = attempts + 1
WHERE id = $2;

COMMIT;
```

---

## 5. NoSQL Databases: When and Which

### Document Stores: MongoDB

**Data structure:** documents (JSON/BSON), collections instead of tables, no fixed schema.

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

**When it fits:**
- Catalogs with heterogeneous schemas (product attributes)
- Prototyping (schema not yet settled)
- Documents that are read/written as a whole
- CMS, configurations, user profiles

**When it doesn't fit:**
- Complex transactions needed (multi-collection ACID)
- Many JOIN-like operations between documents
- Tightly-coupled data with referential integrity

---

### Key-Value: Redis

**Structure:** key → value. Key is always a String; value can be String, List, Set, Sorted Set, Hash, Stream, etc. Everything in memory, optional persistence.

```
Redis Data Structures:

String:   SET session:abc123 "user_id:42"  EX 3600
Hash:     HSET user:42 name "Alice" email "alice@example.com"
List:     RPUSH notifications:42 "New message"
Set:      SADD online_users "user:42"
Sorted:   ZADD leaderboard 1500 "user:42"    ← score + member
Stream:   XADD events * type "click" url "/home"
```

**Typical use cases:**

| Use case | Structure | Commands |
|----------|-----------|---------|
| Cache | String | `SET key value EX ttl`, `GET` |
| Sessions | String/Hash | `SETEX`, `HGETALL` |
| Rate limiting | String | `INCR`, `EXPIRE` / sliding window with Lua |
| Pub/Sub | Pub/Sub | `PUBLISH`, `SUBSCRIBE` |
| Job queue | List | `RPUSH`, `BLPOP` |
| Leaderboard | Sorted Set | `ZADD`, `ZREVRANK` |
| Distributed lock | String | `SET key value NX EX timeout` |

```
Rate limiting in Redis (fixed window):

INCR ratelimit:user:42:2026032309   ← key includes the hour
EXPIRE ratelimit:user:42:2026032309 3600
→ if value > 100: reject
```

---

### Wide-Column: Cassandra / ScyllaDB

**Data model:** rows are stored by partition key. Within a partition, rows are ordered by clustering key.

```
user_activity table in Cassandra:

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

**Key properties:**
- Write always to one partition → O(1) by partition key
- No JOINs, no cross-partition transactions
- Consistency is configurable: `QUORUM`, `ONE`, `ALL`
- Horizontal scaling — native (consistent hashing)

**When it fits:**
- Write-heavy workloads (IoT, events, metrics)
- Time-series data
- When the read pattern is known in advance (query-driven modeling)
- Horizontal scalability is needed without manual sharding

**When it doesn't fit:**
- Arbitrary queries without a partition key
- ACID transactions
- Frequent UPDATE/DELETE (tombstones are a problem)

---

### Graph: Neo4j

**Model:** nodes + edges/relationships + properties on both.

```
Social graph:

(Alice)-[:FOLLOWS]->(Bob)
(Bob)-[:FOLLOWS]->(Carol)
(Alice)-[:LIKES {since: "2024"}]->(Post#1)
(Post#1)-[:CREATED_BY]->(Bob)
(Alice)-[:FRIEND_OF {since: "2020"}]->(Dave)
```

```cypher
-- Find all posts from people Alice follows (2 hops)
MATCH (alice:User {name: "Alice"})-[:FOLLOWS]->(followed:User)
      -[:CREATED]->(post:Post)
RETURN post.title, followed.name
ORDER BY post.created_at DESC
LIMIT 20;

-- Shortest path between two users
MATCH p = shortestPath((alice:User {name: "Alice"})-[*]-(target:User {name: "Eve"}))
RETURN length(p), [n IN nodes(p) | n.name];
```

**When it fits:**
- Social graphs, recommendations
- Dependency graphs (packages, microservices)
- Fraud detection (connection patterns)
- Knowledge graphs

---

### Comparison Table

| | PostgreSQL | MongoDB | Redis | Cassandra | Neo4j |
|--|--|--|--|--|--|
| **Data model** | Relational (tables) | Documents (JSON) | Key-Value / structures | Wide-column | Graph |
| **Schema** | Fixed | Flexible | Schemaless | Partially fixed | Flexible |
| **Transactions** | ACID, multi-row | ACID (single doc; multi-doc since 4.0) | Limited (MULTI) | Lightweight transactions | ACID |
| **Consistency** | Strong | Configurable | Strong (single) / Eventually | Tunable (ONE→ALL) | Strong |
| **Scaling** | Vertical + read replicas | Horizontal sharding | Cluster (Redis Cluster) | Horizontal (native) | Vertical |
| **Queries** | SQL (arbitrary) | MQL (flexible) | By key | By partition key | Cypher (graph traversal) |
| **Latency** | 1-10ms | 1-10ms | <1ms (in-memory) | 1-5ms | Depends on depth |
| **Use case** | OLTP, primary DB | Catalogs, CMS, profiles | Cache, sessions, rate limiting | IoT, time-series, events | Social networks, recommendations |

---

## 6. How to Choose a Database

### Decision Tree

```
Need to choose a DB?
│
├── Data is highly relational (relations, FK, JOINs)?
│   └── YES → SQL (PostgreSQL)
│
├── Need ACID transactions?
│   └── YES → SQL (PostgreSQL) or MongoDB (4.0+)
│
├── Access pattern known in advance, write-heavy, need horizontal scale?
│   └── YES → Cassandra / ScyllaDB
│
├── Speed is the priority, data fits in memory?
│   └── YES → Redis
│
├── Data is a graph with multi-level relationships?
│   └── YES → Neo4j
│
├── Full-text search + aggregations across documents?
│   └── YES → Elasticsearch / OpenSearch
│
├── Heterogeneous schema, documents read/written as a whole?
│   └── YES → MongoDB
│
└── No specific requirements → PostgreSQL
    (richest feature set, maturity, ecosystem)
```

**Questions to ask:**

```
1. Access patterns:
   - Read-heavy (>80% reads) → can add read replicas / cache
   - Write-heavy → need append-friendly storage (Cassandra, Kafka+OLAP)
   - Mixed → PostgreSQL handles up to ~10K RPS

2. Data size:
   - <100GB → PostgreSQL without question
   - >1TB → need to think about sharding or Cassandra
   - In-memory → Redis

3. Consistency requirements:
   - Finance, inventory → Strong Consistency (SQL, Serializable)
   - Like counters, view counts → Eventual Consistency (Redis, Cassandra)

4. Query flexibility:
   - Arbitrary analytical queries → PostgreSQL or OLAP (ClickHouse)
   - Only by known keys → any NoSQL

5. Transactions:
   - Multi-entity consistency → SQL
   - Single-entity → anything

6. Team:
   - Know SQL? → PostgreSQL
   - No experience with Cassandra? → don't adopt it without a clear need
```

---

### Polyglot Persistence

In real systems, a single database rarely covers all needs. A typical architecture:

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

**Rule:** add a new DB only when PostgreSQL demonstrably cannot handle a specific requirement. Each new DB means ops burden, team training, and eventual consistency challenges.

---

### Real Examples: What Databases Major Companies Use

| Company | PostgreSQL | Redis | Cassandra | MongoDB | Specialized |
|---------|-----------|-------|-----------|---------|-------------|
| **Uber** | ✅ (core data) | ✅ (caching) | ✅ (trips history) | — | Schemaless (MySQL-compatible), DocStore |
| **Netflix** | — | ✅ | ✅ (EVCache, viewing history) | — | ClickHouse (analytics) |
| **Discord** | ✅ | ✅ | ✅ (messages) | — | ScyllaDB (migrated from Cassandra) |
| **Instagram** | ✅ (primary) | ✅ | — | — | Sharded PostgreSQL |
| **Notion** | ✅ | ✅ | — | — | PostgreSQL + RDS |
| **Shopify** | — | ✅ | — | — | MySQL + Redis |

**Discord and ScyllaDB:** Discord [published](https://discord.com/blog/how-discord-stores-trillions-of-messages) how they moved from MongoDB → Cassandra → ScyllaDB to store trillions of messages. Cassandra had latency tail issues during compaction; ScyllaDB (a C++ rewrite) solved the problem.

**Uber and Schemaless:** Uber built a custom key-value system on top of MySQL for horizontal scaling. They later migrated to their own DocStore.

---

## 7. Connection Pooling and Working with DBs in Go

### Why a Connection Pool is Needed

Each PostgreSQL connection is a separate backend process on the server (~5-10MB RAM). Establishing a TCP connection + auth + backend fork = ~1-5ms latency.

```
Without pool:
Request → TCP connect → auth → query → TCP disconnect
        ←─────── 5ms overhead ────────────────────→

With pool:
Request → get connection from pool → query → return connection
        ←────── <0.1ms overhead ─────────────────→
```

**PostgreSQL connection limit:**
```sql
-- Check the limit
SHOW max_connections;  -- typically 100-200 by default

-- Current connections
SELECT count(*) FROM pg_stat_activity;

-- By state
SELECT state, count(*)
FROM pg_stat_activity
GROUP BY state;
-- idle         — connection in pool, doing nothing
-- active       — executing a query
-- idle in tx   — in a transaction but not active → PROBLEM
```

**Rule of thumb:** `max_connections PostgreSQL ≈ (number of CPU cores) * 2 + number of disks`

With 10 service instances each with a pool of 10 connections = 100 connections. With 50 instances — you need **PgBouncer**.

---

### database/sql: Pool Configuration

```go
package db

import (
    "database/sql"
    "fmt"
    "time"

    _ "github.com/jackc/pgx/v5/stdlib" // pgx as driver for database/sql
)

func NewSQLDB(dsn string) (*sql.DB, error) {
    db, err := sql.Open("pgx", dsn)
    if err != nil {
        return nil, fmt.Errorf("open db: %w", err)
    }

    // Maximum open connections (including idle)
    // Rule: (max_postgres_connections / number_of_instances) - small buffer
    db.SetMaxOpenConns(25)

    // Maximum idle connections in the pool
    // Must be ≤ MaxOpenConns
    // For high load: = MaxOpenConns (to avoid creating connections under load)
    db.SetMaxIdleConns(25)

    // Maximum connection lifetime (from creation)
    // Allows connection rotation, useful during DNS changes (failover)
    db.SetConnMaxLifetime(5 * time.Minute)

    // Maximum idle time (since last use)
    // Frees resources when load drops
    db.SetConnMaxIdleTime(1 * time.Minute)

    return db, nil
}
```

**Parameters and their impact:**

| Parameter | Low value | High value | Recommendation |
|-----------|-----------|------------|----------------|
| `MaxOpenConns` | Request queue under load | PostgreSQL overload | 10-25 per instance |
| `MaxIdleConns` | Frequent connection creation | Many idle in DB | = MaxOpenConns |
| `ConnMaxLifetime` | Frequent reconnections | Failover problems | 5-30 minutes |
| `ConnMaxIdleTime` | Many idle connections | Reconnection overhead | 1-5 minutes |

---

### pgxpool: Configuration

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

    // Maximum connections in the pool
    cfg.MaxConns = 25

    // Minimum idle connections (always maintained)
    // Reduces latency of the first request after warm-up
    cfg.MinConns = 5

    // Maximum connection lifetime
    cfg.MaxConnLifetime = 30 * time.Minute

    // Jitter for MaxConnLifetime (prevents thundering herd on expiry)
    cfg.MaxConnLifetimeJitter = 5 * time.Minute

    // Maximum idle time
    cfg.MaxConnIdleTime = 5 * time.Minute

    // Health check period for detecting dead connections
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

### Example: Correct Configuration for a High-Load Service

```go
package main

import (
    "context"
    "log/slog"
    "os"
    "time"

    "github.com/jackc/pgx/v5/pgxpool"
)

// HighloadPoolConfig configuration for high load (>1000 RPS)
func HighloadPoolConfig(dsn string) *pgxpool.Config {
    cfg, _ := pgxpool.ParseConfig(dsn)

    // Scenario: 20 service instances, PostgreSQL max_connections=200
    // 200 / 20 = 10 connections per instance, leave buffer for psql and monitoring
    cfg.MaxConns = 8
    cfg.MinConns = 4  // keep connections warmed up

    cfg.MaxConnLifetime = 10 * time.Minute
    cfg.MaxConnLifetimeJitter = 2 * time.Minute
    cfg.MaxConnIdleTime = 3 * time.Minute

    // Health check — detect dead connections quickly
    cfg.HealthCheckPeriod = 30 * time.Second

    // Before acquire — check connection before giving it from the pool
    cfg.BeforeAcquire = func(ctx context.Context, conn *pgx.Conn) bool {
        return conn.Ping(ctx) == nil
    }

    return cfg
}

// Monitor pool state
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

### Common Mistakes

#### Connection Leak

```go
// ❌ WRONG: forgot to close rows
func getBadUsers(ctx context.Context, pool *pgxpool.Pool) ([]User, error) {
    rows, err := pool.Query(ctx, "SELECT id, email FROM users")
    if err != nil {
        return nil, err
    }
    // rows.Close() is never called!
    // Connection returns to pool only when rows is GC'd
    // → under load: all connections busy, new requests hang

    var users []User
    for rows.Next() {
        // ...
    }
    return users, nil
}

// ✅ CORRECT: defer rows.Close()
func getGoodUsers(ctx context.Context, pool *pgxpool.Pool) ([]User, error) {
    rows, err := pool.Query(ctx, "SELECT id, email FROM users")
    if err != nil {
        return nil, err
    }
    defer rows.Close() // ← always!

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

#### Transaction Without Rollback

```go
// ❌ WRONG: no defer tx.Rollback()
func badTransfer(ctx context.Context, pool *pgxpool.Pool) error {
    tx, _ := pool.Begin(ctx)

    _, err := tx.Exec(ctx, "UPDATE accounts SET balance = balance - 100 WHERE id = 1")
    if err != nil {
        return err // tx is not closed! connection leaked!
    }

    return tx.Commit(ctx)
}

// ✅ CORRECT: defer tx.Rollback() — idempotent after Commit
func goodTransfer(ctx context.Context, pool *pgxpool.Pool) error {
    tx, err := pool.Begin(ctx)
    if err != nil {
        return err
    }
    defer tx.Rollback(ctx) // rolls back only if Commit wasn't called

    _, err = tx.Exec(ctx, "UPDATE accounts SET balance = balance - 100 WHERE id = 1")
    if err != nil {
        return err
    }

    return tx.Commit(ctx)
}
```

#### Too Many Idle Connections

```go
// ❌ PROBLEM: MaxIdleConns >> actual load
// When traffic drops, we hold 25 idle connections → load on PostgreSQL

// ✅ SOLUTION: ConnMaxIdleTime releases unnecessary idle connections
db.SetConnMaxIdleTime(1 * time.Minute)

// Also: for workloads with large spikes — PgBouncer between service and DB
// PgBouncer maintains a small pool to PostgreSQL,
// accepts significantly more clients
```

#### Missing Context with Timeout

```go
// ❌ WRONG: query may hang forever
rows, err := pool.Query(context.Background(), "SELECT ...")

// ✅ CORRECT: context with timeout
ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
defer cancel()

rows, err := pool.Query(ctx, "SELECT ...")
// On timeout: query is cancelled on the PostgreSQL side
```

#### PgBouncer Configuration for Scale

```ini
# pgbouncer.ini — for high load with many service instances
[databases]
mydb = host=postgres-primary port=5432 dbname=mydb

[pgbouncer]
# Transaction pooling: connection returns to pool after each transaction
# Allows 1000 clients with 50 connections to PostgreSQL
pool_mode = transaction

# Connections to PostgreSQL
max_client_conn = 1000
default_pool_size = 50
min_pool_size = 10
reserve_pool_size = 10

# Timeouts
server_idle_timeout = 600
client_idle_timeout = 0
query_timeout = 0  # set at the application level

# IMPORTANT: with transaction pooling, the following do NOT work:
# - SET (session-level)
# - LISTEN/NOTIFY
# - prepared statements (without special configuration)
# - advisory locks (session-level)
```

---

## Module Summary

```
┌────────────────────────────────────────────────────────────────┐
│                         Key Takeaways                          │
├────────────────────────────────────────────────────────────────┤
│ PostgreSQL    │ The standard. MVCC gives reads without locks.  │
│               │ WAL is the foundation of durability/replication│
├───────────────┼────────────────────────────────────────────────┤
│ Indexes       │ B-tree covers 90% of cases.                    │
│               │ Column order in composite indexes is critical. │
│               │ EXPLAIN ANALYZE is a mandatory tool.           │
│               │ Unused indexes slow down writes.               │
├───────────────┼────────────────────────────────────────────────┤
│ Transactions  │ Read Committed is the default and enough for   │
│               │ CRUD. Finance → Serializable + FOR UPDATE.     │
│               │ MVCC: readers don't block writers.             │
├───────────────┼────────────────────────────────────────────────┤
│ Locks         │ Optimistic is better under low contention.     │
│               │ FOR UPDATE SKIP LOCKED — pattern for queues.   │
│               │ Deadlock = locks acquired in different order.  │
├───────────────┼────────────────────────────────────────────────┤
│ NoSQL         │ Redis — cache and sessions, not a primary DB.  │
│               │ Cassandra — write-heavy + horizontal scale.    │
│               │ MongoDB — flexible schema, prototypes.         │
├───────────────┼────────────────────────────────────────────────┤
│ DB selection  │ PostgreSQL by default until a clear need.      │
│               │ Polyglot: each DB for its own use case.        │
├───────────────┼────────────────────────────────────────────────┤
│ Connection    │ defer rows.Close() and defer tx.Rollback().    │
│ pooling       │ MaxOpenConns = max_postgres / instances.       │
│               │ PgBouncer when > 100 instances.                │
└───────────────┴────────────────────────────────────────────────┘
```

## Next Module

**Module 04: Caching** — Redis in depth, invalidation strategies, cache-aside vs write-through vs write-behind, the thundering herd problem, distributed cache.
