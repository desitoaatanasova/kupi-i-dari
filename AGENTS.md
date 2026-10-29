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
- `npm test` — `node --test`, full backend suite
- targeted auth suites, e.g.
  `npx node --test test/auth-register.test.js test/auth-volunteer-login.test.js test/auth-rate-limit.test.js`

Flutter commands run from `app/`: `flutter pub get`, `flutter analyze`,
`flutter test`, `flutter run -d chrome`. Targeted client auth suites, e.g.
`flutter test test/auth_api_test.dart test/auth_screens_test.dart test/registration_screen_test.dart`.
On Windows the local SDK executable is `E:\flutter\bin\flutter.bat`.

For Phase 30, `npm run db:reset:test` is **not** a required step. Do not run it
or any database reset unless the target is provably the `DB_NAME_TEST` test
database; never reset the development database.

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
- **Protected client/config files:** Do not change `app/lib/core/config.dart`,
  `app/pubspec.yaml` or `app/lib/core/api/api_scope.dart` without explicit
  permission. Do not edit or add files under `database/migrations/` except as an
  explicitly requested new forward migration.
- **Commits:** Only commit when explicitly asked.

## Current phase

**Backend Phase 12 — Inventory balance reporting; auth extended in Phase 30;
Flutter client Phase 30 — volunteer registration and real authentication.**
Phase 2 implemented auth core (`GET /api/health` plus `POST /api/auth/login`,
`POST /api/auth/volunteer`, `GET /api/auth/me`, `POST /api/auth/logout`). Staff
(`RESPONSIBLE`/`ADMIN`) sign in with phone + bcrypt password; volunteers log in
with name + phone only. Phase 30 adds public volunteer registration and a strict
volunteer-login endpoint while preserving the legacy volunteer endpoint. JWTs are
HS256 with `sub`/`role`/`tv`, expiry via `JWT_EXPIRES_IN` (default `60m`), and
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
Responses expose exactly `{ id, locationId, variantId, quantity }` (Phase 8 later
extends this with `shiftId`); `recorded_by`, `recorded_at` and `updated_at` are
never returned. `quantity` is a
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

Phase 8 adds shift-linked quantity entry and is the first phase since Phase 6 to
add a migration: `database/migrations/004_shift_quantities.sql` drops
`uq_collected_location_variant` and `idx_collected_shift`, then adds
`uq_collected_shift_location_variant` on `(shift_id, location_id, variant_id)`;
`shift_id` stays nullable and **no data is transformed** (existing rows keep
`shift_id = NULL`, the legacy unlinked model, and are never backfilled). Because
MySQL cannot enforce uniqueness over `NULL`, the one-unlinked-row-per
`(location, variant)` invariant is preserved in the application by locking the
location row first, then selecting the existing row before deciding INSERT vs
UPDATE; shift-linked writes are serialised by the shift row lock, with the triple
index as a backstop. `collected_quantities.shift_id` now carries real shift ids.

Safe quantity shape is extended with `shiftId`:
`{ id, shiftId, locationId, variantId, quantity }`, where `shiftId` is a number
for a linked row or `null` for a legacy row. `POST /api/quantities` accepts an
**optional** `shiftId` (validated to exist → `404` otherwise); omitting it keeps
the Phase 6 unlinked upsert, supplying it upserts on the
`(shift_id, location_id, variant_id)` triple. `GET /api/quantities` accepts an
optional `shiftId` filter. Legacy rows stay readable, filterable and correctable.

New volunteer-facing routes live on the shift: `GET /api/shifts/:shiftId/entry`
(any authenticated role) and `PUT /api/shifts/:shiftId/quantities`
(`VOLUNTEER` only, `adminWriteLimiter`). The entry context always exposes exactly
`{ shift, canSubmit, submissionError, entryWindow, locations, quantities }`.
`submissionError` is one of `null`, `SHIFT_NOT_OPEN`, `REGISTRATION_REQUIRED`,
`ENTRY_WINDOW_CLOSED`, `ROLE_NOT_VOLUNTEER`. Scope: `ADMIN` sees every shift
location and quantity row; `RESPONSIBLE` only assigned locations and their rows;
`VOLUNTEER` sees the shift's active locations and aggregate quantity rows. Never
expose registrant names/phones, `recorded_by`, `registered_at` or audit metadata;
a volunteer never receives another volunteer's data.

Submission rules: the shift must be `OPEN` and the wall clock within
`[startTime, endTime + 30 minutes]` in `Europe/Sofia`, inclusive and DST-aware
(helpers in `src/lib/entry-window.js`, `GRACE_MINUTES = 30`); the caller must hold
an active `REGISTERED` registration (`403 REGISTRATION_REQUIRED`); the location
must belong to the shift (`403 LOCATION_NOT_IN_SHIFT`); and the location, variant
and parent product must be active (`404 NOT_FOUND`). The body is
`{ locationId, quantities: [{ variantId, quantity }] }` with 1–100 unique items
(empty/duplicate lists → `400`). `PUT` is a transactional all-or-nothing
absolute replacement keyed by `(shift, location, variant)`: listed variants are set
to the given value (`0` stored explicitly), omitted variants are untouched, and
any invalid item rolls the whole batch back. Global lock order is shift row →
caller registration → location row → variants ascending; the volunteer and staff
paths share it so concurrent writes cannot deadlock. Success returns `200` with
`{ quantities: [...] }` ordered by `variantId`; malformed shift id on `GET` is
`404` (indistinguishable), on `PUT` `400`. `GET /entry` renders `entryWindow`
as Sofia-offset ISO strings via `toSofiaIso`. The volunteer path is deliberately
separate from the staff-only `/api/quantities` API.

