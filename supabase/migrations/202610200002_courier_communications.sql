create table if not exists public.vuppi_courier_messages (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 3 and 90),
  body text not null check (char_length(body) between 3 and 1200),
  priority text not null default 'normal' check (priority in ('normal','important','urgent')),
  target_kind text not null default 'all' check (target_kind in ('all','city','courier')),
  target_value text,
  action_label text,
  action_url text,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((target_kind = 'all' and target_value is null) or (target_kind <> 'all' and nullif(trim(target_value),'') is not null)),
  check (ends_at is null or ends_at > starts_at)
);

create table if not exists public.vuppi_courier_message_reads (
  message_id uuid not null references public.vuppi_courier_messages(id) on delete cascade,
  courier_id uuid not null references auth.users(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (message_id,courier_id)
);

create index if not exists vuppi_courier_messages_active_window_idx
  on public.vuppi_courier_messages(active,starts_at desc,ends_at);
create index if not exists vuppi_courier_messages_target_idx
  on public.vuppi_courier_messages(target_kind,target_value);
create index if not exists vuppi_courier_message_reads_courier_idx
  on public.vuppi_courier_message_reads(courier_id,read_at desc);

alter table public.vuppi_courier_messages enable row level security;
alter table public.vuppi_courier_message_reads enable row level security;

revoke all on public.vuppi_courier_messages from anon, authenticated;
revoke all on public.vuppi_courier_message_reads from anon, authenticated;

comment on table public.vuppi_courier_messages is 'Comunicados operacionais enviados pela central aos entregadores.';
comment on table public.vuppi_courier_message_reads is 'Confirmação idempotente de leitura por entregador.';
