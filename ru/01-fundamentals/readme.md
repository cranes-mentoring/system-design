# Модуль 01: Основы System Design

> Этот модуль — фундамент курса. Здесь нет ни одного "просто запомни". Каждое понятие — с расчётом или примером, потому что в реальных проектах (и на интервью) вас спросят именно об этом.

---

## Содержание

1. [Что такое System Design и зачем он нужен](#1-что-такое-system-design-и-зачем-он-нужен)
2. [Фреймворк для подхода к проектированию](#2-фреймворк-для-подхода-к-проектированию)
3. [Оценка нагрузки (Back-of-the-envelope estimation)](#3-оценка-нагрузки-back-of-the-envelope-estimation)
4. [SLA, SLO, SLI — как измерять надёжность](#4-sla-slo-sli--как-измерять-надёжность)
5. [CAP теорема и PACELC](#5-cap-теорема-и-pacelc)
6. [Горизонтальное vs Вертикальное масштабирование](#6-горизонтальное-vs-вертикальное-масштабирование)

---

## 1. Что такое System Design и зачем он нужен

### Определение

System Design — это процесс проектирования архитектуры программной системы: как её компоненты взаимодействуют, как она выдерживает нагрузку, масштабируется под рост и остаётся надёжной при сбоях.

Если конкретнее: вы принимаете решения о том, какие базы данных использовать, как разбить систему на сервисы, где кэшировать, как обрабатывать отказы. Это не о синтаксисе языка и не о паттернах GoF — это о структуре системы на уровне инфраструктуры и компонентов.

### Low-Level Design (LLD) vs High-Level Design (HLD)

| Аспект | LLD | HLD |
|---|---|---|
| Фокус | Классы, модули, алгоритмы | Компоненты, сервисы, хранилища |
| Вопрос | "Как это реализовать?" | "Из чего это состоит?" |
| Артефакты | UML-диаграммы, псевдокод, API-методы | Архитектурные схемы, выбор БД, data flow |
| Пример | Структура класса `UserRepository`, SOLID | Схема "Frontend → API Gateway → сервисы → PostgreSQL + Redis" |
| Кто делает | Разработчик перед реализацией | Архитектор / senior-разработчик на этапе планирования |

Курс сфокусирован на HLD. LLD — отдельная дисциплина, хотя граница размытая: хороший system designer понимает оба уровня.

### Когда нужен System Design

**1. Техническое интервью на senior/staff уровень**

Начиная с уровня senior большинство компаний (Google, Meta, Amazon, Яндекс, Ozon, VK) проводят отдельный System Design Interview на 45–60 минут. Это не про алгоритмы — это про то, как вы думаете о системах под нагрузкой.

**2. Старт нового продукта или фичи**

Перед тем как писать первую строку кода в новом сервисе, нужно ответить: какова ожидаемая нагрузка? Какая БД подходит? Как сервис масштабируется? Если пропустить этот шаг, через 6 месяцев вы рефакторите архитектуру под давлением дедлайна.

**3. Рефакторинг перегруженного монолита**

Когда деплой занимает 40 минут, CI падает из-за непредвиденных зависимостей, а команда из 5 человек конфликтует на одном файле — это сигнал к декомпозиции. System design помогает спланировать разбиение: где провести границы, как организовать data ownership, как мигрировать без даунтайма.

**4. Миграция инфраструктуры**

MySQL → PostgreSQL, on-premise → cloud, монолит → микросервисы. Любая миграция требует понимания текущей архитектуры и целевого состояния, а также плана перехода без потери данных и доступности.

---

## 2. Фреймворк для подхода к проектированию

Без структуры system design-сессия превращается в хаотичный мозговой штурм. Нужен повторяемый процесс. Один из популярных фреймворков — **RESHADED**:

```
R — Requirements        (что система должна делать)
E — Estimation          (какая нагрузка ожидается)
S — Storage Design      (где и как хранить данные)
H — High-Level Design   (компоненты и их взаимодействие)
A — API Design          (контракты между компонентами)
D — Detailed Design     (глубина в критических путях)
E — Error Handling      (что происходит при сбоях)
D — Discussion          (trade-offs, масштабирование, альтернативы)
```

### Шаг 1: Requirements

Делим требования на два типа:

**Функциональные (Functional Requirements)** — что система должна делать:
- Пользователь может зарегистрироваться и войти
- Система отправляет email/push/SMS уведомления
- История уведомлений хранится 30 дней

**Нефункциональные (Non-Functional Requirements)** — как система должна это делать:
- Latency: уведомление доставлено за < 1 секунды
- Availability: 99.9% uptime
- Scalability: 10 млн пользователей, 100M уведомлений в день
- Durability: ни одно уведомление не теряется

На интервью всегда уточняйте scope. "Спроектируй Twitter" — слишком широко. Уточните: нужны ли DM? Trends? Рекламная система? Это влияет на весь дизайн.

### Шаг 2: Estimation

Считаем цифры до того, как рисовать компоненты. Без этого невозможно принять обоснованные решения о хранилищах и инфраструктуре.

Базовые вычисления:
- DAU (Daily Active Users) × действий на пользователя → события в день
- события в день / 86 400 → средний RPS
- средний RPS × 3–5 → peak RPS (нагрузка в часы пик)
- объём одного события × события в день × 365 × N лет → объём хранилища

Детальный пример — в разделе 3.

### Шаг 3: Storage Design

На основе estimation выбираем хранилища:

| Тип данных | Кандидаты |
|---|---|
| Структурированные транзакционные данные | PostgreSQL, MySQL |
| Документы, гибкая схема | MongoDB, Couchbase |
| High-throughput запись, wide column | Cassandra, ScyllaDB |
| Кэш, сессии | Redis, Memcached |
| Поиск по тексту | Elasticsearch, OpenSearch |
| Очереди, стриминг | Kafka, RabbitMQ, SQS |
| Объектное хранилище (медиа, бэкапы) | S3, GCS |
| Time-series метрики | InfluxDB, Prometheus + Thanos |

### Шаг 4: High-Level Design

Рисуем компоненты и стрелки между ними. На этом этапе — только крупные блоки, без деталей реализации.

```
Клиент → Load Balancer → API Gateway → [Auth Service]
                                    → [Notification Service] → Kafka → [Email Worker]
                                                                     → [Push Worker]
                                                                     → [SMS Worker]
                                    → [User Service] → PostgreSQL
```

### Шаг 5: API Design

Определяем контракты. REST, gRPC или GraphQL — обосновываем выбор.

```
POST /v1/notifications
{
  "user_id": "u_123",
  "type": "email" | "push" | "sms",
  "template_id": "order_shipped",
  "variables": {"order_id": "42", "eta": "2026-03-24"}
}

Response 202 Accepted
{
  "notification_id": "n_456",
  "status": "queued"
}
```

202 Accepted (а не 200 OK) — потому что уведомление отправляется асинхронно.

### Шаг 6: Detailed Design

Углубляемся в критические пути. Для сервиса уведомлений критичны:
- Гарантия доставки (at-least-once vs exactly-once)
- Retry logic при временных сбоях внешних провайдеров (SendGrid, Firebase)
- Rate limiting — нельзя отправлять 1000 email в секунду без риска попасть в спам

```
Notification Service
  ↓
Kafka (topic: notifications, retention: 7d)
  ↓
Email Worker
  ├── Читает из Kafka (consumer group)
  ├── Вызывает SendGrid API
  ├── При 5xx → exponential backoff retry (1s, 2s, 4s, 8s, max 3 retries)
  ├── При исчерпании retry → DLQ (Dead Letter Queue)
  └── Записывает статус в PostgreSQL (notification_logs)
```

### Шаг 7: Error Handling и Edge Cases

Вопросы, которые нужно задать системе:
- Что если Kafka недоступна? → буфер в памяти + алерт + graceful degradation
- Что если SendGrid вернул 429 (rate limit)? → backoff + retry с другого IP
- Что если пользователь отписался от уведомлений? → проверка перед отправкой, не после
- Что если то же уведомление обрабатывается дважды (сбой consumer)? → idempotency key

### Шаг 8: Discussion — Trade-offs

Каждое решение — компромисс. Хороший системный дизайнер не "знает правильный ответ", а умеет обосновать trade-offs:

| Решение | За | Против |
|---|---|---|
| Kafka вместо прямого вызова провайдера | Decoupling, retry, буферизация пиков | Сложность, latency +50–200ms |
| At-least-once delivery | Гарантия доставки | Дубли → нужна idempotency |
| Отдельный сервис для каждого канала | Независимый деплой, изоляция сбоев | Больше сервисов → операционная сложность |

---

### Полный проход RESHADED: сервис уведомлений

**Задача**: спроектировать систему уведомлений для e-commerce платформы с 5M DAU.

---

**R — Requirements**

Функциональные:
- Поддержка трёх каналов: email, push, SMS
- Триггер от внутренних сервисов (заказ оформлен, доставлен, отменён)
- Шаблоны с переменными
- История уведомлений — 90 дней
- Пользователь может отписаться от конкретного типа

Нефункциональные:
- Доставка уведомления: < 5 секунд с момента события
- Availability: 99.9%
- Нельзя терять уведомления
- Масштабируемость: до 50M DAU в 2 года

---

**E — Estimation**

- DAU: 5M
- Уведомлений на пользователя в день: ~3 (транзакционные)
- Всего уведомлений в день: 5M × 3 = 15M
- Средний RPS: 15M / 86 400 ≈ 174 RPS
- Пиковый RPS (утро + распродажи × 5): ~870 RPS
- Размер одного уведомления (метаданные + контент): ~2 KB
- Хранилище в день: 15M × 2 KB = 30 GB/день
- Хранилище за 90 дней: 30 GB × 90 = 2.7 TB

---

**S — Storage Design**

- PostgreSQL: пользователи, настройки подписок, шаблоны
- Cassandra: лог уведомлений (высокий write throughput, TTL 90 дней)
- Redis: кэш настроек пользователя (часто читаем, редко меняем)
- Kafka: очередь событий между сервисами

---

**H — High-Level Design**

```
[Order Service] ──→ Kafka (topic: order.events)
[Payment Service] ─→ Kafka
[Delivery Service]→ Kafka
                         ↓
                 [Notification Service]
                   ├── читает events
                   ├── проверяет preferences (Redis → PostgreSQL)
                   ├── рендерит шаблон
                   └── пишет в Kafka (topic: notifications.email / push / sms)
                         ↓
          ┌──────────────┼──────────────┐
   [Email Worker]  [Push Worker]  [SMS Worker]
       ↓                 ↓              ↓
   SendGrid         Firebase       Twilio/SMSC
       ↓                 ↓              ↓
              [Cassandra: notification_logs]
```

---

**A — API Design**

Внутренний API (вызывается другими сервисами):

```
POST /internal/v1/events
{
  "event_type": "order.shipped",
  "user_id": "u_123",
  "payload": {"order_id": "o_456", "tracking_url": "https://..."}
}
```

Пользовательский API:

```
GET  /v1/notifications?user_id=u_123&limit=20&cursor=...
PUT  /v1/notifications/preferences
{
  "email": true,
  "push": true,
  "sms": false
}
```

---

**D — Detailed Design (критический путь: Email Worker)**

```go
func (w *EmailWorker) ProcessMessage(msg kafka.Message) error {
    var notification Notification
    if err := json.Unmarshal(msg.Value, &notification); err != nil {
        return fmt.Errorf("unmarshal: %w", err)
    }

    // Idempotency check
    if sent, _ := w.store.IsSent(notification.ID); sent {
        return nil // уже отправлено, пропускаем
    }

    if err := w.sendWithRetry(notification); err != nil {
        w.dlq.Publish(notification) // в Dead Letter Queue
        return nil                  // не возвращаем ошибку — Kafka не будет retry
    }

    w.store.MarkSent(notification.ID)
    return nil
}

func (w *EmailWorker) sendWithRetry(n Notification) error {
    delays := []time.Duration{1, 2, 4, 8} // секунды
    for i, delay := range delays {
        err := w.provider.Send(n)
        if err == nil {
            return nil
        }
        if i < len(delays)-1 {
            time.Sleep(delay * time.Second)
        }
    }
    return fmt.Errorf("all retries exhausted for notification %s", n.ID)
}
```

---

**E — Error Handling**

| Сценарий | Обработка |
|---|---|
| Kafka недоступна | Notification Service буферизует в памяти (bounded queue), алерт, fallback на прямую запись |
| SendGrid 429 | Exponential backoff, смена IP/аккаунта |
| Дубль уведомления | Idempotency key = notification_id в Redis (TTL 24h) |
| Пользователь отписался | Проверка preferences до записи в Kafka, не в worker |

---

**D — Discussion**

Ключевой trade-off: **Kafka vs прямой вызов** провайдера.

Прямой вызов проще: Order Service → SendGrid. Но при пике (Black Friday 10× нагрузки) SendGrid начнёт возвращать 429, уведомления теряются. Kafka буферизует пик, workers обрабатывают в своём темпе. Цена: +100–300ms latency и операционная сложность.

Вывод: для транзакционных уведомлений — Kafka. Для критичных (2FA код) — прямой вызов + Kafka как fallback.

---

## 3. Оценка нагрузки (Back-of-the-envelope estimation)

Back-of-the-envelope estimation — это быстрые приблизительные вычисления, точность которых ±1 порядок величины. На интервью важна не точность до запятой, а демонстрация того, что вы понимаете масштаб и умеете с ним работать.

### Ключевые числа, которые нужно знать

#### Latency чисел (таблица Джефа Дина, актуализированная)

| Операция | Latency | Человекопонятно |
|---|---|---|
| L1 cache reference | ~1 ns | 1 секунда (условно) |
| L2 cache reference | ~4 ns | 4 секунды |
| Branch misprediction | ~5 ns | 5 секунд |
| L3 cache reference | ~10 ns | 10 секунд |
| Mutex lock/unlock | ~25 ns | 25 секунд |
| Main memory (RAM) reference | ~100 ns | 100 секунд |
| Compress 1KB with Snappy | ~3 µs | 50 минут |
| Read 1MB sequentially from RAM | ~10 µs | 2.5 часа |
| SSD random read (4KB) | ~100 µs | 11 дней |
| Read 1MB sequentially from SSD | ~1 ms | 4 месяца |
| Round trip в одном DC | ~0.5 ms | 2 месяца |
| HDD seek + read | ~10 ms | 3 года |
| Round trip между DC в одном регионе | ~10–30 ms | 10–30 лет |
| Round trip Москва–США | ~100–150 ms | 100+ лет |
| Reboot виртуальной машины | ~1–10 s | — |

> **Главный вывод**: разница между RAM и HDD — 5 порядков величины. Разница между L1 кэшем и сетью в датацентре — 6 порядков. Это и есть причина, почему кэширование так критично.

#### Пропускная способность (Throughput)

| Устройство/интерфейс | Throughput |
|---|---|
| HDD sequential read | ~150 MB/s |
| SSD sequential read | ~500 MB/s – 3 GB/s (NVMe) |
| NVMe SSD sequential read | 3–7 GB/s |
| RAM bandwidth | ~50 GB/s |
| Сеть: 1 Gbps Ethernet | 125 MB/s |
| Сеть: 10 Gbps Ethernet | 1.25 GB/s |
| Сеть: 100 Gbps (backbone) | 12.5 GB/s |

#### Типичные размеры объектов

| Объект | Размер |
|---|---|
| UUID (строка) | 36 байт |
| Целое число (int64) | 8 байт |
| Tweet (текст) | ~300 байт |
| Email (текст) | 1–10 KB |
| Веб-страница | ~100 KB |
| Аватар/миниатюра | 5–20 KB |
| Фото (JPEG, среднее) | 200 KB – 1 MB |
| Фото (RAW) | 15–30 MB |
| Видео (1 мин, 720p) | ~50 MB |
| Видео (1 мин, 1080p) | ~150 MB |
| Видео (1 мин, 4K) | ~400 MB |

#### Полезные константы времени

| Период | Секунды (приблизительно) |
|---|---|
| 1 минута | 60 с |
| 1 час | 3 600 с |
| 1 день | 86 400 с (~100K) |
| 1 месяц | 2.6M с |
| 1 год | 31.5M с (~30M) |

Подсказка: для estimation запомните **1 день ≈ 100K секунд**. Это упрощает вычисление RPS.

---

### Формула оценки нагрузки

```
RPS_avg = (DAU × actions_per_user) / 86_400
RPS_peak = RPS_avg × peak_factor   // peak_factor = 3–5 для consumer apps, 
                                    // до 10 для event-driven (распродажи)

Storage_year = events_per_day × event_size_bytes × 365
Storage_N_years = Storage_year × N × replication_factor

Bandwidth_ingress = RPS_avg × avg_request_size
Bandwidth_egress  = RPS_avg × avg_response_size × fan_out_factor
```

---

### Практический пример: мессенджер на 10M DAU

**Исходные данные:**
- DAU: 10 миллионов пользователей
- Среднее количество сообщений на пользователя в день: 40
- Средний размер сообщения: 100 байт (текст) + метаданные ~50 байт = 150 байт
- Медиа-сообщения: 10% от всех, средний размер: 500 KB
- Хранение истории: 5 лет
- Replication factor (для надёжности): 3

#### Шаг 1: Количество событий в день

```
Текстовых сообщений в день:
  10M × 40 × 0.9 = 360M сообщений

Медиа-сообщений в день:
  10M × 40 × 0.1 = 40M медиа-сообщений
```

#### Шаг 2: RPS

```
Средний RPS (только текст):
  360M / 86 400 ≈ 4 166 RPS ≈ ~4 200 RPS

Медиа upload RPS:
  40M / 86 400 ≈ 463 RPS

Пиковый RPS (×3 для мессенджера, пик — вечер):
  (4 200 + 463) × 3 ≈ 14 000 RPS
```

#### Шаг 3: Объём хранилища за год (текстовые сообщения)

```
Текст:
  360M сообщений/день × 150 байт = 54 GB/день
  54 GB × 365 = ~19.7 TB/год

С replication factor 3:
  19.7 TB × 3 = ~59 TB/год
```

#### Шаг 4: Объём хранилища за год (медиа)

```
Медиа:
  40M × 500 KB = 20 TB/день (!)
  20 TB × 365 = 7 300 TB/год = ~7.3 PB/год

С replication factor 3:
  ~22 PB/год

Вывод: медиа — узкое место. Решение: сжатие, CDN, удаление после 1 года для неактивных чатов.
```

#### Шаг 5: Bandwidth

```
Ingress (upload):
  Текст: 4 200 RPS × 150 байт ≈ 630 KB/s ≈ ~5 Mbps — незначительно
  Медиа: 463 RPS × 500 KB ≈ 232 MB/s ≈ ~1.85 Gbps — это уже серьёзно

Egress (доставка сообщений получателям):
  Каждое сообщение доставляется в среднем в 1 чат с 2+ участниками.
  Fan-out = 2 для P2P чатов, до 100+ для групп.
  Примем средний fan-out = 3:
  
  Текст egress: 4 200 × 3 × 150 байт ≈ 1.9 MB/s ≈ ~15 Mbps
  Медиа egress: 463 × 3 × 500 KB ≈ 695 MB/s ≈ ~5.5 Gbps
```

#### Итоговая сводка

| Метрика | Значение |
|---|---|
| DAU | 10M |
| Сообщений в день | 400M (360M текст + 40M медиа) |
| Средний RPS | ~4 700 |
| Пиковый RPS | ~14 000 |
| Хранилище (текст, 5 лет, ×3) | ~295 TB |
| Хранилище (медиа, 5 лет, ×3) | ~110 PB |
| Ingress bandwidth (медиа) | ~1.85 Gbps |
| Egress bandwidth (медиа) | ~5.5 Gbps |

**Выводы из estimation:**
1. Текстовые сообщения — не проблема. 14 000 RPS обрабатывается 5–10 инстансами сервиса.
2. Медиа — полностью другая история: нужен отдельный pipeline с S3-совместимым хранилищем, CDN и стратегией retention.
3. Egress bandwidth диктует необходимость CDN и geo-distributed хранилища.

---

## 4. SLA, SLO, SLI — как измерять надёжность

Надёжность — это не "система работает". Надёжность — это измеримая характеристика. Без чисел нет ответственности и нет способа узнать, стало ли лучше.

### SLI — Service Level Indicator

**SLI** — конкретная измеримая метрика производительности или надёжности системы.

Примеры SLI:
- **Availability**: `successful_requests / total_requests` (за 30-дневное окно)
- **Latency**: `p99 latency` — 99-й перцентиль времени ответа
- **Error rate**: `5xx_responses / total_responses`
- **Throughput**: количество обработанных запросов в секунду
- **Freshness**: время с момента последнего успешного обновления данных

Почему p99, а не среднее? Потому что среднее врёт. Если 99% запросов выполняются за 10ms, а 1% — за 10 секунд, среднее покажет ~110ms, но пользователь каждый сотый раз видит зависший интерфейс. Для систем с несколькими зависимостями p99 деградирует быстро:

```
Если сервис A имеет p99 = 100ms, а он вызывает сервисы B и C,
то итоговый p99 ≈ 100ms + 100ms + 100ms = 300ms (при последовательных вызовах)
```

### SLO — Service Level Objective

**SLO** — целевое значение SLI за определённый период.

Примеры SLO:
- `p99 latency < 200ms` (за скользящее 30-дневное окно)
- `availability ≥ 99.9%` (за календарный месяц)
- `error rate < 0.1%`

SLO — внутреннее обязательство команды перед собой. Нарушение SLO — это сигнал к действию, но не юридическая ответственность.

### SLA — Service Level Agreement

**SLA** — юридически обязывающее соглашение с внешними клиентами, основанное на SLO. Как правило, SLA чуть мягче SLO — это буфер:

```
SLO: availability ≥ 99.95%  (внутренняя цель команды)
SLA: availability ≥ 99.9%   (обязательство перед клиентом)
```

При нарушении SLA — компенсации, штрафы, расторжение контракта.

### Таблица "девяток" доступности

| SLA | Downtime в год | Downtime в месяц | Downtime в неделю |
|---|---|---|---|
| 90% (одна девятка) | 36.5 дней | 73 часа | 16.8 часа |
| 99% (две девятки) | 3.65 дней | 7.3 часа | 1.68 часа |
| 99.5% | 1.83 дня | 3.65 часа | 50.4 минуты |
| 99.9% (три девятки) | 8.76 часа | 43.8 минуты | 10.1 минуты |
| 99.95% | 4.38 часа | 21.9 минуты | 5 минут |
| 99.99% (четыре девятки) | 52.6 минуты | 4.38 минуты | 1 минута |
| 99.999% (пять девяток) | 5.26 минуты | 26.3 секунды | 6 секунд |

**Практическое следствие:**
- 99.9% — стандарт для большинства B2B SaaS
- 99.99% — требует автоматизированного failover, активно-активной топологии и серьёзных инвестиций в SRE
- 99.999% — уровень телефонии и финансовых транзакций; достигается ценой огромной операционной сложности

Не гонитесь за пятью девятками там, где достаточно трёх. Каждая девятка стоит непропорционально дороже предыдущей.

### Error Budget

**Error budget** — допустимый объём сбоев за период, производный от SLO.

```
Error budget = 1 - SLO

Если SLO = 99.9%:
  Error budget = 0.1% от времени = 0.1% × 43 200 мин/месяц = 43.2 минуты/месяц

Если SLO = 99.99%:
  Error budget = 0.01% × 43 200 = 4.32 минуты/месяц
```

Error budget — это инструмент баланса между скоростью разработки и надёжностью:

- Если error budget не исчерпан → команда может деплоить новые фичи, проводить эксперименты, рисковать
- Если error budget исчерпан → команда фокусируется исключительно на reliability, новые деплои замораживаются

```
Пример расчёта потреблённого error budget:

За месяц было 2 инцидента:
  Инцидент 1: 15 минут недоступности
  Инцидент 2: 20 минут деградации (50% запросов с ошибками)
             = 20 × 0.5 = 10 минут полного эквивалента

Потреблено: 15 + 10 = 25 минут
Доступный budget (при SLO 99.9%): 43.2 минуты
Остаток: 43.2 - 25 = 18.2 минуты (42% остаток) → можно продолжать деплои
```

### Как измерять SLI на практике (Go пример)

```go
package metrics

import (
    "time"
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
)

var (
    httpRequestsTotal = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "http_requests_total",
            Help: "Total HTTP requests by status class",
        },
        []string{"method", "path", "status_class"},
    )
    
    httpRequestDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "http_request_duration_seconds",
            Help:    "HTTP request duration in seconds",
            Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.5, 1.0, 2.5},
        },
        []string{"method", "path"},
    )
)

func Middleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        rw := &responseWriter{ResponseWriter: w, statusCode: 200}
        
        next.ServeHTTP(rw, r)
        
        duration := time.Since(start).Seconds()
        statusClass := fmt.Sprintf("%dxx", rw.statusCode/100)
        
        httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, statusClass).Inc()
        httpRequestDuration.WithLabelValues(r.Method, r.URL.Path).Observe(duration)
    })
}
```

В Prometheus запрос для SLI availability:

```promql
# Availability за последние 30 дней
(
  sum(rate(http_requests_total{status_class!="5xx"}[30d]))
  /
  sum(rate(http_requests_total[30d]))
) * 100

# p99 latency за последние 5 минут
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
)
```

---

## 5. CAP теорема и PACELC

### CAP теорема

Теорема CAP (Brewer's theorem, 2000) утверждает: распределённая система не может одновременно гарантировать все три свойства:

```
        C — Consistency
       / \
      /   \
     /     \
    A ——————P
Availability  Partition
              Tolerance
```

**C — Consistency (Согласованность)**
Каждый read получает самую актуальную запись или ошибку. После successful write все последующие reads на любом узле вернут записанное значение.

*Пример*: вы перевели деньги — любой узел системы должен немедленно показывать новый баланс.

**A — Availability (Доступность)**
Каждый запрос получает ответ (не обязательно самый свежий). Система никогда не возвращает ошибку из-за недоступности данных.

*Пример*: DNS — вы всегда получаете ответ, хотя он может быть устаревшим (кэш не обновился).

**P — Partition Tolerance (Устойчивость к разделению сети)**
Система продолжает работать при потере или задержке сетевых сообщений между узлами.

### Почему P всегда есть

В распределённой системе из 2+ узлов network partition неизбежен. Сети падают, пакеты теряются, дата-центры изолируются. Отказаться от P означает отказаться от распределённости как таковой.

Поэтому реальный выбор: **CP или AP** при наступлении partition.

```
CP (Consistency + Partition Tolerance):
  При разделении сети → система отказывает в ответе (ошибка или timeout)
  вместо того чтобы вернуть устаревшие данные.
  
  Примеры: ZooKeeper, etcd, HBase, MongoDB (с write concern majority)
  Когда нужен: финансовые транзакции, distributed locks, конфигурация

AP (Availability + Partition Tolerance):
  При разделении сети → система возвращает возможно устаревшие данные.
  
  Примеры: Cassandra, DynamoDB (по умолчанию), CouchDB, DNS
  Когда нужен: социальные фиды, корзина покупок, счётчики просмотров
```

### Примеры СУБД и их CAP-позиция

| База данных | CAP-тип | Поведение при partition |
|---|---|---|
| PostgreSQL (single node) | CA* | Нет partition (один узел) |
| PostgreSQL (streaming replication) | CP | Replica lag → читаем устаревшие данные или блокируемся |
| MongoDB | CP (настраиваемый) | Majority write concern → отказ при потере кворума |
| Cassandra | AP | Всегда доступна, eventual consistency |
| DynamoDB | AP (по умолчанию) / CP | Eventually consistent reads / strongly consistent reads |
| Redis (Cluster) | AP | Возможна потеря данных при failover |
| etcd / ZooKeeper | CP | Отказывает при потере кворума (Raft/ZAB) |
| HBase | CP | HDFS + ZooKeeper → жёсткая consistency |
| CouchDB | AP | Multi-master, eventual consistency, conflict resolution |

> *CA без P возможен только для одноузловых систем — то есть не распределённых.

### PACELC теорема

CAP описывает поведение только при partition. Но что происходит в **нормальном режиме** (без partition)? Это и есть расширение PACELC (Daniel Abadi, 2010):

```
If Partition:
  → выбор между Availability и Consistency (как в CAP)
Else (нет partition):
  → выбор между Latency и Consistency
```

```
PACELC = PAC + ELC

P: Partition
A: Availability
C: Consistency
E: Else (no partition)
L: Latency
C: Consistency
```

**Почему Latency vs Consistency при нормальной работе?**

Чтобы гарантировать consistency при записи в реплицированной системе, нужно дождаться подтверждения от нескольких узлов (quorum write). Это добавляет latency. Если выбираем low latency — пишем асинхронно, теряем strong consistency.

```
Cassandra: PA/EL — высокая доступность при partition, низкая latency при нормальной работе
DynamoDB: PA/EL — аналогично (по умолчанию)
PostgreSQL synchronous_commit=on: PC/EC — consistency важнее latency
Spanner (Google): PC/EC — strong consistency глобально, но ценой latency
MongoDB: PC/EC — при majority read/write
```

### PACELC: расширенная таблица

| Система | При partition | При нормальной работе | Классификация |
|---|---|---|---|
| Cassandra | Availability | Latency | PA/EL |
| DynamoDB (default) | Availability | Latency | PA/EL |
| Riak | Availability | Latency | PA/EL |
| PostgreSQL | Consistency | Consistency | PC/EC |
| MySQL (с semi-sync) | Consistency | Consistency | PC/EC |
| Google Spanner | Consistency | Consistency | PC/EC |
| MongoDB | Configurable | Configurable | PA/EL или PC/EC |
| DynamoDB (strong) | Consistency | Consistency | PC/EC |

### Практический выбор

```
Финансовые операции, переводы, инвентарь → CP / PC/EC
  Использовать: PostgreSQL, Spanner, CockroachDB

Социальный фид, лайки, счётчики → AP / PA/EL
  Использовать: Cassandra, DynamoDB

Сессии пользователей, корзина → AP (eventual consistency OK)
  Использовать: DynamoDB, Redis

Distributed coordination (leader election, locks) → CP
  Использовать: etcd, ZooKeeper
```

---

## 6. Горизонтальное vs Вертикальное масштабирование

### Vertical Scaling (Scale Up)

Добавляем ресурсы к существующему инстансу: больше CPU, RAM, быстрее диски.

```
До:  [Server: 4 CPU, 16 GB RAM]
После: [Server: 32 CPU, 256 GB RAM]
```

**Плюсы:**
- Простота: не нужно менять архитектуру приложения
- Нет проблем с distributed state
- Нет network overhead между нодами
- Транзакции и ACID "из коробки"

**Минусы:**
- Физический потолок: максимальный сервер в cloud — 192 vCPU, 24 TB RAM (AWS u-24tb1.metal)
- Единая точка отказа: падает один сервер — падает всё
- Масштабирование требует downtime (перезапуск инстанса)
- Непропорциональная стоимость: сервер ×8 по ресурсам стоит >×8 по цене

**Когда использовать vertical scaling:**
- База данных до определённого размера (PostgreSQL отлично работает на мощном сервере)
- ML-модели, которые не параллелятся без усилий
- Legacy системы, которые нельзя запустить в нескольких экземплярах
- Быстрое временное решение до архитектурного рефакторинга

### Horizontal Scaling (Scale Out)

Добавляем новые инстансы и распределяем нагрузку между ними.

```
До:  [Server A]

После: [Load Balancer]
          ├── [Server A]
          ├── [Server B]
          └── [Server C]
```

**Плюсы:**
- Теоретически неограниченное масштабирование
- Отказоустойчивость: при падении одного инстанса остальные берут нагрузку
- Обновления без downtime (rolling deploy)
- Линейная стоимость (3 сервера ×3 по ресурсам = ×3 по цене)

**Минусы:**
- Stateful приложения масштабировать сложно (нужны внешний кэш, sticky sessions или stateless архитектура)
- Network latency между инстансами
- Распределённые транзакции — головная боль
- Операционная сложность: нужны load balancer, service discovery, мониторинг каждого инстанса

**Когда использовать horizontal scaling:**
- Stateless сервисы (API серверы, обработчики задач)
- Когда нагрузка непредсказуема и нужен autoscaling
- Когда требуется high availability (несколько AZ)

### Практический критерий выбора

```
Шаг 1: Определите, является ли сервис stateless.
  Stateless (не хранит состояние между запросами) → горизонтальное масштабирование
  Stateful (сессии, in-memory state) → или выносим state во внешнее хранилище, 
                                       или вертикальное масштабирование

Шаг 2: Оцените нагрузку.
  Пиковый RPS × avg_request_duration_ms < 1000 ms и 1 инстанс справляется
  → вертикальное (проще и дешевле)
  Иначе → горизонтальное

Шаг 3: Требования к availability.
  99.99% и выше → горизонтальное (несколько AZ, нет единой точки отказа)
```

### Пример: stateless Go-сервис для горизонтального масштабирования

Ключевое требование для горизонтального масштабирования: **никакого локального состояния, которое нужно другим инстансам**.

```go
package main

import (
    "context"
    "encoding/json"
    "log"
    "net/http"
    "os"
    "time"
    
    "github.com/redis/go-redis/v9"
)

// Плохо: состояние в памяти процесса
// var sessions = map[string]Session{} // при горизонтальном масштабировании
                                       // каждый инстанс имеет свой map → проблемы

// Хорошо: состояние во внешнем хранилище
type SessionStore struct {
    rdb *redis.Client
}

func NewSessionStore() *SessionStore {
    rdb := redis.NewClient(&redis.Options{
        Addr: os.Getenv("REDIS_ADDR"), // redis:6379
    })
    return &SessionStore{rdb: rdb}
}

func (s *SessionStore) Get(ctx context.Context, sessionID string) (*Session, error) {
    val, err := s.rdb.Get(ctx, "session:"+sessionID).Result()
    if err == redis.Nil {
        return nil, nil // сессия не найдена
    }
    if err != nil {
        return nil, err
    }
    
    var session Session
    if err := json.Unmarshal([]byte(val), &session); err != nil {
        return nil, err
    }
    return &session, nil
}

func (s *SessionStore) Set(ctx context.Context, sessionID string, session *Session) error {
    data, err := json.Marshal(session)
    if err != nil {
        return err
    }
    return s.rdb.Set(ctx, "session:"+sessionID, data, 24*time.Hour).Err()
}

type Session struct {
    UserID    string    `json:"user_id"`
    CreatedAt time.Time `json:"created_at"`
    ExpiresAt time.Time `json:"expires_at"`
}

type Handler struct {
    sessions *SessionStore
    db       *Database // абстракция над PostgreSQL
}

// Этот handler полностью stateless:
// - не хранит ничего между запросами в памяти
// - всё состояние — в Redis и PostgreSQL
// - можно запустить 100 инстансов за load balancer

func (h *Handler) GetProfile(w http.ResponseWriter, r *http.Request) {
    sessionID := r.Header.Get("X-Session-ID")
    if sessionID == "" {
        http.Error(w, "unauthorized", http.StatusUnauthorized)
        return
    }
    
    session, err := h.sessions.Get(r.Context(), sessionID)
    if err != nil || session == nil {
        http.Error(w, "session not found", http.StatusUnauthorized)
        return
    }
    
    if time.Now().After(session.ExpiresAt) {
        http.Error(w, "session expired", http.StatusUnauthorized)
        return
    }
    
    user, err := h.db.GetUser(r.Context(), session.UserID)
    if err != nil {
        http.Error(w, "internal error", http.StatusInternalServerError)
        return
    }
    
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(user)
}

func main() {
    store := NewSessionStore()
    db := NewDatabase(os.Getenv("DATABASE_URL"))
    
    handler := &Handler{sessions: store, db: db}
    
    mux := http.NewServeMux()
    mux.HandleFunc("/profile", handler.GetProfile)
    
    // Этот сервис можно запустить на любом количестве машин.
    // Load balancer (nginx, AWS ALB) распределяет трафик round-robin.
    // Каждый инстанс идентичен — нет sticky sessions, нет shared memory.
    
    port := os.Getenv("PORT")
    if port == "" {
        port = "8080"
    }
    
    log.Printf("Starting server on :%s", port)
    if err := http.ListenAndServe(":"+port, mux); err != nil {
        log.Fatal(err)
    }
}
```

### Autoscaling: горизонтальное масштабирование в реальности

Преимущество stateless сервисов — автоматическое масштабирование под нагрузку:

```yaml
# Kubernetes HorizontalPodAutoscaler
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: profile-service
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: profile-service
  minReplicas: 2   # минимум для HA
  maxReplicas: 50  # максимум для защиты БД от перегрузки
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70  # при CPU > 70% → добавляем поды
    - type: Pods
      pods:
        metric:
          name: http_requests_per_second  # custom metric из Prometheus
        target:
          type: AverageValue
          averageValue: "1000"  # 1000 RPS на под → добавляем
```

### Сравнение стратегий масштабирования

| Критерий | Vertical (Scale Up) | Horizontal (Scale Out) |
|---|---|---|
| Сложность реализации | Низкая | Высокая |
| Сложность операций | Низкая | Высокая |
| Предел масштабирования | Физический потолок | Теоретически ∞ |
| Стоимость | Нелинейно растёт | Линейно растёт |
| Downtime при масштабировании | Обычно нужен | Не нужен (rolling update) |
| Отказоустойчивость | Низкая (SPOF) | Высокая (N-1 redundancy) |
| Latency | Нет overhead | +network overhead |
| Stateful системы | Работает | Требует refactoring |
| Подходит для | БД, ML, legacy | API, workers, stateless |

---

## Итого: что нужно помнить из этого модуля

1. **System Design — это trade-offs**, а не правильные ответы. Умение обосновать выбор важнее самого выбора.

2. **Estimation — основа всего**. Без чисел нельзя обоснованно выбрать хранилище, определить нужную инфраструктуру, оценить стоимость.

3. **Надёжность измеряется через SLI/SLO/SLA**. Error budget — это инструмент баланса между скоростью разработки и стабильностью.

4. **CAP: реальный выбор — CP или AP**. P убрать нельзя. PACELC добавляет ещё одно измерение: Latency vs Consistency в нормальной работе.

5. **Stateless — это не опция, это требование** для горизонтального масштабирования. Всё состояние — в Redis, PostgreSQL, Cassandra, но не в памяти процесса.

6. **Вертикальное масштабирование — это временное решение**, горизонтальное — архитектурное. Начинать можно с вертикального, но проектировать нужно с учётом горизонтального.

---

## Дополнительные материалы

- [Designing Data-Intensive Applications](https://dataintensive.net/) — Мартин Клеппманн. Обязательное чтение для понимания Главы 5 (репликация) и Главы 9 (consistency и consensus).
- [Google SRE Book](https://sre.google/sre-book/table-of-contents/) — главы о SLI/SLO/SLA и error budgets. Бесплатно онлайн.
- [The System Design Primer](https://github.com/donnemartin/system-design-primer) — обширный репозиторий с примерами дизайнов реальных систем.
- [Latency Numbers Every Programmer Should Know](https://github.com/sirupsen/napkin-math) — актуализированная версия таблицы Джефа Дина с расчётами.
- [PACELC теорема (Abadi, 2012)](https://www.cs.umd.edu/~abadi/papers/abadi-pacelc.pdf) — оригинальная статья.

---

*Следующий модуль: [02 — Балансировка нагрузки и API Gateway](../02-load-balancing/readme.md)*
