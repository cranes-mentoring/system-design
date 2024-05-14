### Lesson: Working with PostgreSQL and Adding an Order History Table

#### Lesson Objectives:
- Familiarize with the basics of working with PostgreSQL
- Create an order history table to store information about users' previous orders
- Learn basic database operations in the context of a flower shop project

#### Part 1: Introduction to PostgreSQL

PostgreSQL is a powerful database management system that allows storing and operating a large volume of structured data. In this part of the lesson, we will familiarize ourselves with the basics of working with PostgreSQL, including creating tables, adding data, and executing queries.

#### Part 2: Creating an Order History Table

To store information about previous orders of users, we will create a new table in our PostgreSQL database. We will define the table structure, including necessary fields for storing order data, as well as relationships with other tables.

**Example structure of the `order_history` table:**
- `order_id`: Unique order identifier (integer, primary key)
- `customer_id`: Unique user identifier (integer, foreign key linked to the users table)
- `order_date`: Date of order placement (date and time)
- `total_amount`: Total amount of the order (decimal number)

---

### Data Structure for the "Orders" Table

| Field              | Data Type | Description                                  |
|--------------------|-----------|----------------------------------------------|
| `order_id`         | INT       | Unique order identifier                      |
| `order_date`       | DATE      | Date of order placement                      |
| `total_amount`     | DECIMAL   | Total amount of the order                    |
| `customer_id`      | INT       | Customer identifier                          |
| `shipping_address` | VARCHAR   | Shipping address of the order                |
| `payment_method`   | VARCHAR   | Payment method (e.g., credit card)           |
| `status`           | VARCHAR   | Status of the order (e.g., "processing", "delivered") |

Example SQL query to create such a table:

```sql
CREATE TABLE Orders (
    order_id INT PRIMARY KEY,
    order_date DATE,
    total_amount DECIMAL(10, 2),
    customer_id INT,
    shipping_address VARCHAR(255),
    payment_method VARCHAR(50),
    status VARCHAR(20)
);
```
Database size calculation:

1. **Record Size**:
    - Assume each record in the `Orders` table has the following size:
        - `order_id`: INT (4 bytes)
        - `order_date`: DATE (4 bytes)
        - `total_amount`: DECIMAL(10, 2) (8 bytes)
        - `customer_id`: INT (4 bytes)
        - `shipping_address`: VARCHAR(255) (255 bytes)
        - `payment_method`: VARCHAR(50) (50 bytes)
        - `status`: VARCHAR(20) (20 bytes)
    - Total size per record: **345 bytes**.

2. **Total Data Volume**:
    - Total number of records: **47,304,000**.
    - Total data volume: (47,304,000 * 345 bytes = 16,310,280,000 bytes).

3. **Conversion to Gigabytes (GB)**:
    - Total data volume in gigabytes: (16,310,280,000 bytes / (1024^3) = 15,548.25 GB).

Thus, the database weight with the specified structure will be approximately **15,548.25 GB**.