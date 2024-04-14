### Lesson 3: Developing a Simple REST API

#### Lesson Objectives:
- Learn to create a simple REST API for managing products and orders
- Understand the basics of authentication and authorization using request headers

#### Part 1: Introduction to REST API

REST (Representational State Transfer) is an architectural style for developing web applications that defines resources and methods of accessing them through standard HTTP methods (GET, POST, PUT, DELETE). In this lesson, we will develop a simple REST API for managing products and orders in a flower shop.

#### Part 2: Creating Data Models

Before creating the API, we need to define the data structure we will use. We will create data models for products and orders, specifying the necessary fields and relationships between them.

**Example Model Fields:**
- Product Model (`Product`):
  - `id`: Unique identifier of the product (integer)
  - `name`: Name of the product (string)
  - `description`: Description of the product (string)
  - `price`: Price of the product (decimal number)
  - `created_at`: Date and time of record creation (datetime)

- Order Model (`Order`):
  - `id`: Unique identifier of the order (integer)
  - `customer_name`: Customer's name (string)
  - `email`: Customer's email (string)
  - `products`: List of products in the order (relation to `Product` model)
  - `total_amount`: Total amount of the order (decimal number)
  - `created_at`: Date and time of order creation (datetime)

#### Part 3: API Development

At this stage, we will start developing API endpoints to perform various operations such as creating, reading, updating, and deleting products and orders.

**Example Endpoints:**
- `GET /api/products`: Get a list of all products
- `POST /api/products`: Create a new product
- `GET /api/products/{id}`: Get information about a specific product
- `PUT /api/products/{id}`: Update product information
- `DELETE /api/products/{id}`: Delete a product by identifier

- `GET /api/orders`: Get a list of all orders
- `POST /api/orders`: Create a new order
- `GET /api/orders/{id}`: Get information about a specific order
- `PUT /api/orders/{id}`: Update order information
- `DELETE /api/orders/{id}`: Delete an order by identifier

#### Part 5: Authentication and Authorization

To secure our API, we will implement simple authentication and authorization using request headers. Users will pass their unique identifier in the request header to access protected endpoints.

**Example Header:**
- `Authorization: Bearer {token}`

#### Part 7: API Testing

Testing the functionality of our API is a critical part of development. We will write simple tests to verify each endpoint and ensure that the API functions correctly.

**Example Tests:**
- Test creating a new product
- Test retrieving a list of orders
- Test updating product information

**Conclusion:**

In this lesson, we learned the basics of developing a simple REST API, defined data models, developed endpoints for working with products and orders, implemented basic authentication and authorization, and wrote simple tests to verify API functionality. These skills will enable you to create efficient and secure web applications based on REST architecture.

----

#### In Our Example, We Need To:
1. Define the main methods for API operations.
2. Outline example fields for data models.
3. Consider headers and what information we can include there.