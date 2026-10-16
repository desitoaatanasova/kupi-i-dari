# AGENTS.md

Guidance for automated agents working in this repository.

## Project

"Купи и Дари" — charity campaign management. Stack:

- **Client:** Flutter (Web + Android only). UI language: **Bulgarian**.
- **Backend:** Node.js + Express, port **3001**.
- **Database:** MySQL 8, **hand-written SQL** (`mysql2/promise`). No ORM.
- **Auth (Phase 2+):** JWT + bcryptjs. Timezone: **Europe/Sofia**.

Repository layout:

```
backend/               Node.js/Express API
database/migrations/   ordered .sql migrations (checksum-verified)
app/                   Flutter app
```

## Commands

All backend commands run from `backend/`:

- `npm install`
- `npm run migrate` — apply pending migrations to `DB_NAME`
- `npm run db:reset:test` — **destructive**, drops/recreates `DB_NAME_TEST` only
- `npm run seed:admin` — idempotent bootstrap admin
- `npm start` — start API
- `npm test` — `node --test`

Flutter commands run from `app/`: `flutter pub get`, `flutter analyze`,
`flutter test`, `flutter run -d chrome`.

## Rules

- **Database:** Never reset or drop the development database. Use
  `DB_NAME_TEST` for destructive/repeatable tests. Never edit an already-applied
  migration file — add a new forward migration. The migration runner fails loudly
  on checksum mismatch; do not bypass it.
- **Secrets:** Never commit `.env`, credentials, or tokens. Do not log secrets.
  Use `.env.example` as the template only.
- **SQL:** Use parameterised queries. Never interpolate user input into SQL.
- **Encoding:** UTF-8 everywhere. UI strings are Bulgarian — verify they are not
  corrupted (`????`).
- **Scope:** Implement only the requested phase. Do not add later-phase
  functionality early.
- **Commits:** Only commit when explicitly asked.

## Current phase

**Phase 7 — shift management.** Phase 2 implemented auth core
(`GET /api/health` plus `POST /api/auth/login`, `POST /api/auth/volunteer`,
`GET /api/auth/me`, `POST /api/auth/logout`). Staff (`RESPONSIBLE`/`ADMIN`) sign
in with phone + bcrypt password; volunteers identify with name + phone only. JWTs
are HS256 with `sub`/`role`/`tv`, expiry via `JWT_EXPIRES_IN` (default `60m`), and
logout revokes by incrementing `users.token_version`.

Phase 3 added admin-only user management under `/api/admin` (all routes require an
active `ADMIN`): list, create staff (`RESPONSIBLE`/`ADMIN`), read, update
(`firstName`/`lastName`/`phone`), and activate/deactivate. Responses use the safe
profile only. Provisioned accounts get `must_change_password = 1` and
`created_by`. Status changes run in a transaction that locks the admin set and
refuse to deactivate the acting admin (`SELF_DEACTIVATION`) or the last active
admin (`LAST_ADMIN`). Admin writes use `adminWriteLimiter`.

Phase 4 adds locations under `/api/locations`. `GET /api/locations` and
`GET /api/locations/:locationId` are **public** (active locations only; malformed,
missing and archived ids all return `404 NOT_FOUND`). Location writes
(`POST`, `PATCH /:id`, `PATCH /:locationId/status`) and both responsible-assignment
routes require an active `ADMIN` and use `adminWriteLimiter`, except the
assignment read. Archive/reactivate uses `is_active` only and never hard-deletes;
it is idempotent. `PUT /api/locations/:locationId/responsibles` atomically
replaces the whole assignee set in a transaction (location row locked first, then
referenced users validated in ascending id order); any missing/inactive/non-
`RESPONSIBLE` id fails the whole request with `400 INVALID_RESPONSIBLE` and leaves
the previous set intact. Responses use the safe location shape
(`id`/`name`/`address`/`isActive`) and the shared safe user profile.

Phase 4 required **no migration** — the Phase 1 schema already supports it.
`locations.created_by` is not added and `locations.city` is not used or exposed.
The development database `kupi_i_dari` must never be migrated/reset; all DB
testing uses `kupi_i_dari_test` via `npm run db:reset:test`. Do not add a location
deletion endpoint (archive via `is_active` instead); archived names stay reserved
by the unique index.

Phase 5 adds products & variants under `/api/products`. `GET /api/products`,
`GET /api/products/:productId` and `GET /api/products/:productId/variants` are
**public** (active records only; malformed, missing and archived ids all return
`404 NOT_FOUND`). Product writes (`POST`, `PATCH /:id`, `PATCH /:id/status`) and
variant writes (`POST /:productId/variants`, `PATCH /:productId/variants/:id`,
`PATCH /:productId/variants/:id/status`) require an active `ADMIN` and use
`adminWriteLimiter`. Product responses expose exactly
`{ id, name, category, isActive }` and variant responses exactly
`{ id, productId, unitLabel, unitValue, isActive }`; never return timestamps or
raw rows. `unit_value` is `DECIMAL(10,3)` and mysql2 returns it as a string — the
serializer converts it to a number or `null`. Product `name` is globally unique
(case-insensitive) → `409 NAME_TAKEN`; variant `unit_label` is unique per product
→ `409 LABEL_TAKEN`. Archive/reactivate uses `is_active` only, is idempotent and
never hard-deletes; archiving a product does **not** touch its variants. Creating a
variant requires an active parent product; variant status requires the parent to
exist in any state. `category` (optional, free-form string, max 80) is the only
classification; there is no category entity, no `products.description` and no
structured unit-of-measure column.

Phase 5 required **no migration** — the Phase 1 schema already defines `products`
and `product_variants`.

