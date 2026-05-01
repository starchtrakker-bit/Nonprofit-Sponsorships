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
