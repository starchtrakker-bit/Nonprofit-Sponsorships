#!/usr/bin/env bash
#
# setup-new-project.sh — bootstrap a new Codespace project with the same
# conventions used in StarchIQ-platform.
#
# Usage:
#   ./setup-new-project.sh <project-name>
#
# What it sets up:
#   • Next.js 16 (App Router, TypeScript, Tailwind v4, src/, Turbopack)
#   • Supabase: @supabase/ssr + supabase-js + supabase CLI as devDep
#   • Three-client Supabase split (client / server / admin)
#   • Cached getCurrentUser() helper using React's cache()
#   • src/proxy.ts auth gate + MAINTENANCE_MODE skeleton
#   • next.config.ts with Codespaces origins + optimizePackageImports
#   • .vscode/settings.json mirroring this project
#   • .claude/settings.local.json with a starter permission allowlist
#   • CLAUDE.md template with architecture rules + Codespaces gotchas
#   • supabase/ scaffold (migrations dir, config.toml via supabase init)
#   • .env.local.template documenting every required env var
#   • Initial git commit
#
# Run this from the repo's parent directory in a fresh Codespace. It will
# create ./<project-name>/ and initialize everything inside.

set -euo pipefail

PROJECT_NAME="${1:-}"
if [[ -z "$PROJECT_NAME" ]]; then
  echo "usage: $0 <project-name>" >&2
  exit 1
fi
if [[ -e "$PROJECT_NAME" ]]; then
  echo "error: ./$PROJECT_NAME already exists. pick a fresh name." >&2
  exit 1
fi

# ─── Preflight ────────────────────────────────────────────────
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need node
need npm
need git
need npx

NODE_MAJOR="$(node --version | sed 's/^v//; s/\..*//')"
if (( NODE_MAJOR < 20 )); then
  echo "node 20+ required (found v$NODE_MAJOR)" >&2
  exit 1
fi

echo "→ creating Next.js scaffold in ./$PROJECT_NAME"
# Force the latest 16.x release line. --no-eslint keeps the bootstrap
# small; the user re-adds eslint later if they want it.
npx --yes create-next-app@latest "$PROJECT_NAME" \
  --typescript \
  --app \
  --tailwind \
  --src-dir \
  --turbopack \
  --no-eslint \
  --import-alias "@/*" \
  --use-npm \
  --skip-install \
  --no-git

cd "$PROJECT_NAME"

echo "→ installing deps"
npm install \
  @supabase/ssr \
  @supabase/supabase-js \
  @anthropic-ai/sdk \
  resend \
  zod

npm install --save-dev \
  supabase \
  tsx \
  dotenv \
  @types/node

# ─── next.config.ts ───────────────────────────────────────────
cat > next.config.ts <<'EOF'
import type { NextConfig } from 'next'

const nextConfig: NextConfig = {
  // Codespaces: forwarded port URLs change per session, but the suffix
  // is stable. * lets dev work without re-editing per Codespace.
  allowedDevOrigins: ['*.app.github.dev'],
  experimental: {
    serverActions: {
      // Server Actions CSRF check compares Origin to Host. Reverse-proxy
      // setups (Codespaces, Vercel) need to whitelist explicitly.
      allowedOrigins: ['localhost:3000', '*.app.github.dev'],
    },
    // Trims dead exports from libraries used on every page so Turbopack
    // rebuilds and prod server bundles stay tight.
    optimizePackageImports: ['@supabase/ssr', '@supabase/supabase-js'],
  },
}

export default nextConfig
EOF

# ─── .vscode/settings.json ────────────────────────────────────
mkdir -p .vscode
cat > .vscode/settings.json <<'EOF'
{
    "remote.autoForwardPortsFallback": 0
}
EOF

# ─── .claude/settings.local.json ──────────────────────────────
# Starter allowlist for Claude Code's permission system. These are the
# boring read-only / dev-loop commands you don't want to approve every
# time. Add to it as you go.
mkdir -p .claude
cat > .claude/settings.local.json <<'EOF'
{
  "permissions": {
    "allow": [
      "Bash(npm install *)",
      "Bash(npm run *)",
      "Bash(npm list *)",
      "Bash(npx tsc *)",
      "Bash(npx supabase *)",
      "Bash(supabase --version)",
      "Bash(curl -s http://localhost:3000/*)",
      "Bash(curl -s http://localhost:3000/api/*)",
      "Bash(git add *)",
      "Bash(git commit -m *)",
      "Bash(git push *)",
      "Bash(git status *)",
      "Bash(git diff *)",
      "Bash(git log *)",
      "Bash(pkill -f \"next dev\")",
      "Read(//workspaces/**)",
      "Read(//tmp/**)",
      "WebFetch(domain:supabase.com)",
      "WebFetch(domain:nextjs.org)",
      "WebSearch"
    ]
  }
}
EOF