Phase 9 adds a read-only collected quantity report: `GET /api/reports/collected`
(requires `ADMIN` or `RESPONSIBLE`, authenticated; `VOLUNTEER` → `403`). The report
returns `{ totals: { units, rows }, byLocation: [...], byProduct: [...] }` with
exact keys and ordering by `units DESC, id ASC`. Filters: `shiftId` (int ≥1),
`locationId` (int ≥1), `productId` (int ≥1), `dateFrom`, `dateTo` (inclusive).
RESPONSIBLE is scoped to assigned locations; an explicit unassigned `locationId`
returns `403`. Date predicates use the shift's `shift_date` and naturally exclude
legacy unlinked rows (`shift_id IS NULL`) when a shift/date filter is applied;
legacy rows are included in unfiltered reports. The report sums recorded rows —
it is not an inventory balance, distribution or analytics report. No migration or
schema change was added for Phase 9.

Phase 10 adds an authenticated password-change endpoint and enforces the existing
`must_change_password` flag; it required **no migration** and changed no other
endpoint contract. `POST /api/auth/password/change` requires a Bearer token for an
active account with a password hash. Body is `{ currentPassword, newPassword }`
(strict `validateBody`; unknown fields → `400`; both strings, `currentPassword`
non-empty max 200, `newPassword` 8–200, neither trimmed). A `newPassword` equal to
`currentPassword` → `400 VALIDATION_ERROR`; a wrong current password or a
password-less volunteer/unknown user → `401 INVALID_CREDENTIALS`; a disabled
account → `403 ACCOUNT_DISABLED`. Success replaces the bcrypt hash, clears
`must_change_password` and increments `token_version` in a **single atomic
statement** (`users.setPasswordAndClearMustChange`, which re-reads and returns the
refreshed row), then returns a fresh token in the login shape
(`token`/`tokenType`/`expiresIn`/`user` safe profile). A valid `currentPassword`
check is timing-safe (`verifyPassword` against the stored hash; unknown users never
reach hashing). The route uses `loginLimiter`.

Enforcement lives **inside `authenticate`** (`src/middleware/authenticate.js`):
after loading the DB user it calls `enforcePasswordChanged`, so every
authenticated request re-checks the flag and a staff account with
`must_change_password = 1` is blocked from all protected routes with
`403 MUST_CHANGE_PASSWORD` and message `Password change is required before
continuing.`. The only allowlisted paths (matched on `req.originalUrl` without the
query string) are `POST /api/auth/password/change`, `GET /api/auth/me` and
`POST /api/auth/logout`. Public routes (health, public location/product reads) and
login never call `authenticate`, so they are unchanged. Do **not** add
route-level `requirePasswordChanged` calls — enforcement is centralised in
`authenticate` and the middleware is not exported for that reason. Volunteers
never have the flag set (no password hash), so they are unaffected.

Phase 11 adds distribution of collected goods under `/api/distributions` and is the
first phase since Phase 8 to add a migration:
`database/migrations/005_distributions.sql` creates an additive `distributions`
table. A distribution is an **append-only event** (no unique key): the same
`(location, variant)` may be distributed many times, unlike `collected_quantities`.
Columns: `location_id`/`variant_id` (FKs `ON DELETE RESTRICT`), `distribution_date`
DATE (Europe/Sofia business date), `quantity` INT, nullable `recipient` (VARCHAR
160) and `note` (VARCHAR 255), `distributed_by` (FK to `users`, `ON DELETE SET
NULL`), and `distributed_at` TIMESTAMP. No existing table, column or index is
changed and no data is transformed.

