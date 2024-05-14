### Lesson: Apache Kafka

#### Introduction

Apache Kafka is a distributed platform for real-time streaming data processing and message exchanging. In this lesson, we'll explore the core concepts of Apache Kafka, including partitions, topics, delivery guarantees, offsets, consumer groups, and examples of working with Kafka in Python.

---

#### 1. Core Concepts

##### Partitions

Partitions are the primary mechanism for data distribution in Kafka. A topic consists of one or more partitions, each of which is an ordered sequence of messages. Partitions allow for load distribution and parallel message processing.

##### Topics

Topics in Kafka are categories to which messages are sent and from which messages are received. They serve to organize and structure data. Each topic consists of one or more partitions.

##### Offsets and Consumer Groups

Offsets are positions within partitions that indicate where a consumer has stopped reading messages. Consumer groups are used to organize Kafka consumers into logical groups. Each consumer in a group receives its own set of partitions to read from.

##### Kafka Architecture

Apache Kafka consists of several key components:
- **Brokers**: Servers responsible for storing and processing data in Kafka.
- **Topics**: Categories to which messages are sent and received.
- **Partitions**: Divisions within topics for data distribution and storage.
- **Producers**: Applications that send messages to Kafka.
- **Consumers**: Applications that receive messages from Kafka.
- **Zones**: Logical groups of brokers.

#### 2. Working with Kafka in Python - Example

To work with Kafka in Python, we use the `confluent_kafka` library. Let's explore an example of sending and receiving messages.

##### Installing the confluent_kafka Library

```
pip install confluent_kafka
```

##### Example: Sending a Message to a Topic

```python
from confluent_kafka import Producer

# Kafka settings
conf = {'bootstrap.servers': 'localhost:9092'}

# Creating a Producer object
producer = Producer(**conf)

# Sending a message to the 'my_topic' topic
producer.produce('my_topic', key='key', value='Hello, Kafka!')

# Waiting for all messages to be sent
producer.flush()
```

##### Example: Receiving a Message from a Topic

```python
from confluent_kafka import Consumer, KafkaError

# Kafka settings
conf = {'bootstrap.servers': 'localhost:9092', 'group.id': 'my_consumer_group'}

# Creating a Consumer object
consumer = Consumer(**conf)

# Subscribing to the 'my_topic' topic
consumer.subscribe(['my_topic'])

# Receiving messages from the topic
while True:
    msg = consumer.poll(1.0)

    if msg is None:
        continue
    if msg.error():
        if msg.error().code() == KafkaError._PARTITION_EOF:
            continue
        else:
            print(msg.error())
            break

    print('Received message: {}'.format(msg.value().decode('utf-8')))

# Closing the Kafka connection
consumer.close()
```

#### 3. Delivery Guarantees

##### Message Delivery Guarantees in Kafka

Kafka provides three levels of message delivery guarantees:
- **At most once**: Messages may be lost but won't be redelivered.
- **At least once**: Messages will be delivered at least once but may be delivered multiple times.
- **Exactly once**: Each message will be delivered exactly once.

##### Example: Configuring Delivery Guarantees in Kafka

```python
# Kafka settings
conf = {'bootstrap.servers': 'localhost:9092',
        'group.id': 'my_consumer_group',
        'enable.auto.commit': False,
        'auto.offset.reset': 'earliest'}
```

#### 4. Advantages of Apache Kafka

Apache Kafka offers several advantages over other message brokers:
- **High Throughput**: Kafka provides high throughput and reliability when processing large volumes of data.
- **Horizontal Scalability**: Kafka scales easily horizontally due to partitioning.
- **Fault Tolerance**: Kafka ensures reliable data storage and automatic recovery after failures.
- **Flexibility**: Kafka supports a wide range of applications and use cases thanks to its flexible architecture.

You can read and write messages to Apache Kafka using command-line utilities that come with Kafka. Here's how to do it:

### Reading Messages from a Topic:

- Open a terminal.

- Run the `kafka-console-consumer` utility, providing necessary parameters like broker address and the topic from which you want to read messages. For example:

```
kafka-console-consumer --bootstrap-server localhost:9092 --topic my_topic
```

Where:
- `--bootstrap-server localhost:9092` - Kafka broker address and port.
- `--topic my_topic` - Name of the topic from which you want to read messages.

- The utility will start reading messages from the specified topic and display them in the console.

### Writing Messages to a Topic:

- Open a new terminal.

- Run the `kafka-console-producer` utility, providing necessary parameters like broker address and the topic to which you want to write messages. For example:

```
kafka-console-producer

 --bootstrap-server localhost:9092 --topic my_topic
```

Where:
- `--bootstrap-server localhost:9092` - Kafka broker address and port.
- `--topic my_topic` - Name of the topic to which you want to write messages.

Now, you can type messages into the console and press Enter to send them to the specified topic.

This is a simple way to interact with Apache Kafka using command-line utilities for reading and writing messages.

#### Conclusion

Apache Kafka is a powerful and flexible platform for real-time message processing and exchange. Understanding the core concepts and working with Kafka in Python allows developers to efficiently implement distributed data processing and streaming analysis systems.

### Useful Software
[Kafka UI](https://github.com/provectus/kafka-ui)