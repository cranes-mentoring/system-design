### Lesson: Managing Locks in PostgreSQL

#### Introduction to Locks

Locks in PostgreSQL are used to control access to data in a multi-user environment, ensuring data integrity and avoiding conflicts between transactions. Understanding lock types is important for developers and database administrators to effectively manage application operations.

#### Primary Types of Locks

1. **Row-Level Locks**:
    - **FOR UPDATE**: Locks rows for updating, preventing them from being modified or selected by other transactions using `FOR UPDATE`.
    - **FOR NO KEY UPDATE**: Similar to `FOR UPDATE`, but allows other transactions to modify non-key columns.
    - **FOR SHARE**: Locks rows from modifications, allowing other transactions to select them using `FOR SHARE`.
    - **FOR KEY SHARE**: Weakest lock, allowing modifications that do not affect key columns.

2. **Table-Level Locks**:
    - **ACCESS SHARE**: Used for reading data without blocking other read operations.
    - **ROW SHARE**: Used by transactions modifying rows in a table.
    - **ROW EXCLUSIVE**: Prevents other transactions from acquiring the same or similar locks on the table.
    - **SHARE UPDATE EXCLUSIVE**: Ensures certain operations are exclusive on the table without blocking data read or modification.
    - **SHARE**: Allows data reading and row locking but not table structure modifications.
    - **SHARE ROW EXCLUSIVE**: Stricter than ROW EXCLUSIVE, preventing concurrent modifications.
    - **EXCLUSIVE**: Blocks most operations but allows data reading.
    - **ACCESS EXCLUSIVE**: Strongest lock, preventing any other operations on the table.

3. **Advisory Locks**:
   Custom locks not tied to specific database objects. Used to implement complex locking logic at the application level.

#### Examples of Lock Usage

- **Row-Level Locks**:

```sql
-- Locking a row for update
BEGIN;
SELECT * FROM users WHERE id = 1 FOR UPDATE;
UPDATE users SET name = 'New Name' WHERE id = 1;
COMMIT;
```

- **Table-Level Locks**:

```sql
-- Locking a table for reading and updating data
BEGIN;
LOCK TABLE users IN SHARE ROW EXCLUSIVE MODE;
UPDATE users SET name = 'Updated Name' WHERE country = 'USA';
COMMIT;
```

- **Advisory Locks**:

```sql
-- Using advisory lock for a unique operation
SELECT pg_advisory_lock(123456);
-- Performing an operation that needs to be unique
SELECT pg_advisory_unlock(123456);
```

Advisory locks in PostgreSQL do not directly lock tables or rows. They provide a mechanism for applications to set locks on arbitrary keys. This means the impact of the lock is determined by application logic, not the database.

The row-level or table-level locking in PostgreSQL is managed by other mechanisms such as `LOCK TABLE` or transactional row-level locks automatically applied by operations like `SELECT FOR UPDATE`, `UPDATE`, `DELETE`, etc.

### Functions for Working with Advisory Locks in PostgreSQL:

- `pg_advisory_lock(key)`: Locks the specified key until `pg_advisory_unlock` is called or the session ends.
- `pg_try_advisory_lock(key)`: Attempts to acquire a lock on the key. Returns `true` if the lock is acquired and `false` if the lock cannot be acquired.
- `pg_advisory_unlock(key)`: Releases the lock on the specified key.

### Example Usage:

Suppose you need to coordinate access to a critical section of code across different sessions of your application.

#### Scenario:

You want to ensure that only one user can perform a specific operation at any given time (e.g., updating certain data).

#### Steps:

1. **Setting the Lock:**

```sql
SELECT pg_advisory_lock(42);
```

Here, `42` is an arbitrary lock identifier. You can choose any number that uniquely identifies the lock for this operation.

2. **Performing the Critical Operation:**

```sql
UPDATE my_table SET status = 'Processing' WHERE id = 1;
```

