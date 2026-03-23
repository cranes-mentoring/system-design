# Модуль 08: Микросервисы

> **Для кого**: бэкенд-разработчики, которые слышали «разбей монолит на микросервисы» и хотят понять, когда это нужно, а когда это ловушка.
>
> **Что внутри**: Монолит vs микросервисы, принципы проектирования, коммуникация, API design, Service Mesh, распределённые транзакции, data management, deployment, тестирование.

---

## Содержание

1. [Монолит → Микросервисы: когда и зачем](#1-монолит--микросервисы-когда-и-зачем)
2. [Принципы проектирования микросервисов](#2-принципы-проектирования-микросервисов)
3. [Коммуникация между сервисами](#3-коммуникация-между-сервисами)
4. [API Design для микросервисов](#4-api-design-для-микросервисов)
5. [Service Mesh](#5-service-mesh)
6. [Распределённые транзакции в микросервисах](#6-распределённые-транзакции-в-микросервисах)
7. [Data Management в микросервисах](#7-data-management-в-микросервисах)
8. [Deployment и DevOps](#8-deployment-и-devops)
9. [Testing микросервисов](#9-testing-микросервисов)

---

## 1. Монолит → Микросервисы: когда и зачем

### Монолит

Всё приложение развёртывается как единый процесс. Один репозиторий, одна кодовая база, один деплой.

```
┌─────────────────────────────────────────────────────┐
│                   MONOLITH PROCESS                  │
│                                                     │
│  ┌───────────┐  ┌───────────┐  ┌───────────────┐   │
│  │   Auth    │  │  Orders   │  │   Payments    │   │
│  │  Module   │  │  Module   │  │    Module     │   │
│  └─────┬─────┘  └─────┬─────┘  └──────┬────────┘   │
│        │              │               │             │
│  ┌─────▼──────────────▼───────────────▼────────┐    │
│  │            Shared Database (PostgreSQL)      │    │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

**Плюсы монолита:**

- **Простота разработки**: нет network overhead между модулями, вызов функции вместо HTTP-запроса.
- **Простота дебаггинга**: один процесс, один стек вызовов, одни логи. `grep` по логам — и вся цепочка перед глазами.
- **Атомарные транзакции**: `BEGIN` / `COMMIT` работают через весь флоу. Нет saga, нет compensating transactions.
- **Простой деплой**: один артефакт, один CI/CD pipeline, один сервер (или несколько с load balancer).
- **Дешевле на старте**: нет инфраструктурных накладных расходов (service discovery, message broker, distributed tracing).

**Минусы монолита при росте:**

- **Масштабирование**: нельзя масштабировать отдельный компонент. Если горит CPU в модуле отчётов — масштабируешь весь монолит, включая API, который и так справляется.
- **Деплой**: изменение в одном модуле требует деплоя всего приложения. Одна ошибка в неважном модуле — даунтайм для всех.
- **Coupling**: модули начинают знать друг о друге через прямые вызовы и общие таблицы. Со временем граница стирается.
- **Технологический стек**: вся команда на одном языке, одной версии фреймворка, одной версии Go.
- **Скорость разработки**: 50+ разработчиков в одном репозитории = merge conflicts, медленные CI-пайплайны, координация.

---

### Модульный монолит

Промежуточный вариант между монолитом и микросервисами. Один деплой, но чёткие границы между модулями внутри кодовой базы.

```
┌─────────────────────────────────────────────────────────────┐
│                   MODULAR MONOLITH                          │
│                                                             │
│  ┌─────────────────┐    ┌─────────────────┐                │
│  │  Orders Module  │    │ Payments Module │                │
│  │                 │    │                 │                │
│  │ - internal pkg  │    │ - internal pkg  │                │
│  │ - own DB schema │    │ - own DB schema │                │
│  │ - public API    │───>│ - public API    │                │
│  │   (interface)   │    │   (interface)   │                │
│  └─────────────────┘    └─────────────────┘                │
│                                                             │
│  Правило: модули общаются ТОЛЬКО через публичные           │
│  интерфейсы, никогда напрямую через БД.                    │
└─────────────────────────────────────────────────────────────┘
```

**Когда модульного монолита достаточно:**

- Команда < 20 человек.
- Продукт ещё ищет product-market fit.
- Разные части системы имеют схожие SLA и требования к масштабированию.
- Нет жёстких требований к независимому деплою разных частей.

Модульный монолит — это честный выбор, а не компромисс. Многие зрелые продукты намеренно остаются на нём.

---

### Микросервисы: когда действительно нужны

Микросервисы — это организационное решение, упакованное в техническую форму. Их истинная ценность — дать командам автономию.

**Признаки, что пора:**

1. **Команда > 10-15 разработчиков**, и масштабирование монолита создаёт координационные издержки.
2. **Разные части системы развиваются с разной скоростью**: Checkout меняется 10 раз в день, Invoicing — раз в квартал.
3. **Разные SLA**: Real-time notifications требуют latency < 100ms, а отчёты могут ждать 30 секунд.
4. **Разные требования к масштабированию**: Image Processing требует GPU, остальное — нет.
5. **Разные технологические стеки**: ML-пайплайн на Python, основной API на Go, старая интеграция на Java.
6. **Compliance и изоляция данных**: PCI DSS требует, чтобы данные карт были изолированы от остальной системы.

**Правило**: если команда < 10 человек и продукт на ранней стадии — монолит. Микросервисы увеличивают операционную сложность в 3-5 раз. Эта стоимость должна окупаться.

> Netflix, Amazon, Uber перешли на микросервисы при сотнях разработчиков и годах работы монолита. Стартапы, которые начинают с микросервисов, обычно платят слишком высокую цену слишком рано.

---

### Strangler Fig Pattern: пошаговая миграция

Strangler Fig — паттерн миграции из монолита, названный в честь дерева, которое постепенно окутывает и вытесняет дерево-хозяина.

**Шаг 1**: Поставить API Gateway или Facade перед монолитом. Весь трафик идёт через него.

```
Client → API Gateway → Monolith (100% трафика)
```

**Шаг 2**: Выделить первый сервис (начать с наименее связанного модуля).

```
Client → API Gateway → /payments/* → PaymentService (новый)
                    → /*          → Monolith (остальное)
```

**Шаг 3**: Постепенно переносить функциональность, маршрутизируя трафик от монолита к новым сервисам.

```
Client → API Gateway → /payments/* → PaymentService
                    → /orders/*   → OrderService
                    → /auth/*     → AuthService
                    → /*          → Monolith (legacy, уменьшается)
```

**Шаг 4**: Монолит становится пустым — удалить.

**Ключевые принципы при миграции:**
- Никогда не выделяй сервис и одновременно переписывай бизнес-логику. Сначала «вырезай» как есть, потом рефакторинг.
- Начинай с leaf services — те, от которых мало кто зависит.
- Синхронизируй данные через dual-write или Change Data Capture (CDC) в переходный период.

---

### Сравнительная таблица

| Критерий | Монолит | Модульный монолит | Микросервисы |
|---|---|---|---|
| **Сложность разработки** | Низкая | Средняя | Высокая |
| **Сложность деплоя** | Низкая | Низкая | Высокая |
| **Масштабирование** | Вертикальное (весь app) | Вертикальное (весь app) | Горизонтальное (per service) |
| **Отказоустойчивость** | Падает всё | Падает всё | Частичная деградация |
| **Размер команды** | 1-10 | 5-20 | 15+ |
| **Latency** | Минимальная (in-process) | Минимальная (in-process) | Выше (network) |
| **Транзакции** | ACID | ACID | Saga / Eventual consistency |
| **Дебаггинг** | Простой | Простой | Сложный (distributed tracing) |
| **Технологии** | Один стек | Один стек | Разные стеки |
| **Стоимость инфры** | Низкая | Низкая | Высокая |
| **Time to market (старт)** | Быстрый | Быстрый | Медленный |

---

## 2. Принципы проектирования микросервисов

### Single Responsibility и Bounded Context

Один микросервис = один Bounded Context из Domain-Driven Design (DDD).

**Bounded Context** — это граница, внутри которой термины и модели имеют однозначный смысл. Слово «Order» в контексте Ordering означает одно, в контексте Fulfillment — другое.

```
┌──────────────────────┐    ┌──────────────────────┐
│   Ordering Context   │    │  Fulfillment Context  │
│                      │    │                       │
│  Order:              │    │  Order:               │
│   - items            │    │   - warehouse_id      │
│   - total_price      │    │   - picker_id         │
│   - payment_method   │    │   - picking_status    │
│   - promo_code       │    │   - shipping_label    │
└──────────────────────┘    └──────────────────────┘
```

Один объект «Order» в двух контекстах — это два разных сервиса с разными моделями данных, даже если оба называются Order.

**Признаки правильно выделенного сервиса:**
- Можно описать его ответственность одним предложением без союза «и».
- Сервис деплоится и масштабируется независимо.
- Команда одного сервиса не должна координироваться с другими командами для деплоя.

**Признаки неправильно выделенного сервиса:**
- «UserService» отвечает за регистрацию, аутентификацию, профиль, настройки, нотификации и биллинг.
- Любое изменение в одном сервисе требует синхронного изменения в другом.
- Сервисы образуют цепочки синхронных вызовов: A → B → C → D.

---

### Loose Coupling / High Cohesion

**Loose Coupling**: сервисы знают о других как можно меньше. Взаимодействуют через стабильные контракты (API, события), не через внутренние детали реализации.

**High Cohesion**: внутри сервиса всё связанное находится вместе. Бизнес-логика, данные, API — в одном месте.

Нарушение coupling: `OrderService` напрямую читает таблицу `users` из `UserService`'s database. Теперь смена схемы `users` ломает `OrderService`.

Правильно: `OrderService` запрашивает нужные данные через API `UserService` или подписывается на события.

---

### Database per Service

Каждый сервис владеет своими данными и только сам имеет к ним доступ.

```
┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
│  OrderService    │    │  PaymentService  │    │  UserService     │
│                  │    │                  │    │                  │
│  ┌────────────┐  │    │  ┌────────────┐  │    │  ┌────────────┐  │
│  │ orders_db  │  │    │  │payments_db │  │    │  │  users_db  │  │
│  │ PostgreSQL │  │    │  │  MySQL     │  │    │  │  MongoDB   │  │
│  └────────────┘  │    │  └────────────┘  │    │  └────────────┘  │
└──────────────────┘    └──────────────────┘    └──────────────────┘
          │                      │                       │
          └──────────────────────┴───────────────────────┘
                    Общение ТОЛЬКО через API / Events
```

Даже если физически это одна PostgreSQL — у каждого сервиса отдельная схема (schema), и другие сервисы не имеют к ней прямого доступа.

---

### API as a Contract

API сервиса — это публичный контракт. Нарушение контракта = breaking change = сломанные клиенты.

**Backward compatibility**: новые клиенты работают со старыми версиями API.
**Forward compatibility**: старые клиенты работают с новыми версиями API.

Правила безопасных изменений:
- Добавление нового поля в ответ — безопасно.
- Добавление нового опционального поля в запрос — безопасно.
- Удаление поля — breaking change.
- Переименование поля — breaking change.
- Изменение типа поля — breaking change.

---

### Design for Failure

Каждый сетевой вызов может упасть. Сеть ненадёжна. Сервисы перезапускаются. Timeout — норма, а не исключение.

**Правило**: пиши код так, как будто любой вызов удалённого сервиса вернёт ошибку.

- Устанавливай явные `timeout` на каждый HTTP/gRPC-вызов.
- Реализуй retry с exponential backoff и jitter.
- Используй circuit breaker, чтобы не ждать таймаут от мёртвого сервиса.
- Реализуй fallback: что вернуть, если зависимость недоступна?

---

### Autonomy и Graceful Degradation

Сервис должен быть способен выполнять свою основную функцию, даже если некоторые зависимости недоступны.

**Пример**: `ProductService` возвращает карточки товаров. Зависимость — `ReviewService` для рейтингов.

- Плохо: если `ReviewService` недоступен, `ProductService` возвращает 500.
- Хорошо: если `ReviewService` недоступен, `ProductService` возвращает карточки без рейтингов (cached или null).

Graceful degradation = пользователь получает ухудшенный, но работающий сервис, а не ошибку.

---

## 3. Коммуникация между сервисами

### Синхронная коммуникация

Клиент отправляет запрос и **ждёт** ответа. Если сервис не отвечает — запрос завис.

**REST over HTTP/1.1**:
- Стандарт, понятен всем, легко дебажить через curl/Postman.
- JSON: читаемый, но медленный парсинг и большой размер payload.
- Подходит для внешних API и менее критичных внутренних вызовов.

**gRPC over HTTP/2**:
- Бинарный протокол (Protobuf): быстрее парсинг, меньше трафик.
- Multiplexing: несколько запросов через одно TCP-соединение.
- Streaming: server-side, client-side, bidirectional.
- Строгая типизация через `.proto` файлы — контракт зашит в код.
- Подходит для high-throughput внутренних вызовов, где важна производительность.

**Когда использовать синхронный вызов:**
- Нужен ответ прямо сейчас для продолжения операции.
- Пример: проверить баланс пользователя перед списанием.
- Пример: получить токен для аутентификации.
- Пример: валидация данных перед созданием заказа.

```
Checkout → InventoryService: "Есть товар X в количестве 2?"
         ← "Да, есть" (синхронно, без этого нельзя продолжить)
```

---

### Асинхронная коммуникация

Отправитель публикует сообщение в брокер и **не ждёт** ответа. Получатель обрабатывает в своём темпе.

**Kafka**: высокопроизводительный log-based брокер. Сообщения хранятся и могут быть перечитаны. Подходит для event streaming и аудит-трейла.

**NATS**: лёгкий, быстрый, sub-millisecond latency. JetStream добавляет persistence. Подходит для microservices messaging с низкой latency.

**RabbitMQ**: традиционный message queue с routing, exchanges, dead-letter queues. Подходит для сложной маршрутизации сообщений.

**Когда использовать асинхронный вызов:**
- Fire-and-forget: операция не требует ответа прямо сейчас.
- Long-running tasks: отправить email, сгенерировать отчёт, обработать изображение.
- Fanout: одно событие → много потребителей.
- Decoupling: публикатор не знает, кто подписан.

```
OrderService publishes: OrderCreated { order_id, user_id, items }
    ├── EmailService subscribes → отправляет подтверждение
    ├── InventoryService subscribes → резервирует товары
    └── AnalyticsService subscribes → обновляет метрики
```

---

### Request-Reply через Message Broker

Иногда нужен ответ, но через асинхронный канал. Паттерн: опубликовать сообщение с `reply_to` topic/queue, подписаться на него и ждать ответа с таймаутом.

```
Client publishes:
  Topic: "payments.process"
  Message: { request_id: "uuid", reply_to: "payments.reply.uuid", payload: {...} }

PaymentService processes and publishes:
  Topic: "payments.reply.uuid"
  Message: { request_id: "uuid", status: "ok", transaction_id: "..." }

Client receives on "payments.reply.uuid" (with timeout 5s)
```

Используется когда: нужна async обработка, но с гарантией получения результата; клиент не хочет поллить; нужно backpressure.

---

### Сравнительная таблица: Sync vs Async

| Критерий | Sync (REST/gRPC) | Async (Kafka/NATS) |
|---|---|---|
| **Latency** | Низкая (если сервис жив) | Выше (доставка через брокер) |
| **Coupling** | Высокое (знает об адресате) | Низкое (только topic/channel) |
| **Надёжность** | Ниже (падение = ошибка) | Выше (брокер буферизует) |
| **Доступность** | Зависит от зависимости | Независима от потребителя |
| **Debugging** | Проще (request-response) | Сложнее (async flow) |
| **Ordering** | N/A | Возможна (Kafka partition) |
| **Replay** | Нет | Есть (Kafka) |
| **Use case** | Валидация, запрос данных | Events, notifications, tasks |

---

## 4. API Design для микросервисов

### REST API: Versioning

**URL path versioning** (`/v1/orders`):
- Плюсы: явно видно в логах, cacheable, легко тестировать.
- Минусы: версия в URL выглядит «нечисто» с точки зрения REST.
- Рекомендация: используй для публичных API, где клиенты разные и обновляются независимо.

**Header versioning** (`Accept: application/vnd.api+json;version=1`):
- Плюсы: URL чище.
- Минусы: труднее тестировать, не cacheable by default, требует инфраструктуры.
- Рекомендация: внутренние API, где клиентов контролируешь.

**Практика**: выбери одну схему и держись её. URL-версионирование проще поддерживать.

---

### REST API: Pagination

**Offset-based:**
```
GET /v1/orders?offset=100&limit=20
```
Проблема: если вставить новую запись во время пагинации — пользователь пропустит или увидит дубликат. При большом offset база делает full scan.

**Cursor-based:**
```
GET /v1/orders?cursor=eyJpZCI6MTAwfQ&limit=20

Response:
{
  "data": [...],
  "next_cursor": "eyJpZCI6MTIwfQ",
  "has_more": true
}
```
Cursor — это encoded состояние (обычно ID или timestamp последнего элемента). База всегда делает эффективный range scan по индексу.

**Cursor лучше** для: реального времени (лента новостей), больших данных (> 10k записей), стабильной пагинации.

**Offset лучше** для: постраничной навигации («страница 5 из 20»), небольших данных, когда пользователи прыгают по страницам.

---

### REST API: Error Format (RFC 7807)

Стандарт Problem Details для HTTP API. Единый формат ошибок — клиентам не нужно угадывать структуру.

```json
{
  "type": "https://api.example.com/errors/insufficient-funds",
  "title": "Insufficient Funds",
  "status": 422,
  "detail": "Account balance is 50.00, required 100.00",
  "instance": "/v1/payments/tx-123",
  "extensions": {
    "balance": 50.00,
    "required": 100.00,
    "currency": "USD"
  }
}
```

Поля:
- `type`: URI, идентифицирующий тип ошибки (машиночитаемый).
- `title`: человекочитаемое название типа ошибки.
- `status`: HTTP status code.
- `detail`: конкретное описание для этого экземпляра ошибки.
- `instance`: URI конкретного запроса/ресурса.

---

### gRPC: Proto как контракт

```protobuf
syntax = "proto3";

package orders.v1;

option go_package = "github.com/example/orders/api/v1;ordersv1";

service OrderService {
  rpc CreateOrder(CreateOrderRequest) returns (CreateOrderResponse);
  rpc GetOrder(GetOrderRequest) returns (Order);
  rpc ListOrders(ListOrdersRequest) returns (stream Order);  // server-streaming
  rpc WatchOrders(WatchOrdersRequest) returns (stream OrderEvent); // server-streaming
}

message CreateOrderRequest {
  string user_id = 1;
  repeated OrderItem items = 2;
  string idempotency_key = 3;  // всегда добавляй для мутирующих операций
}

message OrderItem {
  string product_id = 1;
  int32 quantity = 2;
  // reserved 3;  // если удаляешь поле — резервируй номер
}
```

**Правила backward/forward compatibility:**
- Добавление нового поля — безопасно (старые клиенты игнорируют).
- Удаление поля — используй `reserved` для номера и имени.
- Никогда не меняй номер существующего поля.
- Никогда не меняй тип существующего поля.
- `optional` / `repeated` можно менять с осторожностью.

**Streaming: когда использовать:**
- **Server-streaming**: клиент запрашивает, сервер отдаёт поток (экспорт данных, live feed событий).
- **Client-streaming**: клиент загружает поток, сервер отвечает одним ответом (загрузка файла, batch insert).
- **Bidirectional**: чат, real-time collaboration, live telemetry.

---

### API Gateway: BFF Pattern

Backend for Frontend (BFF) — отдельный API Gateway для каждого типа клиента.

```
                        ┌──────────────┐
Mobile App ────────────>│  Mobile BFF  │
                        └──────┬───────┘
                               │
                        ┌──────┼──────────────────────┐
                        │      │                       │
Web App ───────────────>│  Web BFF                     │──> OrderService
                        │                              │──> UserService
                        │                              │──> ProductService
Admin Panel ───────────>│  Admin BFF                   │──> PaymentService
                        └──────────────────────────────┘
```

**Почему BFF, а не один API Gateway:**
- Mobile нужно меньше данных (медленная сеть, маленький экран) — BFF агрегирует и обрезает.
- Web нужно больше данных и более богатый API.
- Admin нужны endpoints, которые не должны быть доступны мобильным клиентам.
- Каждая frontend-команда контролирует свой BFF.

---

### Пример на Go: REST API с правильным error handling, pagination, versioning

```go
package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"time"
)

// --- Error types (RFC 7807) ---

type ProblemDetail struct {
	Type     string `json:"type"`
	Title    string `json:"title"`
	Status   int    `json:"status"`
	Detail   string `json:"detail,omitempty"`
	Instance string `json:"instance,omitempty"`
}

func (p ProblemDetail) Error() string { return p.Detail }

var (
	ErrNotFound = ProblemDetail{
		Type:  "https://api.example.com/errors/not-found",
		Title: "Resource Not Found",
	}
	ErrInvalidInput = ProblemDetail{
		Type:  "https://api.example.com/errors/invalid-input",
		Title: "Invalid Input",
	}
)

func writeProblem(w http.ResponseWriter, r *http.Request, pd ProblemDetail, status int, detail string) {
	pd.Status = status
	pd.Detail = detail
	pd.Instance = r.URL.Path

	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(pd)
}

// --- Pagination ---

type Cursor struct {
	ID        int64     `json:"id"`
	CreatedAt time.Time `json:"created_at"`
}

func encodeCursor(c Cursor) string {
	b, _ := json.Marshal(c)
	return base64.StdEncoding.EncodeToString(b)
}

func decodeCursor(s string) (Cursor, error) {
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return Cursor{}, fmt.Errorf("invalid cursor: %w", err)
	}
	var c Cursor
	if err := json.Unmarshal(b, &c); err != nil {
		return Cursor{}, fmt.Errorf("invalid cursor format: %w", err)
	}
	return c, nil
}

type PagedResponse[T any] struct {
	Data       []T    `json:"data"`
	NextCursor string `json:"next_cursor,omitempty"`
	HasMore    bool   `json:"has_more"`
	Total      *int64 `json:"total,omitempty"` // optional, expensive
}

// --- Order domain ---

type Order struct {
	ID        int64     `json:"id"`
	UserID    string    `json:"user_id"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
}

type OrderRepository interface {
	ListOrders(afterID int64, limit int) ([]Order, error)
	GetOrder(id int64) (*Order, error)
}

// --- Handler ---

type OrderHandler struct {
	repo   OrderRepository
	logger *slog.Logger
}

// GET /v1/orders?cursor=...&limit=20
func (h *OrderHandler) ListOrders(w http.ResponseWriter, r *http.Request) {
	const defaultLimit = 20
	const maxLimit = 100

	// Parse limit
	limit := defaultLimit
	if l := r.URL.Query().Get("limit"); l != "" {
		parsed, err := strconv.Atoi(l)
		if err != nil || parsed < 1 {
			writeProblem(w, r, ErrInvalidInput, http.StatusBadRequest,
				"limit must be a positive integer")
			return
		}
		if parsed > maxLimit {
			parsed = maxLimit
		}
		limit = parsed
	}

	// Parse cursor
	var afterID int64
	if c := r.URL.Query().Get("cursor"); c != "" {
		cursor, err := decodeCursor(c)
		if err != nil {
			writeProblem(w, r, ErrInvalidInput, http.StatusBadRequest,
				"invalid cursor value")
			return
		}
		afterID = cursor.ID
	}

	// Fetch limit+1 to determine hasMore
	orders, err := h.repo.ListOrders(afterID, limit+1)
	if err != nil {
		h.logger.Error("failed to list orders", "error", err)
		writeProblem(w, r, ProblemDetail{
			Type:  "https://api.example.com/errors/internal",
			Title: "Internal Server Error",
		}, http.StatusInternalServerError, "failed to retrieve orders")
		return
	}

	hasMore := len(orders) > limit
	if hasMore {
		orders = orders[:limit]
	}

	resp := PagedResponse[Order]{
		Data:    orders,
		HasMore: hasMore,
	}

	if hasMore && len(orders) > 0 {
		last := orders[len(orders)-1]
		resp.NextCursor = encodeCursor(Cursor{ID: last.ID, CreatedAt: last.CreatedAt})
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

// GET /v1/orders/{id}
func (h *OrderHandler) GetOrder(w http.ResponseWriter, r *http.Request) {
	idStr := r.PathValue("id") // Go 1.22+
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		writeProblem(w, r, ErrInvalidInput, http.StatusBadRequest,
			"order id must be an integer")
		return
	}

	order, err := h.repo.GetOrder(id)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			writeProblem(w, r, ErrNotFound, http.StatusNotFound,
				fmt.Sprintf("order %d not found", id))
			return
		}
		h.logger.Error("failed to get order", "id", id, "error", err)
		writeProblem(w, r, ProblemDetail{
			Type:  "https://api.example.com/errors/internal",
			Title: "Internal Server Error",
		}, http.StatusInternalServerError, "failed to retrieve order")
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(order)
}

func main() {
	mux := http.NewServeMux()
	handler := &OrderHandler{
		logger: slog.Default(),
	}

	// Versioned routes (Go 1.22+ routing)
	mux.HandleFunc("GET /v1/orders", handler.ListOrders)
	mux.HandleFunc("GET /v1/orders/{id}", handler.GetOrder)

	srv := &http.Server{
		Addr:         ":8080",
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	slog.Info("starting server", "addr", srv.Addr)
	if err := srv.ListenAndServe(); err != nil {
		slog.Error("server error", "error", err)
	}
}
```

---

## 5. Service Mesh

### Проблема

Каждый микросервис должен реализовать:
- Retry с exponential backoff
- Timeout management
- Circuit breaker
- mTLS (mutual TLS) для шифрования и аутентификации сервисов
- Distributed tracing (передача trace headers)
- Metrics (latency, error rate, throughput)
- Load balancing
- Canary deployments

Это повторяющийся cross-cutting concern. Каждая команда реализует его по-своему, тратит время, делает ошибки.

---

### Решение: Sidecar Proxy

Service Mesh выносит эти задачи в отдельный процесс — sidecar proxy — который запускается рядом с каждым сервисом.

```
┌─────────────────────────────────────────────────────────────────┐
│  Pod / VM                                                       │
│                                                                 │
│  ┌─────────────┐      ┌──────────────────┐                     │
│  │   Your App  │─────>│  Sidecar Proxy   │                     │
│  │  (Go, port  │      │  (Envoy, port    │──── network ────>   │
│  │   8080)     │<─────│   15001)         │                     │
│  └─────────────┘      └──────────────────┘                     │
│                                │                               │
│                                │ telemetry, config             │
│                                ▼                               │
│                         Control Plane                          │
└─────────────────────────────────────────────────────────────────┘
```

Приложение ничего не знает о retry, mTLS, трейсинге — сidecar делает это прозрачно.

---

### Istio

Самый популярный service mesh. Состоит из двух плоскостей:

**Data Plane**: Envoy proxies (sidecar в каждом Pod'е).
**Control Plane**: istiod — управляет конфигурацией всех Envoy.

```
                    ┌──────────────────┐
                    │     istiod       │
                    │  (Control Plane) │
                    │                  │
                    │  - Pilot         │  ← Traffic management
                    │  - Citadel       │  ← Certificate management (mTLS)
                    │  - Galley        │  ← Config validation
                    └────────┬─────────┘
                             │ xDS protocol (gRPC)
            ┌────────────────┼────────────────┐
            ▼                ▼                ▼
      ┌─────────┐      ┌─────────┐      ┌─────────┐
      │ Envoy   │      │ Envoy   │      │ Envoy   │
      │ sidecar │      │ sidecar │      │ sidecar │
      ├─────────┤      ├─────────┤      ├─────────┤
      │ Service │      │ Service │      │ Service │
      │    A    │      │    B    │      │    C    │
      └─────────┘      └─────────┘      └─────────┘
```

**Что даёт Istio:**

| Возможность | Описание |
|---|---|
| **Traffic management** | Routing, load balancing, circuit breaking, fault injection |
| **Observability** | Metrics, distributed tracing (Jaeger/Zipkin), access logs |
| **Security** | mTLS между сервисами, authorization policies |
| **Canary deployments** | Постепенный сдвиг трафика на новую версию |
| **Retries / Timeouts** | Конфигурируется в YAML, не в коде |

Пример Istio VirtualService для canary:

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: order-service
spec:
  hosts:
  - order-service
  http:
  - route:
    - destination:
        host: order-service
        subset: v1
      weight: 90
    - destination:
        host: order-service
        subset: v2   # canary
      weight: 10
```

---

### Linkerd

Лёгкая альтернатива Istio. Написан на Rust (proxy) и Go (control plane).

| | Istio | Linkerd |
|---|---|---|
| **Proxy** | Envoy (C++) | linkerd2-proxy (Rust) |
| **Потребление ресурсов** | Высокое (~200MB RAM/pod) | Низкое (~10MB RAM/pod) |
| **Сложность** | Высокая | Низкая |
| **Функциональность** | Полная | Базовая (достаточно для большинства) |
| **Протоколы** | HTTP/1, HTTP/2, gRPC, TCP | HTTP/1, HTTP/2, gRPC |

---

### Когда нужен Service Mesh, а когда нет

**Нужен:**
- > 20 сервисов в production.
- Нужна mTLS между сервисами (compliance, zero-trust network).
- Хочется canary deployments без изменения кода.
- Нужна observability без instrumentation кода.
- Зрелая Kubernetes-инфраструктура.

**Не нужен:**
- < 10 сервисов.
- Можно встроить retry, timeout, circuit breaker в код (библиотеки: `go-retryablehttp`, `gobreaker`).
- Service Mesh добавляет операционную сложность — нужна команда, которая умеет с ним работать.
- Latency overhead sidecar значим для вашего use case (обычно 1-5ms per hop).

---

## 6. Распределённые транзакции в микросервисах

Этот модуль намеренно краткий — подробное рассмотрение в [Модуле 07: Паттерны распределённых систем](../07-distributed-patterns/readme.md).

### Напоминание: почему 2PC плохо подходит

Two-Phase Commit требует, чтобы все участники транзакции были доступны и держали блокировки до завершения. В микросервисах это:
- Создаёт tight coupling между сервисами.
- При падении координатора — участники блокируются навечно.
- Высокая latency из-за двух round-trip и блокировок.

2PC допустим между двумя базами данных в одной сети, но не между независимыми HTTP-сервисами.

---

### Saga как стандартный подход

Saga — последовательность локальных транзакций, каждая из которых публикует событие или команду для следующего шага.

```
OrderSaga:
  1. OrderService: CreateOrder         → publishes OrderCreated
  2. PaymentService: ProcessPayment    → publishes PaymentProcessed
  3. InventoryService: ReserveItems    → publishes ItemsReserved
  4. ShippingService: ScheduleShipping → publishes ShippingScheduled
```

При ошибке на шаге N запускаются **compensating transactions** в обратном порядке:

```
InventoryService: FAIL → publishes ReservationFailed
  ← PaymentService compensates: RefundPayment
  ← OrderService compensates: CancelOrder
```

Два варианта координации:
- **Choreography**: каждый сервис реагирует на события напрямую. Проще, но сложнее отследить весь флоу.
- **Orchestration**: Saga Orchestrator управляет флоу, посылая команды. Легче дебажить, есть явная точка контроля.

Подробно с примерами на Go — в [Модуле 07](../07-distributed-patterns/readme.md#2-saga-pattern).

---

## 7. Data Management в микросервисах

### Database per Service: детали

Каждый сервис — единственный владелец своих данных. Другие сервисы могут получить данные только через API владельца.

```
┌─────────────────────────────────────────────────────────────────┐
│  Правила владения данными:                                      │
│                                                                 │
│  UserService       owns: users, user_preferences, auth_tokens   │
│  OrderService      owns: orders, order_items, order_status      │
│  PaymentService    owns: transactions, refunds, payment_methods │
│  ProductService    owns: products, categories, pricing          │
│                                                                 │
│  OrderService хочет email пользователя?                        │
│  → GET /v1/users/{user_id}/contact    (через API UserService)  │
│  → НЕ читать напрямую из users таблицы                        │
└─────────────────────────────────────────────────────────────────┘
```

---

### Проблема: Cross-Service Queries

**Сценарий**: нужно показать список заказов с именем пользователя и названием продукта. Данные в трёх разных базах.

**Решение 1: API Composition**

Aggregator-сервис (или BFF) собирает данные из нескольких сервисов и объединяет.

```go
func (h *Handler) GetOrderDetails(w http.ResponseWriter, r *http.Request) {
    orderID := r.PathValue("id")

    // Параллельные вызовы
    var order *Order
    var user *User
    var products []*Product

    g, ctx := errgroup.WithContext(r.Context())

    g.Go(func() error {
        var err error
        order, err = h.orderClient.GetOrder(ctx, orderID)
        return err
    })

    // После получения order — параллельно запрашиваем user и products
    if err := g.Wait(); err != nil {
        // handle error
        return
    }

    g2, ctx2 := errgroup.WithContext(r.Context())
    g2.Go(func() error {
        var err error
        user, err = h.userClient.GetUser(ctx2, order.UserID)
        return err
    })
    g2.Go(func() error {
        var err error
        products, err = h.productClient.GetProducts(ctx2, order.ProductIDs)
        return err
    })

    if err := g2.Wait(); err != nil {
        // handle error
        return
    }

    // Compose response
    resp := composeOrderDetails(order, user, products)
    json.NewEncoder(w).Encode(resp)
}
```

Плюсы: простота, нет дублирования данных.
Минусы: latency суммируется, N+1 запросов при листинге.

**Решение 2: CQRS + Materialized View**

Read Model (Query Side) строит денормализованное представление из событий разных сервисов.

```
Events:
  UserService    → UserCreated    { user_id, name, email }
  OrderService   → OrderCreated   { order_id, user_id, items }
  ProductService → ProductUpdated { product_id, name, price }

OrderReadModel (отдельный сервис/БД):
  Подписывается на все эти события и строит:

  orders_view:
    order_id | user_name | user_email | item_names | total
    ─────────────────────────────────────────────────────
    123      | John Doe  | j@ex.com   | [iPhone]   | 999.00
```

Плюсы: быстрые read-запросы, нет N+1.
Минусы: eventual consistency (данные могут быть чуть устаревшими), сложность поддержки.

---

### Shared Database Anti-Pattern

```
❌ ПЛОХО:

OrderService  ──┐
UserService   ──┼──> Shared Database
PaymentService──┘

Проблемы:
- Изменение схемы требует координации всех команд
- Сервисы coupling через таблицы
- Нельзя использовать разные СУБД для разных задач
- Schema migrations = deployment freeze для всех
```

Shared database — это замаскированный монолит. Если сервисы разделены, но база общая, все проблемы монолита остаются.

**Исключение**: в переходный период при миграции из монолита shared database временно допустима как промежуточный шаг. Важно — это временно, с планом миграции.

---

### Data Ownership: кто отвечает за что

| Данные | Владелец | Доступ для других |
|---|---|---|
| Users, profiles | UserService | GET /users/{id} |
| Auth tokens, sessions | AuthService | POST /auth/validate |
| Orders, order items | OrderService | GET /orders/{id} |
| Payments, refunds | PaymentService | GET /payments/{id} |
| Products, prices | ProductService | GET /products/{id}, bulk |
| Inventory levels | InventoryService | GET /inventory/{sku} |
| Email templates | NotificationService | Internal |

Правило: если несколько команд спорят, кто владеет данными — это сигнал к пересмотру границ сервисов (bounded context).

---

## 8. Deployment и DevOps

### Контейнеризация: Docker

Каждый микросервис — Docker-образ. Гарантирует идентичную среду от development до production.

```dockerfile
# Multi-stage build для минимального образа
FROM golang:1.23-alpine AS builder

WORKDIR /app

# Кешируем зависимости отдельным слоем
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o /bin/service ./cmd/service

# Final image
FROM scratch

COPY --from=builder /bin/service /service
# Если нужны TLS certs
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

EXPOSE 8080

ENTRYPOINT ["/service"]
```

`scratch` — пустой базовый образ. Итоговый размер образа: 5-15 MB против ~300MB для ubuntu-based.

---

### Kubernetes: основные концепции

```
Kubernetes Cluster
│
├── Node (VM или физический сервер)
│   ├── Pod (минимальная единица деплоя)
│   │   ├── Container (ваш сервис)
│   │   └── Container (sidecar, если нужен)
│   └── ...
│
├── Deployment (управляет репликами Pod'ов)
├── Service (стабильный DNS и IP для Pod'ов)
├── ConfigMap (конфиг без секретов)
├── Secret (секреты: пароли, токены, сертификаты)
├── Ingress (HTTP routing снаружи кластера)
└── HorizontalPodAutoscaler (автомасштабирование)
```

**Pod**: один или несколько контейнеров с общей сетью и storage. Pod — эфемерный, перезапускается при падении.

**Deployment**: декларирует желаемое состояние (3 реплики Pod'а). Kubernetes следит, чтобы реплик было столько, сколько нужно.

**Service**: стабильный endpoint (DNS-имя + ClusterIP) для набора Pod'ов. Балансирует трафик между Pod'ами.

**ConfigMap / Secret**: инъекция конфигурации в Pod через env variables или volume mount.

---

### Kubernetes YAML для Go-сервиса

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
  namespace: production
  labels:
    app: order-service
    version: v1.2.3
spec:
  replicas: 3
  selector:
    matchLabels:
      app: order-service
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1        # Максимум на 1 Pod больше во время обновления
      maxUnavailable: 0  # Всегда доступны все реплики
  template:
    metadata:
      labels:
        app: order-service
        version: v1.2.3
    spec:
      containers:
      - name: order-service
        image: registry.example.com/order-service:v1.2.3
        ports:
        - containerPort: 8080
          name: http
        - containerPort: 9090
          name: metrics
        env:
        - name: DB_HOST
          valueFrom:
            configMapKeyRef:
              name: order-service-config
              key: db_host
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: order-service-secrets
              key: db_password
        - name: LOG_LEVEL
          value: "info"
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "256Mi"
        # Liveness: перезапустить Pod если он завис
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
          failureThreshold: 3
        # Readiness: не слать трафик пока не готов
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 3
        # Graceful shutdown: дать время завершить текущие запросы
        lifecycle:
          preStop:
            exec:
              command: ["/bin/sleep", "5"]
      terminationGracePeriodSeconds: 30
---
# service.yaml
apiVersion: v1
kind: Service
metadata:
  name: order-service
  namespace: production
spec:
  selector:
    app: order-service
  ports:
  - name: http
    port: 80
    targetPort: 8080
  - name: metrics
    port: 9090
    targetPort: 9090
  type: ClusterIP  # Доступен только внутри кластера
---
# hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: order-service
  namespace: production
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: order-service
  minReplicas: 3
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```

Health endpoints в Go:

```go
// /healthz — liveness: жив ли процесс?
// Возвращает 200 пока процесс работает.
// НЕ проверяй здесь базу данных — если база упала, Pod не нужно рестартовать.
mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
    w.Write([]byte("ok"))
})

// /readyz — readiness: готов ли принимать трафик?
// Проверяет зависимости (БД, кеш).
// Если не готов — Kubernetes убирает Pod из балансировки.
mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
    if err := db.PingContext(r.Context()); err != nil {
        http.Error(w, "database unavailable", http.StatusServiceUnavailable)
        return
    }
    w.WriteHeader(http.StatusOK)
    w.Write([]byte("ok"))
})
```

---

### Deployment Strategies

**Rolling Update** (по умолчанию в Kubernetes):
```
v1 v1 v1 v1    →    v1 v1 v1 v2    →    v1 v1 v2 v2    →    v2 v2 v2 v2
```
- Постепенно заменяет старые Pod'ы новыми.
- Zero-downtime при правильных probe'ах.
- Сложно откатить если проблема обнаружена через несколько минут.

**Blue-Green**:
```
Blue (v1): 4 реплики — принимает трафик
Green (v2): 4 реплики — задеплоены, тестируются

Переключение: меняем selector в Service
Rollback: переключаем обратно (секунды)
```
- Мгновенный rollback.
- Требует двойных ресурсов.
- Хорошо для баз данных с миграциями (оба окружения должны работать с одной схемой).

**Canary**:
```
v1: 90% трафика
v2: 10% трафика (только subset пользователей)

Мониторинг: error rate, latency, бизнес-метрики
Если OK → постепенно увеличиваем % v2
Если плохо → откатываем 100% на v1
```
- Минимальный blast radius при проблеме.
- Требует service mesh или Ingress с весовой маршрутизацией.

---

### Feature Flags: Deploy ≠ Release

Deploy — технический акт помещения кода в production.
Release — бизнес-решение о том, кто видит новую функциональность.

```go
// Пример с LaunchDarkly / Unleash / самописным feature flag
func (h *Handler) CreateOrder(w http.ResponseWriter, r *http.Request) {
    userID := getUserID(r)

    // Новый алгоритм рекомендаций включён только для 5% пользователей
    if h.flags.IsEnabled("new-recommendation-engine", userID) {
        // новая логика
    } else {
        // старая логика
    }
}
```

**Преимущества:**
- Деплой без риска: код в production, но feature выключена.
- A/B тестирование: разные версии для разных групп пользователей.
- Kill switch: мгновенно выключить проблемный feature без деплоя.
- Постепенный rollout: 1% → 5% → 20% → 100%.

---

## 9. Testing микросервисов

### Пирамида тестирования для микросервисов

```
         ╱─────────────╲
        ╱    E2E Tests   ╲       ← Мало, только critical paths
       ╱─────────────────╲
      ╱   Contract Tests   ╲     ← Проверяем контракты API между сервисами
     ╱─────────────────────╲
    ╱  Integration Tests     ╲   ← Сервис + реальная БД/брокер (testcontainers)
   ╱──────────────────────────╲
  ╱      Unit Tests            ╲ ← Бизнес-логика, быстро, много
 ╱────────────────────────────────╲
```

---

### Unit Tests: бизнес-логика

Тестируем чистую бизнес-логику без внешних зависимостей. Зависимости — через интерфейсы.

```go
// domain/order.go
type Order struct {
    ID     string
    Items  []Item
    Status OrderStatus
}

func (o *Order) Cancel() error {
    if o.Status == StatusShipped {
        return errors.New("cannot cancel shipped order")
    }
    if o.Status == StatusCancelled {
        return errors.New("order already cancelled")
    }
    o.Status = StatusCancelled
    return nil
}

// domain/order_test.go
func TestOrder_Cancel(t *testing.T) {
    tests := []struct {
        name    string
        status  OrderStatus
        wantErr bool
    }{
        {"pending order can be cancelled", StatusPending, false},
        {"shipped order cannot be cancelled", StatusShipped, true},
        {"already cancelled order", StatusCancelled, true},
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            order := &Order{Status: tt.status}
            err := order.Cancel()
            if (err != nil) != tt.wantErr {
                t.Errorf("Cancel() error = %v, wantErr %v", err, tt.wantErr)
            }
        })
    }
}
```

---

### Integration Tests: с реальной БД (testcontainers)

Тестируем сервис с реальной базой данных в Docker-контейнере. Медленнее unit-тестов, но проверяют реальное поведение.

```go
// internal/repository/order_repo_test.go
package repository_test

import (
    "context"
    "testing"

    "github.com/testcontainers/testcontainers-go"
    "github.com/testcontainers/testcontainers-go/modules/postgres"
)

func TestOrderRepository_Integration(t *testing.T) {
    if testing.Short() {
        t.Skip("skipping integration test in short mode")
    }

    ctx := context.Background()

    // Поднимаем PostgreSQL в Docker
    pgContainer, err := postgres.RunContainer(ctx,
        testcontainers.WithImage("postgres:16-alpine"),
        postgres.WithDatabase("testdb"),
        postgres.WithUsername("test"),
        postgres.WithPassword("test"),
    )
    if err != nil {
        t.Fatalf("failed to start postgres: %v", err)
    }
    defer pgContainer.Terminate(ctx)

    connStr, err := pgContainer.ConnectionString(ctx, "sslmode=disable")
    if err != nil {
        t.Fatalf("failed to get connection string: %v", err)
    }

    // Применяем миграции
    db, err := openAndMigrate(connStr)
    if err != nil {
        t.Fatalf("failed to migrate: %v", err)
    }

    repo := NewOrderRepository(db)

    t.Run("create and retrieve order", func(t *testing.T) {
        order := &Order{
            UserID: "user-123",
            Status: StatusPending,
        }

        created, err := repo.CreateOrder(ctx, order)
        if err != nil {
            t.Fatalf("CreateOrder() error = %v", err)
        }
        if created.ID == "" {
            t.Error("expected non-empty ID")
        }

        retrieved, err := repo.GetOrder(ctx, created.ID)
        if err != nil {
            t.Fatalf("GetOrder() error = %v", err)
        }
        if retrieved.UserID != order.UserID {
            t.Errorf("UserID = %v, want %v", retrieved.UserID, order.UserID)
        }
    })
}
```

Запуск интеграционных тестов: `go test ./... -run Integration` или отдельный tag `//go:build integration`.

---

### Contract Tests: Pact

Contract tests проверяют, что потребитель и провайдер API согласны с контрактом. Если OrderService ожидает определённый формат от UserService — это фиксируется в pact-файле.

**Consumer (OrderService) определяет ожидания:**

```go
// consumer_test.go
func TestOrderService_GetUser_Contract(t *testing.T) {
    pact := dsl.Pact{
        Consumer: "OrderService",
        Provider: "UserService",
    }

    pact.AddInteraction().
        Given("user 123 exists").
        UponReceiving("a request for user 123").
        WithRequest(dsl.Request{
            Method: "GET",
            Path:   dsl.String("/v1/users/123"),
        }).
        WillRespondWith(dsl.Response{
            Status: 200,
            Body: dsl.Match(User{
                ID:    "123",
                Email: "test@example.com",
                Name:  "John Doe",
            }),
        })

    if err := pact.Verify(func() error {
        // Запускаем OrderService, который вызывает UserService
        client := NewUserClient(pact.Server.URL)
        user, err := client.GetUser(context.Background(), "123")
        if err != nil {
            return err
        }
        // Verify we got what we expected
        if user.ID != "123" {
            return fmt.Errorf("expected user ID 123, got %s", user.ID)
        }
        return nil
    }); err != nil {
        t.Fatalf("pact verification failed: %v", err)
    }
}
```

**Provider (UserService) верифицирует pact:**

```go
// provider_test.go
func TestUserService_Pact_Provider(t *testing.T) {
    pactVerify := provider.VerifyRequest{
        ProviderBaseURL:            "http://localhost:8080",
        BrokerURL:                  "https://pact-broker.example.com",
        ProviderName:               "UserService",
        PublishVerificationResults: true,
        ProviderVersion:            os.Getenv("GIT_COMMIT"),
    }

    if err := provider.VerifyProvider(t, pactVerify); err != nil {
        t.Fatalf("pact verification failed: %v", err)
    }
}
```

**protovalidate** — валидация proto-сообщений по правилам в `.proto` файле:

```protobuf
import "buf/validate/validate.proto";

message CreateOrderRequest {
  string user_id = 1 [(buf.validate.field).string.uuid = true];
  repeated OrderItem items = 2 [(buf.validate.field).repeated.min_items = 1];
  string idempotency_key = 3 [(buf.validate.field).string.len = 36];
}
```

---

### E2E Tests: только critical paths

E2E тесты проверяют полный флоу через все сервисы в staging-окружении. Медленные, хрупкие, дорогие в поддержке.

```
Critical paths для e2e:
  ✓ Пользователь регистрируется → получает email
  ✓ Пользователь создаёт заказ → платит → получает подтверждение
  ✓ Пользователь отменяет заказ → получает возврат

НЕ нужно покрывать e2e:
  ✗ Все edge cases (это для unit tests)
  ✗ Все комбинации параметров (это для integration tests)
  ✗ Performance (это для load tests)
```

Инструменты: `k6` для API, `Playwright` для UI, `pytest` с `requests` для API workflow.

---

### Сравнительная таблица типов тестов

| Тип | Скорость | Стоимость | Покрытие | Количество |
|---|---|---|---|---|
| **Unit** | < 1ms | Дёшево | Бизнес-логика | Много (100s) |
| **Integration** | 1-30s | Средне | Сервис + БД | Умеренно (10s) |
| **Contract** | 1-10s | Средне | API контракты | По одному на интеграцию |
| **E2E** | 30s-5min | Дорого | Critical paths | Мало (< 10) |

**Правило**: если что-то можно протестировать unit-тестом — тестируй unit-тестом. E2E тест — это страховка для самых важных флоу, не замена нижних уровней пирамиды.

---

## Итоги модуля

| Тема | Главный вывод |
|---|---|
| **Монолит vs Микросервисы** | Микросервисы — организационное решение. До 10 человек и product-market fit — монолит. |
| **Bounded Context** | Один сервис = один BC. Граница сервиса = граница команды. |
| **Коммуникация** | Sync (gRPC/REST) когда нужен ответ прямо сейчас. Async (Kafka/NATS) когда нет. |
| **API Design** | Cursor pagination. RFC 7807 ошибки. Версионирование в URL. |
| **Service Mesh** | Нужен после 20 сервисов. До этого — библиотеки в коде. |
| **Транзакции** | Saga + compensating transactions. 2PC — не для независимых HTTP-сервисов. |
| **Data Management** | Database per service. Shared database — anti-pattern. API Composition или CQRS для cross-service queries. |
| **Deployment** | Rolling update для стандартных деплоев. Blue-Green для критичных. Canary для рискованных. |
| **Testing** | Пирамида: много unit → умеренно integration → мало contract → единицы e2e. |

---

**Следующий модуль**: [Модуль 09: Observability](../09-observability/readme.md) — metrics, tracing, logging в распределённых системах.