`GET /api/distributions`, `GET /api/distributions/:distributionId`,
`POST /api/distributions` and `PATCH /api/distributions/:distributionId` all
require a Bearer token for an active `ADMIN` or `RESPONSIBLE`; `VOLUNTEER` gets
`403`. `ADMIN` may act on any location; `RESPONSIBLE` only on locations assigned
through `responsible_locations` (an unassigned explicit `locationId` returns
`403`, list results are scoped to assigned locations, and per-record reads/updates
authorise against the record's own `location_id`, never a client-supplied id).
Mutations use `adminWriteLimiter`. `POST` inserts a new event (`201`) and requires
an active location, active variant and active parent product (`404` otherwise);
`quantity` is a whole number `>= 1` and `recipient`/`note` are optional nullable
strings. `PATCH` performs an absolute correction of `quantity`/`recipient`/`note`
(empty body → `400`; `null` clears `recipient`/`note`) and does **not** require the
linked location/variant/product to still be active, so archived records stay
correctable; `locationId`, `variantId`, `date` and the distributor are immutable.
`distribution_date` is computed with the existing Europe/Sofia utility
(`lib/entry-window.js`), and list date filters (`dateFrom`/`dateTo`, inclusive) act
on that column. Responses expose exactly
`{ id, locationId, variantId, quantity, date, recipient, note }`; `distributed_by`
and `distributed_at` are never returned. There is no delete endpoint and
`recipient` is a non-personal label, not a place for private beneficiary data.
Over-distribution is not enforced and no inventory balance is calculated.

Phase 12 adds a read-only inventory balance report at
`GET /api/reports/inventory` (requires an active `ADMIN` or `RESPONSIBLE`;
`VOLUNTEER` → `403`, unauthenticated → `401`, and forced-password-change staff are
blocked centrally with `403 MUST_CHANGE_PASSWORD`). It required **no migration**
and changed no existing endpoint. It answers collected vs distributed per
`(location, variant)`, where
`remainingQuantity = collectedQuantity - distributedQuantity`. The two sources are
aggregated **independently** in a single `UNION ALL` keyed by `(location, variant)`,
so multiple collection and distribution rows never multiply and the sets are never
joined row-to-row. The key set is the union of both sources: a **distribution-only**
pair appears with `collectedQuantity = 0` and a negative `remainingQuantity`, an
equal pair appears as a visible zero balance, and a pair with no activity is
omitted (no location-by-variant cross product). `remainingQuantity` is **never
clamped** (Phase 11 deliberately does not enforce distribution limits). Shift-linked
and legacy unlinked collections are both included when no date filter is supplied; a
`dateFrom`/`dateTo` filter dates the collection branch on `shifts.shift_date` (the
INNER join to `shifts` therefore excludes legacy `shift_id IS NULL` rows) and the
distribution branch on `distributions.distribution_date`, so a date-filtered report
is **window net flow**, not a historical balance as of the end date — the same
convention established for `/api/reports/collected`. Supported filters are
`locationId`, `productId`, `variantId`, `dateFrom`, `dateTo` (there is deliberately
no `shiftId`, because distributions are not linked to shifts). `ADMIN` is
unrestricted; `RESPONSIBLE` is scoped to assigned locations on **both** branches
(the `responsible_locations` join is `(user, location)`-unique and never multiplies
rows), and an explicit unassigned `locationId` returns `403`. The response exposes
exactly `{ totals, byLocation, byProduct, byVariant }`, ordered by collected
quantity `DESC` then entity id `ASC`; entries expose only entity ids/names,
`category`, `unitLabel` and the three quantities. Collected, distributed and
remaining quantities are computed in one round-trip and folded in the service
(no N+1), with `SUM()` normalised to JavaScript numbers. No inventory mutation,
reservation, adjustment, over-distribution enforcement, shift-linked distribution
or `shiftId` filter exists.

Phase 30 extends auth and required **no migration**. `POST /api/auth/register`
is public and accepts exactly `{ firstName, lastName, phone, role }`, where
`role` is the enum `VOLUNTEER` only; ADMIN/RESPONSIBLE and unknown/omitted roles
return `400 VALIDATION_ERROR`. Names use the existing trimmed/collapsed
1–60-character validation and phones use the canonical `+359[2-9]\d{8}` helper.
It creates a passwordless volunteer with `created_by = NULL`, returns `201` with
the normal token response, and returns `409 PHONE_TAKEN` when the phone already
exists (including staff numbers). Concurrent registration of the same phone
yields exactly one `201`; `users.createVolunteer` already returns
`{ created: false }` on `ER_DUP_ENTRY`.

`POST /api/auth/volunteer/login` is public and accepts
`{ firstName, lastName, phone }` only. It looks up an existing user and never
creates one. Unknown phone, name mismatch and staff accounts all return the same
`401 INVALID_CREDENTIALS`; a matching inactive `VOLUNTEER` returns
`403 ACCOUNT_DISABLED`; success returns `200` with the normal token response and
updates `last_login_at`. Names match case-insensitively after whitespace
normalisation via the existing `namesMatch`. The legacy `POST /api/auth/volunteer`
endpoint is unchanged for backward compatibility; the Flutter client no longer
uses it.

`registerLimiter` and `volunteerLoginLimiter` are separate express-rate-limit
instances in `src/middleware/auth-rate-limit.js`, both reusing the existing
`config.authRateLimit.volunteerMax` / `AUTH_VOLUNTEER_RATE_LIMIT_MAX` (no new env
variables). They are separate buckets from each other, from the staff
`loginLimiter` and from the legacy `volunteerLimiter`. All errors use the shared
envelope.

**Phase 30 authentication contract — checklist for agents.**

1. Endpoints are exactly: `POST /api/auth/register` (public volunteer
   registration), `POST /api/auth/volunteer/login` (strict passwordless volunteer
   login), `POST /api/auth/volunteer` (legacy, identify-or-create, unchanged),
   `POST /api/auth/login` (staff phone + password), `GET /api/auth/me`,
   `POST /api/auth/password/change`, `POST /api/auth/logout` (204).
2. The strict `/api/auth/volunteer/login` never creates an account and maps all
   unknown/mismatched/staff logins to `401 INVALID_CREDENTIALS`. The legacy
   `/api/auth/volunteer` still creates a volunteer on first use; do not point the
   client at it.
3. Public registration is `VOLUNTEER` only. `ADMIN`/`RESPONSIBLE` and unknown or
   omitted roles are `400 VALIDATION_ERROR`; a taken phone is `409 PHONE_TAKEN`.
4. `ADMIN`/`RESPONSIBLE` accounts are created only by an administrator through
   `POST /api/admin/users` (with `must_change_password = 1`), never publicly.
5. Staff sign in with phone + password via `POST /api/auth/login`; volunteers use
   name + phone only.
6. The client session role always comes from the backend `user.role` in the token
   response, never from the local role selection.
7. The Flutter session is **in memory only**; there is no persistent token
   storage. Do not add one without an explicit request.
8. The central `ApiClient.onUnauthorized` handler fires only for HTTP `401` with
   code `UNAUTHORIZED`, never for `INVALID_CREDENTIALS`, and clears the session via
   `SessionController.handleUnauthorized()`.
9. JWT (`sub`/`role`/`tv`), `users.token_version` revocation, the central
   `must_change_password` enforcement inside `authenticate`, and all role guards
   remain in force. Do not weaken or duplicate them at route level.
10. Backend testing: `npm test` from `backend/`; targeted auth suites can be run
    one file at a time with `npx node --test …`. Flutter testing: `flutter analyze`
    and `flutter test` from `app/` (on Windows
    `E:\flutter\bin\flutter.bat`). Phase 30 needs no database reset.
11. Do not change `app/lib/core/config.dart`, `app/pubspec.yaml` or
    `app/lib/core/api/api_scope.dart` without explicit permission.
12. Do not edit or add files under `database/migrations/` except as an explicitly
    requested new forward migration, and never run a database reset unless the
    target is provably the `DB_NAME_TEST` test database.

Still out of scope: staff self-registration, password reset/recovery, admin-initiated
password reset, password history, role changes,
location/product/variant/quantity/shift/registration/distribution hard delete, shift
editing once `CLOSED`/`CANCELLED`, reopening a `CLOSED`/`CANCELLED` shift, staff
editing a volunteer's shift-linked quantities on the entry path, purchases,
donations, inventory mutations/reservations/adjustments, over-distribution
enforcement, shift-linked distributions, distribution limits, uploads,
dashboards, and further Flutter UI beyond the client phases listed below.

## Client phases (Flutter)

The Flutter app under `app/` is tracked as **client phases 13–30** and runs
alongside the backend phases above (the backend itself is at Phase 12, with the
Phase 30 auth additions).

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
| 24 | Usability & Accessibility Polish | `app/lib/core/theme/app_colors.dart`, `app/lib/core/theme/app_theme.dart`, `app/lib/core/statuses.dart`, `app/lib/widgets/product_sticker_card.dart`, `search_field.dart`, screens |
| 25 | Accessibility regression coverage | `app/test/a11y_phase25_test.dart`, `app/lib/widgets/product_sticker_card.dart`, `app/test/shifts_screen_test.dart`, `app/test/locations_screen_test.dart`, `app/test/entry_screen_test.dart` |
| 26 | Admin shift lifecycle UI | `app/lib/screens/shift_editor_screen.dart`, `app/lib/screens/shifts_screen.dart`, `app/lib/screens/shift_detail_screen.dart`, `app/lib/core/api/shifts_api.dart`, `app/test/shift_admin_test.dart` |
| 27 | Admin location management UI | `app/lib/core/api/locations_api.dart`, `app/lib/screens/location_editor_screen.dart`, `app/lib/screens/locations_screen.dart`, `app/lib/core/auth/auth_messages.dart`, `app/test/locations_api_test.dart`, `app/test/location_admin_test.dart`, `app/test/locations_screen_test.dart` |
| 28 | Admin user management UI | `app/lib/core/api/admin_users_api.dart`, `app/lib/models/admin_user_page.dart`, `app/lib/screens/admin_users_screen.dart`, `app/lib/screens/admin_user_editor_screen.dart`, `app/lib/widgets/user_card.dart`, `app/lib/widgets/app_shell.dart`, `app/test/admin_users_api_test.dart`, `app/test/admin_users_screen_test.dart` |
| 29 | Admin shift management hardening | `app/lib/screens/shift_editor_screen.dart`, `app/lib/screens/shift_detail_screen.dart`, `app/lib/screens/shifts_screen.dart`, `app/lib/widgets/primary_button.dart`, `app/test/shift_admin_test.dart`, `app/test/shifts_screen_test.dart`, `app/test/shifts_api_test.dart` |
| 30 | Volunteer registration and real authentication | `app/lib/core/api/auth_api.dart`, `api_client.dart`, `app/lib/core/session/session_controller.dart`, `app/lib/main.dart`, `app/lib/screens/registration_screen.dart`, `volunteer_identification_screen.dart`, `login_screen.dart`, `start_screen.dart`, `app/test/registration_screen_test.dart` |

**Client Phase 20 — shift registration.** `ShiftDetailScreen` registers the
authenticated volunteer through `POST /api/shifts/:shiftId/registrations`
(`ShiftsApi.registerSelf`): no request body and no `Content-Type` are sent, and
the safe shape `{ id, shiftId, userId, status }` is parsed strictly into
`RegistrationResult` (a malformed payload raises `UNEXPECTED_RESPONSE`). The
register action is offered only to an authenticated volunteer, for an `OPEN`
shift, when the volunteer is not registered yet (`REGISTERED`); while a request
is in flight the action stays visible but disabled, so a duplicate tap never
issues a second request. Success is reported only after the backend confirms it
(`201` for a new registration, `200` for the reactivation of a `CANCELLED`
row), and the shift detail is then reloaded (`GET /api/shifts/:shiftId`) to
reconcile — a confirmed registration is never overwritten by a stale detail
response. `ALREADY_REGISTERED` and `SHIFT_NOT_OPEN` trigger a reconciliation
reload instead of a success message; `401 UNAUTHORIZED` clears the session
through `SessionController`. All user-facing strings are Bulgarian
(`AuthMessages`), and the quantity-entry wording (`SHIFT_NOT_OPEN` →
`Смяната не е отворена за отчитане.`) stays separate from the
registration-specific message. Cancellation was **not** implemented in this
phase: a volunteer cannot discover their own registration id from a shift
detail, so no cancel call was made — see Client Phase 22.

**Client Phase 21 — shared volunteer registration state.** `GET /api/shifts` does
not expose `myRegistration` and there is no "my registrations" endpoint, so the
app caches the confirmed states it has already seen in
`app/lib/core/session/registration_state_controller.dart`, exposed through
`RegistrationScope` (an `InheritedNotifier`, mirroring `SessionScope`). The cache
is keyed by the backend user id first (`user id -> shift id -> status`), so one
volunteer's registrations can never leak into another user's view; `null` removes
an entry and listeners are notified only on a real change. Only states observed
in a confirmed backend response are stored: the `myRegistration.status` of
`GET /api/shifts/:shiftId` and the `status` of a confirmed
`POST /api/shifts/:shiftId/registrations`; nothing is fetched, persisted or
faked. The shift list shows a `Записани сте` chip (`ShiftCard.isRegistered`)
only for an authenticated **volunteer** whose cached status is exactly
`REGISTERED` — a cancelled, unknown or foreign registration shows no chip, and
staff or anonymous sessions never see one. The chip costs **no extra request**:
the list is never reloaded, and the location-filtered list publishes the
registration state of the detail responses it fetches anyway. The detail screen
publishes the *effective* status (the server status, except that a locally
confirmed `REGISTERED` is never erased by a missing server status) and skips
publishing when a newer registration was confirmed while the request was in
flight (the Phase 20 revision gate). The state is intentionally **partial** and
in-memory: it only covers the shifts observed during the current app session and
is lost on a reload.

**Client Phase 22 — volunteer registration cancellation.** The volunteer cancels
their own registration through `PATCH /api/shifts/:shiftId/registrations/:registrationId/cancel`
(`ShiftsApi.cancelSelf`), backed by a new `ApiClient.patch` helper: no request
body is sent (and therefore no `Content-Type`), and the safe shape
`{ id, shiftId, userId, status }` is parsed strictly into `RegistrationResult`.
The cancellation action is offered **only** when the caller is an authenticated
volunteer, the shift is `OPEN`, the status is `REGISTERED` **and the registration
id is known**. The id is returned by the backend only in a registration
response, so it is known **only for registrations made during the current app
session**; `myRegistration` in a shift detail carries the status alone and
`GET /api/shifts/:shiftId/registrations` is staff-only, so a registration from
an earlier session cannot be cancelled. In that case no action is offered and a
muted Bulgarian line explains it (`Този запис е направен в предишна сесия и не
може да бъде отменен от приложението.`). The request is sent only after a
confirmation dialog (`Сигурни ли сте, че искате да откажете записа си за тази
смяна?` → `Да, откажи` / `Не, оставам`); while it is in flight the action stays
visible but disabled, so a repeated tap never issues a second request. The
shared state is changed **only** after the backend confirms the cancellation
(`CANCELLED`, the known id is retained), the revision gate is bumped so an
older in-flight detail response cannot restore `REGISTERED`, and the shift
detail is reloaded silently; a confirmed cancellation is never undone by a
server status that still reports the pre-cancellation registration. Failures
change nothing and are reported in Bulgarian (`SHIFT_NOT_OPEN` →
`Отказът на записа е възможен само докато смяната е отворена.`, `NOT_FOUND` →
`Записът не е намерен. Възможно е вече да е отменен.`, everything else through
`AuthMessages`); `SHIFT_NOT_OPEN` and `NOT_FOUND` trigger a silent
reconciliation and `401 UNAUTHORIZED` clears the session through
`SessionController`. The registration id is kept next to the status in
`RegistrationStateController` (keyed by user id first, in-memory only, never
persisted) and the list's `Записани сте` chip disappears without any extra
request.

**Client Phase 23 — reliable quantity entry and clear access.** Phase 23 is a
**client-only** phase: no backend endpoint, migration, request shape or response
field changed. Three defects of the earlier phases are fixed.

1. *No invented counts.* The backend safe shift shape
   (`{ id, title, date, startTime, endTime, status }`) never exposes a
   registration count or a capacity, but the parsers used to fill both with
   `0`/`1`. `Shift.registeredCount` and `Shift.capacity` are now `int?`
   (`null` = unknown), `Shift.isFull` is `false` while the counts are unknown
   and `Shift.remaining` is `null`. `VolunteerCountBadge` hides itself
   completely when a count is missing, negative or when the capacity is not
   positive; it never renders an invented `0 / 1`.
2. *Quantities belong to a point.* The pending quantities of the entry screen
   were not bound to the selected point: a volunteer could enter quantities,
   switch the point and submit the numbers to the wrong point. Changing the
   point now clears the pending quantities and explains it
   (`Количествата са изчистени, защото сменихте пункта.`); the batch is never
   sent for a point the volunteer did not choose. The `Записано на сървъра`
   marker is scoped to the selected point (the entry context contains the rows
   of every point of the shift), and a successful submission merges the
   returned rows per `(location, variant)` — the backend replaces only the
   **listed** variants, so the untouched rows of the same point and the rows of
   every other point survive.
3. *Anonymous visitors get a clear path.* `GET /api/shifts` requires a bearer
   token, so the shifts screen no longer sends a request that could only fail:
   without a session it shows `Идентифицирайте се, за да виждате смените.` with
   an `Идентифицирайте се` action that opens the existing volunteer
   identification screen (no session-expired message is shown for a session
   that never existed; a real `401 UNAUTHORIZED` still clears the session
   through `SessionController`). The authenticated behaviour is unchanged.

The catalog is now loaded with a **bounded worker pool**: exactly one variants
request per product (the request count is unchanged) but at most **6** requests
run at the same time. A failing request still fails the whole load — a
partially loaded catalog is never presented as loaded and the `Повтори` action
remains. Every worker is awaited, so no asynchronous error is left unhandled.

**Client Phase 24 — Usability & Accessibility Polish.** Client-only phase:
updated color tokens for accessibility (`AppColors.textTertiary` to `#5F6772`,
`AppColors.secondary`/`AppColors.error` to `#C62828`), added `AppColors.success`,
adjusted status chip colors (`available` text `#256428`, `full` text `#C62828`),
updated theme `colorScheme.error` and input borders to accessible colors.
Increased quantity control hit target in `ProductStickerCard` to 48×48 with
semantics labels for +/- actions. Added `RefreshIndicator` to `ShiftsScreen`
and `LocationsScreen` (pull-to-refresh) with `AlwaysScrollableScrollPhysics`
for empty states; anonymous shifts screen behavior unchanged. Added minimal
semantics for submit action and “Записано на сървъра” marker; `SearchField` clear
button has semantics label. Replaced hardcoded “saved on server” color with
token. No backend/SQL/migrations/API/config/dependency changes.

**Client Phase 25 — accessibility regression coverage.** Phase 25 is
**client-only**: no backend endpoint, migration, request shape or response field
changed. It adds deterministic regression tests and one production hit-target
fix.

- `app/test/a11y_phase25_test.dart` computes WCAG relative luminance and asserts
  `>= 4.5:1` for `textTertiary` on both backgrounds, `success` on white, and
  every `ShiftStatus` chip text/background pair.
- The quantity `-`/`+` `IconButton`s expose measured `48×48` hit targets (the
  decorative `48×48` wrapper previously contained a `40×40` interactive button)
  and semantics labels `Намали`/`Увеличи`. `_RoundIconButton` now places the
  `IconButton` directly in the `48×48` box while preserving the visual circle.
- `SearchField` exposes `Изчисти търсенето` as a button; the entry submit action
  exposes `Изпрати` with its enabled/disabled state, and the saved marker exposes
  `Записано на сървъра`.
- Widget tests cover pull-to-refresh on `ShiftsScreen` and `LocationsScreen`
  (fresh load, preserved search/filter, empty state, anonymous shifts never call
  the API). A failed locations refresh is covered as **current behavior**: it
  clears the previous list and shows the network error with `Повтори`; this is
  documented as a limitation, not advertised as offline caching.
- The full Flutter suite passes (235 tests) and `flutter analyze` is clean.

**Client Phase 26 — admin shift lifecycle UI.** Phase 26 is **client-only**: no
backend endpoint, migration, request shape or response field changed. It exposes
the existing Phase 7 shift writes to an authenticated `ADMIN`.

- `ShiftStatus.draft` (`Чернова`) maps `DRAFT`; the chip meets WCAG AA. The
  volunteer-facing mappings and registration/entry behaviour are unchanged.
- `ShiftsApi` adds `createShift`, `updateShift`, `setShiftStatus` and
  `replaceShiftLocations`, with strict safe-response parsing.
- `ShiftsScreen` offers `Нова смяна` only to an admin. It opens
  `ShiftEditorScreen`, preselects the filtered location, and refreshes without
  filters after a confirmed creation. The shifts screen is not wrapped in a
  nested `Scaffold`.
- `ShiftEditorScreen` creates a `DRAFT` shift with 1–100 unique active
  locations, or edits metadata only. It validates `ГГГГ-ММ-ДД`, `ЧЧ:ММ`, an end
  after the start, and a title of at most 120 characters. Locations come only
  from `GET /api/locations`; failures and an empty catalogue show a retry path,
  never sample data.
- `ShiftDetailScreen` shows management only for `DRAFT`/`OPEN`: metadata edit and
  complete location replacement for both, `DRAFT → OPEN`, `OPEN → CLOSED`, and
  cancel from either. Close and cancel require confirmation; `CLOSED` and
  `CANCELLED` are read-only. No optimistic state is shown: success is reported
  only after the backend confirms, the detail is reloaded and the parent list is
  notified. A revision guard keeps an older detail response from restoring stale
  state.
- Location replacement sends the complete active set. Archived linked locations
  stay visible but unselectable and are explained as removed on save.
- `INVALID_LOCATION`, `SHIFT_NOT_EDITABLE` and `INVALID_STATUS_TRANSITION` have
  fixed Bulgarian messages in `AuthMessages`; `401 UNAUTHORIZED` clears the
  session centrally.
- The full Flutter suite passes (256 tests) and `flutter analyze` is clean.

**Client Phase 27 — admin location management UI.** Phase 27 is **client-only**:
no backend endpoint, migration, request shape or response field changed. It
exposes the existing Phase 4 location writes to an authenticated `ADMIN`.

- `LocationsApi` adds `createLocation`, `updateLocation` and
  `setLocationStatus`; responses are parsed strictly through the shared safe
  location parser, and malformed payloads raise `UNEXPECTED_RESPONSE`.
- `LocationsScreen` offers `Нов пункт` only to an admin, in the header, the
  empty state and the error state. Each card has a `Действия за пункта` menu with
  `Редактирай`/`Архивирай`; archive requires confirmation, is applied only after
  the backend confirms, and offers a `Върни` snackbar action.
- `LocationEditorScreen` creates a location or edits an active one. It trims and
  validates `name` (1–120) and `address` (1–255), shows fixed Bulgarian errors,
  disables duplicate submissions while in flight, and returns the safe saved
  location to the list.
- Duplicate names map to `NAME_TAKEN` in `AuthMessages`; `401 UNAUTHORIZED`
  clears the session through `SessionController`.
- Create, edit and restore are applied locally with name/id sorting and a load
  revision guard, so a delayed list response cannot overwrite a confirmed
  mutation. Search is preserved for edits/archives and cleared on create only
  when the new location would otherwise stay hidden; no sample data is used.
- `GET /api/locations` lists active locations only, so there is no persistent
  reactivation path after a reload. Undo is intentionally same-session via the
  snackbar; a future backend inactive-location listing would be required for
  anything more.
- `flutter analyze` is clean and the full Flutter suite passes (286 tests).

**Client Phase 28 — admin user management UI.** Phase 28 is **client-only**: no
backend endpoint, migration, request shape or response field changed. It exposes
the existing Phase 3 admin user API to an authenticated `ADMIN`.

- `AdminUsersApi` adds strict typed calls for `GET /api/admin/users`,
  `POST /api/admin/users`, `PATCH /api/admin/users/:userId` and
  `PATCH /api/admin/users/:userId/status`. It parses only the safe profile
  `{ id, phone, firstName, lastName, role, isActive, mustChangePassword }` and
  the paginated `{ users, pagination }` envelope. Malformed envelopes/users,
  `page < 1`, `pageSize` outside `1..100`, non-positive ids and create roles
  other than `RESPONSIBLE`/`ADMIN` fail locally with `UNEXPECTED_RESPONSE`
  without a request.
- `AppShell` adds the `Потребители` tab only for admins. `AdminUsersScreen`
  independently guards admin access, so non-admin and anonymous callers get the
  Bulgarian forbidden state and no user data.
- `AdminUsersScreen` requests 20 users per page and supports role filters (all,
  volunteer, responsible, admin), status filters (all, active, inactive),
  previous/next paging, pull-to-refresh, retryable errors and an empty state.
  Out-of-range pages clamp to the last available page (or page 1 when empty).
  Load revisions prevent a delayed list response from overwriting a newer filter
  or a confirmed local mutation.
- `AdminUserEditorScreen` creates a `RESPONSIBLE`/`ADMIN` account or edits only
  `firstName`, `lastName` and `phone`. Names are trimmed and limited to 60;
  phones are normalised; create requires a matching initial password of 8–200
  characters. Role and password are read-only/absent when editing. Duplicate
  submissions are disabled while in flight. Newly created staff are provisioned
  with `mustChangePassword = 1`; the editor explains the mandatory first-login
  password change and the list shows the pending-change badge.
- Create reports success only after the backend confirms it, keeps matching
  filters and loads the last page; if the created user does not match the
  filters, both reset to all/all before loading the last page.
- Editing replaces the row locally without a list request; editing the acting
  admin refreshes the session profile. A failed profile refresh does not turn a
  confirmed update into an error.
- Deactivation requires confirmation. Status changes apply only the confirmed
  safe profile: a row that no longer matches the filters is removed, and an
  emptied page reloads the previous one. `PHONE_TAKEN`, `SELF_DEACTIVATION`,
  `LAST_ADMIN`, `FORBIDDEN` and `UNAUTHORIZED` use fixed `AuthMessages` strings;
  a 401 clears the session through `SessionController`.
- `UserCard` shows accessible role/status/forced-password/current-user badges.
  This screen does not change roles, reset/recover passwords, create volunteers,
  hard-delete users or assign responsible users to locations (all out of scope).
- Tests: `app/test/admin_users_api_test.dart` (11 tests) and
  `app/test/admin_users_screen_test.dart` (21 tests) cover the contract,
  access, filters, pagination, stale responses, errors, creation, editing and
  status changes. At the end of Phase 28 the full Flutter suite passed (319
  tests) and `flutter analyze` was clean.

**Client Phase 29 — admin shift management hardening.** Phase 29 is
**client-only**: no backend endpoint, migration, request shape, response field
or dependency changed. It locks in the Phase 26 lifecycle behaviour with
regression coverage and fixes the defects exposed by it.

- The shared `PrimaryButton` keeps its label visible next to the spinner while
  busy. A pending create, edit, publish, close or cancel action stays
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
- Stale list and detail responses cannot overwrite newer state. Existing
  revision guards are covered for older list responses, older errors and an
  older admin detail response arriving after a newer confirmed status. Archived
  linked locations remain visible but unselectable.
- Tests: `app/test/shift_admin_test.dart` (27 tests),
  `app/test/shifts_screen_test.dart` (27 tests) and
  `app/test/shifts_api_test.dart` (25 tests). The full Flutter suite passes
  (334 tests) and `flutter analyze` is clean.
- Out of scope: admin registration management screens/API, new endpoints,
  backend changes, role changes and Phase 30.

**Client Phase 30 — volunteer registration and real authentication.** Phase 30
adds no migration, dependency or persistent token storage. The backend side is
described in the Phase 30 auth paragraph above.

- `AuthApi.registerVolunteer` posts exactly
  `{ firstName, lastName, phone, role: 'VOLUNTEER' }` to
  `POST /api/auth/register` and parses the normal token response strictly. The
  session role always comes from the backend user profile, never from the local
  role selection.
- `AuthApi.loginVolunteer` posts exactly `{ firstName, lastName, phone }` to
  `POST /api/auth/volunteer/login`. It never creates an account and never calls
  the legacy `/api/auth/volunteer` endpoint. `AuthApi.identifyVolunteer` remains
  only for backward compatibility and is unused by the UI.
- `RegistrationScreen`
  (`app/lib/screens/registration_screen.dart`) collects first name, last name,
  phone and role with the `VOLUNTEER` role preselected. `RESPONSIBLE`/`ADMIN` are
  visible but disabled and explained as administrator-provisioned; the request
  always sends `VOLUNTEER`. Local validation prevents empty or overlong names,
  invalid phones and duplicate submissions. Success accepts the returned session
  and opens the app shell. `PHONE_TAKEN`, `VALIDATION_ERROR`, rate-limit,
  network and `UNEXPECTED_RESPONSE` failures stay on the form in Bulgarian.
- `VolunteerIdentificationScreen` is the passwordless volunteer login screen
  (`Вход за доброволци`) and links to registration. `LoginScreen` is the staff
  (`Служебен вход`) phone + password screen for `RESPONSIBLE`/`ADMIN`.
  `StartScreen` routes `Вход`, `Регистрация` and `Служебен вход` separately.
- `ApiClient` accepts a nullable `onUnauthorized` callback. It fires only for an
  HTTP `401` whose code is `UNAUTHORIZED`, never for `INVALID_CREDENTIALS`,
  swallows callback exceptions and always rethrows the original
  `ApiException`. `main.dart` wires it to
  `SessionController.handleUnauthorized()` behind a mounted check, so an expired
  session is cleared centrally.
- `AuthMessages` adds the volunteer-specific
  `Грешно име, фамилия или телефон.` message and `UNEXPECTED_RESPONSE`; the
  staff default for `INVALID_CREDENTIALS` remains
  `Грешен телефон или парола.`.
- Tests: backend `npm test` passes (448 tests); new/updated backend files are
  `test/auth-register.test.js`, `test/auth-volunteer-login.test.js` and
  `test/auth-rate-limit.test.js`. The Flutter suite passes (357 tests) and
  `flutter analyze` is clean; new/updated client files include
  `test/registration_screen_test.dart`, `test/auth_api_test.dart`,
  `test/api_client_test.dart`, `test/session_controller_test.dart`,
  `test/auth_screens_test.dart` and `test/fakes.dart`.
- Out of scope: staff self-registration, admin-triggered volunteer
  registration, password reset/recovery, persistent client tokens, role changes,
  and storing or faking server registration results.

Notes for agents:

- `JWT_SECRET` must be set to start the API (`npm start`); migration/seed scripts
  do not require it. Tests use a fixed test-only secret via `test/helpers/env.js`.
- Passwordless volunteer login is still identification, not strong
  authentication — name + phone only. Public registration does not make it
  stronger. Do not claim otherwise, and do not add SMS/OTP/PIN.
- Staff passwords are bcrypt hashes only (cost 12). Never return hashes, tokens,
  or `token_version`; never log full phone numbers (use `lib/phone.maskPhone`).
- Location responses expose exactly `{ id, name, address, isActive }`; never
  return `city`, `created_by`, timestamps, or raw rows.
