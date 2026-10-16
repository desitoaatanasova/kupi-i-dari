# Купи и Дари

Charity campaign management platform: Flutter (Web + Android) client, Node.js/Express
REST API, MySQL 8 (hand-written SQL, no ORM).

> **Status: Phase 7 — shift management.** The backend skeleton, database
> schema/migrations, and a Flutter placeholder app exist. Phase 2 added staff
> login, volunteer identification, JWT authentication/revocation, and auth rate
> limiting. Phase 3 added admin-only user management (list, create, read, update,
> activate/deactivate) with last-active-admin protection. Phase 4 added public
> location reads plus admin-only location management (create, update,
> archive/reactivate) and atomic replacement of a location's responsible
> assignees. Phase 5 added a product catalog and its variants: public reads of
> active products/variants plus admin-only product/variant management (create,
> update, archive/reactivate). Phase 6 added quantity recording per location and
> variant (atomic upsert and absolute correction). Phase 7 adds shift scheduling
> at one or more locations with volunteer self-registration and cancellation. No
> other business functionality (purchases, donations, distribution, dashboards)
> is implemented yet.

## Layout

```
backend/                 Node.js/Express API
  src/                   app, config, db pool, migrations runner, routes
  scripts/               migrate, seed-admin, db:reset:test
  test/                  node --test suites
database/migrations/     ordered, checksum-verified .sql migrations
app/                     Flutter app (Web + Android) — placeholder
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

## Authentication (Phase 2)

Auth endpoints live under `/api/auth` and follow the structured error contract
`{ "error": { "code": "...", "message": "..." } }`.

| Method | Path                    | Auth        | Purpose                                   |
| ------ | ----------------------- | ----------- | ----------------------------------------- |
| POST   | `/api/auth/login`       | none        | Staff sign-in (phone + password)          |
| POST   | `/api/auth/volunteer`   | none        | Volunteer identify/register (name + phone) |
| GET    | `/api/auth/me`          | Bearer JWT  | Current safe profile                      |
| POST   | `/api/auth/logout`      | Bearer JWT  | Revoke tokens (204, no body)              |

Request bodies:

```jsonc
// POST /api/auth/login
{ "phone": "+359881234567", "password": "..." }

// POST /api/auth/volunteer
{ "firstName": "Мария", "lastName": "Иванова", "phone": "0888123456" }
```

Phones are normalised to `+359XXXXXXXXX`; accepted inputs are `+359…`, `00359…`
and national `0…`, with optional spaces, hyphens and parentheses.

**Staff login** returns a JWT for `RESPONSIBLE` / `ADMIN` accounts. Passwords are
stored only as bcrypt hashes (cost 12) and are never returned.

**Volunteer identification** is deliberately weak — *it is identification, not
strong authentication*. Anyone who knows a volunteer's name and phone number can
impersonate them. This is mitigated only by short token expiry, a dedicated rate
limiter, and low volunteer permissions. No SMS/OTP/PIN flow is implemented.

Tokens are HS256 JWTs with claims `sub`, `role`, `tv` (token version), `iat`,
`exp`. Expiry defaults to `JWT_EXPIRES_IN=60m` and is reported as integer
seconds. `POST /api/auth/logout` atomically increments `users.token_version`, so
every previously issued token is rejected immediately by protected endpoints.

Out of scope in this phase: staff registration, password reset / forced password
change (the `must_change_password` flag is stored and returned but not enforced),
and all later-phase domain features.

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
(staff login, default `10`), `AUTH_VOLUNTEER_RATE_LIMIT_MAX` (default `20`),
`AUTH_ADMIN_WRITE_RATE_LIMIT_MAX` (admin writes, default `30`), plus
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
number (MySQL `INT`, `[0, 2147483647]`); **zero is valid**.

**Access policy.** Every quantity endpoint requires a Bearer token. `ADMIN` may
read and write at any location; `RESPONSIBLE` may only access locations assigned
through `responsible_locations`; `VOLUNTEER` is always `403 FORBIDDEN`. Mutations
share the write rate limiter.

| Method | Path                          | Auth               | Purpose                                        |
| ------ | ----------------------------- | ------------------ | ---------------------------------------------- |
| GET    | `/api/quantities`             | ADMIN, RESPONSIBLE | List records (`locationId`, `variantId`, `productId` filters) |
| GET    | `/api/quantities/:quantityId` | ADMIN, RESPONSIBLE | Read one record                                |
| POST   | `/api/quantities`             | ADMIN, assigned RESPONSIBLE | Create or replace a `(location, variant)` quantity |
| PATCH  | `/api/quantities/:quantityId` | ADMIN, assigned RESPONSIBLE | Replace a record's quantity absolutely         |

Safe shape (always exactly these keys):

```jsonc
{ "id": 1, "locationId": 3, "variantId": 8, "quantity": 12 }
```

Request bodies:

```jsonc
// POST /api/quantities
{ "locationId": 3, "variantId": 8, "quantity": 12 }

// PATCH /api/quantities/:quantityId
{ "quantity": 10 }
```

**Atomic upsert.** `POST /api/quantities` is keyed by `(location, variant)`: the
first write returns `201`, a replacement returns `200`, and the submitted
`quantity` is an **absolute replacement, never an increment**. The location row is
locked first so concurrent writes serialize (a unique index guarantees a single
row per pair, and exactly one concurrent request creates it). `POST` validates
that the location, variant and parent product are **active** (`404 NOT_FOUND`
otherwise) and stores `recorded_by` as the acting user.

**Absolute correction.** `PATCH /api/quantities/:quantityId` replaces the stored
value and does **not** require the linked location, variant or product to still be
active, so a count recorded before an archive stays correctable. It never changes
the record's location or variant.

`id`/`locationId`/`variantId`/`quantity` are the only exposed fields:
`recorded_by`, `recorded_at`, `updated_at` and `shift_id` are never returned.
Malformed ids and invalid bodies return `400 VALIDATION_ERROR`; missing records
and inactive references return `404 NOT_FOUND`; unassigned `RESPONSIBLE` access
returns `403 FORBIDDEN`. There is no delete endpoint — quantity records are never
hard-deleted. Query filters are strictly validated (unknown, duplicate and
malformed parameters return `400`).

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

## Tests

```sh
cd backend
npm run db:reset:test     # provision a clean test database
npm test                  # node --test
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
