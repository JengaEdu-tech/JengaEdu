-- JengaEdu SMS OTP password recovery
create table if not exists public.jenga_password_reset_otps (
  email text primary key,
  phone text not null,
  code_hash text not null,
  expires_at timestamptz not null,
  attempts integer not null default 0,
  verified_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.jenga_password_reset_otps enable row level security;
-- No client policies: this table is only accessed by the password-recovery Edge Function.
