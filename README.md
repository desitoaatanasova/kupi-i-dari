# Купи и Дари

Charity campaign management platform: Flutter (Web + Android) client, Node.js/Express
REST API, MySQL 8 (hand-written SQL, no ORM).

> **Status: Phase 30 — Volunteer registration and real authentication.**
> The backend domain features are complete through Phase 12, and the database
> schema/migrations and Flutter client exist. Phase 2 added staff login,
> volunteer identification, JWT authentication/revocation, and auth rate
> limiting. Phase 3 added admin-only
> user management (list, create, read, update, activate/deactivate) with
> last-active-admin protection. Phase 4 added
> public location reads plus admin-only location management (create, update,
> archive/reactivate) and atomic replacement of a location's responsible
> assignees. Phase 5 added a product catalog and its variants: public reads of
> active products/variants plus admin-only product/variant management (create,
> update, archive/reactivate). Phase 6 added quantity recording per location and
> variant (atomic upsert and absolute correction). Phase 7 added shift scheduling
> at one or more locations with volunteer self-registration and cancellation.
> Phase 8 lets registered volunteers record quantities while a shift is open,
> linked to `(shift, location, variant)`, alongside the existing staff quantity
> API. Phase 9 adds a read-only collected quantity report (`GET /api/reports/collected`)
> for admins and responsible users (scoped to assigned locations). Phase 10 adds
> an authenticated password-change endpoint and centrally enforces the
> `must_change_password` flag. Phase 11 records the **distribution** of collected
> goods to recipients under `/api/distributions` (admin and responsible, scoped to
> assigned locations). Phase 12 adds a read-only **inventory balance** report
> (`GET /api/reports/inventory`) combining collected and distributed quantities
> into a remaining balance. Phase 30 adds public volunteer registration and
> passwordless login for existing volunteers (`POST /api/auth/register`,
> `POST /api/auth/volunteer/login`), while keeping staff password login
> (`POST /api/auth/login`) and the legacy volunteer endpoint
> (`POST /api/auth/volunteer`) compatible. No other business functionality
> (purchases, donations, inventory mutations, dashboards) is implemented yet.

