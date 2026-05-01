-- ============================================================================
-- SponsorBridge — initial schema
-- ============================================================================
-- 13 tables: organizations, users, org_memberships, contacts, programs,
-- students, sponsor_groups, sponsor_group_members, sponsorships,
-- recurring_schedules, payments, ledger_events, audit_logs.
--
-- Multi-tenant via org_id on every domain table; RLS policies below filter
-- by membership using the SECURITY DEFINER helper current_user_org_ids().
-- Service-role writes (audit log inserts, account bootstrap, webhooks)
-- bypass RLS by definition.
-- ============================================================================

create extension if not exists pgcrypto;
create extension if not exists citext;

-- ─── Helper functions ───────────────────────────────────────────────────────

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- Returns the org_ids the current authenticated user is a member of.
-- SECURITY DEFINER so it can read org_memberships without recursing through
-- that table's own RLS policy. search_path locked down per Supabase guidance.
create or replace function public.current_user_org_ids()
returns uuid[] language sql stable security definer
set search_path = public, pg_temp as $$
  select coalesce(array_agg(om.org_id), array[]::uuid[])
  from public.org_memberships om
  join public.users u on u.id = om.user_id
  where u.auth_user_id = auth.uid()
$$;

-- ─── organizations ──────────────────────────────────────────────────────────

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  billing_email citext,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create trigger organizations_set_updated_at
  before update on public.organizations
  for each row execute function public.set_updated_at();

-- ─── users (app profile, mirrors auth.users) ────────────────────────────────

create table public.users (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique references auth.users(id) on delete cascade,
  email citext not null,
  full_name text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index users_email_idx on public.users (email);

create trigger users_set_updated_at
  before update on public.users
  for each row execute function public.set_updated_at();

-- ─── org_memberships ────────────────────────────────────────────────────────

create table public.org_memberships (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  role text not null check (role in ('owner','admin','member','viewer')) default 'member',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, user_id)
);

create index org_memberships_user_idx on public.org_memberships (user_id);

create trigger org_memberships_set_updated_at
  before update on public.org_memberships
  for each row execute function public.set_updated_at();

-- ─── contacts ───────────────────────────────────────────────────────────────
-- Single table for donors and sponsors. Donor vs sponsor is derived from
-- presence in payments / sponsorships, not stored as a flag.

create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  kind text not null check (kind in ('individual','family','organization')) default 'individual',
  display_name text not null,
  primary_email citext,
  primary_phone text,
  address_line1 text,
  address_line2 text,
  city text,
  region text,
  postal_code text,
  country text,
  notes text,
  qbo_customer_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  unique (org_id, qbo_customer_id)
);

create index contacts_org_idx on public.contacts (org_id) where archived_at is null;
create index contacts_email_idx on public.contacts (org_id, primary_email);

create trigger contacts_set_updated_at
  before update on public.contacts
  for each row execute function public.set_updated_at();

-- ─── programs ───────────────────────────────────────────────────────────────
-- Org-defined cohorts that students belong to and that map to QBO classes.

create table public.programs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  description text,
  qbo_class_id text,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, name)
);

create trigger programs_set_updated_at
  before update on public.programs
  for each row execute function public.set_updated_at();

-- ─── students (beneficiaries) ───────────────────────────────────────────────

