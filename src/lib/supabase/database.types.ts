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
