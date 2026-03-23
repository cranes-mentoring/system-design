# Модуль 04: Масштабирование данных

> **Предыдущий модуль:** [03 — Кэширование](../03-caching/readme.md)  
> **Следующий модуль:** [05 — Очереди и асинхронность](../05-queues/readme.md)

---

## Содержание

1. [Репликация](#1-репликация)
2. [Партиционирование (Partitioning)](#2-партиционирование-partitioning)
3. [Шардинг (Sharding)](#3-шардинг-sharding)
4. [Consistent Hashing — deep dive](#4-consistent-hashing--deep-dive)
5. [Стратегии миграции данных](#5-стратегии-миграции-данных)
6. [Data locality и распределённые данные](#6-data-locality-и-распределённые-данные)

---

## 1. Репликация

### Зачем нужна репликация

Репликация решает три независимые задачи, и важно понимать, какую именно ты решаешь:

| Задача | Механизм | Что даёт |
|---|---|---|
| **Read scaling** | Read replicas | Горизонтальный масштаб чтений, write-нагрузка остаётся на master |
| **High availability** | Failover replica | При падении master один из replica становится новым master |
| **Disaster recovery** | Geo-replica / backup | Восстановление при потере дата-центра, RPO и RTO |

Репликация **не** решает проблему write scaling — для этого нужен шардинг.

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

**Как работает:**

1. Primary записывает изменения в WAL (Write-Ahead Log).
2. WAL-записи передаются на реплики — либо потоком (streaming replication), либо через WAL files.
3. Реплика применяет записи к своей копии данных (recovery mode).
4. Реплика доступна только для чтения.

**Async vs Sync replication:**

```
Async (default в PostgreSQL):
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
| Latency writes | низкая | выше (ждём replica ACK) |
| Durability | возможна потеря последних транзакций | гарантирована |
| Availability | replica lag не блокирует | при недоступности replica — primary тоже стоит |
| Использование | типичный случай | финансы, когда нельзя терять ни байта |

В PostgreSQL sync replication включается через `synchronous_standby_names`:

```sql
-- postgresql.conf на primary
synchronous_commit = on
synchronous_standby_names = 'replica1'
```

---

### Multi-Master

Multi-Master нужен, когда один writer — узкое место, и нагрузка на запись распределена географически.

```
  Region EU                    Region US
┌────────────┐               ┌────────────┐
│  Master A  │◀──────────────▶  Master B  │
│            │  bidirectional │            │
└────────────┘  replication  └────────────┘
```

**Когда нужен:**
- Мультирегиональные write-нагрузки (пользователь в EU должен писать с минимальной latency).
- Active-Active архитектура без единой точки отказа.

**Проблемы:**
- **Write conflicts** — два master одновременно обновили одну строку. Нужна conflict resolution стратегия:
  - Last-Write-Wins (LWW) — побеждает запись с более поздним timestamp. Просто, но теряет данные.
  - Application-level merge — приложение решает конфликт (дорого, но надёжно).
  - CRDTs — структуры данных, merge которых всегда детерминирован.
- **Circular replication loops** — изменения гуляют по кругу. Решается через origin tracking.

PostgreSQL из коробки не поддерживает Multi-Master. Используют: **BDR (Bi-Directional Replication)** от EDB, **Citus**, **CockroachDB**.

---

### WAL Shipping в PostgreSQL

WAL (Write-Ahead Log) — это append-only журнал всех изменений в БД. Каждый блок данных изменяется сначала в WAL, потом в actual storage. Это гарантирует durability (D в ACID).

**Два режима передачи WAL на реплику:**

**1. WAL Archiving (file-based shipping)**
```
Primary ──WAL segment (16MB)──▶ archive storage ──▶ Replica
```
- Реплика скачивает завершённые WAL-файлы.
- Lag = время наполнения сегмента (может быть минуты).
- Используется для backup и PITR (Point-In-Time Recovery).

**2. Streaming Replication (WAL stream)**
```
Primary ──continuous WAL stream──▶ Replica (wal receiver)
```
- Реплика подключается к primary через протокол репликации.
- Lag — секунды или меньше.
- Стандартный режим для HA-реплик.

Настройка streaming replication в PostgreSQL:

```ini
# postgresql.conf (primary)
wal_level = replica          # или logical для CDC
max_wal_senders = 10
wal_keep_size = 1GB          # буфер WAL для медленных реплик

# pg_hba.conf (primary)
host  replication  replicator  10.0.0.0/8  md5
```

```ini
# recovery.conf / postgresql.conf (replica, PG 12+)
primary_conninfo = 'host=10.0.0.1 port=5432 user=replicator password=secret'
hot_standby = on
```

---

### Replication Lag: как измерять и чем опасен

**Измерение:**

```sql
-- На primary: список реплик и их lag
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

-- На replica: отставание в байтах
SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) AS lag_bytes;

-- Отставание в секундах (PG 10+)
SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) AS lag_seconds;
```

**Алерт в Prometheus / Grafana:**
```yaml
# prometheus alert
- alert: PostgresReplicationLagHigh
  expr: pg_replication_lag_seconds > 30
  for: 5m
  labels:
    severity: warning
```

**Чем опасен lag:**

1. **Stale reads** — пользователь написал данные, тут же прочитал с реплики — данных нет. Типичный кейс: регистрация → редирект → страница профиля не загружается.

2. **Failover data loss** — если primary упал, а реплика отстала на N секунд — эти транзакции потеряны (RPO > 0).

3. **Long-running queries на реплике** — блокируют применение WAL-записей, lag растёт.

**Как бороться со stale reads:**

```go
// Вариант 1: sticky sessions — после write читаем с primary N секунд
// Вариант 2: read-your-writes через explicit routing
// Вариант 3: version token — передаём LSN клиенту, replica ждёт его достижения
```

---

### Failover: автоматический vs ручной

**Ручной failover** — оператор выполняет команды вручную:
```bash
# На replica:
pg_ctl promote -D /var/lib/postgresql/data
# Переключить DNS / load balancer на новый primary
# Остальные реплики переключить на новый primary
```

Минус: время реакции (минуты), возможны ошибки, нужен человек.

**Автоматический failover** — инструменты отслеживают состояние и переключают сами.

**Patroni** (самый популярный):
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

Patroni хранит информацию о лидере в DCS (etcd/consul/ZooKeeper). При недоступности primary реплика с наибольшим LSN выигрывает election и промоутируется. Переключение занимает ~30 секунд.

```yaml
# patroni.yml (пример конфига)
scope: postgres-cluster
name: node1

etcd:
  host: etcd:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 30
    maximum_lag_on_failover: 1048576  # 1MB — реплика не промоутируется если lag > 1MB

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.0.1:5432
  data_dir: /data/patroni
```

**pg_auto_failover** — более простая альтернатива от Microsoft, встроена в архитектуру monitor + keeper.

---

### Read Replicas: маршрутизация read/write трафика

Задача: writes → primary, reads → одна из реплик (round-robin или least-connections).

Варианты реализации:

1. **На уровне приложения** — в коде две connection pool: одна на primary, одна (или несколько) на реплики.
2. **HAProxy / PgBouncer** — proxy слушает два порта: 5432 (write) и 5433 (read), роутит на нужный backend.
3. **AWS RDS Proxy / Aurora** — managed решение, автоматически роутит readonly транзакции.

---

### Пример: docker-compose с PostgreSQL master + replica

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

### Пример Go: маршрутизация запросов на master/replica через pgx

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

> **Важно:** после write операции, если сразу нужно прочитать свои данные — используй `Writer()` для чтения, чтобы избежать stale read из-за replication lag.

---

## 2. Партиционирование (Partitioning)

Партиционирование — разделение одной логической таблицы на физические части **внутри одного сервера** (в отличие от шардинга, где части на разных серверах).

### Зачем

- **Performance**: query planner исключает нерелевантные партиции (partition pruning) — `WHERE date > '2024-01-01'` сканирует только нужные.
- **Maintenance**: `DROP TABLE partition_2022` вместо `DELETE FROM events WHERE year = 2022` — мгновенно, без bloat.
- **Storage tiering**: старые партиции — на дешёвый storage, горячие — на NVMe.
- **Parallel query**: партиции обрабатываются параллельно.

---

### Вертикальное партиционирование

Разделение таблицы по **столбцам**: редко используемые или большие колонки выносятся в отдельную таблицу.

```sql
-- До: одна таблица
CREATE TABLE users (
    id          BIGINT PRIMARY KEY,
    email       TEXT,
    name        TEXT,
    -- blob-поля, которые нужны редко:
    avatar      BYTEA,
    settings    JSONB,
    bio         TEXT
);

-- После: вертикальное партиционирование
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

Результат: большинство запросов к `users` не читают blob-колонки → меньше I/O, лучше cache hit ratio.

---

### Горизонтальное партиционирование

Разделение таблицы по **строкам** по значению одной или нескольких колонок (partition key).

#### Range Partitioning

Самый частый кейс — партиционирование по дате:

```sql
CREATE TABLE events (
    id         BIGINT,
    user_id    BIGINT,
    event_type TEXT,
    created_at TIMESTAMPTZ NOT NULL,
    payload    JSONB
) PARTITION BY RANGE (created_at);

-- Создаём партиции по месяцам
CREATE TABLE events_2024_01 PARTITION OF events
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

CREATE TABLE events_2024_02 PARTITION OF events
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');

CREATE TABLE events_2024_03 PARTITION OF events
    FOR VALUES FROM ('2024-03-01') TO ('2024-04-01');

-- Default partition для данных вне диапазонов
CREATE TABLE events_default PARTITION OF events DEFAULT;
```

**Partition pruning в действии:**

```sql
-- PostgreSQL автоматически сканирует только events_2024_02
EXPLAIN SELECT * FROM events
WHERE created_at >= '2024-02-01' AND created_at < '2024-03-01';

-- Output:
-- Append
--   ->  Seq Scan on events_2024_02
--         Filter: (created_at >= '2024-02-01' AND created_at < '2024-03-01')
```

**Автоматическое создание партиций** (pg_partman):

```sql
-- pg_partman автоматически создаёт и дропает партиции по расписанию
SELECT partman.create_parent(
    p_parent_table => 'public.events',
    p_control      => 'created_at',
    p_type         => 'range',
    p_interval     => 'monthly',
    p_premake      => 3  -- создать 3 будущих партиции заранее
);
```

#### List Partitioning

По дискретным значениям — регион, статус, тип:

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

Равномерное распределение по hash-значению ключа, когда нет очевидного range или list:

```sql
CREATE TABLE user_activities (
    id      BIGINT,
    user_id BIGINT NOT NULL,
    action  TEXT,
    ts      TIMESTAMPTZ
) PARTITION BY HASH (user_id);

-- 8 партиций — modulus 8
CREATE TABLE user_activities_0 PARTITION OF user_activities
    FOR VALUES WITH (MODULUS 8, REMAINDER 0);
CREATE TABLE user_activities_1 PARTITION OF user_activities
    FOR VALUES WITH (MODULUS 8, REMAINDER 1);
-- ... и так до REMAINDER 7
```

---

### Автоудаление старых партиций

```sql
-- DROP PARTITION — мгновенная операция, не оставляет bloat
-- Эквивалентно DROP TABLE, но без нарушения структуры родительской таблицы

DROP TABLE events_2022_01;  -- удалить партицию за январь 2022

-- Vs. DELETE — медленно, bloat, нагрузка на WAL:
DELETE FROM events WHERE created_at < '2022-02-01';  -- НИКОГДА так не делай на больших таблицах
```

**Скрипт для cron-удаления старых партиций:**

```sql
-- Удалить все партиции старше 12 месяцев
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

### Индексы и ограничения на партиционированных таблицах

```sql
-- Индекс на родительской таблице автоматически создаётся на всех партициях
CREATE INDEX idx_events_user_id ON events (user_id);

-- Primary key должен включать partition key
ALTER TABLE events ADD PRIMARY KEY (id, created_at);

-- Foreign keys ссылающиеся на партиционированную таблицу — не поддерживаются
-- (реализуется через триггеры или на уровне приложения)
```

---

## 3. Шардинг (Sharding)

Шардинг — горизонтальное партиционирование **на уровне отдельных серверов/инстансов БД**. Каждый shard — независимая БД со своим subset данных.

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

**Ключевое отличие от партиционирования:**
- Партиционирование: один сервер, несколько файлов, прозрачно для приложения.
- Шардинг: несколько серверов, приложение (или middleware) знает, куда роутить запрос.

---

### Стратегии шардирования

#### 1. Hash-based Sharding (`user_id % N`)

```
shard_id = hash(user_id) % num_shards
```

```
user_id=100  → hash → 0x64... → 0x64 % 4 = 0  → Shard #0
user_id=101  → hash → 0x65... → 0x65 % 4 = 1  → Shard #1
user_id=200  → hash → 0xC8... → 0xC8 % 4 = 0  → Shard #0
```

✅ Равномерное распределение  
✅ Простая реализация  
❌ **Resharding адский**: при изменении N почти все ключи меняют shard (`N → N+1`: 100 % 4 = 0, 100 % 5 = 0 — повезло, но 101 % 4 = 1, 101 % 5 = 1, 102 % 4 = 2, 102 % 5 = 2 — всего лишь ~1/N ключей остаётся на месте)  
❌ Нет range queries: `WHERE user_id BETWEEN 1000 AND 2000` идёт на все шарды

#### 2. Range-based Sharding

```
user_id 1–1,000,000      → Shard #0
user_id 1,000,001–2,000,000 → Shard #1
user_id 2,000,001–...    → Shard #2
```

✅ Поддерживает range queries  
✅ Простое resharding (добавляем новый shard для новых диапазонов)  
❌ **Hotspot**: новые пользователи всегда пишут на последний shard  
❌ Неравномерное распределение (активные пользователи могут быть в одном диапазоне)

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

✅ Максимальная гибкость: можно переместить user на другой shard без resharding  
✅ Легко балансировать нагрузку  
❌ **Single point of failure**: lookup service упал — ничего не работает  
❌ Дополнительный network hop на каждый запрос  
❌ Lookup service нужно масштабировать отдельно

#### 4. Consistent Hashing

Решает проблему resharding из hash-based подхода. Подробно — в разделе 4.

---

### Shard Key: как выбирать

Shard key — колонка (или комбинация), по которой роутится запрос. Выбор критичен.

**Хорошие shard keys:**

| Кейс | Shard Key | Почему |
|---|---|---|
| Многопользовательское приложение | `user_id` | Все данные пользователя на одном шарде, join внутри шарда |
| SaaS платформа | `tenant_id` | Полная изоляция данных клиента |
| E-commerce | `order_id` | Равномерное распределение, операции над заказом атомарны |
| Геосервис | `region` | Data locality |

**Плохие shard keys:**

```sql
-- BAD: монотонно возрастающий timestamp → hotspot на последнем шарде
shard_key = created_at

-- BAD: низкая кардинальность → мало шардов, некоторые пустые
shard_key = status  -- ('active', 'inactive', 'banned' — всего 3 значения)

-- BAD: null values
shard_key = optional_field
```

---

### Проблемы шардинга

#### Cross-shard Queries (JOIN между шардами)

```sql
-- Этот запрос требует данных с разных шардов:
SELECT u.name, SUM(o.amount)
FROM users u JOIN orders o ON u.id = o.user_id
GROUP BY u.name;
```

**Решения:**
1. **Scatter-Gather**: запрос идёт на все шарды параллельно, результаты мержатся в приложении.
2. **Денормализация**: дублировать нужные поля (имя пользователя хранить в таблице orders).
3. **Global tables**: справочники (список стран, категорий) реплицировать на все шарды.

#### Cross-shard Transactions

```
BEGIN;
  UPDATE accounts SET balance = balance - 100 WHERE id = 1;  -- Shard #0
  UPDATE accounts SET balance = balance + 100 WHERE id = 2;  -- Shard #1
COMMIT;
```

Два shard — нет гарантии atomicity без distributed transaction protocol (2PC, 3PC, Saga).

**2PC (Two-Phase Commit):**
```
Coordinator → Shard #0: PREPARE
Coordinator → Shard #1: PREPARE
← Shard #0: READY
← Shard #1: READY
Coordinator → Shard #0: COMMIT
Coordinator → Shard #1: COMMIT
```
Медленно (2 round-trips), coordinator — single point of failure. В продакшне избегают 2PC.

**Saga Pattern** — распиливаем транзакцию на последовательность локальных транзакций с compensating actions:
```
Debit(user_1) → если ошибка → Compensate(Credit(user_1))
Credit(user_2) → если ошибка → Compensate(Debit(user_2))
```

#### Hotspot шарды

В соцсети запись `posts` шардирована по `user_id`. Пост знаменитости с 100M подписчиков → Shard #N получает в 1000x больше трафика.

**Решения:**
- **Shard splitting**: разбить горячий shard на несколько.
- **Celebrity key treatment**: знаменитостей роутить особым образом (на выделенные шарды или кэш).
- **Write amplification через queue**: записи буферизуются в очередь, fanout происходит асинхронно.

#### Rebalancing при добавлении шардов

При добавлении нового sharding узла часть данных нужно переместить:

```
До:  3 шарда → Shard 0, 1, 2
После: 4 шарда → Shard 0, 1, 2, 3

С hash % N: ~75% данных меняют shard (перемещать почти всё)
С consistent hashing: ~25% данных меняют shard (перемещать только 1/N)
```

---

### Шардинг: приложение vs middleware

| | Application-level | Middleware (Vitess/Citus) |
|---|---|---|
| Контроль | Полный | Ограничен возможностями middleware |
| Сложность | Высокая (логика в коде) | Ниже (прозрачно для приложения) |
| Гибкость | Любая стратегия | Зависит от middleware |
| SQL совместимость | Нужно писать shard-aware queries | Полная (middleware транслирует) |
| Примеры | — | Vitess (MySQL), Citus (PG), ProxySQL |

---

### Пример на Go: shard router по user_id

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

// Cross-shard query: нужно идти на все шарды
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

### Проблема обычного `hash % N`

При добавлении или удалении узла меняется N, и большинство ключей переезжает:

```
3 узла: key → hash % 3
  key="user:100" → hash=1000 → 1000 % 3 = 1  → Node 1
  key="user:200" → hash=2000 → 2000 % 3 = 2  → Node 2
  key="user:300" → hash=3000 → 3000 % 3 = 0  → Node 0

Добавляем Node 3: key → hash % 4
  key="user:100" → 1000 % 4 = 0  → Node 0  ← ПЕРЕЕХАЛ
  key="user:200" → 2000 % 4 = 0  → Node 0  ← ПЕРЕЕХАЛ
  key="user:300" → 3000 % 4 = 3  → Node 3  ← ПЕРЕЕХАЛ
```

При N=3 → N=4 переезжает ~75% ключей. Для кэша это означает cache miss storm. Для шардов — огромный объём перемещения данных.

---

### Как работает Consistent Hashing

**Hash ring** — виртуальное кольцо значений хешей `[0, 2^32)`.

1. Каждый узел размещается на кольце по своему хешу: `hash(node_name)`.
2. Ключ тоже хешируется и размещается на кольце.
3. Ключ принадлежит **первому узлу по часовой стрелке** от его позиции.

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

Key K1 (hash=0x20...) → следующий узел по часовой = Node B
Key K2 (hash=0x90...) → следующий узел по часовой = Node A (перешли через 0)
```

**При добавлении Node C:**
- Node C занимает позицию на кольце.
- Переезжают только ключи между предыдущим узлом и Node C.
- Остальные ключи не трогаются.
- Теоретически перемещается `1/N` ключей.

---

### Virtual Nodes

Без virtual nodes: узлы распределяются неравномерно на кольце → разный объём данных.

Virtual nodes: каждый физический узел представлен **K виртуальными узлами** на кольце:

```
Физический узел A → A#0, A#1, A#2, ..., A#99  (100 virtual nodes)
Физический узел B → B#0, B#1, B#2, ..., B#99
Физический узел C → C#0, C#1, C#2, ..., C#99
```

```
   0────────────────────────────────────────────2^32

   A#3    B#1    C#2    A#0    B#2    C#0    A#1    B#0
   ──●──────●──────●──────●──────●──────●──────●──────●──
```

Результат:
- Данные распределяются равномерно (закон больших чисел).
- При добавлении узла D его virtual nodes равномерно "забирают" ключи со всех существующих узлов.
- Чем больше K, тем равномернее распределение (и больше памяти на ring metadata).

---

### Пример на Go: Consistent Hash Ring с virtual nodes

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

**Тест равномерности распределения:**

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

### Где используется Consistent Hashing

| Система | Применение |
|---|---|
| **Cassandra** | Партиционирование данных по token ring, virtual nodes по умолчанию с vnode count=256 |
| **DynamoDB** | Внутренний механизм распределения данных по storage nodes |
| **Amazon S3** | Распределение объектов по storage nodes |
| **Memcached** | Клиентский consistent hashing для шардинга кэша (libketama) |
| **Redis Cluster** | Hash slots (16384 слота) — вариант consistent hashing |
| **CDN (Akamai, Fastly)** | Маршрутизация запросов на edge nodes |
| **Nginx upstream** | Consistent hash для sticky sessions |

---

## 5. Стратегии миграции данных

Миграция данных — изменение структуры или расположения данных без потери доступности. Главный вопрос: как мигрировать без даунтайма?

### Dual Write

Приложение пишет в обе системы (старую и новую) одновременно:

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

**Фазы:**

```
Phase 1: Начальная синхронизация
  → Bulk copy старых данных в новую БД (pg_dump, custom script)
  → Параллельно запуск dual write в приложении

Phase 2: Dual write активен
  → Writes идут в обе БД
  → Reads всё ещё из старой БД
  → Верифицируем консистентность данных

Phase 3: Переключение reads
  → Переключаем reads на новую БД
  → Dual write продолжается (откат возможен)

Phase 4: Финализация
  → Убираем dual write
  → Старая БД — в архив
```

**Проблемы dual write:**
- Нет atomicity между старой и новой БД: запись прошла в одну, упала в другую → несогласованность.
- Нужна логика верификации и reconciliation.

```go
// Dual write с best-effort и логированием расхождений
func (s *Service) CreateOrder(ctx context.Context, o *Order) error {
    // Пишем в старую БД (primary)
    if err := s.oldDB.Create(ctx, o); err != nil {
        return err // Не пишем в новую если старая упала
    }

    // Пишем в новую БД (best-effort)
    if err := s.newDB.Create(ctx, o); err != nil {
        // Не возвращаем ошибку клиенту, но логируем для reconciliation
        s.logger.Error("dual write failed for new DB",
            "order_id", o.ID, "err", err)
        s.metrics.IncCounter("dual_write_failures")
    }

    return nil
}
```

---

### Change Data Capture (CDC)

CDC перехватывает изменения данных на уровне WAL (для PostgreSQL) или binlog (MySQL) и публикует их как stream событий.

```
PostgreSQL WAL
      │
  ┌───▼────────────────┐
  │ Debezium Connector │  ← читает WAL через logical replication
  │ (pgoutput plugin)  │
  └───────────┬────────┘
              │
     ┌────────▼────────┐
     │   Kafka Topic   │  ← events: INSERT/UPDATE/DELETE
     └────────┬────────┘
              │
    ┌──────────▼──────────┐
    │  Consumer (новая БД) │  ← применяет события к новой БД
    └─────────────────────┘
```

**Настройка в PostgreSQL:**

```sql
-- Включить logical replication
ALTER SYSTEM SET wal_level = logical;
-- pg_reload_conf() или restart

-- Создать publication для нужных таблиц
CREATE PUBLICATION my_migration_pub FOR TABLE orders, users, products;

-- Debezium подключается как logical replication slot
SELECT pg_create_logical_replication_slot('debezium_slot', 'pgoutput');
```

**Debezium конфиг (Kafka Connect):**

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

CDC события в Kafka:

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

Самый безопасный способ изменения схемы без даунтайма. Три фазы:

**Пример: переименование колонки `user_name` → `username`**

```
Phase 1: EXPAND
  → Добавляем новую колонку username (nullable)
  → Триггер или приложение копирует данные при каждом write
  → Фоновый backfill: UPDATE users SET username = user_name WHERE username IS NULL
  → Деплоим версию приложения, которая пишет в ОБЕ колонки, читает из старой

Phase 2: MIGRATE READS
  → Деплоим версию, которая читает из новой колонки
  → Пишет в обе (backward compatibility)

Phase 3: CONTRACT
  → Убеждаемся, что нет кода, читающего старую колонку
  → Деплоим версию, которая пишет только в новую
  → DROP COLUMN user_name
```

```sql
-- Phase 1: EXPAND
ALTER TABLE users ADD COLUMN username TEXT;

-- Триггер для автоматической синхронизации при write
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

-- Фоновый backfill (батчами, чтобы не лочить таблицу)
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
        PERFORM pg_sleep(0.01); -- небольшая пауза, чтобы не убить I/O
    END LOOP;
END;
$$;

-- Phase 3: CONTRACT (после деплоя нового кода)
ALTER TABLE users DROP COLUMN user_name;
DROP TRIGGER trg_sync_username ON users;
DROP FUNCTION sync_username();
```

**Проверка готовности к CONTRACT:**

```sql
-- Убедиться, что нет строк с NULL в новой колонке
SELECT COUNT(*) FROM users WHERE username IS NULL;
-- Должно быть 0

-- Добавить NOT NULL constraint (с DEFAULT или VALIDATE)
ALTER TABLE users ALTER COLUMN username SET NOT NULL;
```

---

### Как мигрировать без даунтайма: чеклист

```
□ Все DDL операции — только backward-compatible изменения
  □ Добавление колонки: nullable или с DEFAULT
  □ Добавление индекса: CREATE INDEX CONCURRENTLY (не лочит)
  □ Удаление колонки: только после того, как код не использует
  □ Переименование: через expand-contract, не ALTER TABLE ... RENAME

□ Backfill — батчами с паузами, не UPDATE всей таблицы

□ Валидация constraint-ов: ALTER TABLE ... VALIDATE CONSTRAINT
  (не ADD CONSTRAINT — он лочит)

□ Мониторинг replication lag во время миграции
  (большой backfill → WAL storm → replica lag растёт)

□ Feature flags для переключения read/write на новую схему
```

---

## 6. Data Locality и распределённые данные

### Geo-Partitioning: данные рядом с пользователем

Данные хранятся в той географической зоне, где живёт пользователь — для снижения latency и compliance (GDPR требует хранения данных EU-граждан в EU).

```
  EU users → data in EU region (Frankfurt, Ireland)
  US users → data in US region (us-east-1, us-west-2)
  APAC users → data in APAC region (Singapore, Tokyo)
```

**Реализация через PostgreSQL tablespaces + partitioning:**

```sql
-- Таблица партиционирована по region
CREATE TABLE users (
    id     BIGINT,
    region TEXT NOT NULL,
    email  TEXT,
    name   TEXT
) PARTITION BY LIST (region);

-- EU партиция физически на EU-сервере
CREATE TABLE users_eu PARTITION OF users
    FOR VALUES IN ('DE', 'FR', 'IT', 'ES', 'NL', 'PL');

-- US партиция на US-сервере
CREATE TABLE users_us PARTITION OF users
    FOR VALUES IN ('US', 'CA', 'MX');
```

CockroachDB и YugabyteDB поддерживают geo-partitioning нативно через `LOCALITY` constraints:

```sql
-- CockroachDB: данные EU реплицируются только в EU nodes
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

  + Простота, нет конфликтов
  - EU users пишут с latency через Atlantic (~80ms+)
  - Failover занимает время

Active-Active:
  ┌─────────────────┐         ┌─────────────────┐
  │   Region US     │◀───────▶│   Region EU     │
  │  Reads+Writes   │  bi-dir │  Reads+Writes   │
  └─────────────────┘  repl.  └─────────────────┘

  + Низкая latency в обоих регионах
  + Нет single point of failure
  - Возможны write conflicts
  - Сложность conflict resolution
```

**Когда что выбирать:**

| | Active-Passive | Active-Active |
|---|---|---|
| Write latency | Высокая для удалённых регионов | Низкая везде |
| Сложность | Низкая | Высокая |
| Конфликты | Нет | Да, нужна стратегия |
| RTO | Минуты (failover) | Секунды |
| Подходит для | Большинство случаев | Глобальные write-heavy приложения |

---

### Conflict Resolution при Multi-Region Writes

Когда два региона одновременно изменяют одни данные, нужна стратегия разрешения конфликтов.

#### Last-Write-Wins (LWW)

```
EU: UPDATE users SET name='Alice EU' WHERE id=1  (ts=100)
US: UPDATE users SET name='Alice US' WHERE id=1  (ts=101)

LWW winner: name='Alice US' (timestamp 101 > 100)
```

Простейший подход. Проблема: физические часы не синхронизированы идеально → clock skew → потеря данных. Cassandra использует LWW по умолчанию.

**Hybrid Logical Clocks (HLC)** — решают проблему clock skew, совмещая физическое время с логическими счётчиками. Используются в CockroachDB.

#### Vector Clocks

Каждый узел хранит версию в виде вектора `{node_id: counter}`:

```
Initial state: {}

EU writes: {EU: 1}  → name='Alice EU'
US writes: {US: 1}  → name='Alice US'

При мерже: {EU: 1} и {US: 1} — concurrent, конфликт!
  Оба значения сохраняются как "siblings"
  Приложение или пользователь разрешает конфликт
```

DynamoDB использует вариант vector clocks (version vectors). Riak — vector clocks для automatic sibling resolution.

#### CRDTs (Conflict-free Replicated Data Types)

Структуры данных, спроектированные так, что их merge **всегда детерминирован** и не требует coordination:

| CRDT тип | Описание | Пример применения |
|---|---|---|
| **G-Counter** | Монотонно возрастающий счётчик | Количество просмотров |
| **PN-Counter** | Increment + decrement | Лайки (добавить/убрать) |
| **G-Set** | Только добавление | Список тегов |
| **OR-Set** | Add/remove с уникальными тегами | Корзина в e-commerce |
| **LWW-Register** | Last-write-wins для single value | Последний статус |
| **MV-Register** | Multi-value (хранит все concurrent значения) | Документ с конфликтами |

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

### NewSQL: CockroachDB и YugabyteDB

NewSQL базы данных объединяют горизонтальный масштаб NoSQL с ACID транзакциями SQL.

```
Traditional SQL:      NoSQL:           NewSQL:
  ACID              Scalable          ACID + Scalable
  Single node       Multi-node        Multi-node
  SQL               Limited/No SQL    Full SQL
  No partition tol. Partition tol.    Partition tol.
```

**CockroachDB:**
- Вдохновлён Google Spanner.
- Данные разбиты на **ranges** (64MB по умолчанию), реплицируются через Raft.
- Использует HLC для глобально упорядоченных транзакций.
- Wire protocol совместим с PostgreSQL.

```sql
-- CockroachDB: multi-region таблица
ALTER TABLE users SET LOCALITY REGIONAL BY ROW;  -- каждая строка в своём регионе

-- Geo-partitioned индексы
ALTER TABLE users ADD COLUMN crdb_region crdb_internal_region
    AS (CASE
        WHEN country IN ('DE','FR') THEN 'eu-west-1'
        WHEN country IN ('US','CA') THEN 'us-east-1'
        ELSE 'ap-southeast-1'
    END) STORED;
```

**YugabyteDB:**
- Реализует PostgreSQL wire protocol и YCQL (Cassandra-совместимый).
- DocDB storage engine на основе RocksDB.
- Raft для репликации, Raft groups для шардов.

```
Выбор NewSQL vs Traditional SQL + Sharding:

NewSQL (CockroachDB, YugabyteDB):
  ✅ Автоматический resharding
  ✅ Geo-distribution из коробки
  ✅ Глобальные транзакции
  ❌ Выше latency на single-region workloads (consensus overhead)
  ❌ Дороже в эксплуатации

Traditional PostgreSQL + Sharding:
  ✅ Зрелая экосистема
  ✅ Низкая latency
  ✅ Больше специалистов
  ❌ Ручной resharding
  ❌ Нет встроенной geo-distribution
```

---

### CAP Theorem и практические следствия

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

В реальности нет абсолютного выбора — системы находятся на спектре между CP и AP, и **partition tolerance** обязателен для distributed системы. Более точный фреймворк — **PACELC**:

```
If Partition:    else:
  Availability     Latency
  vs               vs
  Consistency      Consistency

CockroachDB: PC/EC (consistency везде, но выше latency)
Cassandra:   PA/EL (availability при partition, lower latency)
DynamoDB:    PA/EL (tunable consistency)
```

---

## Итого: как выбирать стратегию

```
                Объём данных / нагрузка
                     │
           ┌─────────▼──────────┐
           │  Умещается на      │
           │  одном сервере?    │
           └─────┬──────┬───────┘
                 │Yes   │No
                 │      │
        ┌────────▼──┐   │
        │Replikation│   │
        │+ Partition│   │
        │(одна БД)  │   │
        └───────────┘   │
                        │
              ┌──────────▼──────────┐
              │  Нужны глобальные   │
              │  транзакции?        │
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

| Масштаб | Стратегия |
|---|---|
| До 10M строк, 100 RPS writes | Один PostgreSQL, индексы |
| До 100M строк | Репликация + read replicas |
| До 1B строк | Партиционирование + репликация |
| Больше 1B строк или write scaling | Шардинг (application-level или NewSQL) |
| Мульти-регион | Geo-partitioning, Active-Active, CRDTs |

---

> **Следующий модуль:** [05 — Очереди и асинхронность](../05-queues/readme.md)
