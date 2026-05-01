# Nonprofit-Sponsorships — Claude Code Session Context

> **⚠ READ FIRST:** Next.js 16.x with breaking changes from 15. Before
> writing Next.js code, read the relevant guide in
> `node_modules/next/dist/docs/`. Key differences: `proxy.ts` (not
> `middleware.ts`), async `cookies()`, Server Actions CSRF via
> `experimental.serverActions.allowedOrigins`.

## Project Overview

**SponsorBridge** is a B2B SaaS platform for mid-size nonprofits ($1M–$10M
budget) running formal child-sponsorship programs. Multi-tenant via Supabase
RLS on `org_id`. Flagship feature is **bookkeeper-configured QuickBooks Online
sync** — every competitor leaves this developer-only. Pre-revenue, solo-founder
build (founder is an active volunteer at a target-customer org — that org is
"customer zero" and the lived workflow is the primary product spec).

Canonical product spec lives in `sponsorbridge-bundle.html` — see the embedded
`docs/sponsorbridge-session1-summary.md` (search for "Session 1 Summary").
The bundle's React prototype is the look-and-feel reference, **not** the data
model — the data model is the 13-table canonical schema in
`supabase/migrations/20260501040013_initial_schema.sql`.

---

## ▶ Backend Setup — Start Here Next Session

**Resume point:** the migration file is written and ready. Push it first.

### Phase 1 — Supabase project + credentials *(done)*
- [x] Supabase cloud project created — project-ref `dhzbmnnhyxkdxclfruhc`
- [x] `.env.local` populated with URL, anon key, service-role key, `NEXT_PUBLIC_APP_URL`
- [x] Auth URL Configuration set in Supabase dashboard
- [x] CLI linked (`supabase/.temp/project-ref` confirms)

### Phase 2 — Schema + migrations *(in progress — push next)*
- [x] Schema designed — 13 tables with sponsor groups (see memory `project_sponsorship_cardinality.md`)
- [x] Migration written → `supabase/migrations/20260501040013_initial_schema.sql` (~535 lines, full RLS, payments hard-immutability, audit_logs append-only)
- [ ] **▶ NEXT: `npx supabase db push --linked`**
- [ ] Regenerate types: `npx supabase gen types typescript --project-id dhzbmnnhyxkdxclfruhc --schema public > src/lib/supabase/database.types.ts`

### Phase 3 — App wiring
- [ ] Update `getCurrentUser()` in `src/lib/auth.ts` to match the real `users` table columns
- [ ] Build auth pages under `src/app/auth/` (login, signup, callback, logout) + signup → `users` + `org_memberships` bootstrap service
- [ ] Scaffold service layer in `src/services/` (validate → execute → audit) for contacts, students, sponsorships, sponsor_groups, payments, recurring_schedules
- [ ] Add `audit_logs` writer in `src/services/audit.ts` using the admin client (note: audit_logs is trigger-enforced append-only — no updates/deletes possible)
- [ ] Service-layer pattern for refunds: insert a new `payments` row with `reverses_payment_id` set (the original is immutable after status leaves `pending`)
- [ ] Wire Resend for transactional emails; add `RESEND_API_KEY` / `RESEND_FROM_EMAIL` to `.env.local`
- [ ] Verify `/api/health` and the `proxy.ts` auth gate against `PUBLIC_ROUTES`

### Phase 4 — Cleanup
- [ ] Prune any unused deps from the scaffold (`@anthropic-ai/sdk`, `resend`) if not used
- [ ] Address `npm audit` findings before first deploy
- [ ] Initial commit covering the scaffold + migration

### Schema design decisions baked into the migration
- **13 tables**: `organizations`, `users`, `org_memberships`, `contacts`, `programs`, `students`, `sponsor_groups`, `sponsor_group_members`, `sponsorships`, `recurring_schedules`, `payments`, `ledger_events`, `audit_logs`.
- **Sponsorships** can be attributed to a single contact OR a `sponsor_group` (XOR via CHECK). Sponsor groups are pure labels with a nickname — no payer concept; any group member can donate independently from their own contact record.
- **Payments are hard-immutable**: rows are write-once after status leaves `pending`. Refunds/voids are NEW rows with `reverses_payment_id` set. Trigger blocks all UPDATE/DELETE that violates this.
- **Audit logs are trigger-enforced append-only** — even the service role cannot rewrite history.
- **RLS** uses `public.current_user_org_ids()` (SECURITY DEFINER, locked search_path) to avoid recursion through `org_memberships`. Pattern: `org_id = ANY (public.current_user_org_ids())`.
- **Donor vs sponsor** is derived (EXISTS subqueries against payments/sponsorships), not a stored flag — same person can wear both roles or neither.