# ─── .gitignore additions ─────────────────────────────────────
cat >> .gitignore <<'EOF'

# Project-specific
.env.local
supabase/.temp/
supabase/.branches/

# Claude Code local state
.claude/projects/
**/transcript.vtt
EOF

# ─── .env.local.template ──────────────────────────────────────
cat > .env.local.template <<'EOF'
# Copy to .env.local — never commit .env.local

# ── Supabase ────────────────────────────────────────────────
NEXT_PUBLIC_SUPABASE_URL=
NEXT_PUBLIC_SUPABASE_ANON_KEY=
SUPABASE_SERVICE_ROLE_KEY=

# ── App URL ─────────────────────────────────────────────────
# Codespaces: must be your public forwarded URL, not localhost,
# or email-verification + OAuth callbacks break for anyone not
# on your local machine. In prod, your real domain.
NEXT_PUBLIC_APP_URL=

# ── AI / Email / Bot protection (uncomment as needed) ───────
# ANTHROPIC_API_KEY=
# RESEND_API_KEY=
# RESEND_FROM_EMAIL=
# NEXT_PUBLIC_TURNSTILE_SITE_KEY=
# TURNSTILE_SECRET_KEY=

# ── Maintenance mode ────────────────────────────────────────
# Set to true (or 1) to drop a 503 page in front of every route
# except /api/health. Useful during rough deploys.
# MAINTENANCE_MODE=
EOF

# ─── src/lib/supabase/client.ts ───────────────────────────────
mkdir -p src/lib/supabase
cat > src/lib/supabase/client.ts <<'EOF'
import { createBrowserClient } from '@supabase/ssr'
import type { Database } from './database.types'

// Browser client — respects RLS. Use in Client Components only.
export function createClient() {
  return createBrowserClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
  )
}
EOF

# ─── src/lib/supabase/server.ts ───────────────────────────────
cat > src/lib/supabase/server.ts <<'EOF'
import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'
import type { Database } from './database.types'

// Server client — async (uses awaited cookies()). Respects RLS.
// Use in Server Components, Route Handlers, and Server Actions.
export async function createClient() {
  const cookieStore = await cookies()

  return createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll()
        },
        setAll(cookiesToSet) {
          try {
            cookiesToSet.forEach(({ name, value, options }) =>
              cookieStore.set(name, value, options)
            )
          } catch {
            // Server Components cannot set cookies; the proxy handles
            // session refresh.
          }
        },
      },
    }
  )
}
EOF

# ─── src/lib/supabase/admin.ts ────────────────────────────────
cat > src/lib/supabase/admin.ts <<'EOF'
import { createClient as createSupabaseClient } from '@supabase/supabase-js'
import type { Database } from './database.types'

// Service-role client — bypasses RLS. Use ONLY in the service layer for
// audit log writes, account bootstrap, webhooks, and other system ops.
// NEVER expose to the browser.
export function createAdminClient() {
  return createSupabaseClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
      },
    }
  )
}
EOF

# ─── src/lib/supabase/database.types.ts placeholder ───────────
cat > src/lib/supabase/database.types.ts <<'EOF'
// Regenerate after every schema change:
//   npx supabase gen types typescript \
//     --project-id <your-project-id> \
//     --schema public \
//     > src/lib/supabase/database.types.ts
//
// Until you push your first migration, this stays as the empty stub
// below so TypeScript imports don't break.

export type Database = {
  public: {
    Tables: Record<string, never>
    Views: Record<string, never>
    Functions: Record<string, never>
    Enums: Record<string, never>
    CompositeTypes: Record<string, never>
  }
}
EOF

# ─── src/lib/auth.ts ──────────────────────────────────────────
cat > src/lib/auth.ts <<'EOF'
import { cache } from 'react'
import { createClient } from '@/lib/supabase/server'

// React's cache() dedupes calls within a single server render pass.
// Layouts + pages both invoke this; the second call returns the first
// call's Promise instead of re-running auth + the users-row lookup.
//
// If your `users` table has a different shape, adjust the .select() to
// match the columns you actually need across pages.
export const getCurrentUser = cache(async () => {
  const supabase = await createClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()

  if (!user) {
    return { supabase, user: null, userRecord: null as null }
  }

  // TODO: adjust columns to match your users table schema
  const { data: userRecord } = await supabase
    .from('users')
    .select('*')
    .eq('auth_user_id', user.id)
    .single()

  return { supabase, user, userRecord }
})
EOF

