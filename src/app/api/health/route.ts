import { NextResponse } from 'next/server'

// Public liveness check. Stays reachable even when MAINTENANCE_MODE is on.
export async function GET() {
  return NextResponse.json({ status: 'ok', ts: new Date().toISOString() })
}
