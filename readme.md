# System Design Course

Полный курс по проектированию высоконагруженных систем для бэкенд-разработчиков.  
Примеры кода на Go. Написан практиками для практиков.

> 🇷🇺 [Русская версия](ru/) | 🇬🇧 [English version](eng/)

---

## Для кого

- Бэкенд-разработчики с опытом 2+ лет
- Готовящиеся к System Design интервью
- Тимлиды, проектирующие архитектуру новых сервисов

## Что внутри

12 модулей — от основ до практических кейсов. Каждый модуль содержит теорию, ASCII-диаграммы, таблицы сравнений, примеры кода на Go и ссылки на дополнительные материалы.

---

## 📋 Программа курса

### Основы
| # | Модуль | Ключевые темы |
|---|--------|---------------|
| 01 | [Основы System Design](ru/01-fundamentals/) | Фреймворк RESHADED, back-of-the-envelope estimation, CAP/PACELC, SLA/SLO/SLI |
| 02 | [Сеть и протоколы](ru/02-networking/) | DNS, HTTP/2/3, REST vs gRPC vs GraphQL, Load Balancing, API Gateway, Service Discovery |

### Данные
| # | Модуль | Ключевые темы |
|---|--------|---------------|
| 03 | [Базы данных](ru/03-databases/) | PostgreSQL, индексы (B-tree, GIN, GiST), транзакции, изоляции, MVCC, SQL vs NoSQL |
| 04 | [Масштабирование данных](ru/04-scaling-data/) | Репликация, партиционирование, шардинг, consistent hashing, CDC, multi-region |
| 05 | [Кеширование](ru/05-caching/) | Cache-aside, write-through, Redis, CDN, cache stampede, инвалидация |

### Архитектура
| # | Модуль | Ключевые темы |
|---|--------|---------------|
| 06 | [Очереди и async](ru/06-message-queues/) | Kafka deep dive, NATS JetStream, RabbitMQ, event-driven architecture |
| 07 | [Паттерны распределённых систем](ru/07-distributed-patterns/) | Saga, Outbox, CQRS, Event Sourcing, Raft, distributed locks |
| 08 | [Микросервисы](ru/08-microservices/) | Монолит → микросервисы, API design, service mesh, deployment strategies |

### Эксплуатация
| # | Модуль | Ключевые темы |
|---|--------|---------------|
| 09 | [Наблюдаемость](ru/09-observability/) | Логи (slog), метрики (Prometheus), трейсинг (OpenTelemetry), incident management |
| 10 | [Надёжность](ru/10-reliability/) | Circuit breaker, retry, rate limiting, load shedding, chaos engineering, DR |
| 11 | [Безопасность](ru/11-security/) | JWT, OAuth 2.0, RBAC/ABAC, mTLS, OWASP Top 10, secrets management, Zero Trust |

### Практика
| # | Модуль | Ключевые темы |
|---|--------|---------------|
| 12 | [Практические кейсы](ru/12-practice-cases/) | URL Shortener, Мессенджер, News Feed, Rate Limiter, Notification Service, Task Scheduler |

---

## 🛠 Технологии

- **Язык**: Go
- **Базы данных**: PostgreSQL, Redis, Cassandra, MongoDB, ClickHouse
- **Message Brokers**: Kafka, NATS, RabbitMQ
- **Observability**: Prometheus, Grafana, OpenTelemetry, Jaeger
- **Infrastructure**: Docker, Kubernetes, Istio

## 📚 Рекомендуемые книги

- *Designing Data-Intensive Applications* — Martin Kleppmann
- *System Design Interview* (Vol. 1 & 2) — Alex Xu
- *Building Microservices* — Sam Newman
- *Site Reliability Engineering* — Google
- *Database Internals* — Alex Petrov

---

## Contributing

Нашли ошибку или хотите дополнить? Открывайте Issue или Pull Request.

## License

MIT
