# Модуль 11: Безопасность

Безопасность — не фича, которую добавляют в конце. Это сквозное свойство системы. Один пропущенный SQL injection или утёкший AWS key может стоить компании миллионы. Этот модуль охватывает практические аспекты безопасности, с которыми сталкивается каждый бэкенд-разработчик.

---

## Содержание

1. [Authentication vs Authorization](#1-authentication-vs-authorization)
2. [Аутентификация](#2-аутентификация)
3. [Авторизация](#3-авторизация)
4. [Шифрование](#4-шифрование)
5. [OWASP Top 10 для разработчиков](#5-owasp-top-10-для-разработчиков)
6. [Secrets Management](#6-secrets-management)
7. [Zero Trust Architecture](#7-zero-trust-architecture)
8. [DDoS Protection и Web Application Firewall](#8-ddos-protection-и-web-application-firewall)

---

## 1. Authentication vs Authorization

Два термина, которые постоянно путают — даже опытные разработчики. Разберём раз и навсегда.

| Понятие | Вопрос | Пример |
|---|---|---|
| **Authentication (AuthN)** | *Кто ты?* | Проверка логина/пароля, JWT-токена, API key |
| **Authorization (AuthZ)** | *Что тебе можно?* | Проверка, может ли пользователь удалить ресурс |

**AuthN всегда предшествует AuthZ.** Нельзя проверить права непонятно кого.

### Поток запроса

```
HTTP Request
     │
     ▼
┌─────────────────────────────────────────────────────────┐
│                    API Gateway / Middleware              │
│                                                         │
│  ┌──────────────┐    ┌──────────────┐    ┌───────────┐  │
│  │    AuthN     │───▶│    AuthZ     │───▶│  Handler  │  │
│  │              │    │              │    │           │  │
│  │ Кто ты?      │    │ Что можно?   │    │ Бизнес-   │  │
│  │              │    │              │    │ логика    │  │
│  │ - JWT валид? │    │ - RBAC?      │    │           │  │
│  │ - Session?   │    │ - ABAC?      │    │           │  │
│  │ - API key?   │    │ - Policy?    │    │           │  │
│  └──────┬───────┘    └──────┬───────┘    └───────────┘  │
│         │ 401               │ 403                        │
│         ▼ Unauthorized      ▼ Forbidden                  │
│      ┌──────┐           ┌──────┐                         │
│      │Error │           │Error │                         │
│      └──────┘           └──────┘                         │
└─────────────────────────────────────────────────────────┘
```

**401 Unauthorized** — не аутентифицирован (название вводит в заблуждение, исторически сложилось).  
**403 Forbidden** — аутентифицирован, но нет прав.

Никогда не возвращай 404 вместо 403 для скрытия факта существования ресурса — это security through obscurity, которая не работает и ломает контракт API.

---

## 2. Аутентификация

### 2.1 Session-based аутентификация

Классический подход: сервер хранит состояние сессии.

```
Client                    Server                  Session Store
  │                          │                       (Redis)
  │  POST /login             │                          │
  │  {user, password}        │                          │
  │─────────────────────────▶│                          │
  │                          │ Verify credentials       │
  │                          │ Create session           │
  │                          │─────────────────────────▶│
  │                          │  session_id → {user_id,  │
  │                          │  roles, expires}         │
  │  Set-Cookie:             │◀─────────────────────────│
  │  session_id=abc123;      │                          │
  │  HttpOnly; Secure        │                          │
  │◀─────────────────────────│                          │
  │                          │                          │
  │  GET /api/profile        │                          │
  │  Cookie: session_id=abc  │                          │
  │─────────────────────────▶│                          │
  │                          │ Lookup session           │
  │                          │─────────────────────────▶│
  │                          │◀─────────────────────────│
  │  200 OK {profile data}   │  {user_id, roles}        │
  │◀─────────────────────────│                          │
```

**Плюсы:** Просто отозвать сессию (удалить из Redis). Сервер контролирует состояние.  
**Минусы:** Stateful — сложно масштабировать горизонтально без sticky sessions или shared store. Проблемы с CSRF.

### 2.2 Token-based аутентификация: JWT

JWT (JSON Web Token) — самоподписанный токен, содержащий всю необходимую информацию.

#### Структура JWT

```
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9
.eyJzdWIiOiJ1c2VyXzEyMyIsInJvbGUiOiJhZG1pbiIsImV4cCI6MTcxMTAwMDAwMH0
.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c

│◀──────────── Header ─────────────▶│◀────────── Payload ──────────────▶│◀── Signature ──▶│
```

**Header** (base64url-декодируется):
```json
{
  "alg": "HS256",
  "typ": "JWT"
}
```

**Payload** (base64url-декодируется):
```json
{
  "sub": "user_123",
  "role": "admin",
  "exp": 1711000000,
  "iat": 1710996400
}
```

**Signature:**
```
HMACSHA256(
  base64url(header) + "." + base64url(payload),
  secret_key
)
```

> **Важно:** Payload НЕ зашифрован — только подписан. Не кладите туда пароли или чувствительные данные.

#### Access Token + Refresh Token

Проблема: если выдавать токен с долгим TTL — он долго живёт после компрометации. Если коротким — пользователь часто перелогинивается.

**Решение: два токена.**

```
┌──────────────────────────────────────────────────────────┐
│                  Token Pair Strategy                     │
│                                                          │
│  Access Token          Refresh Token                     │
│  ┌─────────────┐       ┌─────────────────┐              │
│  │ TTL: 15 min │       │ TTL: 7-30 days  │              │
│  │ Stateless   │       │ Stateful (DB)   │              │
│  │ All requests│       │ Only /refresh   │              │
│  └─────────────┘       └─────────────────┘              │
│                                                          │
│  Flow:                                                   │
│  1. Login → получить оба токена                         │
│  2. Запросы → Authorization: Bearer <access_token>      │
│  3. Access token истёк → POST /auth/refresh             │
│     с refresh_token → получить новый access token       │
│  4. Refresh token истёк / скомпрометирован → logout     │
└──────────────────────────────────────────────────────────┘
```

#### Хранение токенов

| Место хранения | XSS | CSRF | Рекомендация |
|---|---|---|---|
| `localStorage` | Уязвим | Защищён | ❌ Не использовать |
| `sessionStorage` | Уязвим | Защищён | ❌ Не использовать |
| `httpOnly` cookie | Защищён | Уязвим* | ✅ Предпочтительно |
| Memory (JS var) | Уязвим | Защищён | ⚠️ Теряется при refresh |

*`httpOnly` cookie + `SameSite=Strict` или CSRF-токен — решает проблему CSRF.

#### Проблема: JWT нельзя отозвать досрочно

JWT валиден до истечения `exp`. Нельзя "выйти на всех устройствах" без дополнительных механизмов.

**Решения:**

1. **Short TTL** — Access token живёт 15 минут. Простейшее решение. Компрометация → максимум 15 минут доступа.

2. **Blacklist** — хранить отозванные `jti` (JWT ID) в Redis до истечения TTL токена.
   ```
   Redis SET jti:abc123 "revoked" EX 900  # 15 минут
   ```
   Минус: нужно проверять Redis на каждый запрос — теряем stateless преимущество.

3. **Token versioning** — хранить `token_version` в БД для пользователя. Включать в JWT claim. При logout — инкрементировать версию в БД.
   ```json
   { "sub": "user_123", "ver": 5 }
   ```
   Проверка: `user.token_version == jwt.ver`. Один запрос в БД вместо Redis-lookup.

### 2.3 API Keys

Для machine-to-machine аутентификации. Не для пользователей напрямую.

```
Client Service                    API Server
     │                                │
     │  GET /api/data                 │
     │  X-API-Key: sk_live_abc123     │
     │───────────────────────────────▶│
     │                                │ Hash key → lookup in DB
     │                                │ Check permissions, rate limits
     │  200 OK                        │
     │◀───────────────────────────────│
```

**Правила для API keys:**
- Храните только hash ключа (sha256), не сам ключ — как пароли
- Отображайте ключ пользователю один раз при создании
- Prefix для идентификации среды: `sk_live_`, `sk_test_`
- Поддерживайте scope (права) и expiration
- Логируйте использование с IP и User-Agent

### 2.4 OAuth 2.0

OAuth 2.0 — протокол делегированной авторизации. Позволяет вашему приложению действовать от имени пользователя в стороннем сервисе.

**Authorization Code Flow** (самый безопасный, для web apps):

```
User         Your App          Auth Server        Resource Server
  │               │            (Google/GitHub)       (Google API)
  │  Click        │                  │                    │
  │  "Login with  │                  │                    │
  │   Google"     │                  │                    │
  │──────────────▶│                  │                    │
  │               │ Redirect to      │                    │
  │               │ /authorize?      │                    │
  │               │ client_id=...    │                    │
  │               │ code_challenge=  │                    │
  │◀──────────────│ (PKCE)           │                    │
  │                                  │                    │
  │  User logs in & consents         │                    │
  │─────────────────────────────────▶│                    │
  │                                  │                    │
  │  Redirect: /callback?code=xyz    │                    │
  │◀─────────────────────────────────│                    │
  │──────────────▶│                  │                    │
  │               │ POST /token      │                    │
  │               │ code=xyz         │                    │
  │               │ code_verifier=   │                    │
  │               │─────────────────▶│                    │
  │               │  access_token    │                    │
  │               │◀─────────────────│                    │
  │               │                  │  GET /userinfo     │
  │               │──────────────────────────────────────▶│
  │               │◀──────────────────────────────────────│
  │  Logged in!   │                  │                    │
  │◀──────────────│                  │                    │
```

**PKCE (Proof Key for Code Exchange)** — обязателен для public clients (SPA, mobile). Защищает от перехвата authorization code.

### 2.5 OpenID Connect (OIDC)

OAuth 2.0 решает авторизацию, но не аутентификацию. OpenID Connect — тонкий слой поверх OAuth 2.0, добавляющий стандартизированный способ получить информацию о пользователе.

```
OAuth 2.0 + OIDC:
  Получаем: access_token + id_token (JWT с данными пользователя)

id_token claims:
{
  "sub": "user_google_123",     // уникальный ID в Google
  "email": "user@example.com",
  "name": "Ivan Petrov",
  "iss": "https://accounts.google.com",
  "aud": "your-client-id",
  "exp": 1711000000
}
```

**Ключевые endpoints OIDC:**
- `/.well-known/openid-configuration` — discovery document
- `/authorize` — начало flow
- `/token` — обмен кода на токены
- `/userinfo` — получить профиль пользователя

### 2.6 Пример на Go: JWT middleware

```go
package middleware

import (
    "context"
    "fmt"
    "net/http"
    "strings"
    "time"

    "github.com/golang-jwt/jwt/v5"
)

type Claims struct {
    UserID  string `json:"sub"`
    Role    string `json:"role"`
    Version int    `json:"ver"`
    jwt.RegisteredClaims
}

type contextKey string

const claimsKey contextKey = "claims"

// CreateAccessToken создаёт JWT access token
func CreateAccessToken(userID, role string, version int, secretKey []byte) (string, error) {
    claims := Claims{
        UserID:  userID,
        Role:    role,
        Version: version,
        RegisteredClaims: jwt.RegisteredClaims{
            ExpiresAt: jwt.NewNumericDate(time.Now().Add(15 * time.Minute)),
            IssuedAt:  jwt.NewNumericDate(time.Now()),
            Issuer:    "myapp",
            ID:        generateJTI(), // уникальный ID для blacklist
        },
    }

    token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
    return token.SignedString(secretKey)
}

// JWTMiddleware валидирует токен и кладёт claims в context
func JWTMiddleware(secretKey []byte) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            // Извлечь токен из заголовка
            tokenStr := extractBearerToken(r)
            if tokenStr == "" {
                http.Error(w, "missing token", http.StatusUnauthorized)
                return
            }

            // Парсить и валидировать
            claims := &Claims{}
            token, err := jwt.ParseWithClaims(tokenStr, claims, func(t *jwt.Token) (interface{}, error) {
                // Важно: проверить алгоритм подписи
                if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
                    return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
                }
                return secretKey, nil
            })

            if err != nil || !token.Valid {
                http.Error(w, "invalid token", http.StatusUnauthorized)
                return
            }

            // Положить claims в context для downstream handlers
            ctx := context.WithValue(r.Context(), claimsKey, claims)
            next.ServeHTTP(w, r.WithContext(ctx))
        })
    }
}

// ClaimsFromContext извлекает claims из context
func ClaimsFromContext(ctx context.Context) (*Claims, bool) {
    claims, ok := ctx.Value(claimsKey).(*Claims)
    return claims, ok
}

func extractBearerToken(r *http.Request) string {
    auth := r.Header.Get("Authorization")
    parts := strings.SplitN(auth, " ", 2)
    if len(parts) != 2 || parts[0] != "Bearer" {
        return ""
    }
    return parts[1]
}

func generateJTI() string {
    // В реальности: crypto/rand UUID
    return fmt.Sprintf("%d", time.Now().UnixNano())
}
```

```go
// Использование в handler
func profileHandler(w http.ResponseWriter, r *http.Request) {
    claims, ok := middleware.ClaimsFromContext(r.Context())
    if !ok {
        http.Error(w, "unauthorized", http.StatusUnauthorized)
        return
    }

    // claims.UserID, claims.Role доступны здесь
    fmt.Fprintf(w, "Hello, %s (role: %s)", claims.UserID, claims.Role)
}

// Регистрация middleware
mux := http.NewServeMux()
mux.HandleFunc("/api/profile", profileHandler)
handler := middleware.JWTMiddleware(secretKey)(mux)
http.ListenAndServe(":8080", handler)
```

---

## 3. Авторизация

Аутентификация ответила "кто ты". Теперь нужно решить "что тебе можно".

### 3.1 RBAC (Role-Based Access Control)

Классическая и самая распространённая модель. Пользователю назначается роль, роли — набор permissions.

```
User ──▶ Role ──▶ Permissions

Иван ──▶ admin ──▶ {read, write, delete, manage_users}
Мария ──▶ editor ──▶ {read, write}
Гость ──▶ viewer ──▶ {read}
```

**Иерархический RBAC:**
```
superadmin
    │
  admin
    │
  editor
    │
  viewer
```

Каждая роль наследует права нижестоящих.

**Таблицы в БД:**
```sql
-- Роли
CREATE TABLE roles (id UUID, name TEXT);

-- Permissions
CREATE TABLE permissions (id UUID, resource TEXT, action TEXT);
-- Примеры: ('orders', 'read'), ('orders', 'delete'), ('users', 'manage')

-- Связь роль → permissions
CREATE TABLE role_permissions (role_id UUID, permission_id UUID);

-- Связь пользователь → роли
CREATE TABLE user_roles (user_id UUID, role_id UUID);
```

### 3.2 ABAC (Attribute-Based Access Control)

Более гибкая, но сложнее в реализации. Решение принимается на основе атрибутов субъекта, ресурса, действия и контекста.

```
Policy: Allow IF
  subject.department == resource.department
  AND subject.clearance_level >= resource.sensitivity
  AND context.time BETWEEN 09:00 AND 18:00
  AND context.ip IN corporate_network
```

**Когда нужен ABAC:**
- Мультиарендность (multi-tenancy): пользователь видит только ресурсы своей организации
- Контекстные решения (время, геолокация, устройство)
- Динамические политики без изменения кода

### 3.3 ReBAC (Relationship-Based Access Control)

Доступ определяется отношениями между сущностями. Основа — Google Zanzibar (система авторизации Google, обслуживающая Docs, Drive, YouTube).

```
Граф отношений:
document:readme#owner → user:ivan
document:readme#editor → user:maria
folder:projects#viewer → user:alexei
document:readme#parent → folder:projects

Проверка: "Может ли alexei читать document:readme?"
  1. document:readme#reader? Нет явной записи
  2. document:readme#editor? Нет
  3. document:readme#parent → folder:projects
  4. folder:projects#viewer → user:alexei ✓
  5. viewer на папку → viewer на вложенные документы ✓
  6. Разрешено
```

**OpenFGA** — open source реализация Zanzibar от Okta. Используется в production крупными компаниями.

### 3.4 Policy Engines

Для сложных сценариев авторизации выносим политики в отдельный сервис.

**OPA (Open Policy Agent)** — CNCF-проект, язык Rego:

```rego
# policy.rego
package authz

default allow := false

allow if {
    input.method == "GET"
    input.path[0] == "public"
}

allow if {
    input.user.role == "admin"
}

allow if {
    input.user.role == "editor"
    input.method in {"GET", "POST", "PUT"}
    not input.path[0] == "admin"
}
```

**Cedar (AWS)** — более читаемый синтаксис, разработан для строгой верификации:

```cedar
permit (
    principal in Role::"editor",
    action in [Action::"read", Action::"write"],
    resource in ResourceType::"document"
)
unless {
    resource.classification == "top-secret"
};
```

### 3.5 Пример: RBAC middleware на Go

```go
package middleware

import (
    "net/http"
    "slices"
)

// Permission представляет право доступа
type Permission struct {
    Resource string
    Action   string
}

// RolePermissions — маппинг ролей на разрешённые права
var RolePermissions = map[string][]Permission{
    "admin": {
        {Resource: "*", Action: "*"}, // полный доступ
    },
    "editor": {
        {Resource: "posts", Action: "read"},
        {Resource: "posts", Action: "write"},
        {Resource: "posts", Action: "delete"},
        {Resource: "media", Action: "read"},
        {Resource: "media", Action: "upload"},
    },
    "viewer": {
        {Resource: "posts", Action: "read"},
        {Resource: "media", Action: "read"},
    },
}

// RequirePermission возвращает middleware, проверяющий наличие права
func RequirePermission(resource, action string) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            claims, ok := ClaimsFromContext(r.Context())
            if !ok {
                http.Error(w, "unauthorized", http.StatusUnauthorized)
                return
            }

            if !hasPermission(claims.Role, resource, action) {
                http.Error(w, "forbidden", http.StatusForbidden)
                return
            }

            next.ServeHTTP(w, r)
        })
    }
}

func hasPermission(role, resource, action string) bool {
    permissions, exists := RolePermissions[role]
    if !exists {
        return false
    }

    return slices.ContainsFunc(permissions, func(p Permission) bool {
        resourceMatch := p.Resource == "*" || p.Resource == resource
        actionMatch := p.Action == "*" || p.Action == action
        return resourceMatch && actionMatch
    })
}
```

```go
// Использование: цепочка middleware
mux.Handle("/api/posts",
    middleware.JWTMiddleware(secretKey)(
        middleware.RequirePermission("posts", "read")(
            http.HandlerFunc(listPostsHandler),
        ),
    ),
)

mux.Handle("/api/posts/delete",
    middleware.JWTMiddleware(secretKey)(
        middleware.RequirePermission("posts", "delete")(
            http.HandlerFunc(deletePostHandler),
        ),
    ),
)
```

---

## 4. Шифрование

### 4.1 Encryption at Rest

Данные, хранящиеся на диске или в БД, должны быть зашифрованы. Если злоумышленник получит физический доступ к диску или бэкапу — данные останутся нечитаемыми.

**Уровни шифрования:**

```
┌─────────────────────────────────────────────────────┐
│  Application Level Encryption                       │
│  Шифруем отдельные поля (SSN, номера карт)          │
│  Алгоритм: AES-256-GCM (аутентифицированное)        │
├─────────────────────────────────────────────────────┤
│  Database Level Encryption                          │
│  Transparent Data Encryption (TDE)                  │
│  PostgreSQL: pgcrypto, AWS RDS автошифрование       │
├─────────────────────────────────────────────────────┤
│  Disk/Volume Level Encryption                       │
│  dm-crypt/LUKS на Linux                             │
│  AWS EBS encryption, GCP Persistent Disk            │
└─────────────────────────────────────────────────────┘
```

**AES-256-GCM** — предпочтительный симметричный алгоритм:
- 256-bit ключ
- GCM (Galois/Counter Mode) — аутентифицированное шифрование (защита от tampering)
- Nonce/IV должен быть уникальным для каждого шифрования — никогда не переиспользуйте

### 4.2 Encryption in Transit: TLS 1.3

TLS (Transport Layer Security) шифрует данные при передаче. TLS 1.3 — обязательный минимум, TLS 1.0/1.1 — отключить везде.

**Ключевые улучшения TLS 1.3:**
- Только forward-secure cipher suites (ECDHE)
- Handshake за 1 Round Trip (RTT) вместо 2
- 0-RTT resumption (с оговорками о replay атаках)
- Убраны устаревшие алгоритмы: RSA key exchange, SHA-1, DES

### 4.3 TLS Handshake (упрощённо)

```
Client                              Server
  │                                    │
  │  ClientHello                       │
  │  - TLS version                     │
  │  - Cipher suites                   │
  │  - Client random                   │
  │  - Key share (ECDH public key)     │
  │───────────────────────────────────▶│
  │                                    │
  │  ServerHello                       │
  │  - Chosen cipher suite             │
  │  - Server random                   │
  │  - Key share (ECDH public key)     │
  │  ─────────────────────────────────│
  │  {Certificate}                     │
  │  {CertificateVerify}               │
  │  {Finished}                        │
  │◀───────────────────────────────────│
  │                                    │
  │  ← Оба вычисляют session key →    │
  │    ECDH(client_private, server_pub)│
  │                                    │
  │  {Finished}                        │
  │───────────────────────────────────▶│
  │                                    │
  │  [Encrypted Application Data]      │
  │◀──────────────────────────────────▶│
```

TLS 1.3: весь handshake занимает **1 RTT** (против 2 RTT в TLS 1.2).

### 4.4 Certificate Management

**Let's Encrypt** — бесплатные TLS-сертификаты, автоматическое обновление через ACME protocol.

```bash
# certbot автоматически получает и обновляет сертификат
certbot --nginx -d example.com -d www.example.com

# Автообновление через cron или systemd timer
certbot renew --quiet
```

**cert-manager в Kubernetes** — автоматизирует весь lifecycle сертификатов:

```yaml
# Certificate resource
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: api-tls
spec:
  secretName: api-tls-secret
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - api.example.com
```

cert-manager сам запросит, получит, сохранит в Secret и обновит сертификат до истечения.

### 4.5 mTLS (Mutual TLS)

Обычный TLS: клиент проверяет сертификат сервера.  
mTLS: **оба** проверяют сертификаты друг друга. Идеально для service-to-service аутентификации.

```
Service A                              Service B
  │                                        │
  │  "Я Service A, вот мой сертификат"    │
  │───────────────────────────────────────▶│
  │                                        │ Проверяет: сертификат A
  │  "Я Service B, вот мой сертификат"    │ подписан нашим internal CA?
  │◀───────────────────────────────────────│
  │  Проверяет: сертификат B              │
  │  подписан нашим internal CA?          │
  │                                        │
  │  [Зашифрованный трафик]               │
  │◀──────────────────────────────────────▶│
```

В service mesh (Istio, Linkerd) mTLS включается автоматически — sidecar proxy (Envoy) берёт на себя всё. Ваш код вообще не знает о TLS.

### 4.6 Хеширование паролей

**НИКОГДА** не хешируйте пароли с MD5 или SHA-256. Они слишком быстрые — миллиарды хешей в секунду на GPU.

**Правильные алгоритмы:**

| Алгоритм | Настройка | Использование |
|---|---|---|
| **bcrypt** | cost factor (12–14) | Стандарт для большинства приложений |
| **argon2id** | memory, iterations, parallelism | Рекомендован OWASP, более гибкий |
| **scrypt** | N, r, p | Хорошая альтернатива |

**Почему bcrypt медленный — это фича, не баг.** При cost=12: ~250ms на проверку. Для пользователя незаметно. Для брутфорса — 4 попытки в секунду вместо миллиардов.

### 4.7 Пример на Go: хеширование пароля с bcrypt

```go
package auth

import (
    "errors"
    "fmt"

    "golang.org/x/crypto/bcrypt"
)

const bcryptCost = 12 // OWASP рекомендует минимум 10, 12 — баланс безопасности и скорости

// HashPassword создаёт bcrypt хеш пароля
func HashPassword(password string) (string, error) {
    if len(password) < 8 {
        return "", errors.New("password must be at least 8 characters")
    }

    // bcrypt автоматически генерирует salt и включает его в хеш
    hash, err := bcrypt.GenerateFromPassword([]byte(password), bcryptCost)
    if err != nil {
        return "", fmt.Errorf("hashing password: %w", err)
    }

    return string(hash), nil
}

// CheckPassword сравнивает пароль с сохранённым хешем
func CheckPassword(password, hash string) error {
    err := bcrypt.CompareHashAndPassword([]byte(hash), []byte(password))
    if err != nil {
        if errors.Is(err, bcrypt.ErrMismatchedHashAndPassword) {
            return errors.New("invalid credentials") // НЕ уточняем, что именно неверно
        }
        return fmt.Errorf("comparing password: %w", err)
    }
    return nil
}

// NeedsRehash проверяет, нужно ли перехешировать (при увеличении cost)
func NeedsRehash(hash string) bool {
    cost, err := bcrypt.Cost([]byte(hash))
    if err != nil {
        return true
    }
    return cost < bcryptCost
}
```

```go
// Регистрация пользователя
func Register(email, password string) error {
    hash, err := auth.HashPassword(password)
    if err != nil {
        return err
    }
    // Сохранить hash в БД, НЕ password
    return db.SaveUser(email, hash)
}

// Логин
func Login(email, password string) error {
    user, err := db.FindUserByEmail(email)
    if err != nil {
        // Важно: одинаковое время ответа при "пользователь не найден"
        // и "неверный пароль" — против timing attacks
        bcrypt.CompareHashAndPassword([]byte("$2a$12$dummy"), []byte(password))
        return errors.New("invalid credentials")
    }

    if err := auth.CheckPassword(password, user.PasswordHash); err != nil {
        return errors.New("invalid credentials")
    }

    // При логине — проверить, нужно ли перехешировать
    if auth.NeedsRehash(user.PasswordHash) {
        newHash, _ := auth.HashPassword(password)
        db.UpdatePasswordHash(user.ID, newHash)
    }

    return nil
}
```

---

## 5. OWASP Top 10 для разработчиков

[OWASP Top 10](https://owasp.org/www-project-top-ten/) — список наиболее критических уязвимостей веб-приложений. Обновляется каждые несколько лет.

### 5.1 SQL Injection

**Самая старая и до сих пор актуальная уязвимость.** Если видите конкатенацию строк в SQL — это баг.

```go
// ❌ НИКОГДА ТАК
query := "SELECT * FROM users WHERE email = '" + email + "'"
// Атака: email = "' OR '1'='1" — вернёт всех пользователей
// Атака: email = "'; DROP TABLE users; --" — удалит таблицу

// ✅ ВСЕГДА ПАРАМЕТРИЗОВАННЫЕ ЗАПРОСЫ
var user User
err := db.QueryRowContext(ctx,
    "SELECT id, email, role FROM users WHERE email = $1",
    email,  // параметр, никогда не попадает в тело запроса
).Scan(&user.ID, &user.Email, &user.Role)
```

С ORM (например, GORM):
```go
// ✅ GORM безопасен при правильном использовании
db.Where("email = ?", email).First(&user)

// ❌ НО НЕ ТАК (raw SQL без параметров)
db.Where("email = '" + email + "'").First(&user)
```

**Правило:** placeholder (`?`, `$1`) — всегда, конкатенация строк в SQL — никогда.

### 5.2 XSS (Cross-Site Scripting)

Злоумышленник внедряет JavaScript в страницу, который выполняется в браузере жертвы. Кражу cookies, перенаправление, фишинг.

**Типы XSS:**
- **Stored XSS**: скрипт сохранён в БД, показывается всем пользователям
- **Reflected XSS**: скрипт в URL параметре, отражается в ответе
- **DOM-based XSS**: манипуляции с DOM на клиенте

```go
// Backend: sanitize HTML входящий от пользователей
import "github.com/microcosm-cc/bluemonday"

policy := bluemonday.UGCPolicy() // разрешает безопасный HTML (ссылки, базовое форматирование)

// Для контента, где HTML вообще не нужен:
strictPolicy := bluemonday.StrictPolicy() // удаляет весь HTML

safeContent := policy.Sanitize(userInput)
```

**Content Security Policy (CSP)** — браузерная защита, ограничивает источники скриптов:

```go
// Middleware для CSP заголовка
w.Header().Set("Content-Security-Policy",
    "default-src 'self'; "+
    "script-src 'self' https://trusted-cdn.com; "+
    "style-src 'self' 'unsafe-inline'; "+
    "img-src 'self' data: https:; "+
    "connect-src 'self' https://api.example.com; "+
    "frame-ancestors 'none'",
)
```

### 5.3 CSRF (Cross-Site Request Forgery)

Жертва посещает вредоносный сайт, который делает запрос от её имени к вашему API (используя сохранённые cookies).

```
Жертва (залогинена в bank.com)
  │
  │ Открывает evil.com
  │
  ▼
evil.com: <img src="https://bank.com/transfer?to=attacker&amount=1000">
         <form action="https://bank.com/transfer" method="POST">
           <input name="to" value="attacker">
           <input name="amount" value="1000">
         </form>
         <script>document.forms[0].submit()</script>
```

**Защиты:**

1. **SameSite Cookie** — браузер не отправляет cookie при cross-site запросах:
```go
http.SetCookie(w, &http.Cookie{
    Name:     "session_id",
    Value:    sessionID,
    HttpOnly: true,
    Secure:   true,
    SameSite: http.SameSiteStrictMode, // или LaxMode
    Path:     "/",
})
```

2. **CSRF Token** — уникальный токен в форме, проверяемый сервером:
```go
// Генерация CSRF токена
func generateCSRFToken() string {
    b := make([]byte, 32)
    rand.Read(b)
    return base64.URLEncoding.EncodeToString(b)
}

// Проверка: токен из заголовка должен совпадать с токеном из сессии
requestToken := r.Header.Get("X-CSRF-Token")
sessionToken := session.CSRFToken
if !hmac.Equal([]byte(requestToken), []byte(sessionToken)) {
    http.Error(w, "invalid csrf token", http.StatusForbidden)
    return
}
```

### 5.4 SSRF (Server-Side Request Forgery)

Сервер делает HTTP запрос по URL, предоставленному пользователем. Атакующий указывает внутренние адреса.

```
Атака: POST /api/fetch-url
       {"url": "http://169.254.169.254/latest/meta-data/iam/credentials"}
       
Это AWS Instance Metadata Service — отдаёт credentials IAM роли инстанса!
Или: {"url": "http://internal-admin-service:8080/admin"}
```

```go
// Валидация URL перед запросом
func validateURL(rawURL string) error {
    parsed, err := url.Parse(rawURL)
    if err != nil {
        return fmt.Errorf("invalid url: %w", err)
    }

    // Только разрешённые схемы
    if parsed.Scheme != "https" {
        return errors.New("only https allowed")
    }

    // Резолвим hostname и проверяем IP
    addrs, err := net.LookupHost(parsed.Hostname())
    if err != nil {
        return fmt.Errorf("dns lookup failed: %w", err)
    }

    for _, addr := range addrs {
        ip := net.ParseIP(addr)
        if ip == nil {
            continue
        }
        // Блокируем приватные диапазоны
        if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() {
            return fmt.Errorf("private/internal addresses not allowed: %s", addr)
        }
    }

    return nil
}
```

> **Важно:** DNS rebinding атаки — злоумышленник может сначала отрезолвить публичный IP (проходит проверку), затем DNS изменит запись на внутренний IP. Решение: проверяйте IP в момент соединения, не только при резолве (или используйте специализированные библиотеки).

### 5.5 Broken Access Control

Одна из самых распространённых уязвимостей. Проверяете права на входе, но не на уровне данных.

```go
// ❌ Проверяем только аутентификацию, не ownership
func getDocument(w http.ResponseWriter, r *http.Request) {
    claims, _ := ClaimsFromContext(r.Context())
    docID := r.PathValue("id")
    
    doc, _ := db.GetDocument(docID) // Любой залогиненный может получить любой документ!
    json.NewEncoder(w).Encode(doc)
}

// ✅ Проверяем ownership/права на уровне данных
func getDocument(w http.ResponseWriter, r *http.Request) {
    claims, _ := ClaimsFromContext(r.Context())
    docID := r.PathValue("id")
    
    doc, err := db.GetDocumentForUser(docID, claims.UserID) // WHERE id=$1 AND owner_id=$2
    if err != nil {
        if errors.Is(err, sql.ErrNoRows) {
            http.Error(w, "not found", http.StatusNotFound) // Не 403, скрываем факт существования
            return
        }
        http.Error(w, "internal error", http.StatusInternalServerError)
        return
    }
    
    json.NewEncoder(w).Encode(doc)
}
```

**IDOR (Insecure Direct Object Reference)** — частный случай: `/api/invoices/1337` доступен любому пользователю, знающему ID. Решение: либо проверяйте владельца, либо используйте непредсказуемые UUID вместо sequential ID.

### 5.6 Security Headers

Набор HTTP-заголовков, включающих браузерную защиту:

| Заголовок | Назначение | Рекомендуемое значение |
|---|---|---|
| `Strict-Transport-Security` | Принудительный HTTPS | `max-age=31536000; includeSubDomains` |
| `X-Content-Type-Options` | Отключить MIME sniffing | `nosniff` |
| `X-Frame-Options` | Защита от clickjacking | `DENY` или `SAMEORIGIN` |
| `Content-Security-Policy` | Ограничение источников ресурсов | Зависит от приложения |
| `Referrer-Policy` | Контроль Referer заголовка | `strict-origin-when-cross-origin` |
| `Permissions-Policy` | Контроль browser features | `camera=(), microphone=(), geolocation=()` |

### 5.7 Пример на Go: middleware для security headers

```go
package middleware

import "net/http"

// SecurityHeaders добавляет стандартные security headers
func SecurityHeaders(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        h := w.Header()

        // Принудительный HTTPS на 1 год, включая поддомены
        h.Set("Strict-Transport-Security", "max-age=31536000; includeSubDomains; preload")

        // Отключить MIME type sniffing
        h.Set("X-Content-Type-Options", "nosniff")

        // Запретить framing (clickjacking protection)
        h.Set("X-Frame-Options", "DENY")

        // Content Security Policy
        h.Set("Content-Security-Policy",
            "default-src 'self'; "+
                "script-src 'self'; "+
                "style-src 'self' 'unsafe-inline'; "+
                "img-src 'self' data: https:; "+
                "connect-src 'self'; "+
                "font-src 'self'; "+
                "object-src 'none'; "+
                "base-uri 'self'; "+
                "form-action 'self'; "+
                "frame-ancestors 'none'",
        )

        // Контроль реферера
        h.Set("Referrer-Policy", "strict-origin-when-cross-origin")

        // Ограничение browser features
        h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=()")

        // Убрать X-Powered-By (информация об используемом фреймворке)
        h.Del("X-Powered-By")

        next.ServeHTTP(w, r)
    })
}
```

```go
// Применение: самый внешний слой middleware
handler := middleware.SecurityHeaders(
    middleware.RequestLogger(
        middleware.RateLimit(100)(
            router,
        ),
    ),
)
http.ListenAndServeTLS(":443", certFile, keyFile, handler)
```

Проверить заголовки можно через [securityheaders.com](https://securityheaders.com) или [observatory.mozilla.org](https://observatory.mozilla.org).

---

## 6. Secrets Management

### 6.1 Проблема

Credentials в коде или переменных среды — распространённая ошибка с серьёзными последствиями.

```bash
# ❌ Распространённые антипаттерны

# 1. Hardcoded в коде
db_password := "P@ssw0rd123"  // Попадёт в git историю навсегда

# 2. .env файл в репозитории
echo "DB_PASSWORD=secret" >> .env
git add .env  # Попадёт в GitHub, будет найден сканерами

# 3. Docker ENV
ENV DB_PASSWORD=secret  # Видно в docker inspect

# 4. K8s ConfigMap (не Secret)
# ConfigMap не зашифрован даже в etcd
```

**Реальная стоимость утечки:** GitHub сканирует коммиты на известные форматы секретов (AWS keys, GCP service account keys). Утечка AWS key в публичный репо → credential abuse в течение минут.

### 6.2 HashiCorp Vault

Централизованное хранилище секретов с динамической генерацией credentials.

```
┌─────────────────────────────────────────────────────┐
│                  HashiCorp Vault                    │
│                                                     │
│  Static Secrets    Dynamic Secrets    PKI           │
│  ┌─────────────┐  ┌───────────────┐  ┌──────────┐  │
│  │ kv/          │  │ database/     │  │ pki/     │  │
│  │ myapp/db     │  │ roles/        │  │ issue    │  │
│  │ myapp/api    │  │ myapp →       │  │ certs    │  │
│  └─────────────┘  │ CREATE USER.. │  └──────────┘  │
│                   │ TTL: 1h       │                 │
│                   └───────────────┘                 │
│                                                     │
│  Auth Methods: Kubernetes, AWS IAM, GitHub, LDAP    │
└─────────────────────────────────────────────────────┘
```

**Dynamic secrets** — Vault создаёт временные credentials (например, PostgreSQL пользователя) на каждый запрос с коротким TTL. Никаких shared passwords между сервисами.

```bash
# Vault создаёт временного DB пользователя
vault read database/creds/myapp-role
# Key                Value
# lease_id           database/creds/myapp-role/xyz
# lease_duration     1h
# username           v-myapp-abc123
# password           A1S2d3F4g5H6
# Через 1 час credentials автоматически отзываются
```

### 6.3 AWS Secrets Manager и GCP Secret Manager

Managed решения для cloud-native приложений.

```go
// AWS Secrets Manager
import (
    "context"
    "encoding/json"
    
    "github.com/aws/aws-sdk-go-v2/aws"
    "github.com/aws/aws-sdk-go-v2/service/secretsmanager"
)

type DBCredentials struct {
    Host     string `json:"host"`
    Username string `json:"username"`
    Password string `json:"password"`
    DBName   string `json:"dbname"`
}

func GetDBCredentials(ctx context.Context, secretName string) (*DBCredentials, error) {
    client := secretsmanager.NewFromConfig(awsConfig)
    
    result, err := client.GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{
        SecretId: aws.String(secretName),
    })
    if err != nil {
        return nil, fmt.Errorf("getting secret %s: %w", secretName, err)
    }
    
    var creds DBCredentials
    if err := json.Unmarshal([]byte(*result.SecretString), &creds); err != nil {
        return nil, fmt.Errorf("parsing secret: %w", err)
    }
    
    return &creds, nil
}
```

### 6.4 Kubernetes Secrets

```yaml
# K8s Secret — base64, НЕ зашифрован
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
type: Opaque
data:
  password: cGFzc3dvcmQxMjM=  # echo -n "password123" | base64
```

**Проблемы K8s Secrets:**
- Хранятся в etcd в base64 (не шифрование!)
- По умолчанию доступны любому поду в namespace
- Попадают в YAML манифесты → git репозиторий

**Решения:**

1. **Encryption at Rest в etcd** — настройка `EncryptionConfiguration` в kube-apiserver
2. **Sealed Secrets** (Bitnami) — шифрует Secret публичным ключом, расшифровывает только оператор в кластере
3. **External Secrets Operator** — синхронизирует секреты из Vault/AWS SM/GCP SM в K8s Secrets

```yaml
# External Secrets Operator: синхронизация из AWS Secrets Manager
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-credentials
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: db-credentials  # создаёт обычный K8s Secret
  data:
    - secretKey: password
      remoteRef:
        key: myapp/db
        property: password
```

### 6.5 Автоматическая ротация секретов

```
┌──────────────────────────────────────────────────────────┐
│               Secret Rotation Strategy                   │
│                                                          │
│  1. Vault/AWS SM генерирует новый secret                 │
│  2. Обновляет его в хранилище                            │
│  3. Уведомляет приложения (webhook / polling)            │
│  4. Приложения перечитывают secret                       │
│  5. Старый secret деактивируется через N минут           │
│                                                          │
│  ┌─────────┐    ┌──────────────┐    ┌─────────────────┐ │
│  │  Vault  │───▶│  App reads   │───▶│ Reconnect to DB │ │
│  │ rotates │    │  new creds   │    │ with new creds  │ │
│  └─────────┘    └──────────────┘    └─────────────────┘ │
│                                                          │
│  Zero-downtime rotation требует:                         │
│  - DB поддерживает двух активных пользователей           │
│  - Приложение gracefully переподключается                │
└──────────────────────────────────────────────────────────┘
```

### 6.6 Пример: получение секретов из Vault в Go

```go
package vault

import (
    "context"
    "fmt"
    "sync"
    "time"

    vault "github.com/hashicorp/vault/api"
    auth "github.com/hashicorp/vault/api/auth/kubernetes"
)

type SecretCache struct {
    mu      sync.RWMutex
    secrets map[string]string
    expiry  map[string]time.Time
}

type Client struct {
    vault *vault.Client
    cache *SecretCache
}

// NewKubernetesClient создаёт Vault клиент с Kubernetes auth
func NewKubernetesClient(vaultAddr, role string) (*Client, error) {
    config := vault.DefaultConfig()
    config.Address = vaultAddr

    client, err := vault.NewClient(config)
    if err != nil {
        return nil, fmt.Errorf("creating vault client: %w", err)
    }

    // Kubernetes auth: читает JWT из /var/run/secrets/kubernetes.io/serviceaccount/token
    k8sAuth, err := auth.NewKubernetesAuth(role)
    if err != nil {
        return nil, fmt.Errorf("creating k8s auth: %w", err)
    }

    authInfo, err := client.Auth().Login(context.Background(), k8sAuth)
    if err != nil {
        return nil, fmt.Errorf("vault login: %w", err)
    }

    // Запустить фоновое обновление токена
    go renewToken(client, authInfo)

    return &Client{
        vault: client,
        cache: &SecretCache{
            secrets: make(map[string]string),
            expiry:  make(map[string]time.Time),
        },
    }, nil
}

// GetSecret возвращает секрет с кешированием
func (c *Client) GetSecret(ctx context.Context, path, key string) (string, error) {
    cacheKey := path + "#" + key

    // Проверить кеш
    c.cache.mu.RLock()
    if val, ok := c.cache.secrets[cacheKey]; ok {
        if time.Now().Before(c.cache.expiry[cacheKey]) {
            c.cache.mu.RUnlock()
            return val, nil
        }
    }
    c.cache.mu.RUnlock()

    // Запросить из Vault
    secret, err := c.vault.KVv2("secret").Get(ctx, path)
    if err != nil {
        return "", fmt.Errorf("reading secret %s: %w", path, err)
    }

    val, ok := secret.Data[key].(string)
    if !ok {
        return "", fmt.Errorf("key %s not found in secret %s", key, path)
    }

    // Кешировать на 5 минут
    c.cache.mu.Lock()
    c.cache.secrets[cacheKey] = val
    c.cache.expiry[cacheKey] = time.Now().Add(5 * time.Minute)
    c.cache.mu.Unlock()

    return val, nil
}

func renewToken(client *vault.Client, authInfo *vault.Secret) {
    // В реальности: использовать client.NewLifetimeWatcher
    ticker := time.NewTicker(10 * time.Minute)
    for range ticker.C {
        client.Auth().Token().RenewSelf(0)
    }
}
```

```go
// Использование при старте приложения
func main() {
    vaultClient, err := vault.NewKubernetesClient("https://vault:8200", "myapp-role")
    if err != nil {
        log.Fatal(err)
    }

    dbPassword, err := vaultClient.GetSecret(ctx, "myapp/database", "password")
    if err != nil {
        log.Fatal(err)
    }

    db, err := sql.Open("postgres", fmt.Sprintf("host=db user=myapp password=%s", dbPassword))
    // ...
}
```

---

## 7. Zero Trust Architecture

### 7.1 Принципы Zero Trust

Традиционная модель: "всё внутри периметра безопасно". Атакующий проникает внутрь → полный доступ ко всему.

Zero Trust: **"никогда не доверяй, всегда проверяй"**.

```
Старая модель (Castle and Moat):
┌────────────────────────────────────┐
│           Корпоративная сеть       │
│  ┌──────┐  ┌──────┐  ┌──────────┐ │
│  │ DB   │  │ API  │  │ Service  │ │
│  │      │◀─│      │◀─│          │ │ Внутри → доверяем
│  └──────┘  └──────┘  └──────────┘ │
└──────────────────────┬─────────────┘
                       │ Firewall
                    Internet
                    
Проблема: один взломанный сервис → доступ ко всему

Zero Trust:
┌──────────────────────────────────────────┐
│  Каждый запрос:                          │
│  ✓ Аутентифицирован (mTLS)               │
│  ✓ Авторизован (least privilege)         │
│  ✓ Залогирован и проверен                │
│  ✓ Зашифрован (даже internal трафик)     │
└──────────────────────────────────────────┘
```

### 7.2 Три кита Zero Trust

**1. Verify Explicitly**  
Каждый запрос проверяется независимо от источника. Внутренняя сеть — не гарантия безопасности.

```
Service A → Service B:
  - mTLS: проверка сертификата Service A
  - JWT: проверка identity пользователя (user context propagation)
  - Authorization: проверка прав Service A на endpoint
  - Audit log: запись каждого межсервисного вызова
```

**2. Least Privilege**  
Каждый компонент получает минимальный набор прав, необходимый для работы.

```yaml
# K8s: ServiceAccount с минимальными правами
apiVersion: v1
kind: ServiceAccount
metadata:
  name: order-service
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: order-service-role
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    resourceNames: ["order-service-config"]  # Только конкретный ConfigMap
    verbs: ["get"]  # Только чтение, не запись
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: order-service-binding
subjects:
  - kind: ServiceAccount
    name: order-service
roleRef:
  kind: Role
  name: order-service-role
```

**3. Assume Breach**  
Проектируй так, будто атакующий уже внутри. Изолируй blast radius.

```
Меры при Assume Breach:
- Micro-segmentation: сетевые политики между сервисами
- Encrypt everything: даже internal трафик
- Centralized logging: SIEM для детекции аномалий
- Secrets rotation: скомпрометированный секрет → быстро устаревает
- Canary tokens: приманки для обнаружения атакующего
```

### 7.3 Практические инструменты

#### Network Policies в Kubernetes

```yaml
# По умолчанию: запретить весь трафик
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}  # все поды
  policyTypes:
    - Ingress
    - Egress
---
# Разрешить: только order-service → payment-service:8080
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-order-to-payment
spec:
  podSelector:
    matchLabels:
      app: payment-service
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: order-service
      ports:
        - protocol: TCP
          port: 8080
```

#### mTLS в Istio Service Mesh

```yaml
# PeerAuthentication: требовать mTLS для всего namespace
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: production
spec:
  mtls:
    mode: STRICT  # Только mTLS, plaintext запрещён
---
# AuthorizationPolicy: order-service может вызывать только /payments endpoint
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: payment-service-policy
  namespace: production
spec:
  selector:
    matchLabels:
      app: payment-service
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/production/sa/order-service"]
      to:
        - operation:
            methods: ["POST"]
            paths: ["/payments"]
```

### 7.4 User Context Propagation

В микросервисной архитектуре важно передавать identity пользователя через цепочку вызовов:

```
Client → API Gateway → Service A → Service B → Service C
   JWT ────────────────────────────────────────────▶
                       Каждый сервис видит: кто пользователь,
                       какие у него права, для audit log
```

```go
// Передача user context через gRPC metadata
func CallDownstream(ctx context.Context, userClaims *Claims) {
    md := metadata.Pairs(
        "x-user-id", userClaims.UserID,
        "x-user-role", userClaims.Role,
        "x-request-id", requestIDFromContext(ctx),
    )
    ctx = metadata.NewOutgoingContext(ctx, md)
    
    client.SomeMethod(ctx, request)
}
```

---

## 8. DDoS Protection и Web Application Firewall

### 8.1 Типы DDoS атак

```
┌─────────────────────────────────────────────────────────────┐
│                    DDoS Attack Types                        │
│                                                             │
│  Layer 3/4 (Network/Transport) — Volumetric                │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ UDP Flood, ICMP Flood, SYN Flood                      │  │
│  │ Цель: перегрузить пропускную способность канала       │  │
│  │ Масштаб: терабиты/сек                                 │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                             │
│  Layer 4 (Transport) — Protocol Attacks                    │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ SYN Flood, Ping of Death, Smurf Attack                │  │
│  │ Цель: исчерпать ресурсы сетевого оборудования         │  │
│  │ Миллионы пакетов/сек                                  │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                             │
│  Layer 7 (Application) — Application Layer                 │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ HTTP Flood, Slowloris, Cache Busting                  │  │
│  │ Цель: перегрузить приложение, а не канал              │  │
│  │ Легитимные запросы — сложно фильтровать               │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

**Slowloris** — особый вид: открывает много соединений, отправляет HTTP заголовки очень медленно. Сервер держит соединения открытыми, пока не исчерпает thread pool. Защита: timeout на получение полного запроса.

### 8.2 Уровни защиты

```
Internet
   │
   ▼
┌─────────────────────────────────┐
│    Cloudflare / AWS Shield      │  ← Anycast network, absorbs volumetric
│    (Edge Layer)                 │    Capacity: 100+ Tbps
└────────────────┬────────────────┘
                 │ Очищенный трафик
                 ▼
┌─────────────────────────────────┐
│    WAF (Web Application         │  ← Фильтрует L7 атаки
│    Firewall)                    │    SQL injection, XSS, OWASP rules
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│    Load Balancer + Rate Limiter │  ← Rate limiting по IP/user/API key
│    (nginx, HAProxy, Envoy)      │
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│    Application                  │  ← Application-level rate limiting
│                                 │    Business logic защита
└─────────────────────────────────┘
```

### 8.3 Rate Limiting

```go
package middleware

import (
    "net/http"
    "sync"
    "time"

    "golang.org/x/time/rate"
)

type IPRateLimiter struct {
    limiters sync.Map
    rate     rate.Limit  // запросов в секунду
    burst    int         // максимальный всплеск
}

func NewIPRateLimiter(r rate.Limit, burst int) *IPRateLimiter {
    rl := &IPRateLimiter{rate: r, burst: burst}
    
    // Периодически чистить старые лимитеры
    go func() {
        for range time.Tick(time.Minute) {
            rl.limiters.Range(func(key, _ interface{}) bool {
                // Удалить старые записи (упрощённо)
                return true
            })
        }
    }()
    
    return rl
}

func (rl *IPRateLimiter) getLimiter(ip string) *rate.Limiter {
    limiter, _ := rl.limiters.LoadOrStore(ip, rate.NewLimiter(rl.rate, rl.burst))
    return limiter.(*rate.Limiter)
}

// RateLimit middleware: 10 запросов/сек на IP, burst 20
func RateLimit(r rate.Limit, burst int) func(http.Handler) http.Handler {
    limiter := NewIPRateLimiter(r, burst)
    
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            ip := realIP(r) // учитываем X-Forwarded-For за proxy
            
            if !limiter.getLimiter(ip).Allow() {
                w.Header().Set("Retry-After", "1")
                http.Error(w, "rate limit exceeded", http.StatusTooManyRequests)
                return
            }
            
            next.ServeHTTP(w, r)
        })
    }
}

func realIP(r *http.Request) string {
    // За Cloudflare/proxy: реальный IP в заголовке
    if ip := r.Header.Get("CF-Connecting-IP"); ip != "" {
        return ip
    }
    if ip := r.Header.Get("X-Real-IP"); ip != "" {
        return ip
    }
    // Fallback: RemoteAddr (не доверять, если за proxy)
    return r.RemoteAddr
}
```

**Стратегии rate limiting:**

| Стратегия | Описание | Использование |
|---|---|---|
| Per IP | Лимит на IP адрес | Базовая защита от ботов |
| Per User | Лимит на аутентифицированного пользователя | API fairness |
| Per API Key | Лимит на ключ | Тарификация по плану |
| Per Endpoint | Разные лимиты для дорогих операций | `/search` строже, чем `/ping` |
| Global | Общий лимит на весь сервис | Emergency throttling |

### 8.4 WAF (Web Application Firewall)

WAF анализирует HTTP-трафик и блокирует вредоносные запросы по правилам.

**Managed WAF решения:**

| Провайдер | Продукт | Уровень |
|---|---|---|
| Cloudflare | WAF + Bot Management | Edge, перед вашим сервером |
| AWS | AWS WAF + Shield | Интеграция с ALB/CloudFront |
| GCP | Cloud Armor | Интеграция с Load Balancer |
| Open Source | ModSecurity + OWASP Core Rule Set | Self-hosted |

**OWASP ModSecurity Core Rule Set (CRS)** — набор правил для ModSecurity, покрывающий OWASP Top 10.

```nginx
# nginx + ModSecurity
load_module modules/ngx_http_modsecurity_module.so;

server {
    modsecurity on;
    modsecurity_rules_file /etc/nginx/modsecurity/main.conf;
    
    location / {
        proxy_pass http://backend;
    }
}
```

### 8.5 Bot Protection

```
Инструменты для отличия ботов от людей:

1. CAPTCHA / reCAPTCHA v3
   - Score 0.0-1.0: вероятность бота
   - Не прерывает пользователя (v3)
   - Применять на: регистрация, логин, checkout

2. Browser fingerprinting
   - JavaScript challenge: ожидаем выполнение JS
   - TLS fingerprint (JA3): браузеры vs headless Chrome
   - Behavioral analytics: движения мыши, тайминги

3. IP reputation
   - Blocklist известных Tor exit nodes
   - Blocklist datacenter IP ranges (AWS, GCP → не люди)
   - Cloudflare Bot Score

4. Rate limiting + progressively harder challenges
   - Подозрительный IP → CAPTCHA
   - Очень подозрительный → block
```

```go
// Пример: Google reCAPTCHA v3 верификация в Go
type RecaptchaResponse struct {
    Success     bool      `json:"success"`
    Score       float64   `json:"score"`
    Action      string    `json:"action"`
    ChallengeTS time.Time `json:"challenge_ts"`
    Hostname    string    `json:"hostname"`
    ErrorCodes  []string  `json:"error-codes"`
}

func VerifyRecaptcha(token, secretKey string) (*RecaptchaResponse, error) {
    resp, err := http.PostForm("https://www.google.com/recaptcha/api/siteverify",
        url.Values{
            "secret":   {secretKey},
            "response": {token},
        },
    )
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()

    var result RecaptchaResponse
    if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
        return nil, err
    }

    return &result, nil
}

func registerHandler(w http.ResponseWriter, r *http.Request) {
    recaptchaToken := r.FormValue("recaptcha_token")
    
    result, err := VerifyRecaptcha(recaptchaToken, os.Getenv("RECAPTCHA_SECRET"))
    if err != nil || !result.Success || result.Score < 0.5 {
        http.Error(w, "bot detected", http.StatusForbidden)
        return
    }
    
    // Продолжить регистрацию
}
```

---

## Итоговая карта модуля

```
┌──────────────────────────────────────────────────────────────────┐
│                    Security Layers                               │
│                                                                  │
│  EDGE                                                            │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ DDoS Protection (Cloudflare/Shield) • WAF • Bot Protection │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  TRANSPORT                                                       │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ TLS 1.3 (external) • mTLS (internal) • Certificate mgmt   │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  APPLICATION                                                     │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ AuthN (JWT/Session/OAuth) • AuthZ (RBAC/ABAC/ReBAC)        │  │
│  │ Rate Limiting • Security Headers • CSRF/XSS Protection     │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  DATA                                                            │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ Encryption at Rest (AES-256) • Password Hashing (bcrypt)   │  │
│  │ Parameterized Queries • Input Validation                   │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  SECRETS & INFRA                                                 │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ Vault / AWS SM • K8s Sealed Secrets • Auto-rotation        │  │
│  │ Zero Trust • Network Policies • Least Privilege            │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

## Чек-лист для код-ревью

- [ ] SQL запросы используют parameterized queries — нет конкатенации строк
- [ ] Пароли хешируются через bcrypt/argon2, не md5/sha256
- [ ] JWT проверяет алгоритм подписи (не доверять `alg` из заголовка)
- [ ] HTTP cookies: `HttpOnly`, `Secure`, `SameSite=Strict/Lax`
- [ ] Нет secrets в коде, `.env` файлах или Docker ENV
- [ ] Authorization проверяется на уровне данных (не только на входе)
- [ ] User input санируется перед выводом в HTML
- [ ] Security headers выставлены (HSTS, CSP, X-Content-Type-Options)
- [ ] Rate limiting настроен на дорогие endpoints
- [ ] SSRF защита: валидация URL перед fetch
- [ ] TLS 1.0/1.1 отключены, только 1.2+ (лучше 1.3)
- [ ] Одинаковое время ответа для "пользователь не найден" и "неверный пароль"
- [ ] Логи не содержат паролей, токенов, PII данных

## Ресурсы

- [OWASP Top 10](https://owasp.org/www-project-top-ten/) — актуальный список уязвимостей
- [OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/) — конкретные рекомендации по каждой теме
- [Google BeyondCorp](https://cloud.google.com/beyondcorp) — reference реализация Zero Trust
- [Zanzibar paper](https://research.google/pubs/zanzibar-googles-consistent-global-authorization-system/) — Google's authorization system
- [JWT.io](https://jwt.io/) — декодер и документация JWT
- [HashiCorp Vault docs](https://developer.hashicorp.com/vault/docs) — документация Vault
- [securityheaders.com](https://securityheaders.com) — проверка HTTP заголовков
