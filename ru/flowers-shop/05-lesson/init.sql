-- init orders
CREATE TABLE "orders" (
                          id SERIAL,
                          address CHAR(255),
                          description VARCHAR(255),
                          receiver_name VARCHAR(255),
                          receive_time TIMESTAMP,
                          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                          updated_at TIMESTAMP,
                          offer_id INT NOT NULL,
                          status CHAR(15),
                          user_uuid CHAR(36) NOT NULL,
                          customer_id INT NOT NULL,
                          PRIMARY KEY (id, created_at)
);
-- if we need to create partitions and we already have the table - we have to create a new one.
-- we should use user_uuid as UUID type
CREATE TABLE IF NOT EXISTS "orders_1" (
                              id SERIAL,
                              address CHAR(255),
                              description VARCHAR(255),
                              receiver_name VARCHAR(255),
                              receive_time TIMESTAMP,
                              created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                              updated_at TIMESTAMP,
                              offer_id INT NOT NULL,
                              status CHAR(15),
                              user_uuid UUID NOT NULL PRIMARY KEY, -- important
                              customer_id INT NOT NULL
) PARTITION BY HASH (user_uuid);
-- or
CREATE TABLE IF NOT EXISTS "orders_2" (
                              id SERIAL,
                              address CHAR(255),
                              description VARCHAR(255),
                              receiver_name VARCHAR(255),
                              receive_time TIMESTAMP,
                              created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                              updated_at TIMESTAMP,
                              offer_id INT NOT NULL,
                              status CHAR(15),
                              user_uuid UUID NOT NULL, -- important
                              customer_id INT NOT NULL
) PARTITION BY HASH (user_uuid);