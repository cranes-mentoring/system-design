#### Lesson: Basic Database Operations

After creating the order history table, we will explore basic database operations such as adding, reading, updating, and deleting data. We will learn to execute SQL queries to interact with our database using SQL.

**Examples of operations:**
- Adding a new order to the `order_history` table
  ```sql
  INSERT INTO order_history (order_id, customer_id, order_date, total_amount)
  VALUES (1, 123, '2024-04-05', 50.00);
  ```

- Retrieving a list of all orders for a user with `customer_id` equal to 123
  ```sql
  SELECT * FROM order_history WHERE customer_id = 123;
  ```

- Updating the total amount for a specific order
  ```sql
  UPDATE order_history SET total_amount = 60.00 WHERE order_id = 1;
  ```

- Deleting an order from the history by its `order_id`
  ```sql
  DELETE FROM order_history WHERE order_id = 1;
  ```

#### Integrating the Order History Table into the Application
After creating the table, we will integrate it into our application to store information about users' orders when new orders are created.
We will update our API to include new endpoints that allow retrieving information about past orders.

#### In-depth Learning: Masterclass on Indexes in PostgreSQL

In this part of the lesson, we will examine the importance of indexes in PostgreSQL and the various 
types of indexes that can be created to optimize database performance.

##### Understanding Indexes in PostgreSQL
- **Definition and function of an index**: An index speeds up data retrieval by pointing to the data's location in a table, similar to an index in a book.
- **Types of indexes**: B-Tree, Hash, GIN, GiST, BRIN.

##### Examples of Creating Indexes
- **B-Tree**: Optimal for general comparison scenarios.
  ```sql
  CREATE INDEX idx_name ON table_name USING btree(column_name);
  ```

- **Hash**: Good for equality comparison operations.
  ```sql
  CREATE INDEX idx_name ON table_name USING hash(column_name);
  ```

- **GIN**: Ideal for composite values such as arrays or JSONB.
  ```sql
  CREATE INDEX idx_name ON table_name USING gin(column_name);
  ```

- **GiST**: Used for full-text search and geospatial queries.
  ```sql
  CREATE INDEX idx_name ON table_name USING gist(column_name);
  ```

- **BRIN**: Effective for large tables with ordered data.
  ```sql
  CREATE INDEX idx_name ON table_name USING brin(column_name);
  ```

##### Designing and Using Indexes
- **When to create indexes**: For columns frequently used in `WHERE`, `JOIN`, or `ORDER BY` conditions.
- **Monitoring and tuning**: Using `EXPLAIN` and `EXPLAIN ANALYZE` to assess the effectiveness of indexes.

#### Practical Assignment

Identify the most frequently used columns in your queries to a large table. Create appropriate indexes and compare the performance of queries before and after adding indexes using `EXPLAIN ANALYZE`.

---

### Additional: The Importance of Deleting Data in Batches with a Scheduler

Deleting outdated records from the database is an important task for maintaining performance and preventing locks. Frequent deletion of large volumes of data can lead to performance issues and potential failures. A scheduler that deletes data in small batches (e.g., 100 items at a time) reduces the load on the database and avoids potential problems.

#### User Experience

Effective deletion of outdated data directly impacts the user experience by preventing delays and ensuring stable system operation.

#### Preventing Locks and Failures

Regular deletion of data in batches by a scheduler helps prevent database locks and failures, ensuring a more stable and efficient system operation.