create table public.students (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  program_id uuid references public.programs(id) on delete set null,
  full_name text not null,
  preferred_name text,
  birth_date date,
  gender text check (gender in ('male','female','nonbinary','unspecified')) default 'unspecified',
  village text,
  photo_url text,
  status text not null check (status in ('active','graduating_hs','higher_ed','alumni','exited')) default 'active',
  notes text,
  enrolled_at date,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index students_org_idx on public.students (org_id) where archived_at is null;
create index students_program_idx on public.students (program_id);

create trigger students_set_updated_at
  before update on public.students
  for each row execute function public.set_updated_at();

-- ─── sponsor_groups ─────────────────────────────────────────────────────────
-- Pure labeling/grouping mechanism. No payer concept — any member donates
-- independently from their own contact record.

create table public.sponsor_groups (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  nickname text not null,
  description text,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index sponsor_groups_org_idx on public.sponsor_groups (org_id) where archived_at is null;

create trigger sponsor_groups_set_updated_at
  before update on public.sponsor_groups
  for each row execute function public.set_updated_at();

-- ─── sponsor_group_members ──────────────────────────────────────────────────

create table public.sponsor_group_members (
  group_id uuid not null references public.sponsor_groups(id) on delete cascade,
  contact_id uuid not null references public.contacts(id) on delete cascade,
  org_id uuid not null references public.organizations(id) on delete cascade,
  role text not null check (role in ('admin','member')) default 'member',
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  primary key (group_id, contact_id)
);

create index sponsor_group_members_contact_idx on public.sponsor_group_members (contact_id);
create index sponsor_group_members_org_idx on public.sponsor_group_members (org_id);

-- ─── sponsorships ───────────────────────────────────────────────────────────
-- The relationship record. Sponsor is either a single contact OR a group
-- (XOR via CHECK). Defines the human relationship; financial behavior lives
-- on recurring_schedules.

create table public.sponsorships (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete restrict,
  sponsor_contact_id uuid references public.contacts(id) on delete restrict,
  sponsor_group_id uuid references public.sponsor_groups(id) on delete restrict,
  start_date date not null,
  end_date date,
  status text not null check (status in ('active','paused','ended')) default 'active',
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sponsorships_sponsor_xor check (
    (sponsor_contact_id is null) <> (sponsor_group_id is null)
  ),
  constraint sponsorships_dates_ordered check (
    end_date is null or end_date >= start_date
  )
);

create index sponsorships_student_idx on public.sponsorships (student_id);
create index sponsorships_contact_idx on public.sponsorships (sponsor_contact_id);
create index sponsorships_group_idx on public.sponsorships (sponsor_group_id);
create index sponsorships_org_active_idx on public.sponsorships (org_id) where status = 'active';

create trigger sponsorships_set_updated_at
  before update on public.sponsorships
  for each row execute function public.set_updated_at();

-- ─── recurring_schedules ────────────────────────────────────────────────────
-- Financial behavior. Always belongs to one contact (the actual payer).
-- sponsorship_id is optional — a schedule can be a pure recurring donation
-- with no sponsorship attached. Income account lives here, not on sponsorship.

create table public.recurring_schedules (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  contact_id uuid not null references public.contacts(id) on delete restrict,
  sponsorship_id uuid references public.sponsorships(id) on delete set null,
  amount numeric(12,2) not null check (amount > 0),
  currency text not null default 'USD',
  frequency text not null check (frequency in ('monthly','quarterly','annually')) default 'monthly',
  income_account_qbo_id text,
  stripe_subscription_id text unique,
  start_date date not null,
  next_run_date date,
  paused_at timestamptz,
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index recurring_schedules_contact_idx on public.recurring_schedules (contact_id);
create index recurring_schedules_sponsorship_idx on public.recurring_schedules (sponsorship_id);
create index recurring_schedules_org_active_idx on public.recurring_schedules (org_id) where ended_at is null;

create trigger recurring_schedules_set_updated_at
  before update on public.recurring_schedules
  for each row execute function public.set_updated_at();

-- ─── payments ───────────────────────────────────────────────────────────────
-- Every transaction. Always belongs to one contact (the payer). Sponsorship
-- and schedule references are optional — pure one-off donations have neither.

-- Hard immutable: original rows are write-once after they leave 'pending'.
-- Refunds and reversals are NEW rows with reverses_payment_id set. The
-- accounting industry standard for ledger entries — historical sums never
-- shift under you, and QBO's own "void & re-issue" pattern lines up cleanly.
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  contact_id uuid not null references public.contacts(id) on delete restrict,
  sponsorship_id uuid references public.sponsorships(id) on delete set null,
  recurring_schedule_id uuid references public.recurring_schedules(id) on delete set null,
  reverses_payment_id uuid references public.payments(id) on delete restrict,
  amount numeric(12,2) not null check (amount > 0),
  currency text not null default 'USD',
  paid_at timestamptz not null,
  income_account_qbo_id text,
  stripe_charge_id text unique,
  status text not null check (status in ('pending','succeeded','failed')) default 'succeeded',
  failure_reason text,
  memo text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index payments_contact_idx on public.payments (contact_id);
create index payments_sponsorship_idx on public.payments (sponsorship_id);
create index payments_schedule_idx on public.payments (recurring_schedule_id);
create index payments_reverses_idx on public.payments (reverses_payment_id);
create index payments_org_paid_at_idx on public.payments (org_id, paid_at desc);

-- Reversal validation: same org, same contact, same currency; original must
-- be succeeded; cumulative reversals can never exceed the original amount.
create or replace function public.payments_validate_reversal()
returns trigger language plpgsql as $$
declare
  orig public.payments%rowtype;
  prior_reversed numeric(12,2);
begin
  if new.reverses_payment_id is null then
    return new;
  end if;

  select * into orig from public.payments where id = new.reverses_payment_id;
  if not found then
    raise exception 'reverses_payment_id % does not exist', new.reverses_payment_id;
  end if;
  if orig.org_id <> new.org_id then
    raise exception 'reversal must belong to the same org as the original payment';
  end if;
  if orig.contact_id <> new.contact_id then
    raise exception 'reversal must belong to the same contact as the original payment';
  end if;
  if orig.currency <> new.currency then
    raise exception 'reversal currency must match the original payment';
  end if;
  if orig.status <> 'succeeded' then
    raise exception 'cannot reverse a payment whose status is %', orig.status;
  end if;
  if orig.reverses_payment_id is not null then
    raise exception 'cannot reverse a reversal — point at the original payment instead';
  end if;

  -- Count every non-failed reversal so two concurrent pendings can't both pass.
  select coalesce(sum(amount), 0) into prior_reversed
  from public.payments
  where reverses_payment_id = new.reverses_payment_id
    and status <> 'failed';

  if prior_reversed + new.amount > orig.amount then
    raise exception 'cumulative reversals (% + %) exceed original payment amount %',
      prior_reversed, new.amount, orig.amount;
  end if;

  return new;
end;
$$;

create trigger payments_validate_reversal_ins
  before insert on public.payments
  for each row execute function public.payments_validate_reversal();

-- Hard immutability enforcement. Allow exactly one transition path:
--   pending → succeeded   (only status, paid_at, stripe_charge_id, memo, updated_at may change)
--   pending → failed      (only status, failure_reason, memo, updated_at may change)
-- Any other UPDATE raises. DELETE is always blocked.
create or replace function public.payments_block_mutation()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'payments are immutable — issue a reversal instead of deleting';
  end if;

  if old.status <> 'pending' then
    raise exception 'payment % is locked (status=%); insert a reversal row instead',
      old.id, old.status;
  end if;

  if new.status not in ('succeeded','failed') then
    raise exception 'pending payments may only transition to succeeded or failed (got %)', new.status;
  end if;

  -- Identity columns are never mutable, even on the pending → terminal hop.
  if  new.org_id                 is distinct from old.org_id
   or new.contact_id             is distinct from old.contact_id
   or new.sponsorship_id         is distinct from old.sponsorship_id
   or new.recurring_schedule_id  is distinct from old.recurring_schedule_id
   or new.reverses_payment_id    is distinct from old.reverses_payment_id
   or new.amount                 is distinct from old.amount
   or new.currency               is distinct from old.currency
   or new.income_account_qbo_id  is distinct from old.income_account_qbo_id
   or new.created_at             is distinct from old.created_at
  then
    raise exception 'attempted to modify an immutable column on payment %', old.id;
  end if;

  new.updated_at = now();
  return new;
end;
$$;

create trigger payments_block_update
  before update on public.payments
  for each row execute function public.payments_block_mutation();

create trigger payments_block_delete
  before delete on public.payments
  for each row execute function public.payments_block_mutation();

-- ─── ledger_events ──────────────────────────────────────────────────────────
-- Outbound sync log. Today routes to QBO/Xero. Year 3 routes inward to
-- native fund accounting. Zero schema migration needed for that switch.

create table public.ledger_events (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  event_type text not null check (event_type in (
    'payment_posted','payment_voided','payment_refunded',
    'customer_synced','class_created',
    'schedule_created','schedule_updated','schedule_cancelled'
  )),
  subject_table text not null,
  subject_id uuid not null,
  destination text not null check (destination in ('qbo','xero','native')) default 'qbo',
  destination_ref text,
  payload jsonb not null default '{}'::jsonb,
  status text not null check (status in ('pending','synced','failed','skipped')) default 'pending',
  error_message text,
  attempted_at timestamptz,
  synced_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index ledger_events_subject_idx on public.ledger_events (subject_table, subject_id);
create index ledger_events_org_status_idx on public.ledger_events (org_id, status);

create trigger ledger_events_set_updated_at
  before update on public.ledger_events
  for each row execute function public.set_updated_at();

-- ─── audit_logs (append-only) ───────────────────────────────────────────────

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid references public.organizations(id) on delete cascade,
  actor_user_id uuid references public.users(id) on delete set null,
  action text not null,
  subject_table text not null,
  subject_id uuid,
  diff jsonb,
  ip_address inet,
  user_agent text,
  created_at timestamptz not null default now()
);

create index audit_logs_org_created_idx on public.audit_logs (org_id, created_at desc);
create index audit_logs_subject_idx on public.audit_logs (subject_table, subject_id);

-- Append-only enforcement. Even a service-role connection cannot quietly
-- rewrite history — UPDATE and DELETE on audit_logs always raise.
create or replace function public.audit_logs_block_mutation()
returns trigger language plpgsql as $$
begin
  raise exception 'audit_logs is append-only — % is not permitted', tg_op;
end;
$$;

create trigger audit_logs_block_update
  before update on public.audit_logs
  for each row execute function public.audit_logs_block_mutation();

create trigger audit_logs_block_delete
  before delete on public.audit_logs
  for each row execute function public.audit_logs_block_mutation();

-- ============================================================================
-- Row-Level Security
-- ============================================================================
-- Enable RLS on every table, then add per-action policies that restrict
-- access by org membership. Service-role connections bypass RLS by
-- definition, so audit/bootstrap/webhook flows work via createAdminClient().
-- ============================================================================

alter table public.organizations         enable row level security;
alter table public.users                 enable row level security;
alter table public.org_memberships       enable row level security;
alter table public.contacts              enable row level security;
alter table public.programs              enable row level security;
alter table public.students              enable row level security;
alter table public.sponsor_groups        enable row level security;
alter table public.sponsor_group_members enable row level security;
alter table public.sponsorships          enable row level security;
alter table public.recurring_schedules   enable row level security;
alter table public.payments              enable row level security;
alter table public.ledger_events         enable row level security;
alter table public.audit_logs            enable row level security;

-- organizations: members read; writes via service role only.
create policy "members read own organizations"
  on public.organizations for select to authenticated
  using (id = any (public.current_user_org_ids()));

-- users: every authenticated user can read + update their own row.
create policy "users read self"
  on public.users for select to authenticated
  using (auth_user_id = auth.uid());

create policy "users update self"
  on public.users for update to authenticated
  using (auth_user_id = auth.uid())
  with check (auth_user_id = auth.uid());

-- org_memberships: see your own row OR any row in your orgs.
create policy "memberships read own"
  on public.org_memberships for select to authenticated
  using (
    user_id in (select id from public.users where auth_user_id = auth.uid())
    or org_id = any (public.current_user_org_ids())
  );

-- Domain tables: full CRUD gated on org membership.
create policy "contacts org access"
  on public.contacts for all to authenticated
  using (org_id = any (public.current_user_org_ids()))
  with check (org_id = any (public.current_user_org_ids()));

create policy "programs org access"
  on public.programs for all to authenticated
  using (org_id = any (public.current_user_org_ids()))
  with check (org_id = any (public.current_user_org_ids()));

create policy "students org access"
  on public.students for all to authenticated
  using (org_id = any (public.current_user_org_ids()))
  with check (org_id = any (public.current_user_org_ids()));

create policy "sponsor_groups org access"
  on public.sponsor_groups for all to authenticated
  using (org_id = any (public.current_user_org_ids()))
  with check (org_id = any (public.current_user_org_ids()));

create policy "sponsor_group_members org access"
  on public.sponsor_group_members for all to authenticated
  using (org_id = any (public.current_user_org_ids()))
  with check (org_id = any (public.current_user_org_ids()));

create policy "sponsorships org access"
  on public.sponsorships for all to authenticated
  using (org_id = any (public.current_user_org_ids()))
  with check (org_id = any (public.current_user_org_ids()));

create policy "recurring_schedules org access"
  on public.recurring_schedules for all to authenticated
  using (org_id = any (public.current_user_org_ids()))
  with check (org_id = any (public.current_user_org_ids()));

create policy "payments org access"
  on public.payments for all to authenticated
  using (org_id = any (public.current_user_org_ids()))
  with check (org_id = any (public.current_user_org_ids()));

-- ledger_events: read for org members; writes only via service role.
create policy "ledger_events org read"
  on public.ledger_events for select to authenticated
  using (org_id = any (public.current_user_org_ids()));

-- audit_logs: read for org members; writes only via service role
-- (createAdminClient() in src/services/audit.ts). No INSERT policy here.
create policy "audit_logs org read"
  on public.audit_logs for select to authenticated
  using (org_id = any (public.current_user_org_ids()));
