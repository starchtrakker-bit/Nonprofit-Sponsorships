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
