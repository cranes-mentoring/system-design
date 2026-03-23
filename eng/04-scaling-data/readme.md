# Module 04: Data Scaling

> **Previous module:** [03 — Caching](../03-caching/readme.md)  
> **Next module:** [05 — Queues and Asynchrony](../05-queues/readme.md)

---

## Table of Contents

1. [Replication](#1-replication)
2. [Partitioning](#2-partitioning)
3. [Sharding](#3-sharding)
4. [Consistent Hashing — deep dive](#4-consistent-hashing--deep-dive)
5. [Data Migration Strategies](#5-data-migration-strategies)
6. [Data Locality and Distributed Data](#6-data-locality-and-distributed-data)

---

## 1. Replication

### Why Replication Is Needed

Replication solves three independent problems — it's important to understand which one you're addressing:

| Problem | Mechanism | What It Provides |
|---|---|---|
| **Read scaling** | Read replicas | Horizontal read scalability; write load stays on the master |
| **High availability** | Failover replica | When the primary fails, one replica becomes the new primary |
| **Disaster recovery** | Geo-replica / backup | Recovery from datacenter loss; RPO and RTO |

Replication does **not** solve write scaling — that requires sharding.

---

### Master-Slave (Primary-Replica)

```
         Writes                Reads
           │                    │
    ┌──────▼──────┐      ┌─────▼─────┐   ┌───────────┐
    │   Primary   │─────▶│  Replica  │   │  Replica  │
    │  (master)   │─────▶│    #1     │   │    #2     │
    └─────────────┘  WAL └───────────┘   └───────────┘
                     stream
```

**How it works:**

1. The primary writes changes to the WAL (Write-Ahead Log).
2. WAL records are transferred to replicas — either as a stream (streaming replication) or via WAL files.
3. The replica applies the records to its own data copy (recovery mode).
4. The replica is read-only.

**Async vs Sync replication:**

```
Async (default in PostgreSQL):
  Primary ──WAL──▶ commit OK ──▶ client
                       │
                       └──▶ replica (eventually)

Sync:
  Primary ──WAL──▶ replica ACK ──▶ commit OK ──▶ client
                       │
                    (blocking)
```

| | Async | Sync |
|---|---|---|
| Write latency | Low | Higher (waiting for replica ACK) |
| Durability | Last transactions may be lost | Guaranteed |
| Availability | Replica lag does not block primary | If replica is unavailable, primary stalls too |
| Use case | Typical scenario | Finance, when not a single byte can be lost |

In PostgreSQL, sync replication is enabled via `synchronous_standby_names`:

```sql
-- postgresql.conf on primary
synchronous_commit = on
synchronous_standby_names = 'replica1'
```

---

### Multi-Master

Multi-Master is needed when a single writer is the bottleneck and write load is distributed geographically.

```
  Region EU                    Region US
┌────────────┐               ┌────────────┐
│  Master A  │◀──────────────▶  Master B  │
│            │  bidirectional │            │
└────────────┘  replication  └────────────┘
```

**When you need it:**
- Multi-region write workloads (a user in the EU needs to write with minimal latency).
- Active-Active architecture without a single point of failure.

**Problems:**
- **Write conflicts** — two masters simultaneously updated the same row. A conflict resolution strategy is required:
  - Last-Write-Wins (LWW) — the write with the later timestamp wins. Simple, but loses data.
  - Application-level merge — the application resolves the conflict (expensive, but reliable).
  - CRDTs — data structures whose merge is always deterministic.
- **Circular replication loops** — changes loop endlessly. Solved via origin tracking.

PostgreSQL does not support Multi-Master out of the box. Common solutions: **BDR (Bi-Directional Replication)** from EDB, **Citus**, **CockroachDB**.

---

### WAL Shipping in PostgreSQL

WAL (Write-Ahead Log) is an append-only journal of all changes to the database. Each data block is first changed in WAL, then in actual storage. This guarantees durability (the D in ACID).

**Two modes for transferring WAL to a replica:**

**1. WAL Archiving (file-based shipping)**
```
Primary ──WAL segment (16MB)──▶ archive storage ──▶ Replica
```
- The replica downloads completed WAL files.
- Lag = time to fill a segment (can be minutes).
- Used for backup and PITR (Point-In-Time Recovery).

**2. Streaming Replication (WAL stream)**
```
Primary ──continuous WAL stream──▶ Replica (wal receiver)
```
- The replica connects to the primary via the replication protocol.
- Lag — seconds or less.
- Standard mode for HA replicas.

Configuring streaming replication in PostgreSQL:

```ini
# postgresql.conf (primary)
wal_level = replica          # or logical for CDC
max_wal_senders = 10
wal_keep_size = 1GB          # WAL buffer for slow replicas

# pg_hba.conf (primary)
host  replication  replicator  10.0.0.0/8  md5
```

```ini
# recovery.conf / postgresql.conf (replica, PG 12+)
primary_conninfo = 'host=10.0.0.1 port=5432 user=replicator password=secret'
hot_standby = on
```

---

### Replication Lag: How to Measure and Why It's Dangerous

**Measurement:**

```sql
-- On primary: list replicas and their lag
SELECT
    client_addr,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    (sent_lsn - replay_lsn) AS replay_lag_bytes,
    write_lag,
    flush_lag,
    replay_lag
FROM pg_stat_replication;

-- On replica: lag in bytes
SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) AS lag_bytes;

-- Lag in seconds (PG 10+)
SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) AS lag_seconds;
```

**Alert in Prometheus / Grafana:**
```yaml
# prometheus alert
- alert: PostgresReplicationLagHigh
  expr: pg_replication_lag_seconds > 30
  for: 5m
  labels:
    severity: warning
```

**Why lag is dangerous:**

1. **Stale reads** — a user writes data, then immediately reads from the replica — the data isn't there yet. Classic scenario: registration → redirect → profile page fails to load.

2. **Failover data loss** — if the primary went down and the replica was N seconds behind, those transactions are lost (RPO > 0).

3. **Long-running queries on the replica** — block WAL record application, causing lag to grow.

**How to handle stale reads:**

```go
// Option 1: sticky sessions — after a write, read from primary for N seconds
// Option 2: read-your-writes via explicit routing
// Option 3: version token — pass the LSN to the client; replica waits until it reaches it
```

---

### Failover: Automatic vs Manual

**Manual failover** — an operator runs commands by hand:
```bash
# On replica:
pg_ctl promote -D /var/lib/postgresql/data
# Switch DNS / load balancer to the new primary
# Repoint all other replicas to the new primary
```

Downside: response time (minutes), risk of mistakes, requires human involvement.

**Automatic failover** — tools monitor state and switch over automatically.

**Patroni** (the most popular):
```
┌───────────────────────────────────────────┐
│                  etcd / consul            │  ◀─ distributed consensus
└───────────────────────────────────────────┘
         │                    │
  ┌──────▼──────┐      ┌──────▼──────┐
  │   Patroni   │      │   Patroni   │
  │  (primary)  │      │  (replica)  │
  │  PostgreSQL │      │  PostgreSQL │
  └─────────────┘      └─────────────┘
```

Patroni stores leader information in a DCS (etcd/consul/ZooKeeper). When the primary becomes unavailable, the replica with the highest LSN wins the election and is promoted. Switchover takes ~30 seconds.

```yaml
# patroni.yml (example config)
scope: postgres-cluster
name: node1

etcd:
  host: etcd:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 30
    maximum_lag_on_failover: 1048576  # 1MB — replica won't be promoted if lag > 1MB

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.0.1:5432
  data_dir: /data/patroni
```

**pg_auto_failover** — a simpler alternative from Microsoft, built around a monitor + keeper architecture.

---

### Read Replicas: Routing Read/Write Traffic

Goal: writes → primary, reads → one of the replicas (round-robin or least-connections).

Implementation options:

1. **At the application level** — two connection pools in code: one to the primary, one (or more) to replicas.
2. **HAProxy / PgBouncer** — the proxy listens on two ports: 5432 (write) and 5433 (read), routing to the appropriate backend.
3. **AWS RDS Proxy / Aurora** — a managed solution that automatically routes read-only transactions.

---

### Example: docker-compose with PostgreSQL master + replica

```yaml
# docker-compose.yml
version: "3.9"

services:
  postgres-primary:
    image: postgres:16
    environment:
      POSTGRES_USER: app
      POSTGRES_PASSWORD: secret
      POSTGRES_DB: mydb
    command: >
      postgres
        -c wal_level=replica
        -c max_wal_senders=5
        -c wal_keep_size=256MB
        -c hot_standby=on
    volumes:
      - pg-primary-data:/var/lib/postgresql/data
      - ./init-replication.sh:/docker-entrypoint-initdb.d/init-replication.sh
    ports:
      - "5432:5432"

  postgres-replica:
    image: postgres:16
    environment:
      PGUSER: replicator
      PGPASSWORD: repl_secret
    command: >
      bash -c "
        until pg_basebackup -h postgres-primary -D /var/lib/postgresql/data -U replicator -Fp -Xs -P -R; do
          echo 'Waiting for primary...'; sleep 2;
        done
        postgres
      "
    volumes:
      - pg-replica-data:/var/lib/postgresql/data
    ports:
      - "5433:5432"
    depends_on:
      - postgres-primary

volumes:
  pg-primary-data:
  pg-replica-data:
```

```bash
# init-replication.sh
#!/bin/bash
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE USER replicator REPLICATION LOGIN ENCRYPTED PASSWORD 'repl_secret';
EOSQL

echo "host replication replicator 0.0.0.0/0 md5" >> "$PGDATA/pg_hba.conf"
```

---

### Go Example: Routing Requests to Primary/Replica via pgx

```go
package db

import (
    "context"
    "fmt"
    "sync/atomic"

    "github.com/jackc/pgx/v5/pgxpool"
)

// DBCluster holds connection pools for primary and replicas.
type DBCluster struct {
    primary  *pgxpool.Pool
    replicas []*pgxpool.Pool
    counter  atomic.Uint64 // round-robin counter
}

func NewDBCluster(ctx context.Context, primaryDSN string, replicaDSNs []string) (*DBCluster, error) {
    primary, err := pgxpool.New(ctx, primaryDSN)
    if err != nil {
        return nil, fmt.Errorf("primary connect: %w", err)
    }

    replicas := make([]*pgxpool.Pool, 0, len(replicaDSNs))
    for _, dsn := range replicaDSNs {
        pool, err := pgxpool.New(ctx, dsn)
        if err != nil {
            return nil, fmt.Errorf("replica connect %s: %w", dsn, err)
        }
        replicas = append(replicas, pool)
    }

    return &DBCluster{primary: primary, replicas: replicas}, nil
}

// Writer returns the primary pool for write operations.
func (c *DBCluster) Writer() *pgxpool.Pool {
    return c.primary
}

// Reader returns a replica pool using round-robin.
// Falls back to primary if no replicas configured.
func (c *DBCluster) Reader() *pgxpool.Pool {
    if len(c.replicas) == 0 {
        return c.primary
    }
    idx := c.counter.Add(1) % uint64(len(c.replicas))
    return c.replicas[idx]
}

func (c *DBCluster) Close() {
    c.primary.Close()
    for _, r := range c.replicas {
        r.Close()
    }
}
```

```go
// Usage
func (s *UserService) CreateUser(ctx context.Context, u *User) error {
    _, err := s.db.Writer().Exec(ctx,
        `INSERT INTO users (id, email) VALUES ($1, $2)`,
        u.ID, u.Email,
    )
    return err
}

func (s *UserService) GetUser(ctx context.Context, id int64) (*User, error) {
    var u User
    err := s.db.Reader().QueryRow(ctx,
        `SELECT id, email FROM users WHERE id = $1`,
        id,
    ).Scan(&u.ID, &u.Email)
    if err != nil {
        return nil, err
    }
    return &u, nil
}
```

> **Important:** after a write operation, if you need to immediately read your own data — use `Writer()` for the read to avoid a stale read caused by replication lag.

---

## 2. Partitioning

Partitioning — splitting a single logical table into physical pieces **within one server** (as opposed to sharding, where pieces live on different servers).

### Why

- **Performance**: the query planner excludes irrelevant partitions (partition pruning) — `WHERE date > '2024-01-01'` scans only the relevant ones.
- **Maintenance**: `DROP TABLE partition_2022` instead of `DELETE FROM events WHERE year = 2022` — instant, no bloat.
- **Storage tiering**: old partitions on cheap storage, hot ones on NVMe.
- **Parallel query**: partitions are processed in parallel.

---

### Vertical Partitioning

Splitting a table by **columns**: rarely used or large columns are moved to a separate table.

```sql
-- Before: single table
CREATE TABLE users (
    id          BIGINT PRIMARY KEY,
    email       TEXT,
    name        TEXT,
    -- blob fields, rarely needed:
    avatar      BYTEA,
    settings    JSONB,
    bio         TEXT
);

-- After: vertical partitioning
CREATE TABLE users (
    id    BIGINT PRIMARY KEY,
    email TEXT NOT NULL,
    name  TEXT
);

CREATE TABLE user_profiles (
    user_id  BIGINT PRIMARY KEY REFERENCES users(id),
    avatar   BYTEA,
    settings JSONB,
    bio      TEXT
);
```

Result: most queries to `users` don't read blob columns → less I/O, better cache hit ratio.

---

### Horizontal Partitioning

Splitting a table by **rows** based on the value of one or more columns (the partition key).

#### Range Partitioning

The most common case — partitioning by date:

```sql
CREATE TABLE events (
    id         BIGINT,
    user_id    BIGINT,
    event_type TEXT,
    created_at TIMESTAMPTZ NOT NULL,
    payload    JSONB
) PARTITION BY RANGE (created_at);

-- Create monthly partitions
CREATE TABLE events_2024_01 PARTITION OF events
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

CREATE TABLE events_2024_02 PARTITION OF events
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');

CREATE TABLE events_2024_03 PARTITION OF events
    FOR VALUES FROM ('2024-03-01') TO ('2024-04-01');

-- Default partition for data outside defined ranges
CREATE TABLE events_default PARTITION OF events DEFAULT;
```

**Partition pruning in action:**

```sql
-- PostgreSQL automatically scans only events_2024_02
EXPLAIN SELECT * FROM events
WHERE created_at >= '2024-02-01' AND created_at < '2024-03-01';

-- Output:
-- Append
--   ->  Seq Scan on events_2024_02
--         Filter: (created_at >= '2024-02-01' AND created_at < '2024-03-01')
```

**Automatic partition creation** (pg_partman):

```sql
-- pg_partman automatically creates and drops partitions on a schedule
SELECT partman.create_parent(
    p_parent_table => 'public.events',
    p_control      => 'created_at',
    p_type         => 'range',
    p_interval     => 'monthly',
    p_premake      => 3  -- pre-create 3 future partitions in advance
);
```

#### List Partitioning

By discrete values — region, status, type:

```sql
CREATE TABLE orders (
    id         BIGINT,
    region     TEXT NOT NULL,
    status     TEXT,
    amount     NUMERIC,
    created_at TIMESTAMPTZ
) PARTITION BY LIST (region);

CREATE TABLE orders_eu PARTITION OF orders
    FOR VALUES IN ('DE', 'FR', 'IT', 'ES', 'NL');

CREATE TABLE orders_us PARTITION OF orders
    FOR VALUES IN ('US', 'CA', 'MX');

CREATE TABLE orders_apac PARTITION OF orders
    FOR VALUES IN ('JP', 'KR', 'SG', 'AU');

CREATE TABLE orders_other PARTITION OF orders DEFAULT;
```

#### Hash Partitioning

Even distribution by the hash value of a key, when there is no obvious range or list:

```sql
CREATE TABLE user_activities (
    id      BIGINT,
    user_id BIGINT NOT NULL,
    action  TEXT,
    ts      TIMESTAMPTZ
) PARTITION BY HASH (user_id);

-- 8 partitions — modulus 8
CREATE TABLE user_activities_0 PARTITION OF user_activities
    FOR VALUES WITH (MODULUS 8, REMAINDER 0);
CREATE TABLE user_activities_1 PARTITION OF user_activities
    FOR VALUES WITH (MODULUS 8, REMAINDER 1);
-- ... up to REMAINDER 7
```

---

### Automatic Deletion of Old Partitions

```sql
-- DROP PARTITION — instant operation, leaves no bloat
-- Equivalent to DROP TABLE, but without breaking the parent table structure

DROP TABLE events_2022_01;  -- drop the January 2022 partition

-- vs. DELETE — slow, bloat, WAL load:
DELETE FROM events WHERE created_at < '2022-02-01';  -- NEVER do this on large tables
```

**Script for cron-based deletion of old partitions:**

```sql
-- Drop all partitions older than 12 months
DO $$
DECLARE
    partition_name TEXT;
BEGIN
    FOR partition_name IN
        SELECT inhrelid::regclass::text
        FROM pg_inherits
        WHERE inhparent = 'events'::regclass
        AND inhrelid::regclass::text < 'events_' || to_char(now() - interval '12 months', 'YYYY_MM')
    LOOP
        EXECUTE 'DROP TABLE ' || partition_name;
        RAISE NOTICE 'Dropped partition: %', partition_name;
    END LOOP;
END;
$$;
```

---

### Indexes and Constraints on Partitioned Tables

```sql
-- An index on the parent table is automatically created on all partitions
CREATE INDEX idx_events_user_id ON events (user_id);

-- Primary key must include the partition key
ALTER TABLE events ADD PRIMARY KEY (id, created_at);

-- Foreign keys referencing a partitioned table — not supported
-- (implemented via triggers or at the application level)
```

---

## 3. Sharding

Sharding — horizontal partitioning **at the level of separate database servers/instances**. Each shard is an independent database with its own subset of data.

```
                    ┌─────────────┐
                    │  App Layer  │
                    │ Shard Router│
                    └──────┬──────┘
            ┌──────────────┼──────────────┐
            │              │              │
     ┌──────▼──────┐ ┌─────▼──────┐ ┌────▼───────┐
     │  Shard #0   │ │  Shard #1  │ │  Shard #2  │
     │  users 0-33%│ │ users 33-66│ │ users 66-99│
     │  PostgreSQL │ │ PostgreSQL │ │ PostgreSQL │
     └─────────────┘ └────────────┘ └────────────┘
```

**Key difference from partitioning:**
- Partitioning: one server, multiple files, transparent to the application.
- Sharding: multiple servers, the application (or middleware) knows where to route the request.

---

### Sharding Strategies

#### 1. Hash-based Sharding (`user_id % N`)

```
shard_id = hash(user_id) % num_shards
```

```
user_id=100  → hash → 0x64... → 0x64 % 4 = 0  → Shard #0
user_id=101  → hash → 0x65... → 0x65 % 4 = 1  → Shard #1
user_id=200  → hash → 0xC8... → 0xC8 % 4 = 0  → Shard #0
```

✅ Even distribution  
✅ Simple implementation  
❌ **Resharding is painful**: when N changes, almost all keys move to a different shard (`N → N+1`: 100 % 4 = 0, 100 % 5 = 0 — lucky, but 101 % 4 = 1, 101 % 5 = 1, 102 % 4 = 2, 102 % 5 = 2 — only ~1/N keys stay in place)  
❌ No range queries: `WHERE user_id BETWEEN 1000 AND 2000` hits all shards

#### 2. Range-based Sharding

```
user_id 1–1,000,000      → Shard #0
user_id 1,000,001–2,000,000 → Shard #1
user_id 2,000,001–...    → Shard #2
```

✅ Supports range queries  
✅ Simple resharding (add a new shard for new ranges)  
❌ **Hotspot**: new users always write to the last shard  
❌ Uneven distribution (active users may cluster in one range)

#### 3. Directory-based Sharding (Lookup Table)

```
┌──────────────────────────────────┐
│        Lookup Service            │
│  user_id → shard_id mapping      │
│  (Redis / dedicated DB)          │
└──────────────┬───────────────────┘
               │ lookup(user_id)
     ┌─────────▼──────────┐
     │    Shard Router     │
     └─────────────────────┘
```

```
user_id=100  → lookup → shard_id=2  → Shard #2
user_id=101  → lookup → shard_id=0  → Shard #0
```

✅ Maximum flexibility: a user can be moved to a different shard without resharding  
✅ Easy to balance load  
❌ **Single point of failure**: if the lookup service goes down, nothing works  
❌ Extra network hop on every request  
❌ The lookup service must be scaled separately

#### 4. Consistent Hashing

Solves the resharding problem of hash-based sharding. Covered in detail in section 4.

---

### Shard Key: How to Choose

The shard key — a column (or combination) by which requests are routed. The choice is critical.

**Good shard keys:**

| Use Case | Shard Key | Why |
|---|---|---|
| Multi-tenant application | `user_id` | All user data on one shard, joins within the shard |
| SaaS platform | `tenant_id` | Full isolation of customer data |
| E-commerce | `order_id` | Even distribution, order operations are atomic |
| Geo service | `region` | Data locality |

**Bad shard keys:**

```sql
-- BAD: monotonically increasing timestamp → hotspot on the last shard
shard_key = created_at

-- BAD: low cardinality → few shards, some empty
shard_key = status  -- ('active', 'inactive', 'banned' — only 3 values)

-- BAD: null values
shard_key = optional_field
```

---

### Problems with Sharding

#### Cross-shard Queries (JOINs across shards)

```sql
-- This query requires data from different shards:
SELECT u.name, SUM(o.amount)
FROM users u JOIN orders o ON u.id = o.user_id
GROUP BY u.name;
```

**Solutions:**
1. **Scatter-Gather**: the query goes to all shards in parallel, results are merged in the application.
2. **Denormalization**: duplicate the needed fields (store the user name in the orders table).
3. **Global tables**: reference data (list of countries, categories) is replicated to all shards.

#### Cross-shard Transactions

```
BEGIN;
  UPDATE accounts SET balance = balance - 100 WHERE id = 1;  -- Shard #0
  UPDATE accounts SET balance = balance + 100 WHERE id = 2;  -- Shard #1
COMMIT;
```

Two shards — no atomicity guarantee without a distributed transaction protocol (2PC, 3PC, Saga).

**2PC (Two-Phase Commit):**
```
Coordinator → Shard #0: PREPARE
Coordinator → Shard #1: PREPARE
← Shard #0: READY
← Shard #1: READY
Coordinator → Shard #0: COMMIT
Coordinator → Shard #1: COMMIT
```
Slow (2 round-trips), coordinator is a single point of failure. Avoided in production.

**Saga Pattern** — split the transaction into a sequence of local transactions with compensating actions:
```
Debit(user_1) → on failure → Compensate(Credit(user_1))
Credit(user_2) → on failure → Compensate(Debit(user_2))
```

#### Hotspot Shards

In a social network, the `posts` table is sharded by `user_id`. A celebrity post with 100M followers → Shard #N receives 1000x more traffic.

**Solutions:**
- **Shard splitting**: split the hot shard into multiple shards.
- **Celebrity key treatment**: route celebrities in a special way (to dedicated shards or cache).
- **Write amplification via queue**: writes are buffered in a queue, fanout happens asynchronously.

#### Rebalancing When Adding Shards

When a new sharding node is added, part of the data must be moved:

```
Before:  3 shards → Shard 0, 1, 2
After: 4 shards → Shard 0, 1, 2, 3

With hash % N: ~75% of data changes shard (almost everything moves)
With consistent hashing: ~25% of data changes shard (only 1/N moves)
```

---

### Sharding: Application vs Middleware

| | Application-level | Middleware (Vitess/Citus) |
|---|---|---|
| Control | Full | Limited to middleware capabilities |
| Complexity | High (logic in code) | Lower (transparent to application) |
| Flexibility | Any strategy | Depends on middleware |
| SQL compatibility | Must write shard-aware queries | Full (middleware translates) |
| Examples | — | Vitess (MySQL), Citus (PG), ProxySQL |

---

### Go Example: Shard Router by user_id

```go
package shard

import (
    "context"
    "fmt"
    "hash/fnv"

    "github.com/jackc/pgx/v5/pgxpool"
)

// ShardRouter routes queries to the correct shard based on user_id.
type ShardRouter struct {
    shards []*pgxpool.Pool
}

func NewShardRouter(ctx context.Context, dsns []string) (*ShardRouter, error) {
    shards := make([]*pgxpool.Pool, len(dsns))
    for i, dsn := range dsns {
        pool, err := pgxpool.New(ctx, dsn)
        if err != nil {
            return nil, fmt.Errorf("shard %d connect: %w", i, err)
        }
        shards[i] = pool
    }
    return &ShardRouter{shards: shards}, nil
}

// ShardFor returns the shard index for a given user ID.
func (r *ShardRouter) ShardFor(userID int64) int {
    h := fnv.New32a()
    _, _ = fmt.Fprintf(h, "%d", userID)
    return int(h.Sum32()) % len(r.shards)
}

// DB returns the pool for the given user ID.
func (r *ShardRouter) DB(userID int64) *pgxpool.Pool {
    return r.shards[r.ShardFor(userID)]
}

// Close closes all shard connections.
func (r *ShardRouter) Close() {
    for _, s := range r.shards {
        s.Close()
    }
}
```

```go
// Usage
type Order struct {
    ID     int64
    UserID int64
    Amount float64
}

type OrderRepository struct {
    router *shard.ShardRouter
}

func (r *OrderRepository) Create(ctx context.Context, o *Order) error {
    db := r.router.DB(o.UserID)
    _, err := db.Exec(ctx,
        `INSERT INTO orders (id, user_id, amount) VALUES ($1, $2, $3)`,
        o.ID, o.UserID, o.Amount,
    )
    return err
}

func (r *OrderRepository) GetByUser(ctx context.Context, userID int64) ([]Order, error) {
    db := r.router.DB(userID)
    rows, err := db.Query(ctx,
        `SELECT id, user_id, amount FROM orders WHERE user_id = $1`,
        userID,
    )
    if err != nil {
        return nil, err
    }
    defer rows.Close()

    var orders []Order
    for rows.Next() {
        var o Order
        if err := rows.Scan(&o.ID, &o.UserID, &o.Amount); err != nil {
            return nil, err
        }
        orders = append(orders, o)
    }
    return orders, rows.Err()
}

// Cross-shard query: must hit all shards
func (r *OrderRepository) GetTotalRevenue(ctx context.Context) (float64, error) {
    type result struct {
        total float64
        err   error
    }

    results := make(chan result, len(r.router.Shards()))
    for _, pool := range r.router.Shards() {
        pool := pool
        go func() {
            var total float64
            err := pool.QueryRow(ctx, `SELECT COALESCE(SUM(amount), 0) FROM orders`).Scan(&total)
            results <- result{total, err}
        }()
    }

    var grandTotal float64
    for range r.router.Shards() {
        res := <-results
        if res.err != nil {
            return 0, res.err
        }
        grandTotal += res.total
    }
    return grandTotal, nil
}
```

---

## 4. Consistent Hashing — deep dive

### The Problem with Plain `hash % N`

When a node is added or removed, N changes and most keys move:

```
3 nodes: key → hash % 3
  key="user:100" → hash=1000 → 1000 % 3 = 1  → Node 1
  key="user:200" → hash=2000 → 2000 % 3 = 2  → Node 2
  key="user:300" → hash=3000 → 3000 % 3 = 0  → Node 0

Adding Node 3: key → hash % 4
  key="user:100" → 1000 % 4 = 0  → Node 0  ← MOVED
  key="user:200" → 2000 % 4 = 0  → Node 0  ← MOVED
  key="user:300" → 3000 % 4 = 3  → Node 3  ← MOVED
```

Going from N=3 → N=4 moves ~75% of keys. For a cache, this means a cache miss storm. For shards — a massive volume of data movement.

---

### How Consistent Hashing Works

**Hash ring** — a virtual ring of hash values `[0, 2^32)`.

1. Each node is placed on the ring by its hash: `hash(node_name)`.
2. A key is also hashed and placed on the ring.
3. The key belongs to the **first node clockwise** from its position.

```
Hash Ring (0 ... 2^32)

              0
         ┌────┴────┐
    2^30 │         │ 2^2
         │         │
     Node A      Node B
      (hash=      (hash=
      0x10...)   0x80...)
         │         │
    2^31 │         │ 2^31+1
         └────┬────┘
             2^31

Key K1 (hash=0x20...) → next node clockwise = Node B
Key K2 (hash=0x90...) → next node clockwise = Node A (wrapped around 0)
```

**When adding Node C:**
- Node C takes a position on the ring.
- Only keys between the previous node and Node C are moved.
- All other keys are untouched.
- Theoretically `1/N` keys are moved.

---

### Virtual Nodes

Without virtual nodes: nodes are unevenly distributed on the ring → different data volumes.

Virtual nodes: each physical node is represented by **K virtual nodes** on the ring:

```
Physical node A → A#0, A#1, A#2, ..., A#99  (100 virtual nodes)
Physical node B → B#0, B#1, B#2, ..., B#99
Physical node C → C#0, C#1, C#2, ..., C#99
```

```
   0────────────────────────────────────────────2^32

   A#3    B#1    C#2    A#0    B#2    C#0    A#1    B#0
   ──●──────●──────●──────●──────●──────●──────●──────●──
```

Result:
- Data is distributed evenly (law of large numbers).
- When node D is added, its virtual nodes evenly "take" keys from all existing nodes.
- The larger K, the more even the distribution (and the more memory used for ring metadata).

---

### Go Example: Consistent Hash Ring with Virtual Nodes

```go
package consistenthash

import (
    "crypto/sha256"
    "encoding/binary"
    "fmt"
    "sort"
    "sync"
)

// Ring implements consistent hashing with virtual nodes.
type Ring struct {
    mu           sync.RWMutex
    virtualNodes int            // replicas per physical node
    ring         []uint32       // sorted list of virtual node positions
    nodeMap      map[uint32]string // position → physical node name
}

// New creates a new Ring with the given number of virtual nodes per physical node.
func New(virtualNodes int) *Ring {
    return &Ring{
        virtualNodes: virtualNodes,
        nodeMap:      make(map[uint32]string),
    }
}

// hash computes a uint32 position on the ring for the given key.
func hash(key string) uint32 {
    h := sha256.Sum256([]byte(key))
    return binary.BigEndian.Uint32(h[:4])
}

// AddNode adds a physical node to the ring.
func (r *Ring) AddNode(node string) {
    r.mu.Lock()
    defer r.mu.Unlock()

    for i := 0; i < r.virtualNodes; i++ {
        vnode := fmt.Sprintf("%s#%d", node, i)
        pos := hash(vnode)
        r.ring = append(r.ring, pos)
        r.nodeMap[pos] = node
    }
    sort.Slice(r.ring, func(i, j int) bool { return r.ring[i] < r.ring[j] })
}

// RemoveNode removes a physical node from the ring.
func (r *Ring) RemoveNode(node string) {
    r.mu.Lock()
    defer r.mu.Unlock()

    for i := 0; i < r.virtualNodes; i++ {
        vnode := fmt.Sprintf("%s#%d", node, i)
        pos := hash(vnode)
        delete(r.nodeMap, pos)

        // Remove pos from the sorted ring slice
        idx := sort.Search(len(r.ring), func(j int) bool { return r.ring[j] >= pos })
        if idx < len(r.ring) && r.ring[idx] == pos {
            r.ring = append(r.ring[:idx], r.ring[idx+1:]...)
        }
    }
}

// GetNode returns the physical node responsible for the given key.
func (r *Ring) GetNode(key string) string {
    r.mu.RLock()
    defer r.mu.RUnlock()

    if len(r.ring) == 0 {
        return ""
    }

    pos := hash(key)
    // Binary search: find the first virtual node position >= pos
    idx := sort.Search(len(r.ring), func(i int) bool { return r.ring[i] >= pos })
    // Wrap around: if pos is past the last node, use the first
    if idx == len(r.ring) {
        idx = 0
    }

    return r.nodeMap[r.ring[idx]]
}

// GetNodes returns the N distinct physical nodes responsible for the key (for replication).
func (r *Ring) GetNodes(key string, count int) []string {
    r.mu.RLock()
    defer r.mu.RUnlock()

    if len(r.ring) == 0 {
        return nil
    }

    pos := hash(key)
    idx := sort.Search(len(r.ring), func(i int) bool { return r.ring[i] >= pos })

    seen := make(map[string]bool)
    var nodes []string
    for len(nodes) < count {
        node := r.nodeMap[r.ring[idx%len(r.ring)]]
        if !seen[node] {
            seen[node] = true
            nodes = append(nodes, node)
        }
        idx++
        if idx >= len(r.ring)*2 { // prevent infinite loop if count > num physical nodes
            break
        }
    }
    return nodes
}
```

```go
// Example usage
func Example() {
    ring := consistenthash.New(150) // 150 virtual nodes per physical node

    ring.AddNode("cache-1")
    ring.AddNode("cache-2")
    ring.AddNode("cache-3")

    keys := []string{"user:100", "user:200", "user:300", "session:abc", "session:xyz"}
    for _, key := range keys {
        node := ring.GetNode(key)
        fmt.Printf("%s → %s\n", key, node)
    }
    // user:100  → cache-2
    // user:200  → cache-1
    // user:300  → cache-3
    // session:abc → cache-1
    // session:xyz → cache-2

    // Add a new node: only ~25% of keys should move
    ring.AddNode("cache-4")
    for _, key := range keys {
        node := ring.GetNode(key)
        fmt.Printf("%s → %s\n", key, node)
    }
}
```

**Distribution uniformity test:**

```go
func TestDistribution(t *testing.T) {
    ring := New(150)
    ring.AddNode("node-1")
    ring.AddNode("node-2")
    ring.AddNode("node-3")

    distribution := make(map[string]int)
    for i := 0; i < 100_000; i++ {
        key := fmt.Sprintf("key:%d", i)
        node := ring.GetNode(key)
        distribution[node]++
    }

    // Expect roughly 33333 per node, verify no node has > 40% or < 25%
    for node, count := range distribution {
        pct := float64(count) / 1000
        t.Logf("node=%s count=%d (%.1f%%)", node, count, pct)
        if pct > 40 || pct < 25 {
            t.Errorf("uneven distribution for %s: %.1f%%", node, pct)
        }
    }
}
```

---

### Where Consistent Hashing Is Used

| System | Application |
|---|---|
| **Cassandra** | Data partitioning via token ring; virtual nodes enabled by default with vnode count=256 |
| **DynamoDB** | Internal mechanism for distributing data across storage nodes |
| **Amazon S3** | Distribution of objects across storage nodes |
| **Memcached** | Client-side consistent hashing for cache sharding (libketama) |
| **Redis Cluster** | Hash slots (16384 slots) — a variant of consistent hashing |
| **CDN (Akamai, Fastly)** | Routing requests to edge nodes |
| **Nginx upstream** | Consistent hash for sticky sessions |

---

## 5. Data Migration Strategies

Data migration — changing the structure or location of data without losing availability. The key question: how to migrate with zero downtime?

### Dual Write

The application writes to both systems (old and new) simultaneously:

```
           Write
             │
    ┌────────▼────────┐
    │   Application   │
    └────┬──────┬─────┘
         │      │
    ┌────▼──┐ ┌─▼──────┐
    │ Old DB│ │ New DB  │
    └───────┘ └─────────┘
```

**Phases:**

```
Phase 1: Initial sync
  → Bulk copy old data to the new DB (pg_dump, custom script)
  → Simultaneously launch dual write in the application

Phase 2: Dual write active
  → Writes go to both DBs
  → Reads still from the old DB
  → Verify data consistency

Phase 3: Switch reads
  → Switch reads to the new DB
  → Dual write continues (rollback is possible)

Phase 4: Finalization
  → Remove dual write
  → Old DB goes to archive
```

**Problems with dual write:**
- No atomicity between old and new DB: write succeeded in one, failed in the other → inconsistency.
- Verification and reconciliation logic is required.

```go
// Dual write with best-effort and divergence logging
func (s *Service) CreateOrder(ctx context.Context, o *Order) error {
    // Write to old DB (primary)
    if err := s.oldDB.Create(ctx, o); err != nil {
        return err // Don't write to new DB if old one failed
    }

    // Write to new DB (best-effort)
    if err := s.newDB.Create(ctx, o); err != nil {
        // Don't return an error to the client, but log for reconciliation
        s.logger.Error("dual write failed for new DB",
            "order_id", o.ID, "err", err)
        s.metrics.IncCounter("dual_write_failures")
    }

    return nil
}
```

---

### Change Data Capture (CDC)

CDC intercepts data changes at the WAL level (for PostgreSQL) or binlog (MySQL) and publishes them as an event stream.

```
PostgreSQL WAL
      │
  ┌───▼────────────────┐
  │ Debezium Connector │  ← reads WAL via logical replication
  │ (pgoutput plugin)  │
  └───────────┬────────┘
              │
     ┌────────▼────────┐
     │   Kafka Topic   │  ← events: INSERT/UPDATE/DELETE
     └────────┬────────┘
              │
    ┌──────────▼──────────┐
    │  Consumer (new DB)  │  ← applies events to the new DB
    └─────────────────────┘
```

**Setup in PostgreSQL:**

```sql
-- Enable logical replication
ALTER SYSTEM SET wal_level = logical;
-- pg_reload_conf() or restart

-- Create a publication for the required tables
CREATE PUBLICATION my_migration_pub FOR TABLE orders, users, products;

-- Debezium connects as a logical replication slot
SELECT pg_create_logical_replication_slot('debezium_slot', 'pgoutput');
```

**Debezium config (Kafka Connect):**

```json
{
  "name": "postgres-source",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "postgres-primary",
    "database.port": "5432",
    "database.user": "debezium",
    "database.password": "secret",
    "database.dbname": "mydb",
    "database.server.name": "mydb",
    "plugin.name": "pgoutput",
    "publication.name": "my_migration_pub",
    "slot.name": "debezium_slot",
    "table.include.list": "public.orders,public.users"
  }
}
```

CDC events in Kafka:

```json
{
  "op": "c",           // c=create, u=update, d=delete, r=read(snapshot)
  "ts_ms": 1700000000000,
  "before": null,
  "after": {
    "id": 42,
    "user_id": 100,
    "amount": 99.99,
    "created_at": "2024-01-15T10:00:00Z"
  },
  "source": {
    "lsn": "0/1A2B3C4",
    "table": "orders"
  }
}
```

---

### Expand-Contract Pattern (Online Migration)

The safest way to change a schema without downtime. Three phases:

**Example: renaming column `user_name` → `username`**

```
Phase 1: EXPAND
  → Add the new column username (nullable)
  → A trigger or the application copies data on each write
  → Background backfill: UPDATE users SET username = user_name WHERE username IS NULL
  → Deploy the application version that writes to BOTH columns, reads from the old one

Phase 2: MIGRATE READS
  → Deploy a version that reads from the new column
  → Still writes to both (backward compatibility)

Phase 3: CONTRACT
  → Confirm no code reads the old column
  → Deploy a version that writes only to the new column
  → DROP COLUMN user_name
```

```sql
-- Phase 1: EXPAND
ALTER TABLE users ADD COLUMN username TEXT;

-- Trigger to automatically sync on write
CREATE OR REPLACE FUNCTION sync_username()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.username IS NULL AND NEW.user_name IS NOT NULL THEN
        NEW.username := NEW.user_name;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sync_username
    BEFORE INSERT OR UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION sync_username();

-- Background backfill (in batches, to avoid locking the table)
DO $$
DECLARE
    batch_size INT := 1000;
    last_id BIGINT := 0;
    max_id BIGINT;
BEGIN
    SELECT MAX(id) INTO max_id FROM users;
    WHILE last_id < max_id LOOP
        UPDATE users
        SET username = user_name
        WHERE id > last_id AND id <= last_id + batch_size
          AND username IS NULL;
        last_id := last_id + batch_size;
        PERFORM pg_sleep(0.01); -- small pause to avoid hammering I/O
    END LOOP;
END;
$$;

-- Phase 3: CONTRACT (after deploying the new code)
ALTER TABLE users DROP COLUMN user_name;
DROP TRIGGER trg_sync_username ON users;
DROP FUNCTION sync_username();
```

**Readiness check before CONTRACT:**

```sql
-- Confirm no rows have NULL in the new column
SELECT COUNT(*) FROM users WHERE username IS NULL;
-- Must be 0

-- Add NOT NULL constraint (with DEFAULT or VALIDATE)
ALTER TABLE users ALTER COLUMN username SET NOT NULL;
```

---

### Zero-Downtime Migration Checklist

```
□ All DDL operations — only backward-compatible changes
  □ Adding a column: nullable or with DEFAULT
  □ Adding an index: CREATE INDEX CONCURRENTLY (does not lock)
  □ Dropping a column: only after no code uses it
  □ Renaming: via expand-contract, not ALTER TABLE ... RENAME

□ Backfill — in batches with pauses, not UPDATE on the entire table

□ Validating constraints: ALTER TABLE ... VALIDATE CONSTRAINT
  (not ADD CONSTRAINT — that locks)

□ Monitor replication lag during migration
  (large backfill → WAL storm → replica lag grows)

□ Feature flags for switching read/write to the new schema
```

---

## 6. Data Locality and Distributed Data

### Geo-Partitioning: Data Close to the User

Data is stored in the geographic zone where the user lives — to reduce latency and for compliance (GDPR requires EU citizen data to be stored in the EU).

```
  EU users → data in EU region (Frankfurt, Ireland)
  US users → data in US region (us-east-1, us-west-2)
  APAC users → data in APAC region (Singapore, Tokyo)
```

**Implementation via PostgreSQL tablespaces + partitioning:**

```sql
-- Table partitioned by region
CREATE TABLE users (
    id     BIGINT,
    region TEXT NOT NULL,
    email  TEXT,
    name   TEXT
) PARTITION BY LIST (region);

-- EU partition physically on the EU server
CREATE TABLE users_eu PARTITION OF users
    FOR VALUES IN ('DE', 'FR', 'IT', 'ES', 'NL', 'PL');

-- US partition on the US server
CREATE TABLE users_us PARTITION OF users
    FOR VALUES IN ('US', 'CA', 'MX');
```

CockroachDB and YugabyteDB support geo-partitioning natively via `LOCALITY` constraints:

```sql
-- CockroachDB: EU data is replicated only to EU nodes
ALTER TABLE users CONFIGURE ZONE USING
    constraints = '[+region=eu-west]'
    WHERE region IN ('DE', 'FR', 'IT');
```

---

### Active-Active vs Active-Passive Multi-Region

```
Active-Passive:
  ┌─────────────────┐         ┌─────────────────┐
  │   Region US     │         │   Region EU     │
  │   PRIMARY       │────────▶│   STANDBY       │
  │   (Reads+Writes)│  repl.  │   (Reads only)  │
  └─────────────────┘         └─────────────────┘

  + Simple, no conflicts
  - EU users write with latency across the Atlantic (~80ms+)
  - Failover takes time

Active-Active:
  ┌─────────────────┐         ┌─────────────────┐
  │   Region US     │◀───────▶│   Region EU     │
  │  Reads+Writes   │  bi-dir │  Reads+Writes   │
  └─────────────────┘  repl.  └─────────────────┘

  + Low latency in both regions
  + No single point of failure
  - Write conflicts are possible
  - Conflict resolution complexity
```

**When to choose which:**

| | Active-Passive | Active-Active |
|---|---|---|
| Write latency | High for remote regions | Low everywhere |
| Complexity | Low | High |
| Conflicts | None | Yes, strategy required |
| RTO | Minutes (failover) | Seconds |
| Best for | Most cases | Global write-heavy applications |

---

### Conflict Resolution with Multi-Region Writes

When two regions simultaneously modify the same data, a conflict resolution strategy is needed.

#### Last-Write-Wins (LWW)

```
EU: UPDATE users SET name='Alice EU' WHERE id=1  (ts=100)
US: UPDATE users SET name='Alice US' WHERE id=1  (ts=101)

LWW winner: name='Alice US' (timestamp 101 > 100)
```

The simplest approach. Problem: physical clocks are not perfectly synchronized → clock skew → data loss. Cassandra uses LWW by default.

**Hybrid Logical Clocks (HLC)** — solve the clock skew problem by combining physical time with logical counters. Used in CockroachDB.

#### Vector Clocks

Each node stores a version as a vector `{node_id: counter}`:

```
Initial state: {}

EU writes: {EU: 1}  → name='Alice EU'
US writes: {US: 1}  → name='Alice US'

On merge: {EU: 1} and {US: 1} — concurrent, conflict!
  Both values are saved as "siblings"
  The application or user resolves the conflict
```

DynamoDB uses a variant of vector clocks (version vectors). Riak uses vector clocks for automatic sibling resolution.

#### CRDTs (Conflict-free Replicated Data Types)

Data structures designed so their merge is **always deterministic** and requires no coordination:

| CRDT Type | Description | Example Use |
|---|---|---|
| **G-Counter** | Monotonically increasing counter | View count |
| **PN-Counter** | Increment + decrement | Likes (add/remove) |
| **G-Set** | Add only | Tag list |
| **OR-Set** | Add/remove with unique tags | E-commerce shopping cart |
| **LWW-Register** | Last-write-wins for a single value | Latest status |
| **MV-Register** | Multi-value (stores all concurrent values) | Document with conflicts |

```go
// G-Counter CRDT: distributed counter without coordination
type GCounter struct {
    Counts map[string]int64 // nodeID → count
}

func (c *GCounter) Increment(nodeID string) {
    c.Counts[nodeID]++
}

func (c *GCounter) Value() int64 {
    var total int64
    for _, v := range c.Counts {
        total += v
    }
    return total
}

// Merge: take max for each node (idempotent, commutative, associative)
func (c *GCounter) Merge(other *GCounter) *GCounter {
    result := &GCounter{Counts: make(map[string]int64)}
    for node, count := range c.Counts {
        result.Counts[node] = count
    }
    for node, count := range other.Counts {
        if count > result.Counts[node] {
            result.Counts[node] = count
        }
    }
    return result
}
```

---

### NewSQL: CockroachDB and YugabyteDB

NewSQL databases combine the horizontal scalability of NoSQL with ACID SQL transactions.

```
Traditional SQL:      NoSQL:           NewSQL:
  ACID              Scalable          ACID + Scalable
  Single node       Multi-node        Multi-node
  SQL               Limited/No SQL    Full SQL
  No partition tol. Partition tol.    Partition tol.
```

**CockroachDB:**
- Inspired by Google Spanner.
- Data is split into **ranges** (64MB by default), replicated via Raft.
- Uses HLC for globally ordered transactions.
- Wire protocol compatible with PostgreSQL.

```sql
-- CockroachDB: multi-region table
ALTER TABLE users SET LOCALITY REGIONAL BY ROW;  -- each row in its own region

-- Geo-partitioned indexes
ALTER TABLE users ADD COLUMN crdb_region crdb_internal_region
    AS (CASE
        WHEN country IN ('DE','FR') THEN 'eu-west-1'
        WHEN country IN ('US','CA') THEN 'us-east-1'
        ELSE 'ap-southeast-1'
    END) STORED;
```

**YugabyteDB:**
- Implements PostgreSQL wire protocol and YCQL (Cassandra-compatible).
- DocDB storage engine based on RocksDB.
- Raft for replication, Raft groups for shards.

```
Choosing NewSQL vs Traditional SQL + Sharding:

NewSQL (CockroachDB, YugabyteDB):
  ✅ Automatic resharding
  ✅ Geo-distribution out of the box
  ✅ Global transactions
  ❌ Higher latency on single-region workloads (consensus overhead)
  ❌ More expensive to operate

Traditional PostgreSQL + Sharding:
  ✅ Mature ecosystem
  ✅ Low latency
  ✅ More available specialists
  ❌ Manual resharding
  ❌ No built-in geo-distribution
```

---

### CAP Theorem and Practical Implications

```
         Consistency
              △
              │
              │   CA systems
              │   (traditional RDBMS)
              │
CP ───────────┼─────────────── AP
systems       │               systems
(HBase,       │               (Cassandra,
ZooKeeper)    │               DynamoDB,
              │               CouchDB)
              │
         Availability
```

In practice there is no absolute choice — systems sit on a spectrum between CP and AP, and **partition tolerance** is mandatory for any distributed system. A more precise framework is **PACELC**:

```
If Partition:    else:
  Availability     Latency
  vs               vs
  Consistency      Consistency

CockroachDB: PC/EC (consistency everywhere, but higher latency)
Cassandra:   PA/EL (availability on partition, lower latency)
DynamoDB:    PA/EL (tunable consistency)
```

---

## Summary: How to Choose a Strategy

```
                Data volume / load
                     │
           ┌─────────▼──────────┐
           │  Fits on a single  │
           │  server?           │
           └─────┬──────┬───────┘
                 │Yes   │No
                 │      │
        ┌────────▼──┐   │
        │Replication│   │
        │+ Partition│   │
        │(single DB)│   │
        └───────────┘   │
                        │
              ┌──────────▼──────────┐
              │  Need global        │
              │  transactions?      │
              └─────┬──────┬────────┘
                    │Yes   │No
                    │      │
         ┌──────────▼──┐   │
         │   NewSQL     │   │
         │(CockroachDB, │   │
         │ YugabyteDB)  │   │
         └─────────────┘   │
                           │
                 ┌──────────▼──────────┐
                 │  Application-level  │
                 │  Sharding           │
                 │  (consistent hash)  │
                 └─────────────────────┘
```

| Scale | Strategy |
|---|---|
| Up to 10M rows, 100 RPS writes | Single PostgreSQL, indexes |
| Up to 100M rows | Replication + read replicas |
| Up to 1B rows | Partitioning + replication |
| Over 1B rows or write scaling needed | Sharding (application-level or NewSQL) |
| Multi-region | Geo-partitioning, Active-Active, CRDTs |

---

> **Next module:** [05 — Queues and Asynchrony](../05-queues/readme.md)
