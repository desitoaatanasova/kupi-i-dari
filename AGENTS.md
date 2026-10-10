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

**Phase 1 — scaffold & DB foundation.** No auth, CRUD, shifts, products,
quantities, uploads, or dashboards are implemented. `GET /api/health` is the
only endpoint.
