# Scripts

One-off + recurring scripts run via `tsx`. Add `"<name>": "tsx scripts/<file>.ts"`
to package.json scripts when you want a stable npm-script alias.

Conventions:
- Use `dotenv` to load `.env.local` at the top of any script that hits Supabase.
- Service-role mutations only ever happen here or inside services/.
- Sentinel-marked test data so you can clean up safely
  (e.g. `__TEST__` company name, `[SEED]` rationale prefix).