# ─── src/proxy.ts ─────────────────────────────────────────────
cat > src/proxy.ts <<'EOF'
import { NextRequest, NextResponse } from 'next/server'
import { createServerClient } from '@supabase/ssr'

// Next.js 16 uses src/proxy.ts (not middleware.ts).
//
// This file: short-circuits to a maintenance page when MAINTENANCE_MODE
// is set, then runs an auth gate that redirects unauthenticated users to
// /auth/login (preserving the destination via ?next=).
//
// Heavy work belongs in layouts/pages — keep this fast.

const MAINTENANCE = process.env.MAINTENANCE_MODE === 'true' || process.env.MAINTENANCE_MODE === '1'

const PUBLIC_ROUTES = ['/', '/api/health', '/auth']

export async function proxy(request: NextRequest) {
  const { pathname } = request.nextUrl

  // Maintenance short-circuit — runs before any DB call.
  if (MAINTENANCE && pathname !== '/api/health') {
    return new NextResponse(
      '<!DOCTYPE html><html><body><h1>Offline for maintenance</h1></body></html>',
      { status: 503, headers: { 'content-type': 'text/html' } }
    )
  }

  // Public routes need no auth check.
  if (PUBLIC_ROUTES.some(p => pathname === p || pathname.startsWith(p + '/'))) {
    return NextResponse.next()
  }

  // Authenticated routes — verify session.
  const response = NextResponse.next()
  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll: (cookiesToSet) => {
          cookiesToSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options)
          )
        },
      },
    }
  )

  const { data: { user } } = await supabase.auth.getUser()
  if (!user) {
    const url = request.nextUrl.clone()
    url.pathname = '/auth/login'
    url.searchParams.set('next', pathname)
    return NextResponse.redirect(url)
  }

  return response
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'],
}
EOF

# ─── src/app/api/health/route.ts ──────────────────────────────
mkdir -p src/app/api/health
cat > src/app/api/health/route.ts <<'EOF'
import { NextResponse } from 'next/server'

// Public liveness check. Stays reachable even when MAINTENANCE_MODE is on.
export async function GET() {
  return NextResponse.json({ status: 'ok', ts: new Date().toISOString() })
}
EOF

# ─── src/services/.gitkeep + README ───────────────────────────
mkdir -p src/services
cat > src/services/README.md <<'EOF'
# Services

All business logic lives here. Route handlers, server actions, and UI
components are thin wrappers that call services.

Pattern for every method:

    validate → execute → audit

Never put business logic directly in route handlers, server actions, or
UI components.
EOF

# ─── supabase/migrations/.gitkeep ─────────────────────────────
mkdir -p supabase/migrations
touch supabase/migrations/.gitkeep

# ─── scripts/ placeholder ─────────────────────────────────────
mkdir -p scripts
cat > scripts/README.md <<'EOF'
# Scripts

One-off + recurring scripts run via `tsx`. Add `"<name>": "tsx scripts/<file>.ts"`
to package.json scripts when you want a stable npm-script alias.

Conventions:
- Use `dotenv` to load `.env.local` at the top of any script that hits Supabase.
- Service-role mutations only ever happen here or inside services/.
- Sentinel-marked test data so you can clean up safely
  (e.g. `__TEST__` company name, `[SEED]` rationale prefix).
EOF

# ─── CLAUDE.md template ───────────────────────────────────────
cat > CLAUDE.md <<EOF
# $PROJECT_NAME — Claude Code Session Context