The Flutter client is tracked separately at **client Phase 30 — volunteer
registration and real authentication**; see [Client phases](#client-phases)
below.

## Layout

```
backend/                 Node.js/Express API
  src/                   app, config, db pool, migrations runner, routes
  scripts/               migrate, seed-admin, db:reset:test
  test/                  node --test suites
database/migrations/     ordered, checksum-verified .sql migrations
app/                     Flutter app (Web + Android)
```

Migrations live in `database/migrations` and are applied in filename order. Each
applied migration is recorded in `schema_migrations` with a SHA-256 checksum; if a
previously applied file changes, the runner **stops** rather than silently
re-applying it. To change schema, add a new forward migration.

## Prerequisites

- Node.js >= 18
- MySQL 8 running locally
- Flutter SDK (for the `app/` client)

## Backend setup

```sh
cd backend
npm install
cp .env.example .env      # then fill in DB_PASSWORD, JWT_SECRET, SEED_ADMIN_PASSWORD
npm run migrate           # apply migrations to DB_NAME
npm run seed:admin        # create the bootstrap administrator (idempotent)
npm start                 # http://localhost:3001
```

Health check:

```sh
curl http://localhost:3001/api/health
# {"status":"ok","database":"ok","timezone":"Europe/Sofia"}
```

## Authentication (Phase 2, extended in Phase 30)

Auth endpoints live under `/api/auth` and follow the structured error contract
`{ "error": { "code": "...", "message": "..." } }`.

| Method | Path                        | Auth       | Purpose                                      |
| ------ | --------------------------- | ---------- | -------------------------------------------- |
| POST   | `/api/auth/login`           | none       | Staff sign-in (phone + password)             |
| POST   | `/api/auth/register`        | none       | Public volunteer registration (VOLUNTEER only) |
| POST   | `/api/auth/volunteer/login` | none       | Existing volunteer login (name + phone)      |
| POST   | `/api/auth/volunteer`       | none       | Legacy volunteer identify/create (unchanged, backward compatible) |
| GET    | `/api/auth/me`              | Bearer JWT | Current safe profile                         |
| POST   | `/api/auth/password/change` | Bearer JWT | Password change (Phase 10)                   |
| POST   | `/api/auth/logout`          | Bearer JWT | Revoke tokens (204, no body)                 |

Request bodies:

```jsonc
// POST /api/auth/login
{ "phone": "+359881234567", "password": "..." }

// POST /api/auth/register
{ "firstName": "Мария", "lastName": "Иванова", "phone": "0888123456",
  "role": "VOLUNTEER" }

// POST /api/auth/volunteer/login
{ "firstName": "Мария", "lastName": "Иванова", "phone": "0888123456" }

// POST /api/auth/volunteer (legacy)
{ "firstName": "Мария", "lastName": "Иванова", "phone": "0888123456" }
```

Phones are normalised to `+359XXXXXXXXX`; accepted inputs are `+359…`, `00359…`
and national `0…`, with optional spaces, hyphens and parentheses.

**Staff login** (`POST /api/auth/login`) accepts a phone and password and returns
a JWT for active `RESPONSIBLE` / `ADMIN` accounts. Passwords are stored only as
bcrypt hashes (cost 12) and are never returned. Public registration rejects staff
roles, so `RESPONSIBLE` / `ADMIN` accounts are created only by an administrator
through `/api/admin/users` (see below).

**Public volunteer registration** (`POST /api/auth/register`) accepts only
`role: "VOLUNTEER"`, creates a passwordless volunteer account, and returns
`201` with the normal token response. A phone already in use returns
`409 PHONE_TAKEN`; invalid or privileged role values (including `ADMIN`/`RESPONSIBLE` and omitted/unknown roles) return
`400 VALIDATION_ERROR`. `ADMIN` and `RESPONSIBLE` accounts are created only by an administrator
(via the admin user management mechanism). Name fields are trimmed and whitespace-collapsed, and the
phone is canonicalised.

**Existing volunteer login** (`POST /api/auth/volunteer/login`) never creates an
account. It matches an active `VOLUNTEER` by phone plus case-insensitive first
and last name after whitespace normalisation. Unknown phone, name mismatch and staff accounts all return the
same generic `401 INVALID_CREDENTIALS`; a matching disabled account returns
`403 ACCOUNT_DISABLED`. This mechanism is identification only (name + phone) — it is not SMS/OTP/PIN verification
and does not prove phone number ownership.

**Legacy volunteer identification** (`POST /api/auth/volunteer`) keeps its old
identify-or-create behaviour for backward compatibility. The Flutter client no
longer uses it.

Volunteer login/identification is deliberately weak — *it is identification, not
strong authentication*. Anyone who knows a volunteer's name and phone number can
impersonate them. This is mitigated only by short token expiry, dedicated rate
limiters, and low volunteer permissions. No SMS/OTP/PIN flow is implemented.

Tokens are HS256 JWTs with claims `sub`, `role`, `tv` (token version), `iat`,
`exp`. Expiry defaults to `JWT_EXPIRES_IN=60m` and is reported as integer
seconds. `POST /api/auth/logout` atomically increments `users.token_version`, so
every previously issued token is rejected immediately by protected endpoints.
`must_change_password` enforcement and the JWT/role guards remain in force (see
[Forced password change](#forced-password-change-phase-10)).

**Client sessions.** The Flutter client keeps the session **in memory only**
(no persistent token storage). The role used for navigation and guards always
comes from the backend `user.role` in the token response, never from a local
role selection. The central `onUnauthorized` handler clears the session only for
an HTTP `401` with code `UNAUTHORIZED` — a failed login (`401
INVALID_CREDENTIALS`) does not trigger it.

Out of scope: staff self-registration, password reset/recovery, admin-initiated
password resets, persistent client tokens, and all later-phase domain features.
(Forced password change is enforced from Phase 10 — see below.)

## Admin user management (Phase 3)

Admin endpoints live under `/api/admin` and require a Bearer token for an active
`ADMIN` account. Every response uses the same safe profile as `/api/auth/me`
(`id`, `phone`, `firstName`, `lastName`, `role`, `isActive`,
`mustChangePassword`) — password hashes, tokens and `token_version` are never
returned.

| Method | Path                              | Purpose                                  |
| ------ | --------------------------------- | ---------------------------------------- |
| GET    | `/api/admin/users`                | Paginated list (`role`, `isActive`, `page`, `pageSize`) |
| POST   | `/api/admin/users`                | Provision a `RESPONSIBLE`/`ADMIN` account |
| GET    | `/api/admin/users/:userId`        | Fetch one user                            |
| PATCH  | `/api/admin/users/:userId`        | Update `firstName`/`lastName`/`phone`     |
| PATCH  | `/api/admin/users/:userId/status` | Activate/deactivate a user                |

```jsonc
// POST /api/admin/users
{ "firstName": "Иван", "lastName": "Петров", "phone": "0888123456",
  "role": "RESPONSIBLE", "password": "at-least-8-chars" }
```

Created staff are stored with `must_change_password = 1` and `created_by` set to
the acting administrator. Passwords are bcrypt hashes (cost 12) and are never
trimmed before hashing. `PATCH .../status` refuses to deactivate the acting
administrator (`SELF_DEACTIVATION`) or the last active administrator
(`LAST_ADMIN`), using a transaction that locks the admin set. Write endpoints
share a dedicated rate limiter.

### Environment variables

See `backend/.env.example`. Key values: `PORT`, `DB_HOST`, `DB_PORT`, `DB_NAME`,
`DB_USER`, `DB_PASSWORD`, `NODE_ENV`, `TZ` (default `Europe/Sofia`).

Auth/rate-limit values: `JWT_SECRET` (required to start the API), `JWT_EXPIRES_IN`
(default `60m`), `AUTH_RATE_LIMIT_WINDOW_MS` (default `900000`), `AUTH_RATE_LIMIT_MAX`
(staff login, default `10`), `AUTH_VOLUNTEER_RATE_LIMIT_MAX` (default `20`; used
by separate legacy volunteer, public registration and strict volunteer-login
buckets), `AUTH_ADMIN_WRITE_RATE_LIMIT_MAX` (admin writes, default `30`), plus
global CORS/rate-limit settings. `DB_PASSWORD` and `JWT_SECRET` are never committed.

### Database scripts

| Command                 | Effect                                                        |
| ----------------------- | ------------------------------------------------------------- |
| `npm run migrate`       | Apply pending migrations to `DB_NAME` (checksum-verified)     |
| `npm run db:reset:test` | **Destructive.** Drops/recreates `DB_NAME_TEST` and migrates  |
| `npm run seed:admin`    | Create bootstrap ADMIN if the seed phone does not exist       |

`db:reset:test` refuses to run unless the target database name ends with `_test`.

## Locations & responsible assignments (Phase 4)

Locations are the collection points where shifts take place. Endpoints live under
`/api/locations` and reuse the structured error contract
`{ "error": { "code": "...", "message": "..." } }`.

**Access policy.** Reading locations is **public** (active collection points are
non-sensitive). All writes and all responsible-assignment routes require a Bearer
token for an active `ADMIN` account, because assignment responses contain user
phone numbers.

| Method | Path                                      | Auth        | Purpose                                   |
| ------ | ----------------------------------------- | ----------- | ----------------------------------------- |
| GET    | `/api/locations`                          | none        | List active locations (by name, then id)  |
| GET    | `/api/locations/:locationId`              | none        | Read one active location                  |
| POST   | `/api/locations`                          | ADMIN       | Create a location                         |
| PATCH  | `/api/locations/:locationId`              | ADMIN       | Update `name` and/or `address`            |
| PATCH  | `/api/locations/:locationId/status`       | ADMIN       | Archive / reactivate (`isActive`)         |
| GET    | `/api/locations/:locationId/responsibles` | ADMIN       | List active `RESPONSIBLE` assignees       |
| PUT    | `/api/locations/:locationId/responsibles` | ADMIN       | Atomically replace the assignee set       |

Safe location shape (always exactly these keys):

```jsonc
{ "id": 1, "name": "Център", "address": "ул. Дунав 3", "isActive": true }
```

Request bodies:

```jsonc
// POST /api/locations
{ "name": "Център", "address": "ул. Дунав 3" }

// PATCH /api/locations/:locationId  (at least one field required)
{ "name": "Ново име" }

// PATCH /api/locations/:locationId/status
{ "isActive": false }

// PUT /api/locations/:locationId/responsibles
{ "userIds": [12, 34, 56] }   // [] clears all assignments; max 100 ids
```

`name` is 1–120 characters and `address` 1–255; both are trimmed and
whitespace-collapsed. Unknown fields are rejected with `400 VALIDATION_ERROR`.
Location names are unique under `utf8mb4_unicode_ci`, so a duplicate name
(including case variants) returns `409 NAME_TAKEN`.

**Archive semantics.** `is_active` only — locations are **never hard-deleted**.
`PATCH .../status` is idempotent; repeating the current state returns `200`.
Archived locations are excluded from the public list and their detail returns
`404` (malformed, missing and archived ids are indistinguishable). Archived
locations also cannot be updated through the normal update endpoint.

**Responsible assignments.** `GET .../responsibles` returns only active users with
role `RESPONSIBLE`, ordered by `user_id`, using the same safe user profile as
`/api/auth/me`. `PUT .../responsibles` replaces the entire set atomically inside a
transaction (the location row is locked first, then the referenced users are
validated): if any id is missing, inactive, or not a `RESPONSIBLE`, the whole
request fails with `400 INVALID_RESPONSIBLE` and the previous set is left intact.
An empty array clears all assignments.

`city` and `locations.created_by` are **not used** in Phase 4 — neither is
written nor exposed. No migration was added for this phase; the existing schema
already supports it.

## Products & variants (Phase 5)

The product catalog models a **product** (the general catalog item) and its
**variants** (specific packaged forms of it). Endpoints live under `/api/products`
and reuse the structured error contract `{ "error": { "code": "...", "message": "..." } }`.

**Access policy.** Reading products and variants is **public** — active catalog
entries are non-sensitive and mirror the Phase 4 location policy. All mutations
require a Bearer token for an active `ADMIN` account.

| Method | Path                                                     | Auth  | Purpose                                        |
| ------ | -------------------------------------------------------- | ----- | ---------------------------------------------- |
| GET    | `/api/products`                                          | none  | List active products (by name, then id)        |
| GET    | `/api/products/:productId`                               | none  | Read one active product                        |
| POST   | `/api/products`                                          | ADMIN | Create a product                               |
| PATCH  | `/api/products/:productId`                               | ADMIN | Update `name` and/or `category`                |
| PATCH  | `/api/products/:productId/status`                        | ADMIN | Archive / reactivate (`isActive`)              |
| GET    | `/api/products/:productId/variants`                      | none  | List a product's active variants               |
| POST   | `/api/products/:productId/variants`                      | ADMIN | Create a variant                               |
| PATCH  | `/api/products/:productId/variants/:variantId`           | ADMIN | Update `unitLabel` and/or `unitValue`          |
| PATCH  | `/api/products/:productId/variants/:variantId/status`    | ADMIN | Archive / reactivate a variant (`isActive`)    |

Safe shapes (always exactly these keys):

```jsonc
// Product — category may be null
{ "id": 1, "name": "Ориз", "category": "Храни", "isActive": true }

// Variant — unitValue may be null
{ "id": 5, "productId": 1, "unitLabel": "1 кг", "unitValue": 1, "isActive": true }
```

Request bodies:

```jsonc
// POST /api/products
{ "name": "Ориз", "category": "Храни" }   // category optional

// PATCH /api/products/:productId  (at least one field required)
{ "name": "Ориз басмати" }
{ "category": null }                       // clears the category

// PATCH /api/products/:productId/status
{ "isActive": false }

// POST /api/products/:productId/variants
{ "unitLabel": "1 кг", "unitValue": 1 }    // unitValue optional

// PATCH /api/products/:productId/variants/:variantId  (at least one field required)
{ "unitLabel": "500 г" }
{ "unitValue": null }                      // clears the unit value
```

`name` is 1–120 characters; `category` (optional) is 1–80; both are trimmed and
whitespace-collapsed. `unitLabel` is 1–40 characters, trimmed and
whitespace-collapsed; `unitValue` (optional) is a finite number in
`[0, 9999999.999]` with at most three decimal places. Unknown fields are rejected
with `400 VALIDATION_ERROR`. Product names are unique globally under
`utf8mb4_unicode_ci`, so a duplicate name (including case variants) returns
`409 NAME_TAKEN`; a `unitLabel` is unique **within** its product, so a duplicate
returns `409 LABEL_TAKEN`.

**Archive semantics.** `is_active` only — products and variants are **never
hard-deleted**. `PATCH .../status` is idempotent; repeating the current state
returns `200`. Archived products are excluded from the public list and their
detail returns `404` (malformed, missing and archived ids are indistinguishable).
Archived records cannot be updated through the normal update endpoints. Archiving
a product does **not** modify its variants. Archived names and labels stay
reserved by the unique indexes.

**Variants.** A variant always belongs to exactly one product. Creating a variant
requires an **active** product (a missing or archived product returns `404`);
updating one requires an active product and an active variant. A variant addressed
through the wrong product, or an inactive variant, is treated as not found
(`404`). A variant's `.../status` route requires the parent product to exist (any
state) and is idempotent.

Phase 5 required **no migration** — the Phase 1 schema already defines
`products` and `product_variants`. `products.description`, a category entity, and
structured units of measure are **not** introduced.

## Quantities & inventory (Phase 6)

Quantities record **how many units of a product variant were collected at a
location**. Endpoints live under `/api/quantities` and reuse the structured error
contract `{ "error": { "code": "...", "message": "..." } }`.

**Data model.** One row per `(location, variant)` pair. Phase 6 adds the first
migration since Phase 1
(`database/migrations/003_product_quantities.sql`): `collected_quantities.shift_id`
becomes **nullable** (shifts are not implemented) and the uniqueness moves from
`(shift_id, location_id, variant_id)` to `(location_id, variant_id)`. The
`shift_id` column and its foreign key are retained for a future shift phase; every
Phase 6 row is written with `shift_id = NULL`. The location and variant foreign
keys keep `ON DELETE RESTRICT`, so history is preserved. `quantity` is a whole
number (MySQL `INT`, `[0, 2147483647]`); **zero is valid**. Phase 8 later
supersedes the uniqueness with `(shift_id, location_id, variant_id)` so the same
pair can hold separate quantities per shift (see below).

**Access policy.** Every quantity endpoint requires a Bearer token. `ADMIN` may
read and write at any location; `RESPONSIBLE` may only access locations assigned
through `responsible_locations`; `VOLUNTEER` is always `403 FORBIDDEN`. Mutations
share the write rate limiter.

| Method | Path                          | Auth               | Purpose                                        |
| ------ | ----------------------------- | ------------------ | ---------------------------------------------- |
| GET    | `/api/quantities`             | ADMIN, RESPONSIBLE | List records (`locationId`, `variantId`, `productId`, `shiftId` filters) |
| GET    | `/api/quantities/:quantityId` | ADMIN, RESPONSIBLE | Read one record                                |
| POST   | `/api/quantities`             | ADMIN, assigned RESPONSIBLE | Create or replace a `(location, variant)` quantity |
| PATCH  | `/api/quantities/:quantityId` | ADMIN, assigned RESPONSIBLE | Replace a record's quantity absolutely         |

Safe shape (always exactly these keys; `shiftId` is extended in Phase 8 and is
`null` for a legacy unlinked record):

```jsonc
{ "id": 1, "shiftId": null, "locationId": 3, "variantId": 8, "quantity": 12 }
```

Request bodies:

```jsonc
// POST /api/quantities  (shiftId is optional; omit/null for an unlinked record)
{ "locationId": 3, "variantId": 8, "quantity": 12 }

// PATCH /api/quantities/:quantityId
{ "quantity": 10 }
```

**Atomic upsert.** `POST /api/quantities` is keyed by `(location, variant)` for an
unlinked record (or by `(shift, location, variant)` when an optional `shiftId` is
supplied — see Phase 8): the first write returns `201`, a replacement returns
`200`, and the submitted `quantity` is an **absolute replacement, never an
increment**. The location row is locked first so concurrent writes serialize (a
unique index guarantees a single row per pair, and exactly one concurrent request
creates it). `POST` validates that the location, variant and parent product are
**active** (`404 NOT_FOUND` otherwise), that a supplied shift exists, and stores
`recorded_by` as the acting user.

**Absolute correction.** `PATCH /api/quantities/:quantityId` replaces the stored
value and does **not** require the linked location, variant or product to still be
active, so a count recorded before an archive stays correctable. It never changes
the record's location or variant.

`id`/`shiftId`/`locationId`/`variantId`/`quantity` are the only exposed fields:
`recorded_by`, `recorded_at` and `updated_at` are never returned. Malformed ids
and invalid bodies return `400 VALIDATION_ERROR`; missing records and inactive
references return `404 NOT_FOUND`; unassigned `RESPONSIBLE` access returns
`403 FORBIDDEN`. There is no delete endpoint — quantity records are never
hard-deleted. Query filters are strictly validated (unknown, duplicate and
malformed parameters return `400`); an optional `shiftId` filter is supported.

## Shifts & registrations (Phase 7)

Shifts are scheduled collection sessions that take place at **one or more
locations**, and volunteers sign up for them. Endpoints live under `/api/shifts`
and reuse the structured error contract
`{ "error": { "code": "...", "message": "..." } }`.

**Data model.** A shift has a same-day window (`shift_date`, `start_time`,
`end_time`) and a lifecycle status; its locations live in `shift_locations` and
its sign-ups in `shift_registrations`. A registration is a single row per
`(shift, volunteer)`. Phase 7 required **no migration** — the Phase 1 schema
already defines these tables, and `collected_quantities.shift_id` stays unused
(`NULL`) so quantity recording is unchanged.

**Access policy.** Every shift endpoint requires a Bearer token. Reads allow
`ADMIN`, `RESPONSIBLE` and `VOLUNTEER`; writes (create, update, status, location
replacement) require `ADMIN` and use the write rate limiter.

| Method | Path                                                          | Auth                | Purpose                                      |
| ------ | ------------------------------------------------------------- | ------------------- | -------------------------------------------- |
| GET    | `/api/shifts`                                                 | any authenticated   | List shifts (`status`, `date` filters)       |
| GET    | `/api/shifts/:shiftId`                                        | any authenticated   | Read one shift + locations + `myRegistration` |
| POST   | `/api/shifts`                                                 | ADMIN               | Create a `DRAFT` shift                       |
| PATCH  | `/api/shifts/:shiftId`                                        | ADMIN               | Update `title`/`date`/`startTime`/`endTime`  |
| PATCH  | `/api/shifts/:shiftId/status`                                 | ADMIN               | Transition the status                        |
| PUT    | `/api/shifts/:shiftId/locations`                              | ADMIN               | Atomically replace the location set          |
| GET    | `/api/shifts/:shiftId/registrations`                          | ADMIN, RESPONSIBLE  | List a shift's registrations                 |
| POST   | `/api/shifts/:shiftId/registrations`                          | VOLUNTEER           | Register the caller for an `OPEN` shift      |
| PATCH  | `/api/shifts/:shiftId/registrations/:registrationId/cancel`   | VOLUNTEER, ADMIN    | Cancel a registration                        |

Safe shapes (always exactly these keys):

```jsonc
// Shift
{ "id": 1, "title": "Сутрешна смяна", "date": "2026-05-01",
  "startTime": "09:00:00", "endTime": "13:00:00", "status": "OPEN" }

// Shift detail adds its locations and the caller's own registration status
{ "...": "shift fields", "locations": [ /* safe locations */ ],
  "myRegistration": { "status": "REGISTERED" } }   // or null

// Registration
{ "id": 7, "shiftId": 1, "userId": 42, "status": "REGISTERED" }
```

Request bodies:

```jsonc
// POST /api/shifts
{ "title": "Сутрешна смяна",                 // optional, nullable
  "date": "2026-05-01", "startTime": "09:00", "endTime": "13:00",
  "locationIds": [3, 4] }

// PATCH /api/shifts/:shiftId  (at least one field required)
{ "endTime": "14:00" }

// PATCH /api/shifts/:shiftId/status
{ "status": "OPEN" }

// PUT /api/shifts/:shiftId/locations
{ "locationIds": [3, 4] }                    // 1–100 unique ids; replaces the set
```

`title` (optional) is 1–120 characters, trimmed and whitespace-collapsed.
`date` is a real calendar date in `YYYY-MM-DD`; times accept `HH:MM` or
`HH:MM:SS` and are normalised to `HH:MM:SS`. A shift is same-day only and
`endTime` must be strictly later than `startTime` (both on create and update).
Unknown fields are rejected with `400 VALIDATION_ERROR`.

**Lifecycle.** Statuses are `DRAFT`, `OPEN`, `CLOSED`, `CANCELLED`; new shifts
start as `DRAFT`. Allowed transitions are `DRAFT → OPEN`, `OPEN → CLOSED` and
`DRAFT|OPEN → CANCELLED`. Repeating the current status is idempotent (`200`);
any other transition returns `409 INVALID_STATUS_TRANSITION`. There is no reopen
and no hard delete.

**Visibility.** `DRAFT` shifts are staff-only: they are excluded from a
volunteer's list and a volunteer's detail request returns `404` (malformed,
missing and `DRAFT` ids are indistinguishable). Staff see every status.

**Locations.** Creation and `PUT .../locations` require 1–100 unique, active
location ids and validate them in ascending id order inside a transaction; an
invalid, inactive or missing id fails the whole request with `400 INVALID_LOCATION`
and leaves the previous set (or no shift) untouched. Edits and location
replacement are only allowed while the shift is `DRAFT` or `OPEN`; otherwise
`409 SHIFT_NOT_EDITABLE`. `PUT` with an empty set is rejected — use
`CANCELLED` to call a shift off instead.

**Registrations.** A volunteer may register at most once per shift and only while
it is `OPEN`. A duplicate active registration returns `409 ALREADY_REGISTERED`;
re-registering after cancelling reactivates the same row and returns `200`. A
missing or non-`OPEN` shift returns `404 NOT_FOUND` / `409 SHIFT_NOT_OPEN`.
Cancelling is idempotent (`200`); a volunteer can only cancel their own
registration (another volunteer's id, a missing id, or one from a different shift
all return `404 NOT_FOUND`), while an `ADMIN` may cancel any. `ADMIN` and
`RESPONSIBLE` may list a shift's registrations, but `RESPONSIBLE` only for a shift
that includes one of their assigned locations (otherwise `403 FORBIDDEN`);
`VOLUNTEER` cannot list registrations at all. A volunteer sees only their own
status via `myRegistration`, and no response ever exposes registrant names,
phones, `registered_at` or audit fields.

## Shift-linked quantity entry (Phase 8)

Phase 8 lets a **registered volunteer** record quantities for their own shift's
locations while that shift is `OPEN`, without exposing the staff inventory API to
volunteers. Endpoints hang off a shift under `/api/shifts/:shiftId` and reuse the
structured error contract `{ "error": { "code": "...", "message": "..." } }`.

**Data model.** `database/migrations/004_shift_quantities.sql` swaps the Phase 6
unique index for `uq_collected_shift_location_variant`
`(shift_id, location_id, variant_id)` so the same `(location, variant)` pair can
hold **separate quantities per shift**. `shift_id` stays nullable, and the
location/variant foreign keys keep `ON DELETE RESTRICT`. **No data is
transformed**: existing rows keep `shift_id = NULL` (the legacy unlinked model)
and are neither backfilled nor touched. Because MySQL does not enforce
uniqueness over `NULL` columns, one unlinked row per `(location, variant)` is
preserved at the application level by locking the location row before deciding
to insert or update; shift-linked writes are serialised by the shift row lock,
with the triple unique index as a backstop.

| Method | Path                              | Auth              | Purpose                                     |
| ------ | --------------------------------- | ----------------- | ------------------------------------------- |
| GET    | `/api/shifts/:shiftId/entry`      | any authenticated | Entry context for the shift                 |
| PUT    | `/api/shifts/:shiftId/quantities` | VOLUNTEER         | Submit the caller's quantities for a location |

The entry context is role-shaped and always exposes exactly
`{ shift, canSubmit, submissionError, entryWindow, locations, quantities }`:

```jsonc
{
  "shift": { /* safe shift */ },
  "canSubmit": true,
  "submissionError": null,        // or SHIFT_NOT_OPEN | REGISTRATION_REQUIRED |
                                  //    ENTRY_WINDOW_CLOSED | ROLE_NOT_VOLUNTEER
  "entryWindow": { "opensAt": "2026-05-01T09:00:00+03:00",
                   "closesAt": "2026-05-01T13:30:00+03:00" },
  "locations": [ /* safe locations, scoped to the caller */ ],
  "quantities": [ /* safe quantities, scoped to the caller */ ]
}
```

`ADMIN` sees every shift location and quantity row; `RESPONSIBLE` sees only their
assigned locations and their rows; `VOLUNTEER` sees the shift's active locations
and the aggregate quantity rows. No response exposes registrant names, phones,
`recorded_by`, `registered_at` or any audit field, and a `VOLUNTEER` never
receives another volunteer's data.

Request body for `PUT`:

```jsonc
// PUT /api/shifts/:shiftId/quantities
{ "locationId": 3,
  "quantities": [ { "variantId": 8, "quantity": 12 },
                  { "variantId": 9, "quantity": 0 } ] }   // 1–100 unique items
```

**Entry window.** A volunteer may submit only while the shift is `OPEN` **and**
the wall clock is within `[startTime, endTime + 30 minutes]` in
`Europe/Sofia` (inclusive at both ends; DST-aware). Outside it the shift reports
`ENTRY_WINDOW_CLOSED`; a non-`OPEN` shift reports `SHIFT_NOT_OPEN`. A volunteer
must hold an active (`REGISTERED`) registration for that shift, otherwise
`REGISTRATION_REQUIRED` (`403`). The location must be part of the shift
(`403 LOCATION_NOT_IN_SHIFT`), and the location, variant and parent product must
be active (`404 NOT_FOUND`).

**Submission semantics.** `PUT` is a transactional, all-or-nothing batch: the
shift row, the caller's registration, the location, then the variants (ascending
id) are locked in a fixed order (the volunteer path and the staff path share this
order, so concurrent writes cannot deadlock). The submitted `quantities` are an
**absolute replacement** keyed by `(shift, location, variant)`: each listed
variant is set to the given value (**`0` is stored explicitly**), omitted variants
are left untouched, and duplicate or empty `variantId` lists return
`400 VALIDATION_ERROR`. Success returns `200` with
`{ "quantities": [ /* safe quantities, ordered by variantId */ ] }`. Any single
invalid item rolls the whole batch back with no partial writes. Malformed shift
ids return `400`; a missing shift returns `404` (indistinguishable from a
malformed id on the `PUT`).

**Relationship to the Phase 6 API.** The volunteer path is deliberately separate
from `/api/quantities` (which remains staff-only). `POST /api/quantities` accepts
an **optional** `shiftId` so staff can manage shift-linked rows directly; the
response shape is shared, with `shiftId` being a number for linked rows and `null`
for legacy rows. Legacy `shift_id = NULL` rows remain readable, filterable
(`shiftId` omitted, or explicitly matching a shift) and correctable, and are never
backfilled.

## Collected quantity reporting (Phase 9)

Phase 9 adds a **read-only** aggregate report of recorded quantities. It required
**no migration** and changed no existing endpoint contract.

### Endpoint

`GET /api/reports/collected` — requires a Bearer token for an active `ADMIN` or
`RESPONSIBLE`; `VOLUNTEER` is rejected with `403`, and an unauthenticated request
returns `401`.

| Parameter | Type | Notes |
| --- | --- | --- |
| `shiftId` | integer ≥ 1 | exact shift |
| `locationId` | integer ≥ 1 | quantity's location |
| `productId` | integer ≥ 1 | via `product_variants` |
| `dateFrom` | `YYYY-MM-DD` | **inclusive**, on the shift's date |
| `dateTo` | `YYYY-MM-DD` | **inclusive**, on the shift's date |

All parameters are optional. Unknown, malformed, empty or duplicate parameters
return `400 VALIDATION_ERROR`; `dateFrom > dateTo` also returns `400`. Values are
always parameterised — no user input is interpolated into SQL.

### Authorization

`ADMIN` sees every recorded row. `RESPONSIBLE` is restricted to their assigned
locations; requesting an explicit `locationId` they are not assigned to returns
`403`. A `RESPONSIBLE` with no assignments gets zero totals and empty arrays.

### Response structure

```json
{
  "totals":     { "units": 42, "rows": 3 },
  "byLocation": [ { "locationId": 3, "locationName": "Център", "units": 30, "rows": 2 } ],
  "byProduct":  [ { "productId": 1, "productName": "Ориз", "category": "Храни", "units": 42, "rows": 3 } ]
}
```

Keys are exact: top level `totals`/`byLocation`/`byProduct`; `totals` is
`units`/`rows`; location groups are `locationId`/`locationName`/`units`/`rows`;
product groups are `productId`/`productName`/`category`/`units`/`rows`. Every
`units` and `rows` value is a JavaScript number. `category` is `null` when the
product has none. Groups are ordered by `units DESC`, then entity id `ASC`. An
empty report returns `{ totals: { units: 0, rows: 0 }, byLocation: [], byProduct: [] }`.

### Legacy unlinked rows

Rows with `shift_id IS NULL` are included when no shift/date filter is supplied.
A `dateFrom`, `dateTo` or `shiftId` filter requires the shift, so it naturally
excludes them (they are never backfilled with an invented shift). Legacy rows
remain fully reportable alongside shift-linked rows.

### Limitation

The report sums **recorded** quantity rows. It is an operational total, **not** an
inventory balance, distribution, donation or analytics report; it does not
deduct anything and it never exposes `recorded_by`, `recorded_at`, volunteer
names/phones or registration details.

## Forced password change (Phase 10)

Phase 10 adds an authenticated password-change endpoint and **enforces** the
existing `must_change_password` flag. It required **no migration** and changed no
other endpoint contract.

### Endpoint

`POST /api/auth/password/change` — requires a Bearer token for an active account
that has a password hash (staff). Unauthenticated requests return `401`;
password-less volunteer accounts and unknown users fail with the same generic
`401 INVALID_CREDENTIALS`.

```jsonc
// POST /api/auth/password/change
{ "currentPassword": "at-least-8-chars", "newPassword": "at-least-8-chars" }
```

| Field | Type | Rules |
| --- | --- | --- |
| `currentPassword` | string | non-empty, max 200, not trimmed |
| `newPassword` | string | 8–200 characters, not trimmed |

Unknown fields, missing/empty values, an out-of-range `newPassword`, or a
`newPassword` equal to `currentPassword` all return `400 VALIDATION_ERROR`. A
wrong `currentPassword` returns `401 INVALID_CREDENTIALS`; a disabled account
returns `403 ACCOUNT_DISABLED`. Passwords are bcrypt hashes (cost 12).

On success the password hash is replaced, `must_change_password` is cleared and
`users.token_version` is bumped in a **single atomic statement**, so every
previously issued token is rejected immediately. The response is a fresh token in
the same shape as login (`token`, `tokenType`, `expiresIn`, `user` with the safe
profile). Reuses the shared login rate limiter.

### Enforcement

Every authenticated request re-checks the DB-backed flag inside the auth
middleware, so a staff account with `must_change_password = 1` is blocked from
all protected routes with `403 MUST_CHANGE_PASSWORD`
(`"Password change is required before continuing."`). The only exceptions — which
remain reachable while a change is pending — are:

- `POST /api/auth/password/change`
- `GET /api/auth/me`
- `POST /api/auth/logout`

Public routes (health, public location/product reads) and login are unchanged.
Once the password is changed, the returned token unlocks the protected routes.

## Distribution of collected goods (Phase 11)

Phase 11 records the **giving-out** of collected goods. Endpoints live under
`/api/distributions`, reuse the structured error contract
`{ "error": { "code": "...", "message": "..." } }`, and are the counterpart to the
collected-quantity APIs: `collected_quantities` records goods coming in (one
replaceable row per key), while a distribution is an **append-only event** — the
same `(location, variant)` may be distributed many times, so each `POST` inserts a
new row and there is no unique key.

### Data model

`database/migrations/005_distributions.sql` creates the additive `distributions`
table (the first migration since Phase 8): `location_id`/`variant_id` foreign keys
(`ON DELETE RESTRICT`), `distribution_date` DATE (the Europe/Sofia business date,
computed with the existing `lib/entry-window.js` helper), `quantity` INT, nullable
`recipient` (160) and `note` (255), `distributed_by` (FK to `users`, `ON DELETE
SET NULL`) and `distributed_at` TIMESTAMP. No existing table, column or index is
changed and no data is transformed; `distribution_date` is used for date filtering
so queries never depend on the MySQL session timezone.

### Access policy

Every distribution endpoint requires a Bearer token for an active `ADMIN` or
`RESPONSIBLE`; `VOLUNTEER` is rejected with `403`, and an unauthenticated request
returns `401`. `ADMIN` may act on any location; `RESPONSIBLE` only on locations
assigned through `responsible_locations` (an explicit unassigned `locationId` is
`403`; list results are scoped to assigned locations; reads/updates authorise
against the record's own `location_id`, never a client-supplied id). Writes use the
shared `adminWriteLimiter`. Forced-password-change enforcement applies
automatically through the central auth middleware.

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| GET | `/api/distributions` | ADMIN, RESPONSIBLE (scoped) | List events (`locationId`, `variantId`, `productId`, `dateFrom`, `dateTo`) |
| GET | `/api/distributions/:distributionId` | ADMIN, RESPONSIBLE (scoped) | Read one event |
| POST | `/api/distributions` | ADMIN, assigned RESPONSIBLE | Record a new event |
| PATCH | `/api/distributions/:distributionId` | ADMIN, assigned RESPONSIBLE | Correct `quantity`/`recipient`/`note` |

Safe shape (always exactly these keys; `recipient` and `note` may be `null`):

```jsonc
{ "id": 1, "locationId": 3, "variantId": 8, "quantity": 5,
  "date": "2026-05-01", "recipient": "Дом за възрастни", "note": null }
```

Request bodies:

```jsonc
// POST /api/distributions  (recipient and note are optional; quantity >= 1)
{ "locationId": 3, "variantId": 8, "quantity": 5,
  "recipient": "Дом за възрастни", "note": "партида 1" }

// PATCH /api/distributions/:distributionId  (at least one field required)
{ "quantity": 4 }
{ "recipient": null, "note": null }         // clears both
```

`POST` is a `201` new event and requires an **active** location, variant and parent
product (`404` otherwise); the distributor is always the authenticated user, never
taken from the body. `PATCH` is an absolute correction (`200`) of
`quantity`/`recipient`/`note`, does **not** require the linked location/variant/
product to still be active (archived records stay correctable), and rejects an
empty body or unknown/immutable fields (`locationId`, `variantId`, `date` and the
distributor are immutable). Integers are validated as whole numbers in
`[1, 2147483647]`; `recipient`/`note` are trimmed and whitespace-collapsed. List
date filters (`dateFrom`/`dateTo`) are inclusive and act on `distribution_date`;
unknown, malformed or duplicate query parameters return `400 VALIDATION_ERROR`
(`dateFrom > dateTo` also `400`). Malformed ids return `400`, missing records
`404`. Responses never expose `distributed_by`, `distributed_at` or raw rows.

`recipient` is an optional **non-personal recipient label** (for example an
organisation or group), **not** a place for private beneficiary data. This phase
does not enforce `distributed <= collected`; there is no delete endpoint (events
are append-only). Phase 12 later adds a read-only inventory balance report;
distribution limits, inventory mutations, shift-linked distributions, purchases,
donations, uploads, dashboards and the Flutter UI remain out of scope.

## Inventory balance reporting (Phase 12)

Phase 12 adds a **read-only** inventory balance report combining collected
quantities (Phase 6/8) and distributions (Phase 11). It required **no migration**
and changed no existing endpoint.

### Endpoint

`GET /api/reports/inventory` — requires a Bearer token for an active `ADMIN` or
`RESPONSIBLE`. `VOLUNTEER` receives `403 FORBIDDEN`; unauthenticated requests return
`401`. Staff pending a forced password change are blocked by the existing central
middleware with `403 MUST_CHANGE_PASSWORD`.

| Parameter | Type | Applies to |
|---|---|---|
| `locationId` | int ≥ 1 | both collected and distributed |
| `productId` | int ≥ 1 | both sides, via `product_variants` |
| `variantId` | int ≥ 1 | both sides |
| `dateFrom` | `YYYY-MM-DD` inclusive | collections via `shifts.shift_date`; distributions via `distribution_date` |
| `dateTo` | `YYYY-MM-DD` inclusive | same |

All parameters are optional. There is deliberately **no `shiftId`** filter because
distributions are not linked to shifts, so a shift scope would be asymmetric.
Unknown, malformed, empty or duplicate parameters return `400 VALIDATION_ERROR`;
`dateFrom > dateTo` also returns `400`. Values are always parameterised — no user
input is interpolated into SQL.

### Authorization

`ADMIN` sees every location. `RESPONSIBLE` is restricted to assigned locations on
**both** the collected and distributed side; requesting an explicit `locationId`
they are not assigned to returns `403`. A `RESPONSIBLE` with no assignments gets
zero totals and empty arrays. Distributions at unassigned locations never leak into
a scoped report.

### Calculation

For each `(location, variant)` pair the report computes:

- `collectedQuantity` — sum of matching `collected_quantities.quantity`
- `distributedQuantity` — sum of matching `distributions.quantity`
- `remainingQuantity` — `collectedQuantity - distributedQuantity`

The two sources are aggregated **independently** (a single `UNION ALL` keyed by
`(location, variant)`), so multiple collection and distribution rows for the same
pair never multiply. The key set is the union of both sources:

- **Collection only** → `distributedQuantity` is `0`.
- **Distribution only** — appears with `collectedQuantity: 0` and a **negative**
  `remainingQuantity`; it is never dropped for lack of a collection row.
- **Equal collected and distributed** — a visible zero-balance row is included.
- **No activity** — the pair is omitted; the report does not generate a
  location-by-variant cross product.

`remainingQuantity` can be **negative** because Phase 11 does not enforce
distribution limits. It is never clamped to zero.

### Response structure

```json
{
  "totals":     { "collectedQuantity": 42, "distributedQuantity": 50, "remainingQuantity": -8 },
  "byLocation": [ { "locationId": 3, "locationName": "Център", "collectedQuantity": 30, "distributedQuantity": 12, "remainingQuantity": 18 } ],
  "byProduct":  [ { "productId": 1, "productName": "Ориз", "category": "Храни", "collectedQuantity": 42, "distributedQuantity": 50, "remainingQuantity": -8 } ],
  "byVariant":  [ { "variantId": 7, "productId": 1, "productName": "Ориз", "unitLabel": "1 кг", "collectedQuantity": 20, "distributedQuantity": 30, "remainingQuantity": -10 } ]
}
```

Keys are exact: top level `totals`/`byLocation`/`byProduct`/`byVariant`; totals are
`collectedQuantity`/`distributedQuantity`/`remainingQuantity`; location groups add
`locationId`/`locationName`; product groups add
`productId`/`productName`/`category`; variant groups add
`variantId`/`productId`/`productName`/`unitLabel`. `byLocation` groups across
products and variants, `byProduct` across variants and locations, and `byVariant`
across locations. Every quantity is a JavaScript number. `category` is `null` when
the product has none. Groups are ordered by `collectedQuantity DESC`, then entity id
`ASC`. An empty report returns
`{ totals: { collectedQuantity: 0, distributedQuantity: 0, remainingQuantity: 0 }, byLocation: [], byProduct: [], byVariant: [] }`.
Internal/audit fields (`recorded_by`, `recorded_at`, `distributed_by`,
`distributed_at`, raw ids, phone numbers, names) are never returned.

### Legacy rows and date semantics

Without a date filter, shift-linked and legacy unlinked (`shift_id IS NULL`)
collections are both included in the collection sum. Supplying `dateFrom` and/or
`dateTo` dates the collection branch on `shifts.shift_date`; the required join to
`shifts` naturally **excludes** legacy unlinked rows, which have no reliable
business date. Distributions are dated on `distributions.distribution_date`.

Because the two sides use different date sources, a date-filtered report is **net
flow during the selected inclusive window** (collected in the window minus
distributed in the window) — **not** a historical balance as of `dateTo`. Balances
shown without a date filter are all-time.

### Limitation

The report is a read-only view over existing records. It does **not** enforce
distribution limits, mutate inventory, create reservations or adjustments, or
calculate analytics beyond collected vs distributed. No migration or schema change
was required for this phase.

## Tests

Backend (runs from `backend/`):

```sh
npm test                  # node --test, full suite
```

Targeted auth suites (Phase 30):

```sh
npx node --test test/auth-register.test.js test/auth-volunteer-login.test.js \
  test/auth-rate-limit.test.js test/auth-login.test.js test/auth-volunteer.test.js
```

`npm run db:reset:test` exists for provisioning a clean `DB_NAME_TEST`, but it is
**destructive** and is **not** a required step for the Phase 30 auth work. Never
run it against the development database.

Flutter (runs from `app/`):

```sh
flutter analyze           # static analysis
flutter test              # full Flutter suite
```

Targeted client auth/registration tests:

```sh
flutter test test/auth_api_test.dart test/auth_screens_test.dart \
  test/registration_screen_test.dart test/api_client_test.dart \
  test/session_controller_test.dart
```

## Flutter app

```sh
cd app
flutter pub get
flutter analyze
flutter test
flutter run -d chrome     # or: flutter run -d <android-device>
```

The API base URL is centralised in `app/lib/core/config.dart` and can be
overridden at build time with `--dart-define=API_BASE_URL=...`.

### Client phases

The app is developed as client phases 13–30, alongside the backend phases
above (the backend itself is at Phase 12, with the Phase 30 auth additions).

| Phase | Area | Anchor files |
| --- | --- | --- |
| 13 | API client foundation, configuration, error envelope | `app/lib/core/api/api_client.dart`, `api_exception.dart`, `api_scope.dart`, `app/lib/core/config.dart` |
| 14 | Authentication, session state, forced password change | `app/lib/core/session/*`, `app/lib/core/auth/*`, `app/lib/screens/login_screen.dart`, `volunteer_identification_screen.dart`, `change_password_screen.dart` |
| 15 | Application shell and main screens | `app/lib/widgets/app_shell.dart`, `app/lib/screens/start_screen.dart`, `locations_screen.dart`, `shifts_screen.dart`, `shift_detail_screen.dart` |
| 16 | Locations and catalog reads | `app/lib/core/api/locations_api.dart`, `products_api.dart`, `app/lib/models/catalog_product.dart` |
| 17 | Shifts and shift details | `app/lib/core/api/shifts_api.dart`, `app/lib/models/shift.dart` |
| 18 | Shift entry context | `app/lib/core/api/entry_api.dart`, `app/lib/models/entry_context.dart` |
| 19 | Volunteer quantity entry | `app/lib/screens/entry_screen.dart` |
| 20 | Shift registration | `app/lib/core/api/shifts_api.dart` (`registerSelf`), `app/lib/screens/shift_detail_screen.dart` |
| 21 | Shared volunteer registration state | `app/lib/core/session/registration_state_controller.dart`, `registration_scope.dart`, `app/lib/widgets/shift_card.dart` |
| 22 | Volunteer registration cancellation | `app/lib/core/api/api_client.dart` (`patch`), `app/lib/core/api/shifts_api.dart` (`cancelSelf`), `app/lib/core/session/registration_state_controller.dart`, `app/lib/screens/shift_detail_screen.dart` |
| 23 | Reliable quantity entry and clear access | `app/lib/screens/entry_screen.dart`, `app/lib/screens/shifts_screen.dart`, `app/lib/widgets/volunteer_count_badge.dart`, `app/lib/models/shift.dart` |
| 24 | Usability & Accessibility Polish | `app/lib/core/theme/app_colors.dart`, `app/lib/core/theme/app_theme.dart`, `app/lib/core/statuses.dart`, `app/lib/widgets/product_sticker_card.dart`, `app/lib/widgets/search_field.dart`, `app/lib/screens/entry_screen.dart`, `app/lib/screens/shifts_screen.dart`, `app/lib/screens/locations_screen.dart` |
| 25 | Accessibility regression coverage | `app/test/a11y_phase25_test.dart`, `app/lib/widgets/product_sticker_card.dart`, `app/test/shifts_screen_test.dart`, `app/test/locations_screen_test.dart`, `app/test/entry_screen_test.dart` |
| 26 | Admin shift lifecycle UI | `app/lib/screens/shift_editor_screen.dart`, `app/lib/screens/shifts_screen.dart`, `app/lib/screens/shift_detail_screen.dart`, `app/lib/core/api/shifts_api.dart`, `app/test/shift_admin_test.dart` |
| 27 | Admin location management UI | `app/lib/core/api/locations_api.dart`, `app/lib/screens/location_editor_screen.dart`, `app/lib/screens/locations_screen.dart`, `app/lib/core/auth/auth_messages.dart`, `app/test/locations_api_test.dart`, `app/test/location_admin_test.dart`, `app/test/locations_screen_test.dart` |
| 28 | Admin user management UI | `app/lib/core/api/admin_users_api.dart`, `app/lib/models/admin_user_page.dart`, `app/lib/screens/admin_users_screen.dart`, `app/lib/screens/admin_user_editor_screen.dart`, `app/lib/widgets/user_card.dart`, `app/lib/widgets/app_shell.dart`, `app/test/admin_users_api_test.dart`, `app/test/admin_users_screen_test.dart` |
| 29 | Admin shift management hardening | `app/lib/screens/shift_editor_screen.dart`, `app/lib/screens/shift_detail_screen.dart`, `app/lib/screens/shifts_screen.dart`, `app/lib/widgets/primary_button.dart`, `app/test/shift_admin_test.dart`, `app/test/shifts_screen_test.dart`, `app/test/shifts_api_test.dart` |
| 30 | Volunteer registration and real authentication | `app/lib/core/api/auth_api.dart`, `api_client.dart`, `app/lib/core/session/session_controller.dart`, `app/lib/main.dart`, `app/lib/screens/registration_screen.dart`, `volunteer_identification_screen.dart`, `login_screen.dart`, `start_screen.dart`, `app/test/registration_screen_test.dart` |

### Shift registration (client Phase 20)

`ShiftDetailScreen` registers the authenticated volunteer for an open shift
through `POST /api/shifts/:shiftId/registrations`. The request carries no
body and no `Content-Type`; the response is the safe registration shape
`{ id, shiftId, userId, status }`.

```json
{
  "id": 42,
  "shiftId": 7,
  "userId": 12,
  "status": "REGISTERED"
}
```

- The action is offered only to an authenticated volunteer, for an `OPEN`
  shift, when the volunteer is not registered yet.
- While the request is in flight the action stays visible but disabled, so a
  duplicate tap never issues a second request.
- Success is reported only after the backend confirms it: `201` for a new
  registration, `200` when a previously cancelled registration is reactivated.
  The shift detail is then reloaded (`GET /api/shifts/:shiftId`) to reconcile.
- `ALREADY_REGISTERED` and `SHIFT_NOT_OPEN` reload the detail instead of
  claiming a new registration; `401 UNAUTHORIZED` clears the session.
- Every message is Bulgarian. Cancelling a registration was not implemented in
  this phase — the volunteer cannot discover their own registration id. See
  client Phase 22.

### Shared registration state (client Phase 21)

`GET /api/shifts` does not expose `myRegistration`, so the app keeps the
confirmed registration states it has already seen in an in-memory cache
(`RegistrationStateController`, exposed through the `RegistrationScope`
inherited notifier).

- Only states observed in a confirmed backend response are stored: the
  `myRegistration.status` of `GET /api/shifts/:shiftId` and the `status` of a
  confirmed `POST /api/shifts/:shiftId/registrations`.
- The state is keyed by the backend user id first, so one volunteer's
  registrations can never leak into another user's view.
- The shift list marks a shift with a `Записани сте` chip when the signed-in
  **volunteer** has a `REGISTERED` state for it. A cancelled, unknown or
  foreign registration shows no chip, and staff sessions never see one.
- The chip costs **no extra request**: the list is never reloaded, and the
  location-filtered list publishes the registration state of the detail
  responses it fetches anyway.
- The state is intentionally **partial** and in-memory: it only covers the
  shifts whose registration state was observed during the current app session
  and it is lost on a reload. The registration id is kept next to the status
  whenever a confirmed registration response provided one (client Phase 22).

### Registration cancellation (client Phase 22)

The volunteer cancels their own registration through
`PATCH /api/shifts/:shiftId/registrations/:registrationId/cancel`. The request
carries no body and no `Content-Type`; the response is the same safe
registration shape `{ id, shiftId, userId, status }` with `status` `CANCELLED`.

- The action is offered only to an authenticated **volunteer**, for an `OPEN`
  shift, when the status is `REGISTERED` **and the registration id is known**.
- The id is returned by the backend only in a registration response, so it is
  known only for registrations made during the current app session.
  `myRegistration` in a shift detail carries the status alone and
  `GET /api/shifts/:shiftId/registrations` is staff-only, so **a registration
  from an earlier session cannot be cancelled**. In that case no action is
  offered and a muted line explains it:
  `Този запис е направен в предишна сесия и не може да бъде отменен от
  приложението.`
- The request is sent only after a confirmation dialog
  (`Сигурни ли сте, че искате да откажете записа си за тази смяна?` →
  `Да, откажи` / `Не, оставам`). While it is in flight the action stays visible
  but disabled, so a repeated tap never issues a second request.
- The shared state changes only after the backend confirms the cancellation.
  The detail is reloaded silently and a confirmed cancellation is never undone
  by a server status that still reports the pre-cancellation registration.
- Failures change nothing and are reported in Bulgarian: `SHIFT_NOT_OPEN` →
  `Отказът на записа е възможен само докато смяната е отворена.`, `NOT_FOUND` →
  `Записът не е намерен. Възможно е вече да е отменен.`, everything else through
  the shared error messages. `SHIFT_NOT_OPEN` and `NOT_FOUND` reload the detail
  to reconcile, and `401 UNAUTHORIZED` clears the session.
- The shift list's `Записани сте` chip disappears without any extra request.

### Reliable quantity entry and clear access (client Phase 23)

Client-only phase: no backend endpoint, migration, request shape or response
field changed.

### Usability & Accessibility Polish (client Phase 24)

Client-only phase: no backend endpoint, migration, request shape or response
field changed. Updated color tokens for accessibility (`textTertiary`
`#5F6772`, `secondary/error` `#C62828`), adjusted status chip colors
(`available` `#256428`, `full` `#C62828`), refreshed theme error/input styles.
Increased quantity control hit target to 48×48 with semantics labels, added
pull-to-refresh to `ShiftsScreen` and `LocationsScreen`, and added minimal
accessibility semantics.

**No invented counts.** The safe shift shape of the backend has no registration
count and no capacity, so `Shift.registeredCount` and `Shift.capacity` are
`null` (unknown) and `VolunteerCountBadge` hides itself instead of rendering an
invented `0 / 1`. A shift is never reported as full while the counts are
unknown.

**Quantities belong to a point.** The pending quantities of the entry screen
are bound to the selected point:

- Changing the point clears the pending quantities and explains it
  (`Количествата са изчистени, защото сменихте пункта.`), so a batch is never
  sent for a point the volunteer did not choose.
- The `Записано на сървъра` marker is scoped to the selected point, because the
  entry context contains the rows of every point of the shift.
- A successful submission merges the returned rows per `(location, variant)`:
  the backend replaces only the **listed** variants, so the untouched rows of
  the same point and the rows of every other point survive.

**Anonymous visitors get a clear path.** `GET /api/shifts` requires a bearer
token, so the shifts screen does not send a request that could only fail.
Without a session it shows `Идентифицирайте се, за да виждате смените.` and an
`Идентифицирайте се` action that opens the existing volunteer identification
screen. No session-expired message is shown for a session that never existed; a
real `401 UNAUTHORIZED` still clears the session.

**Faster catalog load.** The variants of the products are loaded with a bounded
worker pool: exactly one request per product (the request count is unchanged),
but at most **6** requests run at the same time. A failing request still fails
the whole load — a partially loaded catalog is never presented as loaded and the
`Повтори` action remains.

### Accessibility regression coverage (client Phase 25)

Client-only phase: no backend endpoint, migration, request shape or response
field changed. It adds deterministic regression coverage and one production
hit-target fix.

- `app/test/a11y_phase25_test.dart` computes WCAG relative luminance and asserts
  at least `4.5:1` for `textTertiary` on both backgrounds, `success` on white,
  and every `ShiftStatus` chip text/background pair.
- The quantity `-`/`+` controls now have measured `48×48` hit targets and expose
  the `Намали`/`Увеличи` semantics labels. The decorative `48×48` wrapper
  previously contained a `40×40` interactive button; `_RoundIconButton` now puts
  the `IconButton` directly in the `48×48` box while preserving the visual
  circle.
- `SearchField` exposes `Изчисти търсенето` as a button, the entry submit action
  exposes `Изпрати` with its enabled/disabled state, and the saved marker exposes
  `Записано на сървъра`.
- Widget tests cover pull-to-refresh on `ShiftsScreen` and `LocationsScreen`:
  fresh load, preserved search/filter, empty state, and an anonymous shifts pull
  that never calls the API.
- A failed locations refresh is covered as **current behavior**: it clears the
  previous list and shows the network error with `Повтори`. This is a known
  limitation, not offline caching.
- The full Flutter suite passes (235 tests) and `flutter analyze` is clean.

### Admin shift lifecycle (client Phase 26)

Client-only phase: no backend endpoint, migration, request shape or response
field changed. The existing Phase 7 shift write contract is now usable from the
app by an authenticated `ADMIN`.

- `ShiftStatus.draft` (Чернова) maps `DRAFT` and exposes a WCAG-AA chip; other
  backend statuses keep their existing mappings.
- `ShiftsApi` adds `createShift`, `updateShift`, `setShiftStatus` and
  `replaceShiftLocations`. Request bodies and safe responses are parsed
  strictly; malformed payloads raise `UNEXPECTED_RESPONSE`.
- `ShiftsScreen` shows `Нова смяна` only to an admin. It opens
  `ShiftEditorScreen`, preselects the location when the list is filtered, and
  reloads without filters after a confirmed creation so the new `DRAFT` shift is
  visible. The screen is never wrapped in a nested `Scaffold`.
- The editor validates a real `ГГГГ-ММ-ДД` date, `ЧЧ:ММ` times, an end after
  the start, an optional title up to 120 characters, and 1–100 unique active
  locations. Locations come only from `GET /api/locations`; loading failures and
  an empty catalogue are shown with a retry path, never sample data.
- `ShiftDetailScreen` offers admin management only for `DRAFT`/`OPEN`:
  metadata edit and location replacement for both, publish for `DRAFT`, close
  for `OPEN`, and cancel for both. Closing and cancelling require confirmation.
  `CLOSED`/`CANCELLED` are read-only. Success is reported only after backend
  confirmation, then the detail and the parent list refresh; a revision guard
  prevents an older detail response from restoring stale state.
- Location replacement sends the complete active set. Archived locations linked
  to the shift remain visible but unselectable and are explained as removed on
  save.
- The Bulgarian messages for `INVALID_LOCATION`, `SHIFT_NOT_EDITABLE` and
  `INVALID_STATUS_TRANSITION` are mapped in `AuthMessages`; `401` still clears
  the session centrally.
- The full Flutter suite passes (256 tests) and `flutter analyze` is clean.

### Admin location management (client Phase 27)

Client-only phase: no backend endpoint, migration, request shape or response
field changed. The existing Phase 4 location write contract is now usable from
the app by an authenticated `ADMIN`.

- `LocationsApi` adds `createLocation`, `updateLocation` and `setLocationStatus`,
  with strict safe-response parsing.
- `LocationsScreen` shows `Нов пункт` only to an admin. It provides per-card
  actions `Редактирай` / `Архивирай` (with confirmation) and offers create in the
  header, empty state and error state. Archive removes the card and offers an
  undo snackbar for the same session; a 401 clears the session centrally.
- `LocationEditorScreen` creates a location or edits an existing active
  location, validates trimmed `name` (1–120) and `address` (1–255), and returns
  the saved location. Duplicate names map to `NAME_TAKEN` via `AuthMessages`.
- Public listing remains active-only. There is no admin listing of inactive
  locations, so undo is available only in the current session; persistent
  reactivation after reload is not provided by the current backend.
- Create/edit preserve or adjust local sorting and search; a delayed list
  response cannot overwrite a confirmed local mutation via a revision guard.
- `flutter analyze` is clean and the full Flutter suite passes (286 tests).

### Admin user management (client Phase 28)

Client-only phase: no backend endpoint, migration, request shape or response
field changed. It exposes the existing Phase 3 admin user API to an
authenticated `ADMIN`.

- `AdminUsersApi` provides typed `listUserPage`, `createStaff`,
  `updateUserProfile` and `setUserStatus` calls with strict parsing of the safe
  user profile and paginated envelope. Malformed payloads, pagination outside
  `page >= 1` / `pageSize 1..100`, invalid ids and unsupported create roles
  fail locally with `UNEXPECTED_RESPONSE` without sending a request.
- `AppShell` adds a `Потребители` tab only for an admin. `AdminUsersScreen`
  also guards the page itself, so non-admin and anonymous callers see the
  Bulgarian forbidden state instead of user data.
- The list requests 20 users per page, supports role filters (all, volunteer,
  responsible, admin), status filters (all, active, inactive), previous/next
  paging, pull-to-refresh, retryable errors and an empty state. Out-of-range
  pages are clamped to the last available page (or page 1 when empty). A delayed
  response cannot overwrite a newer filter or a confirmed mutation.
- `AdminUserEditorScreen` creates a responsible/admin staff account or edits the
  active profile fields `firstName`, `lastName` and `phone`. Create takes an
  initial password with confirmation; role and password are not editable for an
  existing account. Names are trimmed and limited to 60 characters, phones are
  normalised, and passwords must be 8–200 characters and match. Duplicate
  submissions are disabled while a request is in flight. Newly created staff are
  provisioned with a mandatory first-login password change; the editor explains
  this before creation and the list shows the pending-change badge.
- Create shows success only after the backend confirms, then keeps matching
  filters and loads the last page; if the new user does not match the current
  filters, both filters reset to all/all and the last page is loaded. Edit
  replaces the row locally and refreshes the session when an admin edits their
  own profile.
- Deactivation requires confirmation. Activation and deactivation are applied
  only after a confirmed safe profile is returned; a row that no longer matches
  the filters is removed, and an emptied page reloads the previous one.
  `PHONE_TAKEN`, `SELF_DEACTIVATION`, `LAST_ADMIN`, `FORBIDDEN` and
  `UNAUTHORIZED` have fixed Bulgarian messages in `AuthMessages`; a 401 clears
  the session centrally.
- `UserCard` exposes role, status, forced-password-change and current-user
  badges with accessibility labels. This screen does not change roles, reset or
  recover passwords, create volunteers, hard-delete users or assign responsible
  users to locations; those remain out of scope.
- At the end of Phase 28 the full Flutter suite passed (319 tests) and
  `flutter analyze` was clean.

### Admin shift management hardening (client Phase 29)

Client-only hardening phase: no backend endpoint, migration, request shape,
response field or dependency changed. It locks in the Phase 26 lifecycle
behaviour with regression coverage and fixes the defects exposed by it.

- The shared `PrimaryButton` keeps its label visible next to the spinner while
  busy. A pending create, edit, publish, close or cancel action therefore stays
  identifiable and disabled, and a repeated tap cannot issue a second request.
- Create, edit, publish, close and cancel are applied only after the backend
  confirms them. Closing and cancelling keep their confirmation dialogs; a
  dismissed dialog sends no request. A `401 UNAUTHORIZED` clears the session
  through `SessionController`.
- Creation from a list filtered by location is preserved. A shift outside the
  selected location is not silently inserted; the list reloads without filters
  and explains why the new shift is not shown, with a `Виж новата` action that
  opens its detail.
- The editor validates the title limit, real `ГГГГ-ММ-ДД` date, `ЧЧ:ММ` times,
  end after start, at least one location and at most 100 locations locally. An
  invalid form never sends an API request.
- Stale list and detail responses cannot overwrite newer state. The existing
  revision guards are covered for older list responses, older errors and an
  older admin detail response arriving after a newer confirmed status. Archived
  linked locations remain visible but unselectable.
- Regression tests: `app/test/shift_admin_test.dart` (27 tests),
  `app/test/shifts_screen_test.dart` (27 tests) and
  `app/test/shifts_api_test.dart` (25 tests). The full Flutter suite passes
  (334 tests) and `flutter analyze` is clean.

### Volunteer registration and real authentication (client Phase 30)

Phase 30 connects the client to the new registration and volunteer-login
endpoints. It adds no migration, dependency or persistent token storage.

- `AuthApi.registerVolunteer` posts `firstName`, `lastName`, `phone` and the
  selected `VOLUNTEER` role to `POST /api/auth/register`. The returned token and
  safe profile are parsed strictly, and the role in the session always comes
  from the backend response.
- `AuthApi.loginVolunteer` uses the strict passwordless
  `POST /api/auth/volunteer/login` endpoint. Failed volunteer login never
  auto-creates an account and never clears an existing session.
- `RegistrationScreen` collects names, phone and role. Volunteer is the only
  selectable public role; responsible and admin are shown as administrator-only.
  The screen validates locally, prevents duplicate submissions, automatically
  accepts the confirmed session and opens the app shell. `PHONE_TAKEN`, network,
  rate-limit and validation errors stay on the form in Bulgarian.
- `VolunteerIdentificationScreen` is now a volunteer login screen with no
  password and links to registration. `LoginScreen` is explicitly the staff
  (responsible/admin) phone + password screen.
- `StartScreen` routes `Вход` to volunteer login, `Регистрация` to public
  registration, and `Служебен вход` to staff login.
- The shared `ApiClient` accepts an `onUnauthorized` callback. It fires only for
  a real `401 UNAUTHORIZED` (not `INVALID_CREDENTIALS`), and `main.dart` wires it
  to `SessionController.handleUnauthorized()` so an expired session is cleared
  centrally.
- The old `identifyVolunteer` API helper and legacy backend endpoint remain for
  backward compatibility but are no longer used by the UI.
- Verification: backend `npm test` passes (448 tests), the full Flutter suite
  passes (357 tests) and `flutter analyze` is clean.
