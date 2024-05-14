### Lesson: Kafka Connectors

Apache Kafka Connect is a framework that provides an easy way to integrate Kafka with external systems. Kafka Connectors serve as adapters for working with various data sources and sinks, allowing you to seamlessly integrate Kafka into your existing infrastructure. Let's explore the key types of Kafka Connectors and their usage.

---

### Part 1: Types of Kafka Connectors

#### 1. Source Connectors (Data Sources)

Source Connectors are used to read data from external systems and write it to Kafka topics. They enable you to integrate Kafka with various data sources such as databases, file systems, cloud services, etc. Examples of data sources include:

- JDBC Source Connector (for SQL databases)
- FileStream Source Connector (for reading data from files)
- Debezium Connector (for capturing database changes)

#### 2. Sink Connectors (Data Sinks)

Sink Connectors are used to read data from Kafka topics and write it to external systems. They enable you to integrate Kafka with various data sinks such as databases, data stores, cloud services, etc. Examples of data sinks include:

- JDBC Sink Connector (for SQL databases)
- HDFS Sink Connector (for writing data to Hadoop HDFS)
- Elasticsearch Sink Connector (for indexing data in Elasticsearch)

### Part 2: Example Usage

Let's consider an example using the JDBC Source Connector to read data from a MySQL database and write it to a Kafka topic:

#### Step 1: Installing and Configuring the Connector

Install and configure the JDBC Source Connector, specifying the connection parameters to your MySQL database.

#### Step 2: Creating the Connector Configuration File

Create a configuration file for the JDBC Source Connector, specifying the Kafka topic to which you want to write the data and the MySQL table from which you want to read the data.

```json
{
  "name": "mysql-source-connector",
  "config": {
    "connector.class": "io.confluent.connect.jdbc.JdbcSourceConnector",
    "tasks.max": "1",
    "connection.url": "jdbc:mysql://localhost:3306/mydatabase",
    "connection.user": "user",
    "connection.password": "password",
    "mode": "incrementing",
    "incrementing.column.name": "id",
    "topic.prefix": "mysql-"
  }
}
```

#### Step 3: Running the Connector

Run the connector using the created configuration file.

```
$ connect-standalone config/connect-standalone.properties config/mysql-source-connector.properties
```

#### Step 4: Checking Data in the Kafka Topic

Verify that data is successfully written to the specified Kafka topic.

Now, let's dive into more detailed examples of configuring Kafka Connectors to read data from MySQL databases and write it to Kafka topics.

### Example 1: Setting Up JDBC Source Connector for MySQL

#### 1. Installing and Configuring the Connector:

First, install the JDBC Source Connector and ensure you have access to the MySQL database.

#### 2. Creating the Connector Configuration File:

Create a file `mysql-source-connector.properties` with the following contents:

```properties
name=mysql-source-connector
connector.class=io.confluent.connect.jdbc.JdbcSourceConnector
tasks.max=1
connection.url=jdbc:mysql://localhost:3306/mydatabase
connection.user=user
connection.password=password
mode=incrementing
incrementing.column.name=id
topic.prefix=mysql-
```

This file defines the connection parameters to the MySQL database and settings for reading and writing data to Kafka topics.

#### 3. Running the Connector:

Run the connector using the command:

```
connect-standalone config/connect-standalone.properties config/mysql-source-connector.properties
```

### Example 2: Setting Up JDBC Sink Connector for PostgreSQL

#### 1. Installing and Configuring the Connector:

Ensure you have access to the PostgreSQL database and install the JDBC Sink Connector.

#### 2. Creating the Connector Configuration File:

Create a file `postgresql-sink-connector.properties` with the following contents:

```properties
name=postgresql-sink-connector
connector.class=io.confluent.connect.jdbc.JdbcSinkConnector
tasks.max=1
topics=mysql-my_topic
connection.url=jdbc:postgresql://localhost:5432/mydatabase
connection.user=user
connection.password=password
auto.create=true
```

This file defines the connection parameters to the PostgreSQL database and settings for writing data from Kafka topics.

#### 3. Running the Connector:

Run the connector using the command:

```
connect-standalone config/connect-standalone.properties config/postgresql-sink-connector.properties
```

These are simple examples of configuring Kafka Connectors to work with MySQL and PostgreSQL databases. You can customize the parameters according to your integration needs and requirements.

### Part 3: Conclusion

Kafka Connectors provide an easy way to integrate Apache Kafka with various data sources and sinks. By using different types of connectors, you can easily exchange data between Kafka and your existing systems, ensuring reliable and scalable integration.