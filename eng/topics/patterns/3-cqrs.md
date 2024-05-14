**CQRS (Command and Query Responsibility Segregation)** is a pattern that separates read and update operations for a data store. Implementing CQRS in your application can maximize its performance, scalability, and security¹.

Let's explore how to apply CQRS to your service, enabling data retrieval through **Elasticsearch** and data storage in **PostgreSQL**.

1. **CQRS in the Context of Data Retrieval via Elasticsearch**:
    - **Commands**: Responsible for updating data. In your case, commands will write data to **PostgreSQL**.
    - **Queries**: Responsible for reading data. Queries will be directed to **Elasticsearch** for data search and analysis.

2. **Elasticsearch**:
    - It is a powerful search and analytics engine.
    - You can index data in Elasticsearch and perform complex search queries.

3. **Designing CQRS for Your Service**:
    - **Commands**:
        - Create a separate layer for handling commands. This layer will write data to **PostgreSQL**.
        - Validate commands and apply business logic before saving data.
        - Asynchronous command processing can be used, e.g., via message queues.
    - **Queries**:
        - Create a separate layer for handling queries. This layer will query **Elasticsearch** for data retrieval.
        - Queries should not modify the database, only read from it.
        - Return DTOs (Data Transfer Objects) without domain logic.

4. **Security**:
    - Access control management can be simplified, as queries and commands are handled by different models.

5. **Example**:
    - User sends a command "Create Order".
    - The service handles the command, validates data, and saves the order in **PostgreSQL**.
    - User sends a query "Get list of orders for the last month".
    - The service queries **Elasticsearch**, performs the search, and returns the list of orders.

**Elasticsearch** is a powerful search and analytics engine that efficiently indexes and searches data. Let's explore setting up Elasticsearch for data indexing:

----

1. **Installing and Running Elasticsearch**:
    - The simplest way is to create a managed deployment using **Elasticsearch Service on Elastic Cloud**.
    - If you prefer managing your own testing environment, install and run Elasticsearch using **Docker**.

2. **Creating an Index**:
    - An index is a logical grouping of data in Elasticsearch.
    - Use the REST API or Elasticsearch Python client to create an index. For example:
      ```python
      self.es.indices.create(index='my_documents')
      ```

3. **Adding Documents to the Index**:
    - Documents are represented as dictionaries with keys and values.
    - You can add documents to an index using the Elasticsearch Python client.

4. **Checking Elasticsearch Status**:
    - Make a REST API request to Elasticsearch to ensure the Elasticsearch container is running:
      ```bash
      curl --cacert http_ca.crt -u elastic:$ELASTIC_PASSWORD https://localhost:9200
      ```

5. **Launching Kibana**:
    - **Kibana** is a user interface for Elasticsearch.
    - Open Kibana in your browser using the generated URL.
    - Connect Kibana to the Elasticsearch container using the previously copied token.

¹: Source - [Microsoft Azure - CQRS pattern](https://docs.microsoft.com/en-us/azure/architecture/patterns/cqrs)