> **⚠ READ FIRST:** Next.js 16.x with breaking changes from 15. Before
> writing Next.js code, read the relevant guide in
> \`node_modules/next/dist/docs/\`. Key differences: \`proxy.ts\` (not
> \`middleware.ts\`), async \`cookies()\`, Server Actions CSRF via
> \`experimental.serverActions.allowedOrigins\`.

## Project Overview

TODO: 1-2 paragraphs — what this product is, who uses it, what phase it's in.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Framework | Next.js 16.x (Turbopack), React 19 |
| Styling | Tailwind CSS v4 (CSS-native config, no \`tailwind.config.ts\`) |
| Language | TypeScript |
| Database | Supabase (PostgreSQL) |
| Auth | Supabase Auth (PKCE via \`@supabase/ssr\`) |
| Hosting | Vercel |

---

## Environment Variables

See \`.env.local.template\`. Required to develop:

\`\`\`
NEXT_PUBLIC_SUPABASE_URL=
NEXT_PUBLIC_SUPABASE_ANON_KEY=
SUPABASE_SERVICE_ROLE_KEY=
NEXT_PUBLIC_APP_URL=    # Codespaces: public URL, not localhost
\`\`\`

---

## Dev Environment — Codespaces Specifics

1. **Port visibility:** Ports tab → right-click 3000 → Port Visibility → Public.
2. **next.config.ts:** \`allowedDevOrigins\` + \`experimental.serverActions.allowedOrigins\`
   are already set for \`*.app.github.dev\`.
3. **Supabase Dashboard → Authentication → URL Configuration:**
   - Site URL: your public Codespaces URL
   - Redirect URLs: add \`https://<codespace>-3000.app.github.dev/**\` and \`http://localhost:3000/**\`
4. **Always browse via the public Codespaces URL** — auth cookies + the verification
   email links must agree on the same domain or PKCE exchange fails.
5. **Codespace restarts** change the URL hostname. Update \`NEXT_PUBLIC_APP_URL\`
   and the Supabase Site URL each time.

---

## Architecture Rules — Never Violate These

### 1. Service Layer Pattern
All business logic lives in \`src/services/\`. Route handlers, server actions, and
UI components are thin wrappers. Pattern: validate → execute → audit.

### 2. Three Supabase Clients
- \`createClient()\` from \`src/lib/supabase/client.ts\` — browser, respects RLS
- \`createClient()\` from \`src/lib/supabase/server.ts\` — server (async), respects RLS
- \`createAdminClient()\` from \`src/lib/supabase/admin.ts\` — service role, bypasses
  RLS. Use ONLY in services for: audit log writes, account bootstrap, webhooks.
  NEVER expose to the browser.

### 3. Account Isolation (RLS)
Every domain query filters by an account scope. RLS enforces it at the database
level; the service layer enforces it again. Never trust client-supplied account ids.

### 4. Use the Cached User Helper
\`getCurrentUser()\` from \`src/lib/auth.ts\` wraps React's \`cache()\`. Use it in
layouts and pages instead of re-running \`auth.getUser()\` + the users lookup.

### 5. Migrations Only
Schema changes go through \`supabase/migrations/\`. Never edit the database
directly in the dashboard.

\`\`\`bash
npx supabase migration new <descriptive_name>
npx supabase db push --linked
npx supabase gen types typescript --project-id <id> --schema public \\
  > src/lib/supabase/database.types.ts
\`\`\`

---

## Next.js 16 Conventions

- **\`src/proxy.ts\`** not \`middleware.ts\`. Export named \`proxy\` (or default).
- **\`cookies()\`** from \`next/headers\` must be \`await\`ed.
- **Server Actions** use \`'use server'\`. POST-only with CSRF check on Origin/Host.
- **\`redirect()\`** from \`next/navigation\` throws a control-flow exception —
  code after it doesn't run.
- **Don't pair \`revalidatePath()\` with \`redirect()\`** to a dynamic page —
  the redirect already triggers a fresh server render.

---

## Performance Conventions

- Run independent reads through \`Promise.all\`, never sequential \`await\` chains.
- Use \`<Link>\` not \`<a>\` for internal navigation (RSC streaming, no full reload).
- For history / large-list pagination, prefer \`count: 'estimated'\` over \`'exact'\`.
- Lazy-import heavy server-only deps (e.g. ExcelJS) inside the function that
  actually needs them, not at module top-level.
- Stream large exports via \`ReadableStream\` instead of buffering in memory.
- React's \`cache()\` dedupes inside a single render — wrap any helper that
  layouts + pages both call.

---

## Git Conventions

\`\`\`
feat: add X
fix: correct Y
chore: update Z
db: add migration for W
perf: optimize Q
\`\`\`
EOF

# ─── Supabase init ────────────────────────────────────────────
echo "→ initializing supabase scaffold"
npx --yes supabase init --force >/dev/null 2>&1 || true

# ─── Copy .env template into place (commented) ────────────────
cp .env.local.template .env.local

# ─── Initial git commit ───────────────────────────────────────
echo "→ git init + initial commit"
git init -q
git add .
git -c user.email="bootstrap@local" -c user.name="bootstrap" \
  commit -q -m "scaffold: bootstrap Next.js 16 + Supabase project from setup-new-project.sh"

echo
echo "✓ ./$PROJECT_NAME ready"
echo
echo "Next steps:"
echo "  1) cd $PROJECT_NAME"
echo "  2) Edit .env.local — fill in your Supabase URL + keys"
echo "  3) npx supabase link --project-ref <your-ref>"
echo "  4) Make your first migration:"
echo "       npx supabase migration new initial_schema"
echo "  5) After pushing migrations:"
echo "       npx supabase gen types typescript --project-id <ref> \\"
echo "         --schema public > src/lib/supabase/database.types.ts"
echo "  6) npm run dev — and remember to make port 3000 public"
echo
echo "Edit CLAUDE.md to fill in the project-specific bits before your"
echo "first real Claude Code session in this repo."
