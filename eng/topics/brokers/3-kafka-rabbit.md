Apache Kafka provides several levels of message delivery guarantees, which can be configured based on the requirements of your application. Let's explore these guarantees using an example Kafka cluster with three brokers.

### Levels of Delivery Guarantees in Kafka

1. **At Most Once**:
    - Messages are sent and may be lost if a failure occurs before they are delivered.
    - Used when performance is more critical, and data loss is acceptable.
    - Example: Logging data, where losing a few log entries is not critical.

2. **At Least Once**:
    - Messages will be delivered at least once, but duplicates are possible.
    - Example: Order processing systems, where it is crucial not to miss any orders, even if it means handling duplicates.

3. **Exactly Once**:
    - Messages will be delivered exactly once, with no loss and no duplicates.
    - Used when it is critical to process each message only once.
    - Example: Financial transactions, where each transaction must be processed exactly once.

### Configuration for Ensuring Different Levels of Guarantees

For the example of a Kafka cluster with three brokers (broker1, broker2, broker3) and a replication factor of 3.

#### Replication and Replication Factor
- **Replication Factor**: Determines the number of copies of each message stored on different brokers.
- **Replication Factor = 3**: Each message will be copied to all three brokers.

#### Producer Parameters
- **acks (acknowledgments)**:
    - `acks=0`: The producer does not wait for an acknowledgment from the broker. Messages might be lost (At Most Once).
    - `acks=1`: The producer waits for an acknowledgment from the partition leader but not from all replicas. Messages might be lost if the leader fails (between At Most Once and At Least Once).
    - `acks=all` (or `acks=-1`): The producer waits for acknowledgments from all replicas. This ensures At Least Once delivery.
- **retries** and **idempotence**:
    - `retries`: Specifies the number of retry attempts if message sending fails.
    - `enable.idempotence=true`: Enables idempotent mode, ensuring Exactly Once semantics.

### Example Configuration for At Least Once
```properties
acks=all
retries=3
```

### Example Configuration for Exactly Once
```properties
acks=all
retries=3
enable.idempotence=true
```

### Message Processing
#### Consumers:
- **Auto-commit offsets**:
    - `enable.auto.commit=false`: Allows manual management of offsets to ensure that offsets are committed only after successful message processing.
- **Manual acknowledgment**:
    - Consumers should manually acknowledge message processing to avoid data loss in case of a failure.

### Example Consumer Configuration for Exactly Once
```properties
enable.auto.commit=false
```

### Processing Flow
1. **Producer**:
    - Sends a message to Kafka with `acks=all` and `enable.idempotence=true`.
2. **Brokers**:
    - The partition leader writes the message and waits for acknowledgments from all replicas.
3. **Consumer**:
    - Receives the message, processes it, then manually commits the offset to confirm successful processing.

### Failure Scenarios
- **Broker Failure**:
    - If the broker acting as the partition leader fails, one of the remaining brokers (a replica) becomes the new leader, ensuring data availability.
- **Producer or Consumer Failure**:
    - In the case of producer failure, with `retries` and `enable.idempotence`, the message will be resent without duplicates.
    - In the case of consumer failure, offsets are only committed after successful processing, preventing message loss.

### Conclusion
Kafka's configuration and parameters allow achieving various levels of message delivery guarantees based on application needs. 
In a cluster with three brokers, you can effectively set up the system to ensure reliable and precise message delivery using the correct combination of producer and consumer parameters.