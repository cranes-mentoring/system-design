# Module 11: Security

Security is not a feature you add at the end. It is a cross-cutting property of the system. A single missed SQL injection or a leaked AWS key can cost a company millions. This module covers the practical security aspects that every backend developer encounters.

---

## Table of Contents

1. [Authentication vs Authorization](#1-authentication-vs-authorization)
2. [Authentication](#2-authentication)
3. [Authorization](#3-authorization)
4. [Encryption](#4-encryption)
5. [OWASP Top 10 for Developers](#5-owasp-top-10-for-developers)
6. [Secrets Management](#6-secrets-management)
7. [Zero Trust Architecture](#7-zero-trust-architecture)
8. [DDoS Protection and Web Application Firewall](#8-ddos-protection-and-web-application-firewall)

---

## 1. Authentication vs Authorization

Two terms that are constantly confused — even by experienced developers. Let's settle this once and for all.

| Concept | Question | Example |
|---------|----------|---------|
| **Authentication (AuthN)** | *Who are you?* | Verifying a login/password, JWT token, API key |
| **Authorization (AuthZ)** | *What are you allowed to do?* | Checking whether a user can delete a resource |

**AuthN always precedes AuthZ.** You cannot check the rights of an unknown entity.

### Request Flow

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
│  │ Who are you? │    │ What can     │    │ Business  │  │
│  │              │    │ you do?      │    │ logic     │  │
│  │ - JWT valid? │    │ - RBAC?      │    │           │  │
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

**401 Unauthorized** — not authenticated (the name is misleading for historical reasons).  
**403 Forbidden** — authenticated, but lacks permission.

Never return 404 instead of 403 to hide the existence of a resource — that is security through obscurity, which doesn't work and breaks the API contract.

---

## 2. Authentication

### 2.1 Session-Based Authentication

The classic approach: the server stores session state.

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

**Pros:** Easy to revoke a session (delete from Redis). Server controls state.  
**Cons:** Stateful — hard to scale horizontally without sticky sessions or a shared store. CSRF issues.

### 2.2 Token-Based Authentication: JWT

JWT (JSON Web Token) — a self-signed token containing all necessary information.

#### JWT Structure

```
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9
.eyJzdWIiOiJ1c2VyXzEyMyIsInJvbGUiOiJhZG1pbiIsImV4cCI6MTcxMTAwMDAwMH0
.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c

│◀──────────── Header ─────────────▶│◀────────── Payload ──────────────▶│◀── Signature ──▶│
```

**Header** (base64url-decoded):
```json
{
  "alg": "HS256",
  "typ": "JWT"
}
```

**Payload** (base64url-decoded):
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

> **Important:** The payload is NOT encrypted — only signed. Do not put passwords or sensitive data in it.

#### Access Token + Refresh Token

Problem: if a long-lived token is issued, it remains valid for a long time after compromise. If short-lived, users must log in frequently.

**Solution: two tokens.**

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
│  1. Login → receive both tokens                         │
│  2. Requests → Authorization: Bearer <access_token>     │
│  3. Access token expires → POST /auth/refresh           │
│     with refresh_token → get a new access token         │
│  4. Refresh token expires / compromised → logout        │
└──────────────────────────────────────────────────────────┘
```

#### Token Storage

| Storage Location | XSS | CSRF | Recommendation |
|-----------------|-----|------|----------------|
| `localStorage` | Vulnerable | Protected | ❌ Do not use |
| `sessionStorage` | Vulnerable | Protected | ❌ Do not use |
| `httpOnly` cookie | Protected | Vulnerable* | ✅ Preferred |
| Memory (JS var) | Vulnerable | Protected | ⚠️ Lost on refresh |

*`httpOnly` cookie + `SameSite=Strict` or a CSRF token — solves the CSRF problem.

#### Problem: JWT Cannot Be Revoked Early

A JWT is valid until `exp` expires. You can't "log out of all devices" without additional mechanisms.

**Solutions:**

1. **Short TTL** — Access token lives 15 minutes. The simplest solution. Compromise → at most 15 minutes of access.

2. **Blacklist** — store revoked `jti` (JWT ID) values in Redis until the token TTL expires.
   ```
   Redis SET jti:abc123 "revoked" EX 900  # 15 minutes
   ```
   Downside: must check Redis on every request — loses the stateless advantage.

3. **Token versioning** — store `token_version` in the DB per user. Include in the JWT claim. On logout — increment the version in the DB.
   ```json
   { "sub": "user_123", "ver": 5 }
   ```
   Check: `user.token_version == jwt.ver`. One DB query instead of a Redis lookup.

### 2.3 API Keys

For machine-to-machine authentication. Not for end users directly.

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

**Rules for API keys:**
- Store only the hash of the key (sha256), not the key itself — like passwords
- Show the key to the user once at creation time
- Use prefixes to identify the environment: `sk_live_`, `sk_test_`
- Support scope (permissions) and expiration
- Log usage with IP and User-Agent

### 2.4 OAuth 2.0

OAuth 2.0 is a delegated authorization protocol. It allows your application to act on behalf of a user in a third-party service.

**Authorization Code Flow** (most secure, for web apps):

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

**PKCE (Proof Key for Code Exchange)** — required for public clients (SPA, mobile). Protects against authorization code interception.

### 2.5 OpenID Connect (OIDC)

OAuth 2.0 handles authorization, but not authentication. OpenID Connect is a thin layer on top of OAuth 2.0 that adds a standardized way to retrieve user information.

```
OAuth 2.0 + OIDC:
  Receive: access_token + id_token (JWT with user data)

id_token claims:
{
  "sub": "user_google_123",     // unique ID at Google
  "email": "user@example.com",
  "name": "Ivan Petrov",
  "iss": "https://accounts.google.com",
  "aud": "your-client-id",
  "exp": 1711000000
}
```

**Key OIDC endpoints:**
- `/.well-known/openid-configuration` — discovery document
- `/authorize` — start of flow
- `/token` — exchange code for tokens
- `/userinfo` — get user profile

### 2.6 Go Example: JWT Middleware

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

// CreateAccessToken creates a JWT access token
func CreateAccessToken(userID, role string, version int, secretKey []byte) (string, error) {
    claims := Claims{
        UserID:  userID,
        Role:    role,
        Version: version,
        RegisteredClaims: jwt.RegisteredClaims{
            ExpiresAt: jwt.NewNumericDate(time.Now().Add(15 * time.Minute)),
            IssuedAt:  jwt.NewNumericDate(time.Now()),
            Issuer:    "myapp",
            ID:        generateJTI(), // unique ID for blacklist
        },
    }

    token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
    return token.SignedString(secretKey)
}

// JWTMiddleware validates the token and places claims in context
func JWTMiddleware(secretKey []byte) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            // Extract token from header
            tokenStr := extractBearerToken(r)
            if tokenStr == "" {
                http.Error(w, "missing token", http.StatusUnauthorized)
                return
            }

            // Parse and validate
            claims := &Claims{}
            token, err := jwt.ParseWithClaims(tokenStr, claims, func(t *jwt.Token) (interface{}, error) {
                // Important: verify the signing algorithm
                if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
                    return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
                }
                return secretKey, nil
            })

            if err != nil || !token.Valid {
                http.Error(w, "invalid token", http.StatusUnauthorized)
                return
            }

            // Place claims in context for downstream handlers
            ctx := context.WithValue(r.Context(), claimsKey, claims)
            next.ServeHTTP(w, r.WithContext(ctx))
        })
    }
}

// ClaimsFromContext extracts claims from context
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
    // In practice: crypto/rand UUID
    return fmt.Sprintf("%d", time.Now().UnixNano())
}
```

```go
// Usage in a handler
func profileHandler(w http.ResponseWriter, r *http.Request) {
    claims, ok := middleware.ClaimsFromContext(r.Context())
    if !ok {
        http.Error(w, "unauthorized", http.StatusUnauthorized)
        return
    }

    // claims.UserID, claims.Role are available here
    fmt.Fprintf(w, "Hello, %s (role: %s)", claims.UserID, claims.Role)
}

// Registering middleware
mux := http.NewServeMux()
mux.HandleFunc("/api/profile", profileHandler)
handler := middleware.JWTMiddleware(secretKey)(mux)
http.ListenAndServe(":8080", handler)
```

---

## 3. Authorization

Authentication answered "who are you". Now we need to decide "what are you allowed to do".

### 3.1 RBAC (Role-Based Access Control)

The classic and most common model. A user is assigned a role; roles have a set of permissions.

```
User ──▶ Role ──▶ Permissions

Ivan ──▶ admin ──▶ {read, write, delete, manage_users}
Maria ──▶ editor ──▶ {read, write}
Guest ──▶ viewer ──▶ {read}
```

**Hierarchical RBAC:**
```
superadmin
    │
  admin
    │
  editor
    │
  viewer
```

Each role inherits the permissions of roles below it.

**Database tables:**
```sql
-- Roles
CREATE TABLE roles (id UUID, name TEXT);

-- Permissions
CREATE TABLE permissions (id UUID, resource TEXT, action TEXT);
-- Examples: ('orders', 'read'), ('orders', 'delete'), ('users', 'manage')

-- Role → permissions mapping
CREATE TABLE role_permissions (role_id UUID, permission_id UUID);

-- User → roles mapping
CREATE TABLE user_roles (user_id UUID, role_id UUID);
```

### 3.2 ABAC (Attribute-Based Access Control)

More flexible, but harder to implement. Decisions are made based on attributes of the subject, resource, action, and context.

```
Policy: Allow IF
  subject.department == resource.department
  AND subject.clearance_level >= resource.sensitivity
  AND context.time BETWEEN 09:00 AND 18:00
  AND context.ip IN corporate_network
```

**When ABAC is needed:**
- Multi-tenancy: users see only resources from their organization
- Context-based decisions (time, geolocation, device)
- Dynamic policies without code changes

### 3.3 ReBAC (Relationship-Based Access Control)

Access is determined by relationships between entities. Based on Google Zanzibar (Google's authorization system, serving Docs, Drive, YouTube).

```
Relationship graph:
document:readme#owner → user:ivan
document:readme#editor → user:maria
folder:projects#viewer → user:alexei
document:readme#parent → folder:projects

Check: "Can alexei read document:readme?"
  1. document:readme#reader? No explicit record
  2. document:readme#editor? No
  3. document:readme#parent → folder:projects
  4. folder:projects#viewer → user:alexei ✓
  5. viewer on folder → viewer on nested documents ✓
  6. Allowed
```

**OpenFGA** — an open source implementation of Zanzibar from Okta. Used in production by large companies.

### 3.4 Policy Engines

For complex authorization scenarios, move policies to a separate service.

**OPA (Open Policy Agent)** — CNCF project, Rego language:

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

**Cedar (AWS)** — more readable syntax, designed for strict verification:

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

### 3.5 Example: RBAC Middleware in Go

```go
package middleware

import (
    "net/http"
    "slices"
)

// Permission represents an access right
type Permission struct {
    Resource string
    Action   string
}

// RolePermissions — mapping of roles to allowed permissions
var RolePermissions = map[string][]Permission{
    "admin": {
        {Resource: "*", Action: "*"}, // full access
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

// RequirePermission returns middleware that checks for a specific permission
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
// Usage: middleware chain
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

## 4. Encryption

### 4.1 Encryption at Rest

Data stored on disk or in a DB must be encrypted. If an attacker gains physical access to a disk or backup, the data remains unreadable.

**Encryption levels:**

```
┌─────────────────────────────────────────────────────┐
│  Application Level Encryption                       │
│  Encrypt individual fields (SSN, card numbers)      │
│  Algorithm: AES-256-GCM (authenticated)             │
├─────────────────────────────────────────────────────┤
│  Database Level Encryption                          │
│  Transparent Data Encryption (TDE)                  │
│  PostgreSQL: pgcrypto, AWS RDS auto-encryption      │
├─────────────────────────────────────────────────────┤
│  Disk/Volume Level Encryption                       │
│  dm-crypt/LUKS on Linux                             │
│  AWS EBS encryption, GCP Persistent Disk            │
└─────────────────────────────────────────────────────┘
```

**AES-256-GCM** — the preferred symmetric algorithm:
- 256-bit key
- GCM (Galois/Counter Mode) — authenticated encryption (tamper protection)
- Nonce/IV must be unique for every encryption operation — never reuse

### 4.2 Encryption in Transit: TLS 1.3

TLS (Transport Layer Security) encrypts data in transit. TLS 1.3 is the mandatory minimum; TLS 1.0/1.1 must be disabled everywhere.

**Key improvements in TLS 1.3:**
- Only forward-secure cipher suites (ECDHE)
- Handshake in 1 Round Trip (RTT) instead of 2
- 0-RTT resumption (with caveats about replay attacks)
- Removed legacy algorithms: RSA key exchange, SHA-1, DES

### 4.3 TLS Handshake (Simplified)

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
  │  ← Both compute session key →     │
  │    ECDH(client_private, server_pub)│
  │                                    │
  │  {Finished}                        │
  │───────────────────────────────────▶│
  │                                    │
  │  [Encrypted Application Data]      │
  │◀──────────────────────────────────▶│
```

TLS 1.3: the entire handshake takes **1 RTT** (versus 2 RTT in TLS 1.2).

### 4.4 Certificate Management

**Let's Encrypt** — free TLS certificates, automatic renewal via ACME protocol.

```bash
# certbot automatically obtains and renews certificates
certbot --nginx -d example.com -d www.example.com

# Auto-renewal via cron or systemd timer
certbot renew --quiet
```

**cert-manager in Kubernetes** — automates the entire certificate lifecycle:

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

cert-manager will request, obtain, store in a Secret, and renew the certificate before it expires.

### 4.5 mTLS (Mutual TLS)

Standard TLS: the client verifies the server's certificate.  
mTLS: **both** verify each other's certificates. Ideal for service-to-service authentication.

```
Service A                              Service B
  │                                        │
  │  "I am Service A, here is my cert"    │
  │───────────────────────────────────────▶│
  │                                        │ Verifies: is A's certificate
  │  "I am Service B, here is my cert"    │ signed by our internal CA?
  │◀───────────────────────────────────────│
  │  Verifies: is B's certificate         │
  │  signed by our internal CA?           │
  │                                        │
  │  [Encrypted traffic]                  │
  │◀──────────────────────────────────────▶│
```

In a service mesh (Istio, Linkerd), mTLS is enabled automatically — the sidecar proxy (Envoy) handles everything. Your code knows nothing about TLS.

### 4.6 Password Hashing

**NEVER** hash passwords with MD5 or SHA-256. They are too fast — billions of hashes per second on a GPU.

**Correct algorithms:**

| Algorithm | Configuration | Usage |
|-----------|--------------|-------|
| **bcrypt** | cost factor (12–14) | Standard for most applications |
| **argon2id** | memory, iterations, parallelism | Recommended by OWASP, more flexible |
| **scrypt** | N, r, p | A good alternative |

**Why bcrypt being slow is a feature, not a bug.** At cost=12: ~250ms per check. Imperceptible to the user. For brute-force: 4 attempts per second instead of billions.

### 4.7 Go Example: Password Hashing with bcrypt

```go
package auth

import (
    "errors"
    "fmt"

    "golang.org/x/crypto/bcrypt"
)

const bcryptCost = 12 // OWASP recommends minimum 10, 12 is a balance of security and speed

// HashPassword creates a bcrypt hash of the password
func HashPassword(password string) (string, error) {
    if len(password) < 8 {
        return "", errors.New("password must be at least 8 characters")
    }

    // bcrypt automatically generates a salt and includes it in the hash
    hash, err := bcrypt.GenerateFromPassword([]byte(password), bcryptCost)
    if err != nil {
        return "", fmt.Errorf("hashing password: %w", err)
    }

    return string(hash), nil
}

// CheckPassword compares a password against the stored hash
func CheckPassword(password, hash string) error {
    err := bcrypt.CompareHashAndPassword([]byte(hash), []byte(password))
    if err != nil {
        if errors.Is(err, bcrypt.ErrMismatchedHashAndPassword) {
            return errors.New("invalid credentials") // Don't specify what exactly is wrong
        }
        return fmt.Errorf("comparing password: %w", err)
    }
    return nil
}

// NeedsRehash checks whether rehashing is needed (when increasing cost)
func NeedsRehash(hash string) bool {
    cost, err := bcrypt.Cost([]byte(hash))
    if err != nil {
        return true
    }
    return cost < bcryptCost
}
```

```go
// User registration
func Register(email, password string) error {
    hash, err := auth.HashPassword(password)
    if err != nil {
        return err
    }
    // Store hash in DB, NOT the password
    return db.SaveUser(email, hash)
}

// Login
func Login(email, password string) error {
    user, err := db.FindUserByEmail(email)
    if err != nil {
        // Important: identical response time for "user not found"
        // and "wrong password" — guards against timing attacks
        bcrypt.CompareHashAndPassword([]byte("$2a$12$dummy"), []byte(password))
        return errors.New("invalid credentials")
    }

    if err := auth.CheckPassword(password, user.PasswordHash); err != nil {
        return errors.New("invalid credentials")
    }

    // On login — check if rehashing is needed
    if auth.NeedsRehash(user.PasswordHash) {
        newHash, _ := auth.HashPassword(password)
        db.UpdatePasswordHash(user.ID, newHash)
    }

    return nil
}
```

---

## 5. OWASP Top 10 for Developers

[OWASP Top 10](https://owasp.org/www-project-top-ten/) — a list of the most critical web application vulnerabilities. Updated every few years.

### 5.1 SQL Injection

**The oldest vulnerability and still very relevant.** If you see string concatenation in SQL — it's a bug.

```go
// ❌ NEVER DO THIS
query := "SELECT * FROM users WHERE email = '" + email + "'"
// Attack: email = "' OR '1'='1" — returns all users
// Attack: email = "'; DROP TABLE users; --" — deletes the table

// ✅ ALWAYS USE PARAMETERIZED QUERIES
var user User
err := db.QueryRowContext(ctx,
    "SELECT id, email, role FROM users WHERE email = $1",
    email,  // parameter, never inserted directly into the query body
).Scan(&user.ID, &user.Email, &user.Role)
```

With ORM (e.g., GORM):
```go
// ✅ GORM is safe when used correctly
db.Where("email = ?", email).First(&user)

// ❌ BUT NOT LIKE THIS (raw SQL without parameters)
db.Where("email = '" + email + "'").First(&user)
```

**Rule:** placeholder (`?`, `$1`) — always; string concatenation in SQL — never.

### 5.2 XSS (Cross-Site Scripting)

An attacker injects JavaScript into a page that executes in the victim's browser. Enables cookie theft, redirects, phishing.

**Types of XSS:**
- **Stored XSS**: script is stored in the DB and shown to all users
- **Reflected XSS**: script is in a URL parameter and reflected in the response
- **DOM-based XSS**: client-side DOM manipulation

```go
// Backend: sanitize HTML incoming from users
import "github.com/microcosm-cc/bluemonday"

policy := bluemonday.UGCPolicy() // allows safe HTML (links, basic formatting)

// For content where HTML is not needed at all:
strictPolicy := bluemonday.StrictPolicy() // removes all HTML

safeContent := policy.Sanitize(userInput)
```

**Content Security Policy (CSP)** — browser protection that restricts script sources:

```go
// Middleware for CSP header
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

A victim visits a malicious site that makes a request on their behalf to your API (using stored cookies).

```
Victim (logged in at bank.com)
  │
  │ Opens evil.com
  │
  ▼
evil.com: <img src="https://bank.com/transfer?to=attacker&amount=1000">
         <form action="https://bank.com/transfer" method="POST">
           <input name="to" value="attacker">
           <input name="amount" value="1000">
         </form>
         <script>document.forms[0].submit()</script>
```

**Defenses:**

1. **SameSite Cookie** — the browser does not send cookies on cross-site requests:
```go
http.SetCookie(w, &http.Cookie{
    Name:     "session_id",
    Value:    sessionID,
    HttpOnly: true,
    Secure:   true,
    SameSite: http.SameSiteStrictMode, // or LaxMode
    Path:     "/",
})
```

2. **CSRF Token** — a unique token in the form, verified by the server:
```go
// Generate CSRF token
func generateCSRFToken() string {
    b := make([]byte, 32)
    rand.Read(b)
    return base64.URLEncoding.EncodeToString(b)
}

// Check: token from header must match token from session
requestToken := r.Header.Get("X-CSRF-Token")
sessionToken := session.CSRFToken
if !hmac.Equal([]byte(requestToken), []byte(sessionToken)) {
    http.Error(w, "invalid csrf token", http.StatusForbidden)
    return
}
```

### 5.4 SSRF (Server-Side Request Forgery)

The server makes an HTTP request to a URL provided by the user. The attacker supplies internal addresses.

```
Attack: POST /api/fetch-url
        {"url": "http://169.254.169.254/latest/meta-data/iam/credentials"}
        
This is the AWS Instance Metadata Service — it returns credentials of the instance's IAM role!
Or: {"url": "http://internal-admin-service:8080/admin"}
```

```go
// Validate URL before making the request
func validateURL(rawURL string) error {
    parsed, err := url.Parse(rawURL)
    if err != nil {
        return fmt.Errorf("invalid url: %w", err)
    }

    // Only allowed schemes
    if parsed.Scheme != "https" {
        return errors.New("only https allowed")
    }

    // Resolve hostname and check IP
    addrs, err := net.LookupHost(parsed.Hostname())
    if err != nil {
        return fmt.Errorf("dns lookup failed: %w", err)
    }

    for _, addr := range addrs {
        ip := net.ParseIP(addr)
        if ip == nil {
            continue
        }
        // Block private ranges
        if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() {
            return fmt.Errorf("private/internal addresses not allowed: %s", addr)
        }
    }

    return nil
}
```

> **Important:** DNS rebinding attacks — an attacker can first resolve a public IP (passes the check), then the DNS record changes to an internal IP. Solution: check the IP at connection time, not only during resolution (or use specialized libraries).

### 5.5 Broken Access Control

One of the most common vulnerabilities. You check rights at the entry point but not at the data level.

```go
// ❌ Only checking authentication, not ownership
func getDocument(w http.ResponseWriter, r *http.Request) {
    claims, _ := ClaimsFromContext(r.Context())
    docID := r.PathValue("id")
    
    doc, _ := db.GetDocument(docID) // Any logged-in user can get any document!
    json.NewEncoder(w).Encode(doc)
}

// ✅ Check ownership/rights at the data level
func getDocument(w http.ResponseWriter, r *http.Request) {
    claims, _ := ClaimsFromContext(r.Context())
    docID := r.PathValue("id")
    
    doc, err := db.GetDocumentForUser(docID, claims.UserID) // WHERE id=$1 AND owner_id=$2
    if err != nil {
        if errors.Is(err, sql.ErrNoRows) {
            http.Error(w, "not found", http.StatusNotFound) // Not 403, hide existence
            return
        }
        http.Error(w, "internal error", http.StatusInternalServerError)
        return
    }
    
    json.NewEncoder(w).Encode(doc)
}
```

**IDOR (Insecure Direct Object Reference)** — a specific case: `/api/invoices/1337` is accessible to any user who knows the ID. Solution: either check ownership, or use unpredictable UUIDs instead of sequential IDs.

### 5.6 Security Headers

A set of HTTP headers that enable browser-level protection:

| Header | Purpose | Recommended Value |
|--------|---------|------------------|
| `Strict-Transport-Security` | Force HTTPS | `max-age=31536000; includeSubDomains` |
| `X-Content-Type-Options` | Disable MIME sniffing | `nosniff` |
| `X-Frame-Options` | Clickjacking protection | `DENY` or `SAMEORIGIN` |
| `Content-Security-Policy` | Restrict resource sources | Depends on the application |
| `Referrer-Policy` | Control the Referer header | `strict-origin-when-cross-origin` |
| `Permissions-Policy` | Control browser features | `camera=(), microphone=(), geolocation=()` |

### 5.7 Go Example: Security Headers Middleware

```go
package middleware

import "net/http"

// SecurityHeaders adds standard security headers
func SecurityHeaders(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        h := w.Header()

        // Force HTTPS for 1 year, including subdomains
        h.Set("Strict-Transport-Security", "max-age=31536000; includeSubDomains; preload")

        // Disable MIME type sniffing
        h.Set("X-Content-Type-Options", "nosniff")

        // Prevent framing (clickjacking protection)
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

        // Referrer control
        h.Set("Referrer-Policy", "strict-origin-when-cross-origin")

        // Restrict browser features
        h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=()")

        // Remove X-Powered-By (exposes framework information)
        h.Del("X-Powered-By")

        next.ServeHTTP(w, r)
    })
}
```

```go
// Usage: outermost middleware layer
handler := middleware.SecurityHeaders(
    middleware.RequestLogger(
        middleware.RateLimit(100)(
            router,
        ),
    ),
)
http.ListenAndServeTLS(":443", certFile, keyFile, handler)
```

Check headers via [securityheaders.com](https://securityheaders.com) or [observatory.mozilla.org](https://observatory.mozilla.org).

---

## 6. Secrets Management

### 6.1 The Problem

Credentials in code or environment variables — a common mistake with serious consequences.

```bash
# ❌ Common anti-patterns

# 1. Hardcoded in code
db_password := "P@ssw0rd123"  // Ends up in git history forever

# 2. .env file in the repository
echo "DB_PASSWORD=secret" >> .env
git add .env  # Ends up on GitHub, found by scanners

# 3. Docker ENV
ENV DB_PASSWORD=secret  # Visible in docker inspect

# 4. K8s ConfigMap (not Secret)
# ConfigMap is not encrypted even in etcd
```

**The real cost of a leak:** GitHub scans commits for known secret formats (AWS keys, GCP service account keys). An AWS key leaked into a public repo → credential abuse within minutes.

### 6.2 HashiCorp Vault

Centralized secret storage with dynamic credential generation.

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

**Dynamic secrets** — Vault creates temporary credentials (e.g., a PostgreSQL user) per request with a short TTL. No shared passwords between services.

```bash
# Vault creates a temporary DB user
vault read database/creds/myapp-role
# Key                Value
# lease_id           database/creds/myapp-role/xyz
# lease_duration     1h
# username           v-myapp-abc123
# password           A1S2d3F4g5H6
# After 1 hour, credentials are automatically revoked
```

### 6.3 AWS Secrets Manager and GCP Secret Manager

Managed solutions for cloud-native applications.

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
# K8s Secret — base64, NOT encrypted
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
type: Opaque
data:
  password: cGFzc3dvcmQxMjM=  # echo -n "password123" | base64
```

**Problems with K8s Secrets:**
- Stored in etcd in base64 (not encryption!)
- By default accessible to any pod in the namespace
- End up in YAML manifests → git repository

**Solutions:**

1. **Encryption at Rest in etcd** — configure `EncryptionConfiguration` in kube-apiserver
2. **Sealed Secrets** (Bitnami) — encrypts the Secret with a public key, only the operator in the cluster can decrypt it
3. **External Secrets Operator** — syncs secrets from Vault/AWS SM/GCP SM into K8s Secrets

```yaml
# External Secrets Operator: sync from AWS Secrets Manager
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
    name: db-credentials  # creates a regular K8s Secret
  data:
    - secretKey: password
      remoteRef:
        key: myapp/db
        property: password
```

### 6.5 Automatic Secret Rotation

```
┌──────────────────────────────────────────────────────────┐
│               Secret Rotation Strategy                   │
│                                                          │
│  1. Vault/AWS SM generates a new secret                  │
│  2. Updates it in the store                              │
│  3. Notifies applications (webhook / polling)            │
│  4. Applications re-read the secret                      │
│  5. Old secret is deactivated after N minutes            │
│                                                          │
│  ┌─────────┐    ┌──────────────┐    ┌─────────────────┐ │
│  │  Vault  │───▶│  App reads   │───▶│ Reconnect to DB │ │
│  │ rotates │    │  new creds   │    │ with new creds  │ │
│  └─────────┘    └──────────────┘    └─────────────────┘ │
│                                                          │
│  Zero-downtime rotation requires:                        │
│  - DB supports two active users simultaneously           │
│  - Application gracefully reconnects                     │
└──────────────────────────────────────────────────────────┘
```

### 6.6 Example: Reading Secrets from Vault in Go

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

// NewKubernetesClient creates a Vault client with Kubernetes auth
func NewKubernetesClient(vaultAddr, role string) (*Client, error) {
    config := vault.DefaultConfig()
    config.Address = vaultAddr

    client, err := vault.NewClient(config)
    if err != nil {
        return nil, fmt.Errorf("creating vault client: %w", err)
    }

    // Kubernetes auth: reads JWT from /var/run/secrets/kubernetes.io/serviceaccount/token
    k8sAuth, err := auth.NewKubernetesAuth(role)
    if err != nil {
        return nil, fmt.Errorf("creating k8s auth: %w", err)
    }

    authInfo, err := client.Auth().Login(context.Background(), k8sAuth)
    if err != nil {
        return nil, fmt.Errorf("vault login: %w", err)
    }

    // Start background token renewal
    go renewToken(client, authInfo)

    return &Client{
        vault: client,
        cache: &SecretCache{
            secrets: make(map[string]string),
            expiry:  make(map[string]time.Time),
        },
    }, nil
}

// GetSecret returns a secret with caching
func (c *Client) GetSecret(ctx context.Context, path, key string) (string, error) {
    cacheKey := path + "#" + key

    // Check cache
    c.cache.mu.RLock()
    if val, ok := c.cache.secrets[cacheKey]; ok {
        if time.Now().Before(c.cache.expiry[cacheKey]) {
            c.cache.mu.RUnlock()
            return val, nil
        }
    }
    c.cache.mu.RUnlock()

    // Fetch from Vault
    secret, err := c.vault.KVv2("secret").Get(ctx, path)
    if err != nil {
        return "", fmt.Errorf("reading secret %s: %w", path, err)
    }

    val, ok := secret.Data[key].(string)
    if !ok {
        return "", fmt.Errorf("key %s not found in secret %s", key, path)
    }

    // Cache for 5 minutes
    c.cache.mu.Lock()
    c.cache.secrets[cacheKey] = val
    c.cache.expiry[cacheKey] = time.Now().Add(5 * time.Minute)
    c.cache.mu.Unlock()

    return val, nil
}

func renewToken(client *vault.Client, authInfo *vault.Secret) {
    // In practice: use client.NewLifetimeWatcher
    ticker := time.NewTicker(10 * time.Minute)
    for range ticker.C {
        client.Auth().Token().RenewSelf(0)
    }
}
```

```go
// Usage at application startup
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

### 7.1 Zero Trust Principles

Traditional model: "everything inside the perimeter is safe". An attacker gets inside → full access to everything.

Zero Trust: **"never trust, always verify"**.

```
Old model (Castle and Moat):
┌────────────────────────────────────┐
│         Corporate Network          │
│  ┌──────┐  ┌──────┐  ┌──────────┐ │
│  │ DB   │  │ API  │  │ Service  │ │
│  │      │◀─│      │◀─│          │ │ Inside → trusted
│  └──────┘  └──────┘  └──────────┘ │
└──────────────────────┬─────────────┘
                       │ Firewall
                    Internet
                    
Problem: one compromised service → access to everything

Zero Trust:
┌──────────────────────────────────────────┐
│  Every request:                          │
│  ✓ Authenticated (mTLS)                  │
│  ✓ Authorized (least privilege)          │
│  ✓ Logged and verified                   │
│  ✓ Encrypted (even internal traffic)     │
└──────────────────────────────────────────┘
```

### 7.2 The Three Pillars of Zero Trust

**1. Verify Explicitly**  
Every request is verified regardless of its source. Internal network is not a security guarantee.

```
Service A → Service B:
  - mTLS: verify Service A's certificate
  - JWT: verify user identity (user context propagation)
  - Authorization: verify Service A's rights on the endpoint
  - Audit log: record every inter-service call
```

**2. Least Privilege**  
Each component receives the minimum set of permissions needed for its operation.

```yaml
# K8s: ServiceAccount with minimal permissions
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
    resourceNames: ["order-service-config"]  # Only this specific ConfigMap
    verbs: ["get"]  # Read-only, not write
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
Design as if an attacker is already inside. Isolate the blast radius.

```
Measures under Assume Breach:
- Micro-segmentation: network policies between services
- Encrypt everything: even internal traffic
- Centralized logging: SIEM for anomaly detection
- Secrets rotation: a compromised secret → quickly becomes stale
- Canary tokens: decoys for detecting an attacker
```

### 7.3 Practical Tools

#### Network Policies in Kubernetes

```yaml
# Default: deny all traffic
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}  # all pods
  policyTypes:
    - Ingress
    - Egress
---
# Allow: only order-service → payment-service:8080
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

#### mTLS in Istio Service Mesh

```yaml
# PeerAuthentication: require mTLS for the entire namespace
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: production
spec:
  mtls:
    mode: STRICT  # mTLS only, plaintext is forbidden
---
# AuthorizationPolicy: order-service can only call the /payments endpoint
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

In a microservices architecture, it is important to propagate user identity through the call chain:

```
Client → API Gateway → Service A → Service B → Service C
   JWT ────────────────────────────────────────────▶
                       Each service sees: who the user is,
                       what their permissions are, for the audit log
```

```go
// Passing user context through gRPC metadata
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

## 8. DDoS Protection and Web Application Firewall

### 8.1 Types of DDoS Attacks

```
┌─────────────────────────────────────────────────────────────┐
│                    DDoS Attack Types                        │
│                                                             │
│  Layer 3/4 (Network/Transport) — Volumetric                │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ UDP Flood, ICMP Flood, SYN Flood                      │  │
│  │ Goal: saturate bandwidth                              │  │
│  │ Scale: terabits/sec                                   │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                             │
│  Layer 4 (Transport) — Protocol Attacks                    │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ SYN Flood, Ping of Death, Smurf Attack                │  │
│  │ Goal: exhaust network equipment resources             │  │
│  │ Millions of packets/sec                               │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                             │
│  Layer 7 (Application) — Application Layer                 │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ HTTP Flood, Slowloris, Cache Busting                  │  │
│  │ Goal: overload the application, not the channel       │  │
│  │ Legitimate-looking requests — hard to filter          │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

**Slowloris** — a special type: opens many connections and sends HTTP headers very slowly. The server keeps connections open until its thread pool is exhausted. Defense: timeout on receiving the complete request.

### 8.2 Defense Layers

```
Internet
   │
   ▼
┌─────────────────────────────────┐
│    Cloudflare / AWS Shield      │  ← Anycast network, absorbs volumetric
│    (Edge Layer)                 │    Capacity: 100+ Tbps
└────────────────┬────────────────┘
                 │ Cleaned traffic
                 ▼
┌─────────────────────────────────┐
│    WAF (Web Application         │  ← Filters L7 attacks
│    Firewall)                    │    SQL injection, XSS, OWASP rules
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│    Load Balancer + Rate Limiter │  ← Rate limiting by IP/user/API key
│    (nginx, HAProxy, Envoy)      │
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│    Application                  │  ← Application-level rate limiting
│                                 │    Business logic protection
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
    rate     rate.Limit  // requests per second
    burst    int         // maximum burst
}

func NewIPRateLimiter(r rate.Limit, burst int) *IPRateLimiter {
    rl := &IPRateLimiter{rate: r, burst: burst}
    
    // Periodically clean up old limiters
    go func() {
        for range time.Tick(time.Minute) {
            rl.limiters.Range(func(key, _ interface{}) bool {
                // Delete old entries (simplified)
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

// RateLimit middleware: 10 requests/sec per IP, burst 20
func RateLimit(r rate.Limit, burst int) func(http.Handler) http.Handler {
    limiter := NewIPRateLimiter(r, burst)
    
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            ip := realIP(r) // account for X-Forwarded-For behind proxy
            
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
    // Behind Cloudflare/proxy: real IP in header
    if ip := r.Header.Get("CF-Connecting-IP"); ip != "" {
        return ip
    }
    if ip := r.Header.Get("X-Real-IP"); ip != "" {
        return ip
    }
    // Fallback: RemoteAddr (don't trust if behind proxy)
    return r.RemoteAddr
}
```

**Rate limiting strategies:**

| Strategy | Description | Usage |
|----------|-------------|-------|
| Per IP | Limit per IP address | Basic bot protection |
| Per User | Limit per authenticated user | API fairness |
| Per API Key | Limit per key | Billing by plan |
| Per Endpoint | Different limits for expensive operations | `/search` stricter than `/ping` |
| Global | Overall limit for the entire service | Emergency throttling |

### 8.4 WAF (Web Application Firewall)

WAF analyzes HTTP traffic and blocks malicious requests based on rules.

**Managed WAF solutions:**

| Provider | Product | Level |
|----------|---------|-------|
| Cloudflare | WAF + Bot Management | Edge, in front of your server |
| AWS | AWS WAF + Shield | Integration with ALB/CloudFront |
| GCP | Cloud Armor | Integration with Load Balancer |
| Open Source | ModSecurity + OWASP Core Rule Set | Self-hosted |

**OWASP ModSecurity Core Rule Set (CRS)** — a set of ModSecurity rules covering OWASP Top 10.

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
Tools for distinguishing bots from humans:

1. CAPTCHA / reCAPTCHA v3
   - Score 0.0-1.0: bot probability
   - Does not interrupt the user (v3)
   - Apply on: registration, login, checkout

2. Browser fingerprinting
   - JavaScript challenge: expect JS execution
   - TLS fingerprint (JA3): browsers vs headless Chrome
   - Behavioral analytics: mouse movements, timings

3. IP reputation
   - Blocklist known Tor exit nodes
   - Blocklist datacenter IP ranges (AWS, GCP → not humans)
   - Cloudflare Bot Score

4. Rate limiting + progressively harder challenges
   - Suspicious IP → CAPTCHA
   - Very suspicious → block
```

```go
// Example: Google reCAPTCHA v3 verification in Go
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
    
    // Continue with registration
}
```

---

## Module Map

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

## Code Review Checklist

- [ ] SQL queries use parameterized queries — no string concatenation
- [ ] Passwords are hashed with bcrypt/argon2, not md5/sha256
- [ ] JWT validates the signing algorithm (don't trust `alg` from the header)
- [ ] HTTP cookies: `HttpOnly`, `Secure`, `SameSite=Strict/Lax`
- [ ] No secrets in code, `.env` files, or Docker ENV
- [ ] Authorization is checked at the data level (not only at the entry point)
- [ ] User input is sanitized before being output as HTML
- [ ] Security headers are set (HSTS, CSP, X-Content-Type-Options)
- [ ] Rate limiting is configured on expensive endpoints
- [ ] SSRF protection: URL validation before fetch
- [ ] TLS 1.0/1.1 are disabled, only 1.2+ (preferably 1.3)
- [ ] Identical response time for "user not found" and "wrong password"
- [ ] Logs do not contain passwords, tokens, or PII data

## Resources

- [OWASP Top 10](https://owasp.org/www-project-top-ten/) — current vulnerability list
- [OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/) — specific recommendations for each topic
- [Google BeyondCorp](https://cloud.google.com/beyondcorp) — reference Zero Trust implementation
- [Zanzibar paper](https://research.google/pubs/zanzibar-googles-consistent-global-authorization-system/) — Google's authorization system
- [JWT.io](https://jwt.io/) — JWT decoder and documentation
- [HashiCorp Vault docs](https://developer.hashicorp.com/vault/docs) — Vault documentation
- [securityheaders.com](https://securityheaders.com) — HTTP headers checker
