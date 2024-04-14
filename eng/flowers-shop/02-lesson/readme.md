### Lesson 2: Analysis and Planning

#### Lesson Objectives:
- Understand the requirements gathering and system analysis process
- Define functional and non-functional requirements for the project
- Develop a database schema and determine data storage volumes

--- 

#### Part 1: Requirements Gathering

To begin, open any diagramming tool capable of drawing diagrams:
- [draw.io](https://app.diagrams.net)
- [Miro](https://miro.com)

Before diving into the design, it's crucial to fully understand the system's requirements. We need to communicate with stakeholders, identify their needs, and clarify details.

Start by focusing on specific modules rather than designing all services at once:
1) Clarify what exactly is required from us, which module.
2) Gather maximum details about potential users.

### Understanding Activity and Load

During system design interviews, questions related to performance and scalability metrics may arise, such as RPS (requests per second), MAU (monthly active users), and DAU (daily active users).

These metrics help understand the system's load and usage.

1. **RPS (Requests Per Second)**:
  - RPS is the number of requests a system handles per second. It helps estimate the traffic volume the system needs to handle during peak hours. Requests can be of various types, e.g., HTTP requests to a web server or database queries.

   Key interview questions:
  - What types of requests are considered in RPS calculation?
  - What is the expected peak RPS?

   Use of this information:
  - Use RPS to determine scalability requirements, such as how many servers or resources are needed to handle the expected load.

2. **MAU (Monthly Active Users) and DAU (Daily Active Users)**:
  - MAU is the count of unique users interacting with the system in a month.
  - DAU is the count of unique users interacting with the system in a day.

   These metrics are important for assessing overall system popularity and usage over time.

   Key interview questions:
  - What is the expected growth of MAU and DAU over time?
  - What user actions are considered activity for calculating MAU and DAU?

   Use of this information:
  - Utilize MAU and DAU for resource planning and system scalability, considering user base growth.

At this stage, we need to be able to estimate approximate load. If we lack sufficient information, it may be time to move to the next point.

#### Understanding What Needs to Be Done

In our case, the key requirements for the flower shop service include:
- Ability to add, edit, and delete products (flowers)
- Ability to create user orders
- Storage of order history for a year
- Automatic removal of old records
- Ensuring secure data access

### Part 2: System Design Interview

During system design interviews, key performance metrics like RPS (requests per second), MAU (monthly active users), and DAU (daily active users) are often discussed. These metrics help assess the system's load and usage.

**1. RPS (Requests Per Second):**
- RPS represents the number of requests the system processes per second. It helps estimate the traffic volume the system needs to handle during peak hours.

  **Example interview questions:**
  - What types of requests are considered in RPS calculation?
  - What is the expected peak RPS?

**2. MAU (Monthly Active Users) and DAU (Daily Active Users):**
- MAU is the count of unique users active in the system within a month.
- DAU is the count of unique users active in the system within a day.

  **Example interview questions:**
  - What is the expected growth of MAU and DAU over time?
  - Which user actions are considered activity for calculating MAU and DAU?

**Using this information:**
- RPS helps determine the required scalability of the system, such as the number of servers or resources needed to handle expected load.
- MAU and DAU aid in resource planning and future system scalability, considering user base growth.

Overall, these metrics provide insight into the system's load and usage expectations, helping design a system that meets user needs and scalability capabilities.

----- 
#### In Our Example:

Based on gathered requirements, we can identify functional and non-functional requirements. Functional requirements define what the system should do, while non-functional requirements define how the system should operate. For example:
- Functional Requirements:
  - Creation, editing, and deletion of products
  - Order creation and cancellation
  - Storage of order history
- Non-functional Requirements:
  - Storage of order history for a year
  - Ensuring data security

#### Part 3: Database Design

Based on identified requirements, we can proceed to design the database schema. For our flower shop, we'll need the following entities:
- "Products" table to store flower information
- "Orders" table to store user order information
- "Order_History" table to store order change history

#### Part 4: Estimating Data Volumes

The next step is to estimate the data volumes that will be stored in our database. We need to calculate how many records will be created over a certain period and how much database memory will be consumed. This helps us choose appropriate storage tools and optimize system performance.

Additional useful figures:
- [Understanding Scalability and Performance](https://habr.com/ru/articles/108537/)
- [Numbers Everyone Should Know](http://julianhyde.blogspot.com/2010/11/numbers-everyone-should-know.html)