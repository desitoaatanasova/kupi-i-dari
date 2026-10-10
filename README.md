# Купи и Дари

Charity campaign management platform: Flutter (Web + Android) client, Node.js/Express
REST API, MySQL 8 (hand-written SQL, no ORM).

> **Status: Phase 1 — scaffold & DB foundation.** Only the backend skeleton, the
> database schema/migrations, and a Flutter placeholder app exist. No business
> functionality (auth, shifts, products, quantities, dashboards) is implemented yet.

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

### Environment variables

See `backend/.env.example`. Key values: `PORT`, `DB_HOST`, `DB_PORT`, `DB_NAME`,
`DB_USER`, `DB_PASSWORD`, `JWT_SECRET`, `NODE_ENV`, plus `TZ` (default
`Europe/Sofia`) and CORS/rate-limit settings. `DB_PASSWORD` and `JWT_SECRET` are
never committed.

### Database scripts

| Command                 | Effect                                                        |
| ----------------------- | ------------------------------------------------------------- |
| `npm run migrate`       | Apply pending migrations to `DB_NAME` (checksum-verified)     |
| `npm run db:reset:test` | **Destructive.** Drops/recreates `DB_NAME_TEST` and migrates  |
| `npm run seed:admin`    | Create bootstrap ADMIN if the seed phone does not exist       |

`db:reset:test` refuses to run unless the target database name ends with `_test`.

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
