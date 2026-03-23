# Module 02: Networking and Protocols

> **Audience:** backend developers with 2+ years of experience  
> **Goal:** understand how networking works under the hood in distributed systems, to make sound architectural decisions

---

## Table of Contents

1. [DNS: How it works and why you need to know](#1-dns)
2. [HTTP/1.1 → HTTP/2 → HTTP/3](#2-http)
3. [REST vs gRPC vs GraphQL](#3-rest-grpc-graphql)
4. [WebSocket and Server-Sent Events](#4-websocket-sse)
5. [Load Balancing](#5-load-balancing)
6. [API Gateway](#6-api-gateway)
7. [Service Discovery](#7-service-discovery)
8. [Idempotency in Network Communication](#8-idempotency)

---

## 1. DNS

DNS (Domain Name System) is a distributed hierarchical database that maps domain names to IP addresses. For system design, DNS matters not only as a "phone book," but also as a tool for load balancing, failover, and traffic routing.

### 1.1 DNS Hierarchy

```
Query: api.example.com

Client
  │
  ▼
Recursive Resolver (ISP or 8.8.8.8)
  │
  ├─► Root Name Server (.)
  │     "Don't know, ask TLD .com"
  │
  ├─► TLD Name Server (.com)
  │     "Don't know, ask authoritative for example.com"
  │
  └─► Authoritative Name Server (example.com)
        "api.example.com → 93.184.216.34"
```

**Root servers:** 13 logical servers (A–M), physically replicated worldwide via anycast. Their addresses are hardcoded in DNS resolvers.

**TLD servers:** managed by registrars (Verisign for `.com`, RIPE NCC for `.eu`, etc.).

**Authoritative servers:** this is what you configure in your DNS provider (Route53, Cloudflare, NS1). They give the final answer.

**Recursive resolver:** caches results. Most queries don't go past it.

### 1.2 DNS Record Types

| Type   | Description                                      | Example                                               |
|--------|--------------------------------------------------|-------------------------------------------------------|
| `A`    | Domain → IPv4                                    | `api.example.com → 93.184.216.34`                     |
| `AAAA` | Domain → IPv6                                    | `api.example.com → 2606:2800:220:1:248:1893:25c8:1946` |
| `CNAME`| Alias to another domain                          | `www.example.com → example.com`                       |
| `MX`   | Mail exchange for domain                         | `example.com → mail.example.com` (priority 10)        |
| `NS`   | Authoritative name servers                       | `example.com NS ns1.cloudflare.com`                   |
| `TXT`  | Arbitrary text (SPF, DKIM, verification)         | `v=spf1 include:_spf.google.com ~all`                 |
| `SRV`  | Service, port, protocol                          | `_grpc._tcp.example.com 10 0 50051 grpc.example.com`  |
| `PTR`  | Reverse lookup: IP → domain                      | `34.216.184.93.in-addr.arpa → api.example.com`        |
| `CAA`  | Permitted Certificate Authorities               | `example.com CAA 0 issue "letsencrypt.org"`           |

**SRV records** are especially useful for service discovery in microservices: the client can automatically find the service's port and priority without hardcoding.

### 1.3 TTL and Caching

TTL (Time-To-Live) — how many seconds a record can be cached. This is a key parameter when planning changes.

```
Record: api.example.com A 93.184.216.34 TTL=300

What happens:
- Resolver cached the record
- You change IP to 10.0.0.5
- Before 300s expire: some clients see the old IP
- After expiry: all clients get the new IP

Summary: propagation delay ≈ TTL
```

**TTL recommendations:**

| Situation                           | TTL          |
|-------------------------------------|--------------|
| Production, rarely changes          | 3600–86400 s |
| 24–48h before a planned migration   | 60–300 s     |
| Active migration                    | 30–60 s      |
| After migration (stable)            | 3600+ s      |

Short TTL = more DNS queries = load on the authoritative server and slight resolution latency.

### 1.4 DNS-based Load Balancing

**Round-Robin DNS:** one domain returns multiple A records. The client selects one, usually the first.

```dns
api.example.com  300  A  10.0.1.1
api.example.com  300  A  10.0.1.2
api.example.com  300  A  10.0.1.3
```

Problems with round-robin DNS:
- Client caches the first IP → uneven load
- No health check: if 10.0.1.2 is down, DNS keeps returning it
- Sticky clients (mobile SDKs, browsers) don't rotate records

**GeoDNS:** the authoritative server returns different IPs based on the client resolver's geolocation.

```
Client from EU → api.eu.example.com (10.20.1.1)
Client from US → api.us.example.com (10.10.1.1)
Client from AP → api.ap.example.com (10.30.1.1)
```

Used in AWS Route53 (Geolocation routing), Cloudflare, NS1.

**Weighted DNS:** different weights for A/B deployment or gradual traffic switching.

```
api.example.com  A  10.0.1.1  weight=90   # old version
api.example.com  A  10.0.1.2  weight=10   # new version (canary)
```

### 1.5 DNS Problems

**DNS Propagation:** changing a record does not propagate instantly. Old TTLs are cached by recursive resolvers around the world. Real propagation can take up to 48 hours, though at TTL=300 most resolvers will update in 5–10 minutes.

**DNS Cache Poisoning (Kaminsky Attack):** an attacker replaces cached records in a recursive resolver, directing traffic to a malicious IP. Defenses: DNSSEC (digital signatures), randomized source ports, 0x20 encoding.

**DNSSEC:** adds a chain of trust via cryptographic signatures. Complicates infrastructure but protects against record spoofing.

**Split-horizon DNS:** one domain resolves to different IPs depending on whether the network is internal or external. Common in corporate systems: `db.internal.example.com` → `10.0.0.5` inside the VPC, error from outside.

### 1.6 Example: HA with multiple A records

```
# Route53 configuration (or equivalent)
api.example.com  60  A  10.0.1.10   # primary, eu-west-1
api.example.com  60  A  10.0.1.11   # secondary, eu-west-1

# Health check policy: if primary doesn't respond on :80/health
# → Route53 removes it from the response automatically

# Diagram:
  DNS Query for api.example.com
         │
         ▼
   Route53 (health-check aware)
    ├── 10.0.1.10 (healthy) ✓  ← returned
    └── 10.0.1.11 (healthy) ✓  ← returned
    
  If 10.0.1.10 goes down:
    ├── 10.0.1.10 (unhealthy) ✗  ← not returned
    └── 10.0.1.11 (healthy)  ✓  ← only answer
```

TTL=60 means failover takes at most 1 minute. For critical systems, Route53 allows alias records with TTL=0.

---

## 2. HTTP

### 2.1 HTTP/1.1

HTTP/1.1 was released in 1997 and is still widely used. Key features:

**Keep-Alive (persistent connections):** the connection is not closed after each request. Before HTTP/1.1, a new TCP handshake (3 RTT) was created for each request. With keep-alive — one connection for multiple requests.

```
HTTP/1.0:
  TCP connect → Request → Response → TCP close    (repeat)

HTTP/1.1 (keep-alive):
  TCP connect → Request → Response → Request → Response → ... → TCP close
```

**Head-of-Line (HOL) Blocking:** requests on a single TCP connection are processed sequentially. A slow request blocks all subsequent ones.

```
Connection 1: [Request A (slow)] → [Request B] → [Request C]
               ← waiting for A ─────────────────────────────

Browsers worked around this with 6 parallel connections per domain:
Connection 1: Request A
Connection 2: Request B
Connection 3: Request C
...
```

**Pipelining** in HTTP/1.1: send multiple requests without waiting for a response — theoretically available, practically doesn't work due to HOL blocking at the TCP level and poor proxy support.

**Chunked Transfer Encoding:** the server can start sending the response body before it knows the full size (useful for streaming).

### 2.2 HTTP/2

HTTP/2 (RFC 7540, 2015) solved the main problems of HTTP/1.1, while leaving the semantics unchanged (methods, headers, status codes remained the same).

**Multiplexing:** multiple requests and responses are transmitted in parallel within a single TCP connection via the concept of streams.

```
HTTP/1.1 (3 connections):
  Conn 1: ──[Req A]────────────────[Resp A]──
  Conn 2: ──[Req B]──[Resp B]────────────────
  Conn 3: ──[Req C]────[Resp C]──────────────

HTTP/2 (1 connection, 3 streams):
  Stream 1: ──[Req A]──────────────[Resp A]──
  Stream 3: ──[Req B]──[Resp B]────────────── 
  Stream 5: ──[Req C]────[Resp C]────────────
  TCP:      ════════════════════════════════
```

**Binary framing:** data is split into frames (HEADERS, DATA, SETTINGS, PUSH_PROMISE, etc.). This is more efficient than the text protocol of HTTP/1.1.

**HPACK header compression:** headers are transmitted in compressed form. Repeated headers (Authorization, Content-Type) are encoded as an index from a shared table.

```
First request:
  HEADERS: method=GET, path=/api/users, authorization=Bearer abc123

Second request to the same domain:
  HEADERS: [index 2] (method=GET from table)
           [index 5] (path=/api/orders — new, added to table)
           [index 8] (authorization — from table, not retransmitted)
```

**Server Push:** the server can send resources before the client requests them. Practically unused in APIs (more for HTML+CSS+JS).

**Priority streams:** the client can specify stream priority. Rarely used in APIs, important for browser rendering.

**HTTP/2 problem:** HOL blocking remains, but now at the TCP level. If a TCP packet is lost, all streams in the connection wait for retransmission.

### 2.3 HTTP/3 and QUIC

HTTP/3 (RFC 9114, 2022) replaces TCP with QUIC (Quick UDP Internet Connections).

**QUIC runs over UDP.** This allows:
- Built-in encryption (TLS 1.3 is mandatory)
- Independent streams: packet loss in one stream doesn't block others
- 0-RTT and 1-RTT handshake

```
TCP + TLS 1.2:
  SYN → SYN-ACK → ACK             (1 RTT TCP)
  ClientHello → ServerHello        (1 RTT TLS)
  → 2 RTT to first byte of data

TCP + TLS 1.3:
  SYN → SYN-ACK → ACK             (1 RTT TCP)
  ClientHello + TLS = 1 RTT combined
  → 1 RTT to first byte of data

QUIC (0-RTT, reconnect):
  → 0 RTT for known servers (session resumption)
  → 1 RTT for new connections
```

**Connection Migration:** QUIC identifies connections by Connection ID, not by IP:port. This allows mobile clients to switch between WiFi and LTE without dropping the connection.

```
Client IP: 192.168.1.5 (WiFi)
  → QUIC Connection ID: 0xABCD1234
  
WiFi disconnected, LTE connected
Client IP: 10.0.0.1 (LTE)
  → QUIC Connection ID: 0xABCD1234 (the same!)
  → Connection preserved, request continues
```

### 2.4 HTTP Version Comparison

| Feature                   | HTTP/1.1       | HTTP/2          | HTTP/3 (QUIC)   |
|---------------------------|----------------|-----------------|-----------------|
| Transport protocol        | TCP            | TCP             | UDP (QUIC)      |
| Multiplexing              | No (workaround: 6 conn) | Yes, streams | Yes, independent streams |
| HOL Blocking              | Yes (app + TCP) | TCP only       | No              |
| Header compression        | No             | HPACK           | QPACK           |
| Encryption                | Optional       | Optional (de-facto TLS) | Mandatory (TLS 1.3) |
| Server Push               | No             | Yes (rarely used) | Yes (deprecated in RFC) |
| 0-RTT handshake           | No             | No              | Yes             |
| Connection Migration      | No             | No              | Yes             |
| Browser support           | 100%           | ~98%            | ~95%            |
| Server support            | 100%           | ~80% (Nginx, Apache, Go) | ~60% (Cloudflare, Caddy) |

### 2.5 When to Use Which

**HTTP/1.1:** legacy systems, simple internal APIs without strict latency requirements, tooling (curl by default).

**HTTP/2:** most new APIs, gRPC (requires HTTP/2), websites with many resources, mobile clients (saves connections).

**HTTP/3:** public APIs with a global audience (especially mobile), CDN edge, latency-sensitive services on poor networks. Cloudflare and Google actively use HTTP/3.

```
Example: protocol choice for an API
  
  Internal gRPC between services → HTTP/2 (mandatory)
  Public REST API for mobile → HTTP/2 (minimum), HTTP/3 (with Caddy/Cloudflare)
  Webhook receiver → HTTP/1.1 (sufficient)
  Data streaming to client → HTTP/2 with server push or HTTP/3
```

---

## 3. REST vs gRPC vs GraphQL

### 3.1 REST

REST (Representational State Transfer) is an architectural style, not a protocol. Key principles per Fielding:

1. **Stateless:** each request contains all the needed information. No server-side session state.
2. **Client-Server:** separation of concerns.
3. **Cacheable:** responses are explicitly marked as cacheable or not.
4. **Uniform Interface:** unified interface through resources, HTTP methods, response codes.
5. **Layered System:** the client doesn't know whether it's talking directly to the server or through a proxy.
6. **Code on Demand (optional):** the server may deliver executable code.

**Richardson Maturity Model (RMM):**

```
Level 0: RPC over HTTP
  POST /getUserById
  POST /createOrder
  POST /deleteProduct

Level 1: Resources
  GET /users/123
  POST /orders
  DELETE /products/456

Level 2: HTTP methods + response codes
  GET    /users/123        → 200 OK
  POST   /users            → 201 Created
  PUT    /users/123        → 200 OK
  DELETE /users/123        → 204 No Content
  GET    /users/999        → 404 Not Found

Level 3: HATEOAS (Hypermedia)
  GET /users/123
  {
    "id": 123,
    "name": "Alice",
    "_links": {
      "self":   { "href": "/users/123" },
      "orders": { "href": "/users/123/orders" },
      "delete": { "href": "/users/123", "method": "DELETE" }
    }
  }
```

Most "REST APIs" in production are Level 2. Level 3 is rare.

**Idempotency of HTTP methods:**

| Method  | Idempotent | Safe | Cacheable |
|---------|------------|------|-----------|
| GET     | Yes        | Yes  | Yes       |
| HEAD    | Yes        | Yes  | Yes       |
| OPTIONS | Yes        | Yes  | No        |
| PUT     | Yes        | No   | No        |
| DELETE  | Yes        | No   | No        |
| POST    | No         | No   | Sometimes |
| PATCH   | No*        | No   | No        |

*PATCH can be idempotent if the operation sets a specific value rather than "add N."

### 3.2 gRPC

gRPC is an RPC framework from Google that uses Protocol Buffers (protobuf) for serialization and HTTP/2 for transport.

**Protocol Buffers:** binary serialization with an explicit schema. More efficient than JSON (smaller size, faster parsing) and self-documenting.

```proto
// user.proto
syntax = "proto3";

package user.v1;

option go_package = "github.com/example/api/gen/user/v1;userv1";

service UserService {
  rpc GetUser(GetUserRequest) returns (GetUserResponse);
  rpc ListUsers(ListUsersRequest) returns (stream User);          // server streaming
  rpc CreateUsers(stream CreateUserRequest) returns (CreateUsersResponse); // client streaming
  rpc SyncUsers(stream SyncRequest) returns (stream SyncResponse); // bidirectional
}

message GetUserRequest {
  int64 id = 1;
}

message GetUserResponse {
  User user = 1;
}

message User {
  int64  id    = 1;
  string name  = 2;
  string email = 3;
  int64  created_at = 4; // unix timestamp
}

message ListUsersRequest {
  int32 page_size = 1;
  string page_token = 2;
}

message CreateUserRequest {
  string name  = 1;
  string email = 2;
}

message CreateUsersResponse {
  int32 created_count = 1;
}

message SyncRequest {
  int64 user_id = 1;
}

message SyncResponse {
  User user = 1;
  string status = 2;
}
```

**gRPC streaming types:**

```
Unary RPC:
  Client ──[Request]──► Server ──[Response]──► Client
  Like a regular HTTP call

Server Streaming:
  Client ──[Request]──► Server ──[Response 1]──[Response 2]──[Response 3]──► Client
  Example: subscribe to updates, export a large file

Client Streaming:
  Client ──[Req 1]──[Req 2]──[Req 3]──► Server ──[Response]──► Client
  Example: uploading a file in chunks, batch record creation

Bidirectional Streaming:
  Client ──[Req 1]──[Req 2]──────────────────────────────────► Server
  Client ◄──────────────────[Resp 1]──[Resp 2]──[Resp 3]───── Server
  Example: chat, real-time data exchange
```

### 3.3 GraphQL

GraphQL is a query language for APIs, developed by Facebook in 2012 and published in 2015.

**Problems it solves:**

```
# REST: get a user with their orders and shipping addresses
GET /users/123                    → {id, name, email, ...}   (over-fetching: extra fields)
GET /users/123/orders             → [{id, total, items...}]
GET /users/123/orders/456/address → {street, city...}

# GraphQL: one query, exactly the fields you need
query {
  user(id: "123") {
    name
    orders(last: 5) {
      id
      total
      shippingAddress {
        city
        country
      }
    }
  }
}
```

**When GraphQL is actually needed:**
- Public API with diverse clients (web, mobile, partners) with different data needs
- Frequent changes in client requirements without the ability to change the backend
- BFF (Backend For Frontend) as an aggregation layer

**When GraphQL is overkill:**
- Internal services between backends (gRPC is better)
- Simple CRUD APIs with predictable queries
- Small team where API changes are coordinated quickly

### 3.4 Comparison Table

| Criterion             | REST            | gRPC                  | GraphQL               |
|-----------------------|-----------------|-----------------------|-----------------------|
| Protocol              | HTTP/1.1+       | HTTP/2 (required)     | HTTP/1.1+             |
| Data format           | JSON (typically) | Protocol Buffers     | JSON                  |
| Payload size          | Large           | Small (~3–10× smaller) | Depends on query    |
| Serialization speed   | Medium          | High                  | Medium                |
| Typing                | Optional (OpenAPI) | Strict (proto)    | Strict (schema)       |
| Browser support       | Full            | Limited (grpc-web)    | Full                  |
| Streaming             | SSE / WebSocket | Built-in              | Subscriptions (WS)    |
| Debugging             | Easy (curl)     | Harder (grpcurl, Evans) | Medium (Playground) |
| Code generation       | Optional        | Mandatory             | Optional              |
| Caching               | HTTP-cache      | None (custom)         | Complex (per-field)   |
| Versioning            | /v1/, /v2/      | Via proto packages    | Schema evolution      |

### 3.5 Go Example: Same Endpoint in REST and gRPC

**Proto file (already shown in 3.2). Generated handler for gRPC:**

```go
// Installing dependencies:
// go get google.golang.org/grpc
// go get google.golang.org/protobuf
// protoc --go_out=. --go-grpc_out=. user.proto

// grpc_server.go
package main

import (
	"context"
	"fmt"
	"log"
	"net"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	userv1 "github.com/example/api/gen/user/v1"
)

// UserStore — storage abstraction (same for REST and gRPC)
type UserStore interface {
	GetByID(ctx context.Context, id int64) (*User, error)
}

type User struct {
	ID        int64
	Name      string
	Email     string
	CreatedAt int64
}

// gRPC handler
type userGRPCServer struct {
	userv1.UnimplementedUserServiceServer
	store UserStore
}

func (s *userGRPCServer) GetUser(ctx context.Context, req *userv1.GetUserRequest) (*userv1.GetUserResponse, error) {
	if req.Id <= 0 {
		return nil, status.Errorf(codes.InvalidArgument, "id must be positive, got %d", req.Id)
	}

	user, err := s.store.GetByID(ctx, req.Id)
	if err != nil {
		// Mapping domain errors to gRPC statuses
		return nil, status.Errorf(codes.Internal, "store error: %v", err)
	}
	if user == nil {
		return nil, status.Errorf(codes.NotFound, "user %d not found", req.Id)
	}

	return &userv1.GetUserResponse{
		User: &userv1.User{
			Id:        user.ID,
			Name:      user.Name,
			Email:     user.Email,
			CreatedAt: user.CreatedAt,
		},
	}, nil
}

// Server Streaming: stream users page by page
func (s *userGRPCServer) ListUsers(req *userv1.ListUsersRequest, stream userv1.UserService_ListUsersServer) error {
	// Simulation: send 3 users
	users := []userv1.User{
		{Id: 1, Name: "Alice", Email: "alice@example.com"},
		{Id: 2, Name: "Bob", Email: "bob@example.com"},
		{Id: 3, Name: "Carol", Email: "carol@example.com"},
	}

	for _, u := range users {
		u := u // capture
		if err := stream.Send(&u); err != nil {
			return status.Errorf(codes.Internal, "send error: %v", err)
		}
	}
	return nil
}

func main() {
	lis, err := net.Listen("tcp", ":50051")
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	srv := grpc.NewServer(
		grpc.UnaryInterceptor(loggingInterceptor),
	)
	userv1.RegisterUserServiceServer(srv, &userGRPCServer{
		store: newMemoryStore(),
	})

	fmt.Println("gRPC server listening on :50051")
	if err := srv.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}

func loggingInterceptor(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
	log.Printf("gRPC call: %s", info.FullMethod)
	resp, err := handler(ctx, req)
	if err != nil {
		log.Printf("gRPC error: %v", err)
	}
	return resp, err
}
```

**The same endpoint in REST:**

```go
// rest_server.go
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

type userRESTHandler struct {
	store UserStore
}

type getUserResponse struct {
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	Email     string `json:"email"`
	CreatedAt int64  `json:"created_at"`
}

type errorResponse struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (h *userRESTHandler) GetUser(w http.ResponseWriter, r *http.Request) {
	idStr := chi.URLParam(r, "id")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || id <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse{
			Code:    "INVALID_ARGUMENT",
			Message: "id must be a positive integer",
		})
		return
	}

	user, err := h.store.GetByID(r.Context(), id)
	if err != nil {
		var notFound *NotFoundError
		if errors.As(err, &notFound) {
			writeJSON(w, http.StatusNotFound, errorResponse{
				Code:    "NOT_FOUND",
				Message: notFound.Error(),
			})
			return
		}
		writeJSON(w, http.StatusInternalServerError, errorResponse{
			Code:    "INTERNAL",
			Message: "internal server error",
		})
		return
	}

	writeJSON(w, http.StatusOK, getUserResponse{
		ID:        user.ID,
		Name:      user.Name,
		Email:     user.Email,
		CreatedAt: user.CreatedAt,
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("writeJSON error: %v", err)
	}
}

func main() {
	r := chi.NewRouter()
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)

	h := &userRESTHandler{store: newMemoryStore()}

	r.Get("/v1/users/{id}", h.GetUser)
	r.Get("/v1/users", h.ListUsers)

	log.Println("REST server listening on :8080")
	if err := http.ListenAndServe(":8080", r); err != nil {
		log.Fatal(err)
	}
}

type NotFoundError struct {
	ID int64
}

func (e *NotFoundError) Error() string {
	return fmt.Sprintf("user %d not found", e.ID)
}
```

**Key difference:** in gRPC, typing and errors are defined in the proto contract and generated automatically. In REST — you describe response structures and error-to-HTTP-code mappings yourself. gRPC wins for internal APIs between services; REST wins for public APIs.

---

## 4. WebSocket and Server-Sent Events

### 4.1 WebSocket

WebSocket is a full-duplex communication protocol over a single TCP connection. It begins with an HTTP Upgrade handshake.

```
Client → Server:
  GET /ws HTTP/1.1
  Upgrade: websocket
  Connection: Upgrade
  Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
  Sec-WebSocket-Version: 13

Server → Client:
  HTTP/1.1 101 Switching Protocols
  Upgrade: websocket
  Connection: Upgrade
  Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=

After handshake: binary frame protocol in both directions
```

**When WebSocket is needed:**
- Chat (messages in both directions)
- Real-time games (game events in both directions)
- Collaborative editing (Google Docs-style)
- Financial tickers with commands (subscribe/unsubscribe)
- Live dashboards where the user can control the stream

**WebSocket problems:**
- Stateful connections: harder to scale horizontally
- No HTTP caching
- Firewalls/proxies may block it (fallback needed)
- Heartbeat/ping-pong needed to detect disconnections

### 4.2 Server-Sent Events (SSE)

SSE is a one-directional channel from server to client over regular HTTP. The client opens a connection, the server pushes events.

```
Client → Server:
  GET /events HTTP/1.1
  Accept: text/event-stream

Server → Client (infinite stream):
  HTTP/1.1 200 OK
  Content-Type: text/event-stream
  Cache-Control: no-cache

  id: 1
  event: message
  data: {"user": "Alice", "text": "Hello"}

  id: 2
  event: notification
  data: {"type": "order_shipped", "order_id": 456}

  : heartbeat (comment, client ignores)

  id: 3
  data: simple message without event type
```

**Automatic reconnection:** the browser automatically reconnects on disconnection, sending `Last-Event-ID`, which allows the server to resume from where it left off.

**When SSE is sufficient:**
- Push notifications to the user
- Progress of a long task (export, processing)
- Live event feed (audit log, deployment log)
- Streaming responses from an LLM (like ChatGPT)

### 4.3 Realtime Transport Comparison

```
Long Polling:
  Client: GET /updates  ─────────────────────────────────────► (waiting...)
  Server:                                            ◄── data available → response
  Client: GET /updates  ──────────────────────────────────────► (new request)

SSE:
  Client: GET /events  ──────────────────────────────────────►
  Server:              ◄── event ──◄── event ──◄── event ─────

WebSocket:
  Client: GET /ws → Upgrade ─────────────────────────────────►
  Bidirectional: ◄───────────────────────────────────────────►
```

| Feature                | Long Polling     | SSE              | WebSocket        |
|------------------------|------------------|------------------|------------------|
| Direction              | Server → Client  | Server → Client  | Bidirectional    |
| Protocol               | HTTP             | HTTP             | WS (over HTTP)   |
| Auto-reconnect         | Manual           | Built-in         | Manual           |
| Browser support        | Universal        | All modern       | All modern       |
| Server complexity      | Simple           | Simple           | Medium           |
| HTTP/2 compatibility   | Yes              | Yes (improving)  | Separate protocol |
| Load balancing         | Easy             | Easy             | Sticky sessions needed |

### 4.4 Go Example: WebSocket with gorilla/websocket

```go
// go get github.com/gorilla/websocket

package main

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	// In production — check the Origin
	CheckOrigin: func(r *http.Request) bool {
		return true // dev only!
	},
}

type Message struct {
	Type    string `json:"type"`
	Payload string `json:"payload"`
	From    string `json:"from,omitempty"`
}

// Hub manages all active connections
type Hub struct {
	mu      sync.RWMutex
	clients map[*websocket.Conn]string // conn → userID
}

func NewHub() *Hub {
	return &Hub{clients: make(map[*websocket.Conn]string)}
}

func (h *Hub) register(conn *websocket.Conn, userID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.clients[conn] = userID
}

func (h *Hub) unregister(conn *websocket.Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.clients, conn)
}

// Broadcast sends a message to everyone except the sender
func (h *Hub) Broadcast(msg Message, sender *websocket.Conn) {
	h.mu.RLock()
	defer h.mu.RUnlock()

	data, err := json.Marshal(msg)
	if err != nil {
		return
	}

	for conn := range h.clients {
		if conn == sender {
			continue
		}
		// Set write deadline to avoid blocking
		conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
		if err := conn.WriteMessage(websocket.TextMessage, data); err != nil {
			log.Printf("broadcast write error: %v", err)
		}
	}
}

func (h *Hub) wsHandler(w http.ResponseWriter, r *http.Request) {
	userID := r.URL.Query().Get("user_id")
	if userID == "" {
		http.Error(w, "user_id required", http.StatusBadRequest)
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("upgrade error: %v", err)
		return
	}
	defer conn.Close()

	h.register(conn, userID)
	defer h.unregister(conn)

	// Configure ping/pong to detect dead connections
	conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		return nil
	})

	// Goroutine for periodic ping
	go func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
			if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}()

	log.Printf("user %s connected", userID)

	for {
		_, rawMsg, err := conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
				log.Printf("unexpected close from user %s: %v", userID, err)
			}
			break
		}

		var msg Message
		if err := json.Unmarshal(rawMsg, &msg); err != nil {
			log.Printf("invalid message from %s: %v", userID, err)
			continue
		}
		msg.From = userID

		h.Broadcast(msg, conn)
	}

	log.Printf("user %s disconnected", userID)
}

func main() {
	hub := NewHub()

	http.HandleFunc("/ws", hub.wsHandler)
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	log.Println("WebSocket server on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
```

**SSE server in Go for comparison:**

```go
// sse_handler.go
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"time"
)

type Event struct {
	ID    int    `json:"id"`
	Type  string `json:"type"`
	Data  any    `json:"data"`
}

func sseHandler(w http.ResponseWriter, r *http.Request) {
	// Check flushing support
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming not supported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("Access-Control-Allow-Origin", "*")

	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	eventID := 0

	for {
		select {
		case <-r.Context().Done():
			// Client disconnected
			log.Println("client disconnected")
			return

		case t := <-ticker.C:
			eventID++
			event := Event{
				ID:   eventID,
				Type: "update",
				Data: map[string]any{
					"timestamp": t.Unix(),
					"value":     eventID * 10,
				},
			}

			data, _ := json.Marshal(event.Data)

			// SSE format: field: value\n\n
			fmt.Fprintf(w, "id: %d\n", event.ID)
			fmt.Fprintf(w, "event: %s\n", event.Type)
			fmt.Fprintf(w, "data: %s\n\n", data) // double \n — end of event

			flusher.Flush()
		}
	}
}
```

---

## 5. Load Balancing

### 5.1 Why a Load Balancer is Needed

```
Without load balancer:
  Client → Server (single point of failure, vertical scaling is limited)

With load balancer:
  Client → Load Balancer → Server 1
                         → Server 2
                         → Server 3
```

Load balancer responsibilities:
- Distributing load across instances
- Health checking: removing unhealthy servers
- SSL termination (Layer 7)
- Providing a single entry point
- Horizontal scaling without changing clients

### 5.2 Layer 4 vs Layer 7

**Layer 4 (Transport):** works with TCP/UDP connections. Does not understand request content.

```
Client: TCP SYN → LB → TCP SYN → Backend
LB simply proxies the TCP stream, does not read HTTP
Faster, less overhead
Cannot route by URL, headers, or cookie
```

**Layer 7 (Application):** understands HTTP, reads headers and URLs.

```
Client: GET /api/users HTTP/1.1 → LB
LB:
  path /api/users → users-service
  path /api/orders → orders-service
  Header: X-Version: v2 → backend-v2

Can:
- Route by URL/headers
- SSL termination
- Sticky sessions by cookie
- Request rewriting
- Rate limiting
- Caching
```

| Feature             | Layer 4            | Layer 7               |
|---------------------|--------------------|-----------------------|
| Protocols           | TCP, UDP           | HTTP, HTTPS, gRPC     |
| Speed               | Higher             | Lower (HTTP parsing)  |
| Routing             | IP:Port            | URL, headers, method  |
| SSL termination     | No (passthrough)   | Yes                   |
| Health check        | TCP connect        | HTTP /health          |
| Examples            | AWS NLB, HAProxy L4 | Nginx, Envoy, AWS ALB |

### 5.3 Load Balancing Algorithms

**Round Robin:** requests are distributed in a circular pattern.

```
Request 1 → Server A
Request 2 → Server B
Request 3 → Server C
Request 4 → Server A  (again)
```

Good for homogeneous servers with equal per-request load.

**Weighted Round Robin:** servers are assigned weights.

```
Server A: weight=5  → receives 5/8 requests
Server B: weight=2  → receives 2/8 requests
Server C: weight=1  → receives 1/8 requests

Used for: different server capacities, canary deployment
```

**Least Connections:** request goes to the server with the fewest active connections.

```
Server A: 10 active connections
Server B: 2 active connections  ← goes here
Server C: 7 active connections

Good for: requests with varying execution time (long and short)
```

**IP Hash:** the client IP is hashed, the result determines the server.

```
hash(client_ip) % n_servers = server_index

Guarantees: one client always ends up on the same server
Problem: uneven distribution, hard to scale
```

**Consistent Hashing:** a more advanced version of IP Hash.

```
Hash ring (0 ... 2^32):

     0
     │
  A(100) ←── hash("client1") = 80   → A
  B(200) ←── hash("client2") = 150  → B
  C(300) ←── hash("client3") = 250  → C
     │
    2^32

When a server is added/removed, a minimum of keys are redistributed.
Used for: CDN, distributed caches, database sharding
```

**Random:** a random server. Simple, gives good distribution with many requests.

### 5.4 Nginx Configuration Example

```nginx
# /etc/nginx/conf.d/api.conf

upstream api_backend {
    # Algorithm: round-robin by default
    # For least_conn: add the least_conn directive;

    server 10.0.1.1:8080 weight=3;
    server 10.0.1.2:8080 weight=3;
    server 10.0.1.3:8080 weight=1 backup; # used if others are down

    # Health check (Nginx Plus or OpenResty)
    # keepalive 32;
}

server {
    listen 80;
    server_name api.example.com;

    # Redirect to HTTPS
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name api.example.com;

    ssl_certificate     /etc/ssl/certs/api.crt;
    ssl_certificate_key /etc/ssl/private/api.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    # Timeouts
    proxy_connect_timeout  5s;
    proxy_read_timeout     60s;
    proxy_send_timeout     60s;

    location /api/ {
        proxy_pass         http://api_backend;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_set_header   Connection        "";  # keep-alive upstream

        # Retry on errors (only for idempotent requests)
        proxy_next_upstream error timeout http_502 http_503;
        proxy_next_upstream_tries 2;
    }

    # Health check endpoint — we respond ourselves, don't proxy
    location /health {
        return 200 "OK\n";
        add_header Content-Type text/plain;
    }
}
```

**Active health check via nginx_upstream_check_module:**

```nginx
upstream api_backend {
    server 10.0.1.1:8080;
    server 10.0.1.2:8080;

    check interval=3000 rise=2 fall=3 timeout=1000 type=http;
    check_http_send "GET /health HTTP/1.0\r\n\r\n";
    check_http_expect_alive http_2xx;
}
```

### 5.5 Load Balancer Comparison

| Criterion          | Nginx            | HAProxy          | Envoy            | AWS ALB          |
|--------------------|------------------|------------------|------------------|------------------|
| Layer              | 4 + 7            | 4 + 7            | 4 + 7            | 7                |
| Performance        | High             | Very high        | High             | High             |
| gRPC support       | Yes (1.13+)      | Yes              | Excellent        | Yes              |
| Service Mesh       | No               | No               | Yes (Istio)      | No               |
| Configuration      | Files + API      | Files            | xDS API (dynamic) | AWS Console/API |
| Observability      | Basic            | Good             | Excellent        | CloudWatch       |
| Managed/Self-hosted | Self            | Self             | Self             | Managed          |
| Cost               | Free             | Free             | Free             | $0.008/LCU-hour  |

**When to choose what:**
- **Nginx:** general purpose, static + proxying, familiar to the team
- **HAProxy:** maximum L4/L7 performance, financial systems
- **Envoy:** service mesh, complex routing, observability (Prometheus out of box)
- **Cloud LB:** fast start, no ops burden, integration with managed services

### 5.6 Sticky Sessions

Sticky sessions (session affinity): the same client always goes to the same backend.

```
Without sticky sessions (stateless):
  Request 1 → Server A (no session needed, state in Redis)
  Request 2 → Server B (finds state in Redis)
  ✓ Works correctly

With sticky sessions:
  Request 1 → Server A (session in Server A memory)
  Request 2 → Server B (doesn't know about the session)
  ✗ Authentication error!

  Solution: sticky sessions (LB remembers Server A for this client)
  Nginx: ip_hash; or cookie: proxy_cookie_path / route-cookie
```

**Why sticky sessions are an anti-pattern:**
- When Server A goes down, all its "stuck" users lose their session
- Uneven load: some servers are overloaded, others are idle
- Complicates rolling deploy: can't take down a server without losing sessions
- Hinders horizontal scaling

**The right solution:** move state out of servers into shared storage (Redis, Memcached, DB). Then any backend can serve any request.

```
Stateless architecture:
  Client → [LB] → Server A ┐
                  Server B ├── Redis (sessions, cache)
                  Server C ┘
  
  Any server can handle any request.
  Autoscaling works without limitations.
```

---

## 6. API Gateway

### 6.1 Why an API Gateway is Needed

```
Without API Gateway (clients talk directly to services):

  Mobile App ──────────────────────► Users Service :8001
  Web App ─────────────────────────► Orders Service :8002
  Partner API ─────────────────────► Products Service :8003
  
  Problems:
  - Each service implements auth, rate limiting, logging separately
  - Client must know the addresses of all services
  - Changing a service address breaks all clients

With API Gateway:

  Mobile App ──────────────────────┐
  Web App ─────────────────────────┤─► API Gateway ─► Users Service
  Partner API ─────────────────────┘         │──────► Orders Service
                                              └──────► Products Service
  
  Single entry point: auth, rate limiting, logging — once
```

**API Gateway functions:**
- **Routing:** routing by path/host/header to the right service
- **Auth/AuthZ:** JWT validation, OAuth, API keys
- **Rate Limiting:** protection against abuse
- **SSL Termination:** TLS at the gateway, plain HTTP inside the network
- **Request/Response Transformation:** rewrite headers, body
- **Circuit Breaking:** stop sending traffic to a failed service
- **Caching:** cache responses
- **Logging/Tracing:** centralized observability

### 6.2 API Gateway vs Load Balancer vs Reverse Proxy

```
Reverse Proxy:
  Simple request forwarding. No business logic.
  Example: Nginx as a reverse proxy for a single service.

Load Balancer:
  Distributes load across N instances of ONE service.
  Can be Layer 4 or Layer 7.
  No auth, no transformation.

API Gateway:
  Routes to N DIFFERENT services.
  Full set of cross-cutting concerns.
  Always Layer 7.
  
Stack:
  DNS → Load Balancer → API Gateway → Reverse Proxy (in front of each service) → Service
```

| Feature                | Reverse Proxy | Load Balancer | API Gateway |
|------------------------|:-------------:|:-------------:|:-----------:|
| Request routing        | ✓             | ✓             | ✓           |
| Load balancing         | ✓             | ✓             | ✓           |
| SSL Termination        | ✓             | Layer 7 only  | ✓           |
| Authentication         | -             | -             | ✓           |
| Rate Limiting          | Basic         | -             | ✓           |
| Request Transformation | -             | -             | ✓           |
| Multi-service routing  | -             | -             | ✓           |
| API versioning         | -             | -             | ✓           |

### 6.3 Popular Solutions

| Solution       | Type       | Configuration | gRPC | Performance | Special Feature              |
|----------------|------------|---------------|------|-------------|------------------------------|
| Kong           | Self/Cloud | Admin API + YAML | Yes | High (OpenResty) | Plugin ecosystem        |
| Envoy          | Self       | xDS API (dynamic) | Excellent | Very high | Service mesh, Istio   |
| Traefik        | Self       | Auto-discovery | Yes | High       | Kubernetes-native, Let's Encrypt |
| AWS API GW     | Managed    | Console/CDK   | REST/HTTP | High    | Lambda integration, WAF   |
| GCP API GW     | Managed    | OpenAPI spec  | REST | High       | Cloud Run/Functions          |
| Azure APIM     | Managed    | Portal/ARM    | Yes  | High       | Enterprise features          |
| Nginx (+ Lua)  | Self       | nginx.conf    | Yes  | Very high  | Customization via Lua        |

### 6.4 Example: Routing to Microservices

**Kong (declarative configuration):**

```yaml
# kong.yaml
_format_version: "3.0"

services:
  - name: users-service
    url: http://users-service:8001
    routes:
      - name: users-route
        paths:
          - /api/v1/users
        methods:
          - GET
          - POST
          - PUT
          - DELETE
    plugins:
      - name: jwt
        config:
          secret_is_base64: false
      - name: rate-limiting
        config:
          minute: 100
          policy: local

  - name: orders-service
    url: http://orders-service:8002
    routes:
      - name: orders-route
        paths:
          - /api/v1/orders
        methods:
          - GET
          - POST
    plugins:
      - name: jwt
      - name: rate-limiting
        config:
          minute: 50

  - name: products-service
    url: http://products-service:8003
    routes:
      - name: products-public-route
        paths:
          - /api/v1/products
        methods:
          - GET  # public endpoint, no auth
      - name: products-admin-route
        paths:
          - /api/v1/admin/products
        plugins:
          - name: key-auth  # admin requires API key
```

**Traefik (Kubernetes IngressRoute):**

```yaml
# ingress-route.yaml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: api-routes
  namespace: production
spec:
  entryPoints:
    - websecure
  routes:
    - match: PathPrefix(`/api/v1/users`)
      kind: Rule
      services:
        - name: users-service
          port: 8001
      middlewares:
        - name: jwt-auth
        - name: rate-limit

    - match: PathPrefix(`/api/v1/orders`)
      kind: Rule
      services:
        - name: orders-service
          port: 8002
      middlewares:
        - name: jwt-auth

    - match: PathPrefix(`/api/v1/products`) && Method(`GET`)
      kind: Rule
      services:
        - name: products-service
          port: 8003
      # No auth — public endpoint

  tls:
    certResolver: letsencrypt
---
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: rate-limit
spec:
  rateLimit:
    average: 100
    burst: 50
```

---

## 7. Service Discovery

### 7.1 The Problem

In statically deployed systems, server IP addresses are fixed and hardcoded in configs. In dynamic environments (Kubernetes, cloud auto-scaling), services appear and disappear, their IPs change on every deployment.

```
Without service discovery:
  orders-service/config.yaml:
    users_service_url: "http://10.0.1.15:8001"  # hardcoded
  
  New users-service pod deployed → new IP 10.0.1.23
  orders-service doesn't know → errors

With service discovery:
  orders-service asks: "where is users-service?"
  Registry responds: "10.0.1.23:8001"
  → always up-to-date address
```

### 7.2 Client-side vs Server-side Discovery

**Client-side Discovery:**

```
Service A ──► Registry (Consul/etcd) ──► "Service B: 10.0.1.1:8002, 10.0.1.2:8002"
Service A selects an instance itself (client-side load balancing)
Service A ──► 10.0.1.1:8002

Pros: fewer components, client controls the selection
Cons: discovery logic in every client, language-specific libraries
Examples: Netflix Eureka + Ribbon, Consul client
```

**Server-side Discovery:**

```
Service A ──► Load Balancer/Router ──► Registry ──► "Service B instances"
                                   └──────────────► Service B

Service A doesn't know about Registry, LB does everything itself.
Pros: simple clients, one component knows about routing
Cons: additional hop, LB is a SPOF without HA
Examples: Kubernetes Service, AWS ALB + ECS, Envoy
```

### 7.3 Tools

**Consul:** a full-featured solution: service registry + health checks + KV store + DNS interface.

```bash
# Register a service in Consul
curl -X PUT http://localhost:8500/v1/agent/service/register \
  -H "Content-Type: application/json" \
  -d '{
    "ID": "users-service-1",
    "Name": "users-service",
    "Address": "10.0.1.23",
    "Port": 8001,
    "Check": {
      "HTTP": "http://10.0.1.23:8001/health",
      "Interval": "10s",
      "Timeout": "2s",
      "DeregisterCriticalServiceAfter": "30s"
    }
  }'

# Find healthy instances
curl http://localhost:8500/v1/health/service/users-service?passing=true

# Via DNS (Consul as a DNS server):
dig @127.0.0.1 -p 8600 users-service.service.consul
# → 10.0.1.23
```

**etcd:** a distributed KV store. Kubernetes uses etcd for all its data.

**Kubernetes DNS:** built-in service discovery via CoreDNS.

### 7.4 Kubernetes Service Discovery

Kubernetes automatically creates DNS records for each Service.

```
DNS name format:
  <service-name>.<namespace>.svc.cluster.local

Examples:
  users-service.production.svc.cluster.local  → service ClusterIP
  users-service.production.svc.cluster.local  → port 8001
```

```yaml
# users-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: users-service
  namespace: production
spec:
  selector:
    app: users
  ports:
    - name: http
      protocol: TCP
      port: 8001        # Service port (external for other pods)
      targetPort: 8001  # container port
  type: ClusterIP       # only inside the cluster
```

```yaml
# orders-deployment.yaml — how orders-service reaches users-service
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders
  namespace: production
spec:
  template:
    spec:
      containers:
        - name: orders
          image: orders:latest
          env:
            # Kubernetes automatically injects env variables for services:
            # USERS_SERVICE_SERVICE_HOST=10.96.1.50
            # USERS_SERVICE_SERVICE_PORT=8001
            # But DNS is preferred:
            - name: USERS_SERVICE_URL
              value: "http://users-service.production.svc.cluster.local:8001"
```

**Go example: calling a service via Kubernetes DNS:**

```go
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"
)

type UserClient struct {
	baseURL    string
	httpClient *http.Client
}

func NewUserClient() *UserClient {
	// Kubernetes DNS: service-name.namespace.svc.cluster.local
	baseURL := os.Getenv("USERS_SERVICE_URL")
	if baseURL == "" {
		// Default for local development
		baseURL = "http://localhost:8001"
	}

	return &UserClient{
		baseURL: baseURL,
		httpClient: &http.Client{
			Timeout: 5 * time.Second,
			Transport: &http.Transport{
				MaxIdleConns:        100,
				MaxIdleConnsPerHost: 10,
				IdleConnTimeout:     90 * time.Second,
			},
		},
	}
}

type User struct {
	ID    int64  `json:"id"`
	Name  string `json:"name"`
	Email string `json:"email"`
}

func (c *UserClient) GetUser(ctx context.Context, id int64) (*User, error) {
	url := fmt.Sprintf("%s/v1/users/%d", c.baseURL, id)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("do request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return nil, fmt.Errorf("user %d not found", id)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status: %d", resp.StatusCode)
	}

	var user User
	if err := json.NewDecoder(resp.Body).Decode(&user); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}
	return &user, nil
}
```

**DNS resolution diagram in Kubernetes:**

```
Pod (orders-service) requests: users-service.production.svc.cluster.local

  Pod DNS config (/etc/resolv.conf):
    nameserver 10.96.0.10        (CoreDNS ClusterIP)
    search production.svc.cluster.local svc.cluster.local cluster.local

  Request → CoreDNS (10.96.0.10)
    CoreDNS → queries kube-apiserver
    → finds Service "users-service" in namespace "production"
    → returns ClusterIP: 10.96.1.50

  iptables (kube-proxy) on the node:
    10.96.1.50:8001 → DNAT → 10.0.1.23:8001 (Pod IP, round-robin)
```

**Headless Service** (for StatefulSet, when individual pod IPs are needed):

```yaml
spec:
  clusterIP: None  # Headless!
  # DNS will return A records for each Pod, not ClusterIP
  # postgres-0.postgres.production.svc.cluster.local → 10.0.1.5
  # postgres-1.postgres.production.svc.cluster.local → 10.0.1.6
```

---

## 8. Idempotency in Network Communication

### 8.1 Why It Matters

In distributed systems, requests get lost, connections drop, servers restart. Retry is the standard reliability mechanism. But retry without idempotency creates duplicates.

```
Problem:
  Client ──POST /payments {amount: 100}──► Server
  Server processed, responded...
  TCP packet with response was lost!
  
  Client did not receive a response → considers the request failed → retry
  Client ──POST /payments {amount: 100}──► Server
  
  Result: the charge happened twice. The client sees one attempt.
```

**An idempotent operation:** executing it N times produces the same result as executing it once.

```
Idempotent operations:
  SET x = 5          (can be executed any number of times, x will always be 5)
  DELETE user_id=123 (first call deletes, subsequent ones — no-op or 404)
  PUT /users/123 {name: "Alice"} (result is the same regardless of call count)

Non-idempotent operations:
  INCREMENT counter   (each call changes the result)
  POST /payments     (each call creates a new payment)
  APPEND to log      (each call adds a record)
```

### 8.2 Idempotency Key

An Idempotency Key is a unique token that the client generates before the request and attaches to every attempt. The server uses it as a deduplication key.

```
Client:
  idempotency_key = uuid() // generate once
  
  Attempt 1: POST /payments
    Idempotency-Key: 550e8400-e29b-41d4-a716-446655440000
    Body: {amount: 100, currency: "USD"}

  Response was lost → retry

  Attempt 2: POST /payments (same key!)
    Idempotency-Key: 550e8400-e29b-41d4-a716-446655440000
    Body: {amount: 100, currency: "USD"}

Server (attempt 1):
  - Sees the key for the first time
  - Processes the payment
  - Saves the result in Redis: key → {status: success, response: {...}}
  - Returns response (packet was lost)

Server (attempt 2):
  - Sees the same key
  - Finds the result in Redis
  - Returns the cached response (payment is NOT created again)
```

### 8.3 Go Example: Idempotency Key Middleware with Redis

```go
// go get github.com/redis/go-redis/v9

package middleware

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	idempotencyKeyHeader = "Idempotency-Key"
	// Cache TTL: long enough for the client's retry window
	idempotencyTTL = 24 * time.Hour
)

// idempotentResponse stores the cached response
type idempotentResponse struct {
	StatusCode int               `json:"status_code"`
	Headers    map[string]string `json:"headers"`
	Body       []byte            `json:"body"`
}

// responseRecorder intercepts the handler's response for caching
type responseRecorder struct {
	http.ResponseWriter
	statusCode int
	body       bytes.Buffer
}

func (r *responseRecorder) WriteHeader(code int) {
	r.statusCode = code
	r.ResponseWriter.WriteHeader(code)
}

func (r *responseRecorder) Write(b []byte) (int, error) {
	r.body.Write(b) // write to buffer
	return r.ResponseWriter.Write(b)
}

// IdempotencyMiddleware handles the Idempotency-Key header
func IdempotencyMiddleware(rdb *redis.Client) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Idempotency is only needed for non-idempotent methods
			if r.Method != http.MethodPost && r.Method != http.MethodPatch {
				next.ServeHTTP(w, r)
				return
			}

			idempotencyKey := r.Header.Get(idempotencyKeyHeader)
			if idempotencyKey == "" {
				// If no key — require it for POST
				http.Error(w, `{"error":"Idempotency-Key header required"}`, http.StatusUnprocessableEntity)
				return
			}

			// Include path in cache key: one key must not work for different endpoints
			cacheKey := buildCacheKey(idempotencyKey, r.URL.Path)

			ctx := r.Context()

			// Check: is there already a result for this key?
			cached, err := rdb.Get(ctx, cacheKey).Bytes()
			if err == nil {
				// Found — return cached response
				var resp idempotentResponse
				if jsonErr := json.Unmarshal(cached, &resp); jsonErr == nil {
					for k, v := range resp.Headers {
						w.Header().Set(k, v)
					}
					w.Header().Set("Idempotent-Replayed", "true")
					w.WriteHeader(resp.StatusCode)
					w.Write(resp.Body)
					return
				}
			}

			// No key — try to lock (so parallel retries don't pass)
			lockKey := cacheKey + ":lock"
			locked, err := rdb.SetNX(ctx, lockKey, "1", 30*time.Second).Result()
			if err != nil || !locked {
				// Another request is already processing this key
				http.Error(w, `{"error":"concurrent request with same Idempotency-Key"}`, http.StatusConflict)
				return
			}
			defer rdb.Del(ctx, lockKey)

			// Record response in buffer
			recorder := &responseRecorder{
				ResponseWriter: w,
				statusCode:     http.StatusOK,
			}

			// Read body to save request checksum
			var bodyBytes []byte
			if r.Body != nil {
				bodyBytes, _ = io.ReadAll(r.Body)
				r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
			}

			next.ServeHTTP(recorder, r)

			// Only cache successful responses (2xx)
			if recorder.statusCode >= 200 && recorder.statusCode < 300 {
				resp := idempotentResponse{
					StatusCode: recorder.statusCode,
					Headers: map[string]string{
						"Content-Type": recorder.Header().Get("Content-Type"),
					},
					Body: recorder.body.Bytes(),
				}

				data, _ := json.Marshal(resp)
				// Save in Redis with TTL
				rdb.Set(ctx, cacheKey, data, idempotencyTTL)
			}
		})
	}
}

func buildCacheKey(idempotencyKey, path string) string {
	h := sha256.Sum256([]byte(idempotencyKey + "|" + path))
	return fmt.Sprintf("idem:%x", h[:16])
}
```

**Using the middleware:**

```go
// main.go
package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/redis/go-redis/v9"
)

func main() {
	rdb := redis.NewClient(&redis.Options{
		Addr:         "localhost:6379",
		Password:     "",
		DB:           0,
		DialTimeout:  2 * time.Second,
		ReadTimeout:  2 * time.Second,
		WriteTimeout: 2 * time.Second,
	})

	// Check connection
	if err := rdb.Ping(context.Background()).Err(); err != nil {
		log.Fatalf("redis connect error: %v", err)
	}

	r := chi.NewRouter()

	// Apply middleware only to relevant routes
	r.Group(func(r chi.Router) {
		r.Use(IdempotencyMiddleware(rdb))

		r.Post("/v1/payments", createPaymentHandler)
		r.Post("/v1/orders", createOrderHandler)
	})

	// GET routes don't need idempotency
	r.Get("/v1/payments/{id}", getPaymentHandler)

	log.Println("Server on :8080")
	log.Fatal(http.ListenAndServe(":8080", r))
}

type CreatePaymentRequest struct {
	Amount   float64 `json:"amount"`
	Currency string  `json:"currency"`
	To       string  `json:"to"`
}

type CreatePaymentResponse struct {
	PaymentID string  `json:"payment_id"`
	Status    string  `json:"status"`
	Amount    float64 `json:"amount"`
}

func createPaymentHandler(w http.ResponseWriter, r *http.Request) {
	var req CreatePaymentRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid body"}`, http.StatusBadRequest)
		return
	}

	// Business logic for creating a payment
	// On a repeated request with the same Idempotency-Key, this code will NOT execute
	paymentID := generatePaymentID()
	log.Printf("Creating payment %s for %.2f %s", paymentID, req.Amount, req.Currency)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(CreatePaymentResponse{
		PaymentID: paymentID,
		Status:    "pending",
		Amount:    req.Amount,
	})
}

func generatePaymentID() string {
	// In production: UUID or ULID
	return fmt.Sprintf("pay_%d", time.Now().UnixNano())
}
```

**Client side with retry and idempotency key:**

```go
// client_with_retry.go
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/google/uuid"
)

type PaymentClient struct {
	baseURL    string
	httpClient *http.Client
}

func (c *PaymentClient) CreatePayment(ctx context.Context, req CreatePaymentRequest) (*CreatePaymentResponse, error) {
	// Generate the key ONCE before all attempts
	idempotencyKey := uuid.New().String()

	body, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("marshal: %w", err)
	}

	backoff := 100 * time.Millisecond
	maxAttempts := 3

	for attempt := 1; attempt <= maxAttempts; attempt++ {
		httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost,
			c.baseURL+"/v1/payments", bytes.NewBuffer(body))
		if err != nil {
			return nil, fmt.Errorf("create request: %w", err)
		}

		httpReq.Header.Set("Content-Type", "application/json")
		// Same key on every attempt!
		httpReq.Header.Set("Idempotency-Key", idempotencyKey)

		resp, err := c.httpClient.Do(httpReq)
		if err != nil {
			if attempt < maxAttempts {
				time.Sleep(backoff)
				backoff *= 2 // exponential backoff
				continue
			}
			return nil, fmt.Errorf("do request: %w", err)
		}
		defer resp.Body.Close()

		// 409 Conflict — concurrent request, wait and retry
		if resp.StatusCode == http.StatusConflict {
			time.Sleep(backoff)
			backoff *= 2
			continue
		}

		// 4xx (except 409) — don't retry (client error)
		if resp.StatusCode >= 400 && resp.StatusCode < 500 && resp.StatusCode != 429 {
			var errResp map[string]string
			json.NewDecoder(resp.Body).Decode(&errResp)
			return nil, fmt.Errorf("client error %d: %v", resp.StatusCode, errResp)
		}

		// 5xx or 429 — retry
		if resp.StatusCode >= 500 || resp.StatusCode == 429 {
			if attempt < maxAttempts {
				time.Sleep(backoff)
				backoff *= 2
				continue
			}
		}

		var result CreatePaymentResponse
		if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
			return nil, fmt.Errorf("decode: %w", err)
		}

		// Server returned "Idempotent-Replayed: true" — this is a retry, not a duplicate
		replayed := resp.Header.Get("Idempotent-Replayed") == "true"
		if replayed {
			fmt.Printf("Idempotent replay: payment %s already created\n", result.PaymentID)
		}

		return &result, nil
	}

	return nil, fmt.Errorf("max attempts reached")
}
```

### 8.4 What to Store and For How Long

```
In Redis we store:
  Key:   idem:<sha256(idempotencyKey + path)>
  Value: {status_code, headers, body}
  TTL:   24 hours (or according to your retry window)

Important details:
  - Bind the key to user_id: one key works only for one user
    Key: idem:<sha256(user_id + idempotencyKey + path)>
  
  - Store a hash of the request body: if the body differs — these are different operations
    (protection against accidental key reuse)
  
  - Don't cache errors: on error (5xx), the client should be able to retry
    Cache only 2xx and 4xx (client errors won't change on retry)
```

---

## Module Summary

| Topic                 | Key Takeaway                                                              |
|-----------------------|---------------------------------------------------------------------------|
| DNS                   | TTL is the main lever for controlling propagation. Lower TTL before migration. |
| HTTP versions         | HTTP/2 is the standard for gRPC and APIs. HTTP/3 — for mobile and edge.  |
| REST vs gRPC vs GraphQL | gRPC for internal services, REST for public, GraphQL — only if you truly need query flexibility. |
| WebSocket vs SSE      | SSE is sufficient for most push scenarios. WebSocket — only for bidirectional. |
| Load Balancing        | Layer 7 + Least Connections for APIs. Sticky sessions — anti-pattern.    |
| API Gateway           | Single entry point. Don't duplicate cross-cutting concerns in every service. |
| Service Discovery     | In Kubernetes use DNS (`service.namespace.svc.cluster.local`).           |
| Idempotency           | Idempotency Key + Redis for all creating operations. Generate the key once on the client. |

## What's Next

- **Module 03:** Databases — relational, NoSQL, storage selection
- **Module 04:** Caching — Redis, Memcached, CDN, cache strategies
- **Module 05:** Message queues — Kafka, RabbitMQ, asynchronous interaction patterns