This action will only proceed if the current session successfully acquired the lock.

3. **Releasing the Lock:**

```sql
SELECT pg_advisory_unlock(42);
```

After completing the operation, release the lock so other sessions can continue working with this part of the code.

### Note:

- Failure to release a lock will keep it active until the session ends, potentially blocking other sessions attempting the same operation.
- Using advisory locks requires careful planning and management to avoid deadlocks and other concurrency issues.

Thus, advisory locks in PostgreSQL allow developers to control parallel process execution at the application level, ensuring efficient and safe handling of critical data operations.

### Best Practices for Working with Locks

- Avoid long-running transactions with locks to minimize wait time and blocking of other transactions.
- Use the least restrictive lock level that suits the task to avoid excessive locking and conflicts.
- Monitor and analyze locks using PostgreSQL system catalogs such as `pg_stat_activity` and `pg_locks`.
- Develop a strategy to handle deadlocks to prevent them and minimize their impact on system performance.
- Using locks in PostgreSQL requires careful planning and consideration of your application's characteristics. Choose lock types and levels carefully to ensure safe and efficient data operations.


#### Application in Project

In a project, implementing a data cleanup mechanism for N records using a scheduler may require locks to safely delete data. For example, you can use `FOR UPDATE` to select and lock rows before deleting them with a scheduler. Choosing the right lock level is crucial to avoid conflicts and maintain data integrity.


---

## Pessimistic vs. Optimistic Locking

### Pessimistic Locking

Pessimistic locking is often implemented using SQL statements that explicitly block data access for the duration of a transaction. This is typically achieved using commands like `SELECT FOR UPDATE` or `SELECT FOR SHARE`.

**Example:**

Let's say we have a table `accounts` with columns `id` and `balance`. You want to update the balance but ensure that the record won't be changed by another transaction first.

```sql
BEGIN;

-- Lock the row for update
SELECT balance FROM accounts WHERE id = 1 FOR UPDATE;

-- Perform the balance update
UPDATE accounts SET balance = balance + 100 WHERE id = 1;

COMMIT;
```

Here, `FOR UPDATE` locks the selected row, preventing it from being modified by other transactions until the current transaction completes with `COMMIT`.

### Optimistic Locking

Optimistic locking typically uses a version-checking technique. This involves assigning a version number or timestamp to each row in a table that gets updated with each change.

**Example:**

Let's add a `version` column to the `accounts` table. Now, every update must account for the current version.

```sql
-- Assume balance and version were retrieved earlier in the application
-- Current values: balance = 200, version = 3

BEGIN;

-- Update the row only if the version hasn't changed
UPDATE accounts
SET balance = balance + 100, version = version + 1
WHERE id = 1 AND version = 3;

-- Check if the row was updated
IF NOT FOUND THEN
    RAISE EXCEPTION 'Version conflict: data was modified by another transaction.';
END IF;

COMMIT;
```

Here, we attempt to update the record, increasing the balance and version, only if the current version matches the expected version (i.e., the version we started with). If the record was modified by another transaction (and the version incremented), the `UPDATE` statement won't affect any rows (`NOT FOUND` will be true), and the transaction will raise an exception.

### Conclusion

Choosing between pessimistic and optimistic approaches depends on specific application requirements. Pessimistic locking is suitable for highly concurrent scenarios where the risk of deadlocks or other concurrency issues is relatively low. Optimistic locking is typically more efficient in lower-concurrency environments or where locks could significantly degrade performance due to prolonged waits.


--- 

🐸🐸🐸 References 🐸🐸🐸
1) Lock Functions
    - [PostgreSQL Docs](https://www.postgresql.org/docs/9.1/functions-admin.html)
    - [SQL SELECT Statement](https://www.postgresql.org/docs/current/sql-select.html)

2) Query Analysis
    - [PostgreSQL Explain](https://www.postgresql.org/docs/current/sql-explain.html)