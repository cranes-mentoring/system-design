# Модуль 02: Сеть и протоколы

> **Аудитория:** backend-разработчики с опытом 2+ лет  
> **Цель:** понять, как работает сеть под капотом distributed systems, чтобы принимать правильные архитектурные решения

---

## Содержание

1. [DNS: как работает и зачем это знать](#1-dns)
2. [HTTP/1.1 → HTTP/2 → HTTP/3](#2-http)
3. [REST vs gRPC vs GraphQL](#3-rest-grpc-graphql)
4. [WebSocket и Server-Sent Events](#4-websocket-sse)
5. [Load Balancing](#5-load-balancing)
6. [API Gateway](#6-api-gateway)
7. [Service Discovery](#7-service-discovery)
8. [Идемпотентность в сетевых взаимодействиях](#8-idempotency)

---

## 1. DNS

DNS (Domain Name System) — это распределённая иерархическая база данных, которая преобразует доменные имена в IP-адреса. Для системного дизайна DNS важен не только как "телефонный справочник", но и как инструмент балансировки, failover и маршрутизации трафика.

### 1.1 Иерархия DNS

```
Запрос: api.example.com

Client
  │
  ▼
Recursive Resolver (ISP или 8.8.8.8)
  │
  ├─► Root Name Server (.)
  │     "Не знаю, спроси TLD .com"
  │
  ├─► TLD Name Server (.com)
  │     "Не знаю, спроси authoritative для example.com"
  │
  └─► Authoritative Name Server (example.com)
        "api.example.com → 93.184.216.34"
```

**Root servers:** 13 логических серверов (A–M), физически реплицированных по всему миру через anycast. Их адреса зашиты в DNS-резолверах.

**TLD servers:** управляются регистраторами (Verisign для `.com`, RIPE NCC для `.eu` и т.д.).

**Authoritative servers:** это то, что вы настраиваете в своём DNS-провайдере (Route53, Cloudflare, NS1). Они дают окончательный ответ.

**Recursive resolver:** кеширует результаты. Большинство запросов не доходит дальше него.

### 1.2 Типы DNS-записей

| Тип    | Описание                                  | Пример                                              |
|--------|-------------------------------------------|-----------------------------------------------------|
| `A`    | Домен → IPv4                              | `api.example.com → 93.184.216.34`                   |
| `AAAA` | Домен → IPv6                              | `api.example.com → 2606:2800:220:1:248:1893:25c8:1946` |
| `CNAME`| Алиас на другой домен                     | `www.example.com → example.com`                     |
| `MX`   | Mail exchange для домена                  | `example.com → mail.example.com` (priority 10)      |
| `NS`   | Authoritative name servers                | `example.com NS ns1.cloudflare.com`                 |
| `TXT`  | Произвольный текст (SPF, DKIM, верификация) | `v=spf1 include:_spf.google.com ~all`             |
| `SRV`  | Сервис, порт, протокол                    | `_grpc._tcp.example.com 10 0 50051 grpc.example.com` |
| `PTR`  | Обратный lookup: IP → домен              | `34.216.184.93.in-addr.arpa → api.example.com`      |
| `CAA`  | Разрешённые Certificate Authorities       | `example.com CAA 0 issue "letsencrypt.org"`         |

**SRV-записи** особенно полезны для service discovery в микросервисах: клиент может автоматически узнать порт и приоритет сервиса без хардкода.

### 1.3 TTL и кеширование

TTL (Time-To-Live) — сколько секунд запись можно кешировать. Это ключевой параметр при планировании изменений.

```
Запись: api.example.com A 93.184.216.34 TTL=300

Что происходит:
- Resolver закешировал запись
- Вы меняете IP на 10.0.0.5
- До истечения 300 сек: часть клиентов видит старый IP
- После истечения: все получают новый IP

Итого: propagation delay ≈ TTL
```

**Рекомендации по TTL:**

| Ситуация                        | TTL          |
|---------------------------------|--------------|
| Продакшн, редко меняется        | 3600–86400 с |
| За 24–48ч до плановой миграции  | 60–300 с     |
| Активная миграция               | 30–60 с      |
| После миграции (стабильно)      | 3600+ с      |

Короткий TTL = больше DNS-запросов = нагрузка на authoritative сервер и небольшая задержка на резолюцию.

### 1.4 DNS-based Load Balancing

**Round-Robin DNS:** один домен возвращает несколько A-записей. Клиент сам выбирает, обычно первый в списке.

```dns
api.example.com  300  A  10.0.1.1
api.example.com  300  A  10.0.1.2
api.example.com  300  A  10.0.1.3
```

Проблемы round-robin DNS:
- Клиент кеширует первый IP → неравномерная нагрузка
- Нет health check: если 10.0.1.2 упал, DNS продолжает его возвращать
- Sticky клиенты (мобильные SDK, браузеры) не ротируют записи

**GeoDNS:** authoritative сервер возвращает разные IP в зависимости от геолокации клиентского resolver'а.

```
Клиент из EU → api.eu.example.com (10.20.1.1)
Клиент из US → api.us.example.com (10.10.1.1)
Клиент из AP → api.ap.example.com (10.30.1.1)
```

Используется в AWS Route53 (Geolocation routing), Cloudflare, NS1.

**Weighted DNS:** разные веса для A/B деплоя или постепенного переключения трафика.

```
api.example.com  A  10.0.1.1  weight=90   # старая версия
api.example.com  A  10.0.1.2  weight=10   # новая версия (canary)
```

### 1.5 Проблемы DNS

**DNS Propagation:** изменение записи не распространяется мгновенно. Старые TTL кешируются рекурсивными резолверами по всему миру. Реальный propagation может занять до 48 часов, хотя при TTL=300 большинство резолверов обновится за 5–10 минут.

**DNS Cache Poisoning (Kaminsky Attack):** атакующий подменяет кешированные записи в recursive resolver'е, направляя трафик на вредоносный IP. Защита: DNSSEC (цифровые подписи), randomized source ports, 0x20 encoding.

**DNSSEC:** добавляет цепочку доверия через криптографические подписи. Усложняет инфраструктуру, но защищает от подмены записей.

**Split-horizon DNS:** один домен резолвится в разные IP в зависимости от того, внутренняя или внешняя сеть. Типично для корпоративных систем: `db.internal.example.com` → `10.0.0.5` внутри VPC, снаружи — ошибка.

### 1.6 Пример: HA с несколькими A-записями

```
# Конфигурация Route53 (или аналог)
api.example.com  60  A  10.0.1.10   # primary, eu-west-1
api.example.com  60  A  10.0.1.11   # secondary, eu-west-1

# Health check policy: если primary не отвечает на :80/health
# → Route53 убирает его из ответа автоматически

# Схема:
  DNS Query for api.example.com
         │
         ▼
   Route53 (health-check aware)
    ├── 10.0.1.10 (healthy) ✓  ← возвращается
    └── 10.0.1.11 (healthy) ✓  ← возвращается
    
  Если 10.0.1.10 падает:
    ├── 10.0.1.10 (unhealthy) ✗  ← не возвращается
    └── 10.0.1.11 (healthy)  ✓  ← единственный ответ
```

TTL=60 означает, что failover займёт максимум 1 минуту. Для критичных систем Route53 позволяет использовать alias-записи с TTL=0.

---

## 2. HTTP

### 2.1 HTTP/1.1

HTTP/1.1 вышел в 1997 году и до сих пор широко используется. Ключевые особенности:

**Keep-Alive (persistent connections):** соединение не закрывается после каждого запроса. До HTTP/1.1 на каждый запрос создавался новый TCP handshake (3 RTT). С keep-alive — одно соединение на несколько запросов.

```
HTTP/1.0:
  TCP connect → Request → Response → TCP close    (повторять)

HTTP/1.1 (keep-alive):
  TCP connect → Request → Response → Request → Response → ... → TCP close
```

**Head-of-Line (HOL) Blocking:** запросы в одном TCP-соединении обрабатываются последовательно. Медленный запрос блокирует все последующие.

```
Connection 1: [Request A (slow)] → [Request B] → [Request C]
               ← ждём A ─────────────────────────────────────

Браузеры обходили это через 6 параллельных соединений на домен:
Connection 1: Request A
Connection 2: Request B
Connection 3: Request C
...
```

**Pipelining** в HTTP/1.1: отправить несколько запросов не дожидаясь ответа — теоретически есть, практически не работает из-за HOL blocking на уровне TCP и плохой поддержки прокси.

**Chunked Transfer Encoding:** сервер может начать отправлять тело ответа до того, как знает его полный размер (полезно для стриминга).

### 2.2 HTTP/2

HTTP/2 (RFC 7540, 2015) решил основные проблемы HTTP/1.1, оставив семантику неизменной (методы, заголовки, статус-коды остались теми же).

**Мультиплексирование (Multiplexing):** несколько запросов и ответов передаются параллельно в одном TCP-соединении через концепцию streams.

```
HTTP/1.1 (3 соединения):
  Conn 1: ──[Req A]────────────────[Resp A]──
  Conn 2: ──[Req B]──[Resp B]────────────────
  Conn 3: ──[Req C]────[Resp C]──────────────

HTTP/2 (1 соединение, 3 streams):
  Stream 1: ──[Req A]──────────────[Resp A]──
  Stream 3: ──[Req B]──[Resp B]────────────── 
  Stream 5: ──[Req C]────[Resp C]────────────
  TCP:      ════════════════════════════════
```

**Бинарный framing:** данные разбиваются на frames (HEADERS, DATA, SETTINGS, PUSH_PROMISE и т.д.). Это эффективнее текстового протокола HTTP/1.1.

**HPACK сжатие заголовков:** заголовки передаются в сжатом виде. Повторяющиеся заголовки (Authorization, Content-Type) кодируются индексом из общей таблицы.

```
Первый запрос:
  HEADERS: method=GET, path=/api/users, authorization=Bearer abc123

Второй запрос на тот же домен:
  HEADERS: [index 2] (method=GET из таблицы)
           [index 5] (path=/api/orders — новый, добавляется в таблицу)
           [index 8] (authorization — из таблицы, не передаётся повторно)
```

**Server Push:** сервер может отправить ресурсы до того, как клиент их запросил. Практически не используется в API (больше для HTML+CSS+JS).

**Priority streams:** клиент может указать приоритет потока. Редко используется в API, важно для браузерного рендеринга.

**Проблема HTTP/2:** HOL blocking остаётся, но теперь на уровне TCP. Если TCP-пакет теряется, все streams в соединении ждут его повторной передачи.

### 2.3 HTTP/3 и QUIC

HTTP/3 (RFC 9114, 2022) заменяет TCP на QUIC (Quick UDP Internet Connections).

**QUIC работает поверх UDP.** Это позволяет:
- Встроенное шифрование (TLS 1.3 обязателен)
- Независимые streams: потеря пакета в одном stream не блокирует другие
- 0-RTT и 1-RTT handshake

```
TCP + TLS 1.2:
  SYN → SYN-ACK → ACK             (1 RTT TCP)
  ClientHello → ServerHello        (1 RTT TLS)
  → 2 RTT до первого байта данных

TCP + TLS 1.3:
  SYN → SYN-ACK → ACK             (1 RTT TCP)
  ClientHello + TLS = 1 RTT combined
  → 1 RTT до первого байта данных

QUIC (0-RTT, повторное соединение):
  → 0 RTT для известных серверов (session resumption)
  → 1 RTT для новых соединений
```

**Connection Migration:** QUIC идентифицирует соединение по Connection ID, а не по IP:port. Это позволяет мобильным клиентам переключаться между WiFi и LTE без разрыва соединения.

```
Client IP: 192.168.1.5 (WiFi)
  → QUIC Connection ID: 0xABCD1234
  
WiFi отключился, LTE включился
Client IP: 10.0.0.1 (LTE)
  → QUIC Connection ID: 0xABCD1234 (тот же!)
  → Соединение сохраняется, запрос продолжается
```

### 2.4 Сравнение HTTP версий

| Характеристика          | HTTP/1.1       | HTTP/2          | HTTP/3 (QUIC)   |
|-------------------------|----------------|-----------------|-----------------|
| Протокол транспорта      | TCP            | TCP             | UDP (QUIC)      |
| Мультиплексирование      | Нет (workaround: 6 conn) | Да, streams | Да, независимые streams |
| HOL Blocking            | Да (приложение + TCP) | Только TCP  | Нет             |
| Сжатие заголовков       | Нет            | HPACK           | QPACK           |
| Шифрование              | Опционально    | Опционально (де-факто TLS) | Обязательно (TLS 1.3) |
| Server Push             | Нет            | Да (редко используется) | Да (deprecated в RFC) |
| 0-RTT handshake         | Нет            | Нет             | Да              |
| Connection Migration    | Нет            | Нет             | Да              |
| Поддержка браузерами    | 100%           | ~98%            | ~95%            |
| Поддержка на серверах   | 100%           | ~80% (Nginx, Apache, Go) | ~60% (Cloudflare, Caddy) |

### 2.5 Когда что использовать

**HTTP/1.1:** legacy системы, простые внутренние API без строгих требований к latency, инструменты (curl по умолчанию).

**HTTP/2:** большинство новых API, gRPC (обязателен HTTP/2), сайты с большим количеством ресурсов, мобильные клиенты (экономия на количестве соединений).

**HTTP/3:** публичные API с глобальной аудиторией (особенно мобильные), CDN-edge, сервисы с требованием к latency при плохих сетях. Cloudflare и Google активно используют HTTP/3.

```
Пример: выбор протокола для API
  
  Внутренний gRPC между сервисами → HTTP/2 (обязательно)
  Публичный REST API для мобильных → HTTP/2 (минимум), HTTP/3 (если есть Caddy/Cloudflare)
  Webhook-приёмник → HTTP/1.1 (достаточно)
  Стриминг данных клиенту → HTTP/2 с server push или HTTP/3
```

---

## 3. REST vs gRPC vs GraphQL

### 3.1 REST

REST (Representational State Transfer) — архитектурный стиль, не протокол. Ключевые принципы по Fielding:

1. **Stateless:** каждый запрос содержит всю нужную информацию. Нет серверного состояния сессии.
2. **Client-Server:** разделение ответственности.
3. **Cacheable:** ответы явно помечаются как кешируемые или нет.
4. **Uniform Interface:** единый интерфейс через ресурсы, методы HTTP, коды ответа.
5. **Layered System:** клиент не знает, обращается ли он напрямую к серверу или через прокси.
6. **Code on Demand (опционально):** сервер может передавать исполняемый код.

**Richardson Maturity Model (RMM):**

```
Level 0: RPC over HTTP
  POST /getUserById
  POST /createOrder
  POST /deleteProduct

Level 1: Ресурсы
  GET /users/123
  POST /orders
  DELETE /products/456

Level 2: HTTP-методы + коды ответа
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

Большинство "REST API" в продакшне — это Level 2. Level 3 встречается редко.

**Идемпотентность HTTP-методов:**

| Метод   | Идемпотентный | Безопасный | Кешируемый |
|---------|---------------|------------|------------|
| GET     | Да            | Да         | Да         |
| HEAD    | Да            | Да         | Да         |
| OPTIONS | Да            | Да         | Нет        |
| PUT     | Да            | Нет        | Нет        |
| DELETE  | Да            | Нет        | Нет        |
| POST    | Нет           | Нет        | Иногда     |
| PATCH   | Нет*          | Нет        | Нет        |

*PATCH может быть идемпотентным, если операция задаёт конкретное значение, а не "добавить N".

### 3.2 gRPC

gRPC — это RPC-фреймворк от Google, использующий Protocol Buffers (protobuf) для сериализации и HTTP/2 для транспорта.

**Protocol Buffers:** бинарная сериализация с явной схемой. Эффективнее JSON (меньше размер, быстрее парсинг) и самодокументирована.

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

**Типы streaming в gRPC:**

```
Unary RPC:
  Client ──[Request]──► Server ──[Response]──► Client
  Как обычный HTTP-вызов

Server Streaming:
  Client ──[Request]──► Server ──[Response 1]──[Response 2]──[Response 3]──► Client
  Пример: подписка на обновления, экспорт большого файла

Client Streaming:
  Client ──[Req 1]──[Req 2]──[Req 3]──► Server ──[Response]──► Client
  Пример: загрузка файла чанками, батч-создание записей

Bidirectional Streaming:
  Client ──[Req 1]──[Req 2]──────────────────────────────────► Server
  Client ◄──────────────────[Resp 1]──[Resp 2]──[Resp 3]───── Server
  Пример: чат, реалтайм обмен данными
```

### 3.3 GraphQL

GraphQL — язык запросов для API, разработанный Facebook в 2012, опубликован в 2015.

**Проблемы, которые решает:**

```
# REST: получить пользователя с его заказами и адресами доставки
GET /users/123                    → {id, name, email, ...}   (over-fetching: лишние поля)
GET /users/123/orders             → [{id, total, items...}]
GET /users/123/orders/456/address → {street, city...}

# GraphQL: один запрос, точно нужные поля
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

**Когда GraphQL действительно нужен:**
- Публичный API с разнообразными клиентами (web, mobile, partners) с разными потребностями в данных
- Частое изменение клиентских требований без возможности менять backend
- BFF (Backend For Frontend) как aggregation layer

**Когда GraphQL избыточен:**
- Внутренние сервисы между бэкендами (gRPC лучше)
- Простые CRUD API с предсказуемыми запросами
- Команда небольшая и изменения API согласуются быстро

### 3.4 Сравнительная таблица

| Критерий              | REST            | gRPC                  | GraphQL               |
|-----------------------|-----------------|-----------------------|-----------------------|
| Протокол              | HTTP/1.1+       | HTTP/2 (обязателен)   | HTTP/1.1+             |
| Формат данных         | JSON (обычно)   | Protocol Buffers      | JSON                  |
| Размер payload        | Большой         | Малый (~3–10× меньше) | Зависит от запроса    |
| Скорость сериализации | Средняя         | Высокая               | Средняя               |
| Типизация             | Опционально (OpenAPI) | Строгая (proto) | Строгая (schema)      |
| Browser support       | Полный          | Ограничен (grpc-web)  | Полный                |
| Streaming             | SSE / WebSocket | Встроенный            | Subscriptions (WS)    |
| Debugging             | Простой (curl)  | Сложнее (grpcurl, Evans) | Средний (Playground) |
| Code generation       | Опционально     | Обязательно           | Опционально           |
| Кеширование           | HTTP-cache      | Нет (кастомное)       | Сложно (per-field)    |
| Версионирование       | /v1/, /v2/      | Через пакеты proto    | Эволюция схемы        |

### 3.5 Пример на Go: один эндпоинт на REST и gRPC

**Proto-файл (уже показан выше в 3.2). Сгенерированный handler для gRPC:**

```go
// Установка зависимостей:
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

// UserStore — абстракция хранилища (одинакова для REST и gRPC)
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
		// Маппинг доменных ошибок в gRPC статусы
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

// Server Streaming: стримить пользователей постранично
func (s *userGRPCServer) ListUsers(req *userv1.ListUsersRequest, stream userv1.UserService_ListUsersServer) error {
	// Имитация: отправляем 3 пользователей
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

**Тот же эндпоинт на REST:**

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

**Ключевое отличие:** в gRPC типизация и ошибки определены в proto-контракте и генерируются автоматически. В REST — вы сами описываете структуры ответов и маппинг ошибок на HTTP-коды. gRPC выигрывает на внутренних API между сервисами; REST — на публичных API.

---

## 4. WebSocket и Server-Sent Events

### 4.1 WebSocket

WebSocket — протокол полнодуплексной связи поверх одного TCP-соединения. Начинается с HTTP Upgrade handshake.

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

После handshake: бинарный фреймовый протокол в обе стороны
```

**Когда нужен WebSocket:**
- Чат (сообщения туда и обратно)
- Реалтайм-игры (игровые события в обоих направлениях)
- Коллаборативное редактирование (Google Docs-style)
- Финансовые тикеры с командами (subscribe/unsubscribe)
- Live-дашборды, где пользователь может управлять потоком

**Проблемы WebSocket:**
- Stateful соединения: сложнее горизонтально масштабировать
- Нет HTTP-кеширования
- Firewall/proxy могут блокировать (нужен fallback)
- Heartbeat/ping-pong для определения разрыва

### 4.2 Server-Sent Events (SSE)

SSE — однонаправленный канал от сервера к клиенту поверх обычного HTTP. Клиент открывает соединение, сервер пушит события.

```
Client → Server:
  GET /events HTTP/1.1
  Accept: text/event-stream

Server → Client (бесконечный поток):
  HTTP/1.1 200 OK
  Content-Type: text/event-stream
  Cache-Control: no-cache

  id: 1
  event: message
  data: {"user": "Alice", "text": "Hello"}

  id: 2
  event: notification
  data: {"type": "order_shipped", "order_id": 456}

  : heartbeat (comment, клиент игнорирует)

  id: 3
  data: simple message without event type
```

**Автоматическое переподключение:** браузер автоматически переподключается при разрыве, отправляя `Last-Event-ID`, что позволяет серверу продолжить с нужного места.

**Когда достаточно SSE:**
- Push-уведомления пользователю
- Прогресс долгой задачи (экспорт, обработка)
- Live-лента событий (аудит-лог, лог деплоя)
- Стриминг ответов от LLM (как ChatGPT)

### 4.3 Сравнение транспортов для реалтайма

```
Long Polling:
  Client: GET /updates  ─────────────────────────────────────► (ждём...)
  Server:                                            ◄── есть данные → ответ
  Client: GET /updates  ──────────────────────────────────────► (новый запрос)

SSE:
  Client: GET /events  ──────────────────────────────────────►
  Server:              ◄── event ──◄── event ──◄── event ─────

WebSocket:
  Client: GET /ws → Upgrade ─────────────────────────────────►
  Bidirectional: ◄───────────────────────────────────────────►
```

| Характеристика         | Long Polling     | SSE              | WebSocket        |
|------------------------|------------------|------------------|------------------|
| Направление            | Server → Client  | Server → Client  | Bidirectional    |
| Протокол               | HTTP             | HTTP             | WS (поверх HTTP) |
| Автореконнект          | Вручную          | Встроен          | Вручную          |
| Браузерная поддержка   | Универсальная    | Все современные  | Все современные  |
| Сложность серверной    | Простая          | Простая          | Средняя          |
| HTTP/2-совместимость   | Да               | Да (улучшается)  | Отдельный протокол |
| Балансировка           | Легко            | Легко            | Sticky sessions нужны |

### 4.4 Пример на Go: WebSocket с gorilla/websocket

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
	// В продакшне — проверяйте Origin
	CheckOrigin: func(r *http.Request) bool {
		return true // dev only!
	},
}

type Message struct {
	Type    string `json:"type"`
	Payload string `json:"payload"`
	From    string `json:"from,omitempty"`
}

// Hub управляет всеми активными соединениями
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

// Broadcast отправляет сообщение всем кроме отправителя
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
		// Устанавливаем deadline для write, чтобы не блокировать
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

	// Настраиваем ping/pong для обнаружения мёртвых соединений
	conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		return nil
	})

	// Горутина для периодического ping
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

**SSE-сервер на Go для сравнения:**

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
	// Проверяем поддержку flushing
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
			// Клиент отключился
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

			// Формат SSE: поле: значение\n\n
			fmt.Fprintf(w, "id: %d\n", event.ID)
			fmt.Fprintf(w, "event: %s\n", event.Type)
			fmt.Fprintf(w, "data: %s\n\n", data) // двойной \n — конец события

			flusher.Flush()
		}
	}
}
```

---

## 5. Load Balancing

### 5.1 Зачем нужен балансировщик

```
Без балансировщика:
  Client → Server (единая точка отказа, вертикальное масштабирование ограничено)

С балансировщиком:
  Client → Load Balancer → Server 1
                         → Server 2
                         → Server 3
```

Задачи балансировщика:
- Распределение нагрузки между инстансами
- Health checking: исключение нездоровых серверов
- SSL termination (Layer 7)
- Предоставление единой точки входа
- Горизонтальное масштабирование без изменения клиентов

### 5.2 Layer 4 vs Layer 7

**Layer 4 (Transport):** работает с TCP/UDP-соединениями. Не понимает содержимое запроса.

```
Клиент: TCP SYN → LB → TCP SYN → Backend
LB просто проксирует TCP-поток, не читает HTTP
Быстрее, меньше накладных расходов
Не может маршрутизировать по URL, заголовкам, cookie
```

**Layer 7 (Application):** понимает HTTP, читает заголовки и URL.

```
Клиент: GET /api/users HTTP/1.1 → LB
LB:
  path /api/users → users-service
  path /api/orders → orders-service
  Header: X-Version: v2 → backend-v2

Может:
- Маршрутизировать по URL/заголовкам
- SSL termination
- Sticky sessions по cookie
- Перезапись запросов
- Rate limiting
- Caching
```

| Характеристика      | Layer 4            | Layer 7               |
|---------------------|--------------------|-----------------------|
| Протоколы           | TCP, UDP           | HTTP, HTTPS, gRPC     |
| Скорость            | Выше               | Ниже (парсинг HTTP)   |
| Маршрутизация       | IP:Port            | URL, заголовки, метод |
| SSL termination     | Нет (passthrough)  | Да                    |
| Health check        | TCP connect        | HTTP /health          |
| Примеры             | AWS NLB, HAProxy L4 | Nginx, Envoy, AWS ALB |

### 5.3 Алгоритмы балансировки

**Round Robin:** запросы распределяются по кругу.

```
Запрос 1 → Server A
Запрос 2 → Server B
Запрос 3 → Server C
Запрос 4 → Server A  (снова)
```

Хорошо для однородных серверов с одинаковой нагрузкой на запрос.

**Weighted Round Robin:** серверам присваиваются веса.

```
Server A: weight=5  → получает 5/8 запросов
Server B: weight=2  → получает 2/8 запросов
Server C: weight=1  → получает 1/8 запросов

Используется: разные мощности серверов, canary-деплой
```

**Least Connections:** запрос идёт на сервер с наименьшим числом активных соединений.

```
Server A: 10 active connections
Server B: 2 active connections  ← сюда
Server C: 7 active connections

Хорошо для: запросы с разным временем выполнения (долгие и короткие)
```

**IP Hash:** IP клиента хешируется, результат определяет сервер.

```
hash(client_ip) % n_servers = server_index

Гарантирует: один клиент всегда попадает на один сервер
Проблема: неравномерное распределение, сложно масштабировать
```

**Consistent Hashing:** более продвинутая версия IP Hash.

```
Хэш-кольцо (0 ... 2^32):

     0
     │
  A(100) ←── hash("client1") = 80   → A
  B(200) ←── hash("client2") = 150  → B
  C(300) ←── hash("client3") = 250  → C
     │
    2^32

При добавлении/удалении сервера перераспределяется минимум ключей.
Используется: CDN, distributed caches, database sharding
```

**Random:** случайный сервер. Прост, даёт хорошее распределение при большом числе запросов.

### 5.4 Пример конфигурации Nginx

```nginx
# /etc/nginx/conf.d/api.conf

upstream api_backend {
    # Алгоритм: по умолчанию round-robin
    # Для least_conn: добавить директиву least_conn;

    server 10.0.1.1:8080 weight=3;
    server 10.0.1.2:8080 weight=3;
    server 10.0.1.3:8080 weight=1 backup; # используется если остальные упали

    # Health check (Nginx Plus или OpenResty)
    # keepalive 32;
}

server {
    listen 80;
    server_name api.example.com;

    # Редирект на HTTPS
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name api.example.com;

    ssl_certificate     /etc/ssl/certs/api.crt;
    ssl_certificate_key /etc/ssl/private/api.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    # Таймауты
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

        # Retry при ошибках (только для идемпотентных запросов)
        proxy_next_upstream error timeout http_502 http_503;
        proxy_next_upstream_tries 2;
    }

    # Health check endpoint — не проксируем, отвечаем сами
    location /health {
        return 200 "OK\n";
        add_header Content-Type text/plain;
    }
}
```

**Активный health check через nginx_upstream_check_module:**

```nginx
upstream api_backend {
    server 10.0.1.1:8080;
    server 10.0.1.2:8080;

    check interval=3000 rise=2 fall=3 timeout=1000 type=http;
    check_http_send "GET /health HTTP/1.0\r\n\r\n";
    check_http_expect_alive http_2xx;
}
```

### 5.5 Сравнение балансировщиков

| Критерий           | Nginx            | HAProxy          | Envoy            | AWS ALB          |
|--------------------|------------------|------------------|------------------|------------------|
| Layer              | 4 + 7            | 4 + 7            | 4 + 7            | 7                |
| Производительность | Высокая          | Очень высокая    | Высокая          | Высокая          |
| gRPC support       | Да (1.13+)       | Да               | Отличный         | Да               |
| Service Mesh       | Нет              | Нет              | Да (Istio)       | Нет              |
| Конфигурация       | Файлы + API      | Файлы            | xDS API (динамически) | AWS Console/API |
| Observability      | Базовая          | Хорошая          | Отличная         | CloudWatch       |
| Managed/Self-hosted | Self            | Self             | Self             | Managed          |
| Стоимость          | Бесплатный       | Бесплатный       | Бесплатный       | $0.008/LCU-hour  |

**Когда что выбирать:**
- **Nginx:** general purpose, статика + проксирование, хорошо знаком команде
- **HAProxy:** максимальная производительность L4/L7, финансовые системы
- **Envoy:** service mesh, сложная маршрутизация, observability (Prometheus out of box)
- **Cloud LB:** быстрый старт, отсутствие ops-нагрузки, интеграция с managed сервисами

### 5.6 Sticky Sessions

Sticky sessions (session affinity): один и тот же клиент всегда попадает на один и тот же backend.

```
Без sticky sessions (stateless):
  Запрос 1 → Server A (сессия не нужна, state в Redis)
  Запрос 2 → Server B (находит state в Redis)
  ✓ Работает правильно

С sticky sessions:
  Запрос 1 → Server A (сессия в памяти Server A)
  Запрос 2 → Server B (не знает о сессии)
  ✗ Ошибка аутентификации!

  Решение: sticky sessions (LB запоминает Server A для этого клиента)
  Nginx: ip_hash; или cookie: proxy_cookie_path / route-cookie
```

**Почему sticky sessions — антипаттерн:**
- При падении Server A все его "прилипшие" пользователи теряют сессию
- Неравномерная нагрузка: одни серверы перегружены, другие простаивают
- Усложняет rolling deploy: нельзя вывести сервер без потери сессий
- Препятствует горизонтальному масштабированию

**Правильное решение:** вынести state из серверов в общее хранилище (Redis, Memcached, БД). Тогда любой backend может обслужить любой запрос.

```
Stateless архитектура:
  Client → [LB] → Server A ┐
                  Server B ├── Redis (sessions, cache)
                  Server C ┘
  
  Любой сервер может обработать любой запрос.
  Автоскейлинг работает без ограничений.
```

---

## 6. API Gateway

### 6.1 Зачем нужен API Gateway

```
Без API Gateway (клиенты обращаются к сервисам напрямую):

  Mobile App ──────────────────────► Users Service :8001
  Web App ─────────────────────────► Orders Service :8002
  Partner API ─────────────────────► Products Service :8003
  
  Проблемы:
  - Каждый сервис реализует auth, rate limiting, logging отдельно
  - Клиент должен знать адреса всех сервисов
  - Изменение адреса сервиса ломает всех клиентов

С API Gateway:

  Mobile App ──────────────────────┐
  Web App ─────────────────────────┤─► API Gateway ─► Users Service
  Partner API ─────────────────────┘         │──────► Orders Service
                                              └──────► Products Service
  
  Единая точка входа: auth, rate limiting, logging — один раз
```

**Функции API Gateway:**
- **Routing:** маршрутизация по path/host/header к нужному сервису
- **Auth/AuthZ:** JWT validation, OAuth, API keys
- **Rate Limiting:** защита от злоупотреблений
- **SSL Termination:** TLS на gateway, внутри сети — plain HTTP
- **Request/Response Transformation:** переписать заголовки, body
- **Circuit Breaking:** не пускать трафик на упавший сервис
- **Caching:** кешировать ответы
- **Logging/Tracing:** централизованная observability

### 6.2 API Gateway vs Load Balancer vs Reverse Proxy

```
Reverse Proxy:
  Простая переадресация запросов. Нет бизнес-логики.
  Пример: Nginx как reverse proxy для одного сервиса.

Load Balancer:
  Распределение нагрузки между N экземплярами ОДНОГО сервиса.
  Может быть Layer 4 или Layer 7.
  Нет auth, нет трансформации.

API Gateway:
  Маршрутизация к N РАЗНЫМ сервисам.
  Полный набор cross-cutting concerns.
  Всегда Layer 7.
  
Стек:
  DNS → Load Balancer → API Gateway → Reverse Proxy (перед каждым сервисом) → Service
```

| Возможность            | Reverse Proxy | Load Balancer | API Gateway |
|------------------------|:-------------:|:-------------:|:-----------:|
| Маршрутизация запросов | ✓             | ✓             | ✓           |
| Балансировка нагрузки  | ✓             | ✓             | ✓           |
| SSL Termination        | ✓             | Layer 7 only  | ✓           |
| Аутентификация         | -             | -             | ✓           |
| Rate Limiting          | Базовый       | -             | ✓           |
| Request Transformation | -             | -             | ✓           |
| Multi-service routing  | -             | -             | ✓           |
| API versioning         | -             | -             | ✓           |

### 6.3 Популярные решения

| Решение        | Тип        | Конфигурация | gRPC | Производительность | Особенность                    |
|----------------|------------|--------------|------|--------------------|-------------------------------|
| Kong           | Self/Cloud | Admin API + YAML | Да | Высокая (OpenResty) | Plugin ecosystem              |
| Envoy          | Self       | xDS API (динам.) | Отличный | Очень высокая | Service mesh, Istio           |
| Traefik        | Self       | Auto-discovery | Да | Высокая            | Kubernetes-native, Let's Encrypt |
| AWS API GW     | Managed    | Console/CDK  | REST/HTTP | Высокая         | Lambda integration, WAF       |
| GCP API GW     | Managed    | OpenAPI spec | REST | Высокая           | Cloud Run/Functions           |
| Azure APIM     | Managed    | Portal/ARM   | Да  | Высокая            | Enterprise features           |
| Nginx (+ Lua)  | Self       | nginx.conf   | Да  | Очень высокая      | Кастомизация через Lua        |

### 6.4 Пример: маршрутизация к микросервисам

**Kong (декларативная конфигурация):**

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
          - GET  # публичный endpoint, без auth
      - name: products-admin-route
        paths:
          - /api/v1/admin/products
        plugins:
          - name: key-auth  # admin требует API key
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
      # Без auth — публичный endpoint

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

### 7.1 Проблема

В statically deployed системах IP-адреса серверов фиксированы и прописаны в конфигах. В динамических средах (Kubernetes, cloud auto-scaling) сервисы появляются и исчезают, их IP меняются при каждом деплое.

```
Без service discovery:
  orders-service/config.yaml:
    users_service_url: "http://10.0.1.15:8001"  # хардкод
  
  Деплой нового pods users-service → новый IP 10.0.1.23
  orders-service не знает об этом → ошибки

С service discovery:
  orders-service запрашивает: "где users-service?"
  Registry отвечает: "10.0.1.23:8001"
  → всегда актуальный адрес
```

### 7.2 Client-side vs Server-side Discovery

**Client-side Discovery:**

```
Service A ──► Registry (Consul/etcd) ──► "Service B: 10.0.1.1:8002, 10.0.1.2:8002"
Service A выбирает инстанс сам (load balancing на клиенте)
Service A ──► 10.0.1.1:8002

Плюсы: меньше компонентов, клиент контролирует выбор
Минусы: логика discovery в каждом клиенте, language-specific библиотеки
Примеры: Netflix Eureka + Ribbon, Consul client
```

**Server-side Discovery:**

```
Service A ──► Load Balancer/Router ──► Registry ──► "Service B instances"
                                   └──────────────► Service B

Service A не знает про Registry, LB делает всё сам.
Плюсы: простые клиенты, один компонент знает про routing
Минусы: дополнительный hop, LB — SPOF без HA
Примеры: Kubernetes Service, AWS ALB + ECS, Envoy
```

### 7.3 Инструменты

**Consul:** полноценное решение: service registry + health checks + KV store + DNS interface.

```bash
# Регистрация сервиса в Consul
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

# Поиск здоровых инстансов
curl http://localhost:8500/v1/health/service/users-service?passing=true

# Через DNS (Consul как DNS-сервер):
dig @127.0.0.1 -p 8600 users-service.service.consul
# → 10.0.1.23
```

**etcd:** распределённое KV хранилище. Kubernetes использует etcd для всех своих данных.

**Kubernetes DNS:** встроенный service discovery через CoreDNS.

### 7.4 Kubernetes Service Discovery

Kubernetes автоматически создаёт DNS-записи для каждого Service.

```
Формат DNS-имени:
  <service-name>.<namespace>.svc.cluster.local

Примеры:
  users-service.production.svc.cluster.local  → ClusterIP сервиса
  users-service.production.svc.cluster.local  → порт 8001
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
      port: 8001        # порт Service (внешний для других pods)
      targetPort: 8001  # порт контейнера
  type: ClusterIP       # только внутри кластера
```

```yaml
# orders-deployment.yaml — как orders-service обращается к users-service
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
            # Kubernetes автоматически инжектирует env-переменные для сервисов:
            # USERS_SERVICE_SERVICE_HOST=10.96.1.50
            # USERS_SERVICE_SERVICE_PORT=8001
            # Но лучше использовать DNS:
            - name: USERS_SERVICE_URL
              value: "http://users-service.production.svc.cluster.local:8001"
```

**Пример на Go: обращение к сервису через Kubernetes DNS:**

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
		// Дефолт для локальной разработки
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

**Схема DNS-резолюции в Kubernetes:**

```
Pod (orders-service) запрашивает: users-service.production.svc.cluster.local

  Pod DNS config (/etc/resolv.conf):
    nameserver 10.96.0.10        (CoreDNS ClusterIP)
    search production.svc.cluster.local svc.cluster.local cluster.local

  Запрос → CoreDNS (10.96.0.10)
    CoreDNS → смотрит в kube-apiserver
    → находит Service "users-service" в namespace "production"
    → возвращает ClusterIP: 10.96.1.50

  iptables (kube-proxy) на ноде:
    10.96.1.50:8001 → DNAT → 10.0.1.23:8001 (Pod IP, round-robin)
```

**Headless Service** (для StatefulSet, когда нужны IP отдельных pods):

```yaml
spec:
  clusterIP: None  # Headless!
  # DNS вернёт A-записи для каждого Pod, не ClusterIP
  # postgres-0.postgres.production.svc.cluster.local → 10.0.1.5
  # postgres-1.postgres.production.svc.cluster.local → 10.0.1.6
```

---

## 8. Идемпотентность в сетевых взаимодействиях

### 8.1 Зачем это нужно

В распределённых системах запросы теряются, соединения прерываются, серверы перезагружаются. Retry — стандартный механизм надёжности. Но retry без идемпотентности создаёт дубликаты.

```
Проблема:
  Client ──POST /payments {amount: 100}──► Server
  Server обработал, ответил...
  TCP-пакет с ответом потерялся!
  
  Client не получил ответ → считает запрос неудачным → retry
  Client ──POST /payments {amount: 100}──► Server
  
  Результат: списание произошло дважды. Клиент видит одну попытку.
```

**Идемпотентная операция:** выполнение N раз даёт тот же результат, что и один раз.

```
Идемпотентные операции:
  SET x = 5          (можно выполнять сколько угодно, x всегда будет 5)
  DELETE user_id=123 (первый вызов удаляет, следующие — no-op или 404)
  PUT /users/123 {name: "Alice"} (результат одинаков при любом числе вызовов)

Неидемпотентные операции:
  INCREMENT counter   (каждый вызов меняет результат)
  POST /payments     (каждый вызов создаёт новый платёж)
  APPEND to log      (каждый вызов добавляет запись)
```

### 8.2 Idempotency Key

Idempotency Key — уникальный токен, который клиент генерирует перед запросом и прикладывает к каждой попытке. Сервер использует его как дедупликации ключ.

```
Клиент:
  idempotency_key = uuid() // генерируем один раз
  
  Попытка 1: POST /payments
    Idempotency-Key: 550e8400-e29b-41d4-a716-446655440000
    Body: {amount: 100, currency: "USD"}

  Ответ потерялся → retry

  Попытка 2: POST /payments (тот же ключ!)
    Idempotency-Key: 550e8400-e29b-41d4-a716-446655440000
    Body: {amount: 100, currency: "USD"}

Сервер (попытка 1):
  - Видит ключ впервые
  - Обрабатывает платёж
  - Сохраняет результат в Redis: key → {status: success, response: {...}}
  - Возвращает ответ (пакет потерялся)

Сервер (попытка 2):
  - Видит тот же ключ
  - Находит результат в Redis
  - Возвращает закешированный ответ (платёж НЕ создаётся повторно)
```

### 8.3 Пример на Go: middleware для idempotency key с Redis

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
	// TTL кеша: достаточно долго для retry-окна клиента
	idempotencyTTL = 24 * time.Hour
)

// idempotentResponse хранит закешированный ответ
type idempotentResponse struct {
	StatusCode int               `json:"status_code"`
	Headers    map[string]string `json:"headers"`
	Body       []byte            `json:"body"`
}

// responseRecorder перехватывает ответ handler'а для кеширования
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
	r.body.Write(b) // пишем в буфер
	return r.ResponseWriter.Write(b)
}

// IdempotencyMiddleware обрабатывает Idempotency-Key заголовок
func IdempotencyMiddleware(rdb *redis.Client) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Идемпотентность нужна только для не-идемпотентных методов
			if r.Method != http.MethodPost && r.Method != http.MethodPatch {
				next.ServeHTTP(w, r)
				return
			}

			idempotencyKey := r.Header.Get(idempotencyKeyHeader)
			if idempotencyKey == "" {
				// Если ключа нет — требуем его для POST
				http.Error(w, `{"error":"Idempotency-Key header required"}`, http.StatusUnprocessableEntity)
				return
			}

			// Включаем path в ключ кеша: один ключ не должен работать для разных эндпоинтов
			cacheKey := buildCacheKey(idempotencyKey, r.URL.Path)

			ctx := r.Context()

			// Проверяем: есть ли уже результат для этого ключа?
			cached, err := rdb.Get(ctx, cacheKey).Bytes()
			if err == nil {
				// Нашли — возвращаем закешированный ответ
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

			// Ключа нет — пробуем заблокировать (чтобы параллельные retry не прошли)
			lockKey := cacheKey + ":lock"
			locked, err := rdb.SetNX(ctx, lockKey, "1", 30*time.Second).Result()
			if err != nil || !locked {
				// Другой запрос уже обрабатывает этот ключ
				http.Error(w, `{"error":"concurrent request with same Idempotency-Key"}`, http.StatusConflict)
				return
			}
			defer rdb.Del(ctx, lockKey)

			// Записываем ответ в буфер
			recorder := &responseRecorder{
				ResponseWriter: w,
				statusCode:     http.StatusOK,
			}

			// Читаем body чтобы сохранить контрольную сумму запроса
			var bodyBytes []byte
			if r.Body != nil {
				bodyBytes, _ = io.ReadAll(r.Body)
				r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
			}

			next.ServeHTTP(recorder, r)

			// Кешируем только успешные ответы (2xx)
			if recorder.statusCode >= 200 && recorder.statusCode < 300 {
				resp := idempotentResponse{
					StatusCode: recorder.statusCode,
					Headers: map[string]string{
						"Content-Type": recorder.Header().Get("Content-Type"),
					},
					Body: recorder.body.Bytes(),
				}

				data, _ := json.Marshal(resp)
				// Сохраняем в Redis с TTL
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

**Использование middleware:**

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

	// Проверяем подключение
	if err := rdb.Ping(context.Background()).Err(); err != nil {
		log.Fatalf("redis connect error: %v", err)
	}

	r := chi.NewRouter()

	// Применяем middleware только к нужным роутам
	r.Group(func(r chi.Router) {
		r.Use(IdempotencyMiddleware(rdb))

		r.Post("/v1/payments", createPaymentHandler)
		r.Post("/v1/orders", createOrderHandler)
	})

	// GET-роуты не нуждаются в идемпотентности
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

	// Бизнес-логика создания платежа
	// При повторном запросе с тем же Idempotency-Key этот код НЕ выполнится
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
	// В реальности: UUID или ULID
	return fmt.Sprintf("pay_%d", time.Now().UnixNano())
}
```

**Клиентская сторона с retry и idempotency key:**

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
	// Генерируем ключ один раз ДО всех попыток
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
		// Один и тот же ключ на каждой попытке!
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

		// 409 Conflict — параллельный запрос, ждём и повторяем
		if resp.StatusCode == http.StatusConflict {
			time.Sleep(backoff)
			backoff *= 2
			continue
		}

		// 4xx (кроме 409) — не ретраим (клиентская ошибка)
		if resp.StatusCode >= 400 && resp.StatusCode < 500 && resp.StatusCode != 429 {
			var errResp map[string]string
			json.NewDecoder(resp.Body).Decode(&errResp)
			return nil, fmt.Errorf("client error %d: %v", resp.StatusCode, errResp)
		}

		// 5xx или 429 — ретраим
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

		// Сервер вернул "Idempotent-Replayed: true" — это retry, не дубликат
		replayed := resp.Header.Get("Idempotent-Replayed") == "true"
		if replayed {
			fmt.Printf("Idempotent replay: payment %s already created\n", result.PaymentID)
		}

		return &result, nil
	}

	return nil, fmt.Errorf("max attempts reached")
}
```

### 8.4 Что хранить и как долго

```
В Redis храним:
  Key:   idem:<sha256(idempotencyKey + path)>
  Value: {status_code, headers, body}
  TTL:   24 часа (или в соответствии с вашим retry-окном)