### Known scaffold gotchas
- `src/lib/supabase/database.types.ts` is the empty stub — every Supabase call is loosely typed until the migration is pushed and types are regenerated.
- The scaffold + migration are uncommitted; the existing repo `.git` is intact and ready for a single bootstrap commit.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Framework | Next.js 16.x (Turbopack), React 19 |
| Styling | Tailwind CSS v4 (CSS-native config, no `tailwind.config.ts`) |
| Language | TypeScript |
| Database | Supabase (PostgreSQL) |
| Auth | Supabase Auth (PKCE via `@supabase/ssr`) |
| Hosting | Vercel |

---

## Environment Variables

See `.env.local.template`. Required to develop:

```
NEXT_PUBLIC_SUPABASE_URL=
NEXT_PUBLIC_SUPABASE_ANON_KEY=
SUPABASE_SERVICE_ROLE_KEY=
NEXT_PUBLIC_APP_URL=    # Codespaces: public URL, not localhost
```

---

## Dev Environment — Codespaces Specifics

1. **Port visibility:** Ports tab → right-click 3000 → Port Visibility → Public.
2. **next.config.ts:** `allowedDevOrigins` + `experimental.serverActions.allowedOrigins`
   are already set for `*.app.github.dev`.
3. **Supabase Dashboard → Authentication → URL Configuration:**
   - Site URL: your public Codespaces URL
   - Redirect URLs: add `https://<codespace>-3000.app.github.dev/**` and `http://localhost:3000/**`
4. **Always browse via the public Codespaces URL** — auth cookies + the verification
   email links must agree on the same domain or PKCE exchange fails.
5. **Codespace restarts** change the URL hostname. Update `NEXT_PUBLIC_APP_URL`
   and the Supabase Site URL each time.

---

## Architecture Rules — Never Violate These

### 1. Service Layer Pattern
All business logic lives in `src/services/`. Route handlers, server actions, and
UI components are thin wrappers. Pattern: validate → execute → audit.

### 2. Three Supabase Clients
- `createClient()` from `src/lib/supabase/client.ts` — browser, respects RLS
- `createClient()` from `src/lib/supabase/server.ts` — server (async), respects RLS
- `createAdminClient()` from `src/lib/supabase/admin.ts` — service role, bypasses
  RLS. Use ONLY in services for: audit log writes, account bootstrap, webhooks.
  NEVER expose to the browser.

### 3. Account Isolation (RLS)
Every domain query filters by an account scope. RLS enforces it at the database
level; the service layer enforces it again. Never trust client-supplied account ids.

### 4. Use the Cached User Helper
`getCurrentUser()` from `src/lib/auth.ts` wraps React's `cache()`. Use it in
layouts and pages instead of re-running `auth.getUser()` + the users lookup.

### 5. Migrations Only
Schema changes go through `supabase/migrations/`. Never edit the database
directly in the dashboard.

```bash
npx supabase migration new <descriptive_name>
npx supabase db push --linked
npx supabase gen types typescript --project-id <id> --schema public \
  > src/lib/supabase/database.types.ts
```

---

## Next.js 16 Conventions

- **`src/proxy.ts`** not `middleware.ts`. Export named `proxy` (or default).
- **`cookies()`** from `next/headers` must be `await`ed.
- **Server Actions** use `'use server'`. POST-only with CSRF check on Origin/Host.
- **`redirect()`** from `next/navigation` throws a control-flow exception —
  code after it doesn't run.
- **Don't pair `revalidatePath()` with `redirect()`** to a dynamic page —
  the redirect already triggers a fresh server render.

---

## Performance Conventions

- Run independent reads through `Promise.all`, never sequential `await` chains.
- Use `<Link>` not `<a>` for internal navigation (RSC streaming, no full reload).
- For history / large-list pagination, prefer `count: 'estimated'` over `'exact'`.
- Lazy-import heavy server-only deps (e.g. ExcelJS) inside the function that
  actually needs them, not at module top-level.
- Stream large exports via `ReadableStream` instead of buffering in memory.
- React's `cache()` dedupes inside a single render — wrap any helper that
  layouts + pages both call.

---

## Git Conventions

```
feat: add X
fix: correct Y
chore: update Z
db: add migration for W
perf: optimize Q
```