Phase 6 adds product quantities under `/api/quantities` and is the first phase to
add a migration since Phase 1: `database/migrations/003_product_quantities.sql`
makes `collected_quantities.shift_id` **nullable** (shifts are still not
implemented) and replaces the unique key `uq_collected` on
`(shift_id, location_id, variant_id)` with `uq_collected_location_variant` on
`(location_id, variant_id)`. A plain `idx_collected_shift` index is added first so
the retained `shift_id` foreign key stays valid; the location/variant FKs keep
`ON DELETE RESTRICT` to protect history. The model is **one quantity row per
(location, variant)**, written with `shift_id = NULL`.

`GET /api/quantities`, `GET /api/quantities/:quantityId`,
`POST /api/quantities` and `PATCH /api/quantities/:quantityId` all require a
Bearer token for an active `ADMIN` or `RESPONSIBLE`. `VOLUNTEER` gets `403`.
`ADMIN` may act on any location; `RESPONSIBLE` only on locations assigned through
`responsible_locations` (an unassigned explicit `locationId` returns `403`, and
list results are scoped to assigned locations). Mutations use `adminWriteLimiter`.
`POST` is an **atomic upsert** keyed by `(location, variant)`: the first write
returns `201`, a replacement returns `200`, and the submitted `quantity` is an
absolute replacement, never an increment (a unique index prevents duplicate rows;
the location row is locked first, so concurrent writes serialize and exactly one
`201` occurs). `POST` requires an active location, variant and parent product
(`404` otherwise) and sets `recorded_by` to the acting user. `PATCH` replaces an
existing record's quantity absolutely and does **not** require the linked
location/variant/product to still be active, so archived records stay correctable.
Responses expose exactly `{ id, locationId, variantId, quantity }`; `recorded_by`,
`recorded_at`, `updated_at` and `shift_id` are never returned. `quantity` is a
whole number in `[0, 2147483647]`; zero is valid. A new backward-compatible `int`
body type was added to `lib/validate.js` (`min` defaults to 1; `min: 0` for
quantities). No delete endpoint exists; quantity records are never hard-deleted.

Phase 7 adds shift management under `/api/shifts` and required **no migration** —
the Phase 1 schema already defines `shifts`, `shift_locations` and
`shift_registrations`, and `collected_quantities.shift_id` stays `NULL` so
quantities are unchanged. All routes require a Bearer token. Reads (`GET
/api/shifts`, `GET /api/shifts/:shiftId`) allow `ADMIN`/`RESPONSIBLE`/`VOLUNTEER`;
writes (`POST`, `PATCH /:shiftId`, `PATCH /:shiftId/status`, `PUT
/:shiftId/locations`) require an active `ADMIN` and use `adminWriteLimiter`. A
shift is same-day only; `date` is a real `YYYY-MM-DD` calendar date and times
normalise `HH:MM`/`HH:MM:SS` to `HH:MM:SS`, with `endTime` strictly after
`startTime`. New shifts start `DRAFT`; allowed transitions are `DRAFT→OPEN`,
`OPEN→CLOSED`, `DRAFT|OPEN→CANCELLED`, repeating the current status is idempotent
(`200`) and anything else is `409 INVALID_STATUS_TRANSITION` (no reopen, no hard
delete). `DRAFT` is staff-only: volunteers never see it in lists and get `404` on
detail (malformed/missing/`DRAFT` ids are indistinguishable). Creation and `PUT
/:shiftId/locations` take 1–100 unique **active** location ids, validated in
ascending id order inside a transaction; any invalid/inactive/missing id is `400
INVALID_LOCATION` with no partial write. Updates and location replacement are only
allowed while `DRAFT`/`OPEN` (`409 SHIFT_NOT_EDITABLE`). Registrations: a
volunteer registers at most once, only while `OPEN` (duplicate → `409
ALREADY_REGISTERED`; re-register after cancel reactivates the same row → `200`;
non-`OPEN` → `409 SHIFT_NOT_OPEN`; missing → `404`). Cancel is idempotent (`200`);
a volunteer cancels only their own row (any other id/missing/wrong-shift →
`404`), `ADMIN` cancels any. `ADMIN`/`RESPONSIBLE` may list a shift's
registrations, `RESPONSIBLE` only when the shift includes one of their assigned
locations (else `403`); `VOLUNTEER` cannot list them. Safe shapes: shift
`{ id, title, date, startTime, endTime, status }` (detail adds `locations` and
`myRegistration: { status } | null`), registration
`{ id, shiftId, userId, status }`. Never expose `created_by`, timestamps,
`registered_at`, registrant names/phones or raw rows. New backward-compatible
`date` and `time` body/query types were added to `lib/validate.js`.

Still out of scope: staff self-registration, password reset, forced password change
enforcement (`must_change_password` is stored/returned but not enforced), role
changes, location/product/variant/quantity/shift/registration hard delete, shift
editing once `CLOSED`/`CANCELLED`, reopening a `CLOSED`/`CANCELLED` shift,
shift↔quantity integration, purchases, donations, distribution, inventory
balances/analytics, uploads, dashboards, and any Flutter UI.

Notes for agents:

- `JWT_SECRET` must be set to start the API (`npm start`); migration/seed scripts
  do not require it. Tests use a fixed test-only secret via `test/helpers/env.js`.
- Volunteer identification is weak by design — name + phone is identification, not
  strong authentication. Do not claim otherwise, and do not add SMS/OTP/PIN.
- Staff passwords are bcrypt hashes only (cost 12). Never return hashes, tokens,
  or `token_version`; never log full phone numbers (use `lib/phone.maskPhone`).
- Location responses expose exactly `{ id, name, address, isActive }`; never
  return `city`, `created_by`, timestamps, or raw rows.