Важные детали:
  - Привязывать ключ к user_id: один ключ работает только для одного пользователя
    Key: idem:<sha256(user_id + idempotencyKey + path)>
  
  - Хранить hash тела запроса: если тело отличается — это разные операции
    (защита от случайного переиспользования ключа)
  
  - Не кешировать ошибки: при ошибке (5xx) клиент должен иметь возможность retry
    Кешируем только 2xx и 4xx (клиентские ошибки не изменятся при retry)
```

---

## Итог модуля

| Тема                  | Ключевой вывод                                                        |
|-----------------------|-----------------------------------------------------------------------|
| DNS                   | TTL — главный рычаг управления propagation. Снижай TTL до миграции.  |
| HTTP версии           | HTTP/2 — стандарт для gRPC и API. HTTP/3 — для мобильных и edge.    |
| REST vs gRPC vs GraphQL | gRPC для внутренних сервисов, REST для публичных, GraphQL — только если реально нужна гибкость запросов. |
| WebSocket vs SSE      | SSE достаточен для большинства push-сценариев. WebSocket — только для bidirectional. |
| Load Balancing        | Layer 7 + Least Connections для API. Sticky sessions — антипаттерн.  |
| API Gateway           | Единая точка входа. Не дублируй cross-cutting concerns в каждом сервисе. |
| Service Discovery     | В Kubernetes используй DNS (`service.namespace.svc.cluster.local`).  |
| Идемпотентность       | Idempotency Key + Redis для всех создающих операций. Генерируй ключ один раз на клиенте. |

## Что дальше

- **Модуль 03:** Базы данных — реляционные, NoSQL, выбор хранилища
- **Модуль 04:** Кеширование — Redis, Memcached, CDN, cache strategies
- **Модуль 05:** Очереди сообщений — Kafka, RabbitMQ, паттерны асинхронного взаимодействия
