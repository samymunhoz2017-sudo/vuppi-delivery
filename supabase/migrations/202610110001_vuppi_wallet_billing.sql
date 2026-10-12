-- Vuppi Wallet: billing mensal, isencoes e revisao de saques.
-- Incremental: reutiliza vuppi_wallets, vuppi_wallet_accounts,
-- vuppi_financial_transactions, vuppi_ledger_entries e vuppi_post_transaction.
begin;

alter table public.vuppi_finance_settings
 add column if not exists merchant_monthly_fee_cents bigint not null default 2990 check(merchant_monthly_fee_cents>0),
 add column if not exists merchant_monthly_billing boolean not null default false,
 add column if not exists mass_billing_exemptions boolean not null default false,
 add column if not exists withdrawal_risk_review boolean not null default true,
 add column if not exists billing_grace_period_days integer not null default 5 check(billing_grace_period_days between 0 and 90),
 add column if not exists billing_enforcement_mode text not null default 'warn' check(billing_enforcement_mode in ('warn','block_after_grace')),
 add column if not exists overdue_in_topup_mode text not null default 'all' check(overdue_in_topup_mode in ('all','oldest','none')),
 add column if not exists withdrawal_review_threshold_cents bigint check(withdrawal_review_threshold_cents>0),
 add column if not exists withdrawal_dual_approval_threshold_cents bigint check(withdrawal_dual_approval_threshold_cents>0),
 add column if not exists manual_operation_limit_cents bigint not null default 100000 check(manual_operation_limit_cents>0),
 add column if not exists billing_timezone text not null default 'America/Sao_Paulo';

alter table public.vuppi_topups
 add column if not exists subscription_debt_cents bigint not null default 0 check(subscription_debt_cents>=0);

alter table public.vuppi_withdrawals
 add column if not exists risk_score integer not null default 0 check(risk_score between 0 and 100),
 add column if not exists risk_reasons jsonb not null default '[]'::jsonb,
 add column if not exists first_approved_by uuid references auth.users(id),
 add column if not exists first_approved_at timestamptz,
 add column if not exists second_approved_by uuid references auth.users(id),
 add column if not exists second_approved_at timestamptz;

create table if not exists public.vuppi_finance_permissions(
 user_id uuid not null references auth.users(id) on delete cascade,
 city text not null references public.up_cidades(id),
 permission text not null check(permission in(
  'wallet.view','wallet.view_own','wallet.manual_credit','wallet.manual_debit','wallet.manual_payout','wallet.reversal','wallet.audit',
  'billing.view','billing.configure','billing.exemption.create','billing.exemption.mass','billing.exemption.revoke',
  'withdrawal.review','withdrawal.approve','withdrawal.dual_approve','financial.reconciliation','financial.settings')),
 granted_by uuid references auth.users(id),created_at timestamptz not null default now(),
 primary key(user_id,city,permission)
);

create table if not exists public.vuppi_store_billing_profiles(
 merchant_id uuid primary key references public.vuppi_members(user_id) on delete restrict,
 city text not null references public.up_cidades(id),
 status text not null default 'active' check(status in('active','exempt','past_due','suspended','cancelled')),
 monthly_fee_cents bigint not null default 2990 check(monthly_fee_cents>0),
 billing_anchor_at date not null,
 next_billing_at timestamptz not null,
 grace_period_days integer not null default 5 check(grace_period_days between 0 and 90),
 enforcement_mode text not null default 'warn' check(enforcement_mode in('warn','block_after_grace')),
 created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);

create table if not exists public.vuppi_billing_exemptions(
 id uuid primary key default gen_random_uuid(),merchant_id uuid not null references public.vuppi_members(user_id) on delete restrict,
 city text not null references public.up_cidades(id),
 type text not null check(type in('free_trial','commercial_waiver','retention','promotional','manual','mass_waiver')),
 starts_at timestamptz not null,ends_at timestamptz not null check(ends_at>starts_at),reason text not null check(length(trim(reason))>=3),notes text,
 created_by uuid not null references auth.users(id),approved_by uuid references auth.users(id),created_at timestamptz not null default now(),
 revoked_at timestamptz,revoked_by uuid references auth.users(id),metadata jsonb not null default '{}'::jsonb,
 idempotency_key text not null unique
);

create table if not exists public.vuppi_subscription_invoices(
 id uuid primary key default gen_random_uuid(),merchant_id uuid not null references public.vuppi_members(user_id) on delete restrict,
 city text not null references public.up_cidades(id),billing_period_start date not null,billing_period_end date not null,
 due_at timestamptz not null,amount_cents bigint not null check(amount_cents>0),
 status text not null default 'open' check(status in('open','paid','waived','overdue','cancelled')),
 paid_at timestamptz,waived_at timestamptz,wallet_transaction_id uuid references public.vuppi_financial_transactions(id),
 external_payment_id text,billing_exemption_id uuid references public.vuppi_billing_exemptions(id),
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 unique(merchant_id,billing_period_start)
);

create table if not exists public.vuppi_billing_runs(
 id uuid primary key default gen_random_uuid(),city text not null references public.up_cidades(id),run_key text not null,
 dry_run boolean not null default true,status text not null default 'running' check(status in('running','completed','partial','failed')),
 started_at timestamptz not null default now(),completed_at timestamptz,stores_processed integer not null default 0,
 paid integer not null default 0,waived integer not null default 0,past_due integer not null default 0,failed integer not null default 0,
 total_amount_cents bigint not null default 0,details jsonb not null default '{}'::jsonb,created_by uuid references auth.users(id),
 unique(city,run_key,dry_run)
);

create table if not exists public.vuppi_billing_run_items(
 id uuid primary key default gen_random_uuid(),run_id uuid not null references public.vuppi_billing_runs(id) on delete restrict,
 merchant_id uuid not null references public.vuppi_members(user_id) on delete restrict,invoice_id uuid references public.vuppi_subscription_invoices(id),
 outcome text not null check(outcome in('would_pay','would_waive','would_overdue','paid','waived','overdue','skipped','failed')),
 amount_cents bigint not null default 0,error_code text,created_at timestamptz not null default now(),unique(run_id,merchant_id)
);

create table if not exists public.vuppi_payment_allocations(
 id uuid primary key default gen_random_uuid(),topup_id uuid not null references public.vuppi_topups(id) on delete restrict,
 allocation_type text not null check(allocation_type in('wallet_recharge','subscription_fee')),
 invoice_id uuid references public.vuppi_subscription_invoices(id),amount_cents bigint not null check(amount_cents>0),
 status text not null default 'pending' check(status in('pending','posted','reversed')),
 transaction_id uuid references public.vuppi_financial_transactions(id),created_at timestamptz not null default now(),posted_at timestamptz,
 unique(topup_id,allocation_type,invoice_id)
);

create table if not exists public.vuppi_finance_security_events(
 id bigint generated always as identity primary key,actor_id uuid references auth.users(id),city text,event_type text not null,
 severity text not null check(severity in('info','warning','critical')),target_type text,target_id text,correlation_id text,
 details jsonb not null default '{}'::jsonb,created_at timestamptz not null default now()
);

create index if not exists vuppi_invoice_status_due_idx on public.vuppi_subscription_invoices(city,status,due_at);
create index if not exists vuppi_exemption_active_idx on public.vuppi_billing_exemptions(merchant_id,starts_at,ends_at) where revoked_at is null;
create index if not exists vuppi_billing_profile_next_idx on public.vuppi_store_billing_profiles(city,next_billing_at) where status<>'cancelled';
create index if not exists vuppi_security_event_idx on public.vuppi_finance_security_events(city,created_at desc);

alter table public.vuppi_finance_permissions enable row level security;
alter table public.vuppi_store_billing_profiles enable row level security;
alter table public.vuppi_billing_exemptions enable row level security;
alter table public.vuppi_subscription_invoices enable row level security;
alter table public.vuppi_billing_runs enable row level security;
alter table public.vuppi_billing_run_items enable row level security;
alter table public.vuppi_payment_allocations enable row level security;
alter table public.vuppi_finance_security_events enable row level security;
revoke all on public.vuppi_finance_permissions,public.vuppi_store_billing_profiles,public.vuppi_billing_exemptions,
 public.vuppi_subscription_invoices,public.vuppi_billing_runs,public.vuppi_billing_run_items,
 public.vuppi_payment_allocations,public.vuppi_finance_security_events from anon,authenticated;

create or replace function public.vuppi_finance_allowed(p_permission text,p_city text) returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
 select coalesce((auth.jwt()->>'role')='service_role',false) or public.up_platform_is_admin() or exists(
  select 1 from public.vuppi_finance_permissions where user_id=auth.uid() and city=p_city and permission=p_permission
 )
$$;

create or replace function public.vuppi_finance_step_up() returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
 select coalesce((auth.jwt()->>'role')='service_role',false) or coalesce((auth.jwt()->>'aal')='aal2',false)
$$;

create or replace function public.vuppi_billing_next(p_anchor date,p_after date) returns date
language sql immutable as $$
 select (date_trunc('month',p_after::timestamp)+interval '1 month'+(least(extract(day from p_anchor)::int,
 extract(day from (date_trunc('month',p_after::timestamp)+interval '2 month - 1 day'))::int)-1)*interval '1 day')::date
$$;

create or replace function public.vuppi_billing_profile_ensure(p_merchant uuid) returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare m public.vuppi_members;cfg public.vuppi_finance_settings;anchor date;
begin
 select * into m from public.vuppi_members where user_id=p_merchant and kind='merchant';
 if m.user_id is null then raise exception 'VUPPI_FINANCE: Estabelecimento inválido.';end if;
 insert into public.vuppi_finance_settings(city) values(m.city) on conflict do nothing;
 select * into cfg from public.vuppi_finance_settings where city=m.city;anchor:=coalesce(m.created_at::date,current_date);
 insert into public.vuppi_store_billing_profiles(merchant_id,city,monthly_fee_cents,billing_anchor_at,next_billing_at,grace_period_days,enforcement_mode)
 values(m.user_id,m.city,cfg.merchant_monthly_fee_cents,anchor,(anchor+interval '1 month')::timestamptz,cfg.billing_grace_period_days,cfg.billing_enforcement_mode)
 on conflict(merchant_id) do nothing;return m.user_id;
end;$$;

create or replace function public.vuppi_active_billing_exemption(p_merchant uuid,p_at timestamptz default now()) returns uuid
language sql stable security definer set search_path=public,pg_temp as $$
 select id from public.vuppi_billing_exemptions where merchant_id=p_merchant and revoked_at is null and starts_at<=p_at and ends_at>p_at order by ends_at desc limit 1
$$;

create or replace function public.vuppi_billing_run_execute(p_city text,p_dry_run boolean default true,p_run_key text default null) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid();cfg public.vuppi_finance_settings;r public.vuppi_billing_runs;p public.vuppi_store_billing_profiles;
 inv public.vuppi_subscription_invoices;ex uuid;mw uuid;pw uuid;available bigint;outcome text;tx uuid;period_start date;period_end date;
begin
 if not public.vuppi_finance_allowed('billing.configure',p_city) then raise exception 'VUPPI_FINANCE: Permissão de billing necessária.';end if;
 if not p_dry_run and not public.vuppi_finance_step_up() then raise exception 'VUPPI_FINANCE: Autenticação reforçada necessária.';end if;
 insert into public.vuppi_finance_settings(city) values(p_city) on conflict do nothing;select * into cfg from public.vuppi_finance_settings where city=p_city;
 if not p_dry_run and not cfg.merchant_monthly_billing then raise exception 'VUPPI_FINANCE: Billing real permanece desativado.';end if;
 insert into public.vuppi_billing_runs(city,run_key,dry_run,created_by) values(p_city,coalesce(nullif(p_run_key,''),to_char(now() at time zone cfg.billing_timezone,'YYYY-MM-DD-HH24')),p_dry_run,uid)
 on conflict(city,run_key,dry_run) do update set run_key=excluded.run_key returning * into r;
 if r.completed_at is not null then return to_jsonb(r);end if;
 for p in select bp.* from public.vuppi_store_billing_profiles bp where bp.city=p_city and bp.status<>'cancelled' and bp.next_billing_at<=now() order by bp.merchant_id for update loop
  begin
   inv:=null;period_start:=p.next_billing_at::date;period_end:=public.vuppi_billing_next(p.billing_anchor_at,period_start)-1;ex:=public.vuppi_active_billing_exemption(p.merchant_id,p.next_billing_at);
   mw:=public.vuppi_wallet_ensure('merchant',p.merchant_id,p.city,'delivery');pw:=public.vuppi_wallet_ensure('platform',null,p.city,'delivery');
   select balance_cents into available from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available' for update;
   outcome:=case when ex is not null then case when p_dry_run then 'would_waive' else 'waived' end when available>=p.monthly_fee_cents then case when p_dry_run then 'would_pay' else 'paid' end else case when p_dry_run then 'would_overdue' else 'overdue' end end;
   if not p_dry_run then
    insert into public.vuppi_subscription_invoices(merchant_id,city,billing_period_start,billing_period_end,due_at,amount_cents,status,billing_exemption_id,waived_at)
    values(p.merchant_id,p.city,period_start,period_end,p.next_billing_at,p.monthly_fee_cents,case when ex is not null then 'waived' when available>=p.monthly_fee_cents then 'open' else 'overdue' end,ex,case when ex is not null then now() end)
    on conflict(merchant_id,billing_period_start) do update set updated_at=now() returning * into inv;
    if ex is null and available>=p.monthly_fee_cents and inv.status='open' then
     tx:=public.vuppi_post_transaction('subscription_fee',p.city,p.monthly_fee_cents,
      (select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),
      (select id from public.vuppi_wallet_accounts where wallet_id=pw and bucket='available'),
      'subscription-fee:'||inv.id,'Mensalidade Vuppi',jsonb_build_object('merchant_id',p.merchant_id,'invoice_id',inv.id,'revenue_category','subscription_revenue'));
     update public.vuppi_subscription_invoices set status='paid',paid_at=now(),wallet_transaction_id=tx,updated_at=now() where id=inv.id;
    end if;
    update public.vuppi_store_billing_profiles set status=case when ex is not null then 'exempt' when available>=p.monthly_fee_cents then 'active' else 'past_due' end,
     next_billing_at=public.vuppi_billing_next(p.billing_anchor_at,period_start)::timestamptz,updated_at=now() where merchant_id=p.merchant_id;
   end if;
   insert into public.vuppi_billing_run_items(run_id,merchant_id,invoice_id,outcome,amount_cents) values(r.id,p.merchant_id,inv.id,outcome,p.monthly_fee_cents) on conflict do nothing;
  exception when others then
   insert into public.vuppi_billing_run_items(run_id,merchant_id,outcome,error_code) values(r.id,p.merchant_id,'failed',sqlstate) on conflict do nothing;
  end;
 end loop;
 update public.vuppi_billing_runs br set completed_at=now(),status=case when exists(select 1 from public.vuppi_billing_run_items where run_id=br.id and outcome='failed') then 'partial' else 'completed' end,
  stores_processed=(select count(*) from public.vuppi_billing_run_items where run_id=br.id),
  paid=(select count(*) from public.vuppi_billing_run_items where run_id=br.id and outcome in('paid','would_pay')),
  waived=(select count(*) from public.vuppi_billing_run_items where run_id=br.id and outcome in('waived','would_waive')),
  past_due=(select count(*) from public.vuppi_billing_run_items where run_id=br.id and outcome in('overdue','would_overdue')),
  failed=(select count(*) from public.vuppi_billing_run_items where run_id=br.id and outcome='failed'),
  total_amount_cents=(select coalesce(sum(amount_cents),0) from public.vuppi_billing_run_items where run_id=br.id and outcome in('paid','would_pay')) where br.id=r.id returning * into r;
 return to_jsonb(r);
end;$$;

create or replace function public.vuppi_wallet_billing(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid();m public.vuppi_members;adm boolean:=public.up_platform_is_admin();v_city text;merchant uuid;days integer;ends timestamptz;eid uuid;cfg public.vuppi_finance_settings;ids uuid[];item uuid;affected integer:=0;wd public.vuppi_withdrawals;
begin
 if uid is null then raise exception 'VUPPI_FINANCE: Entre para continuar.';end if;select * into m from public.vuppi_members where user_id=uid;v_city:=coalesce(nullif(p_data->>'city',''),m.city);
 if p_action='state' then
  if m.kind='merchant' then perform public.vuppi_billing_profile_ensure(uid);end if;
  if not adm and m.kind<>'merchant' then raise exception 'VUPPI_FINANCE: Área de billing não autorizada.';end if;
  return jsonb_build_object(
   'profile',case when m.kind='merchant' then (select to_jsonb(x) from public.vuppi_store_billing_profiles x where merchant_id=uid) else null end,
   'invoices',case when adm then (select coalesce(jsonb_agg(x order by x.due_at desc),'[]') from (select i.*,mb.name merchant_name from public.vuppi_subscription_invoices i join public.vuppi_members mb on mb.user_id=i.merchant_id limit 500)x) else (select coalesce(jsonb_agg(i order by i.due_at desc),'[]') from public.vuppi_subscription_invoices i where merchant_id=uid) end,
   'exemptions',case when adm then (select coalesce(jsonb_agg(x order by x.created_at desc),'[]') from (select e.*,mb.name merchant_name from public.vuppi_billing_exemptions e join public.vuppi_members mb on mb.user_id=e.merchant_id limit 500)x) else (select coalesce(jsonb_agg(e order by e.created_at desc),'[]') from public.vuppi_billing_exemptions e where merchant_id=uid and revoked_at is null) end,
   'profiles',case when adm then (select coalesce(jsonb_agg(x),'[]') from (select bp.*,mb.name merchant_name,(select coalesce(sum(amount_cents),0) from public.vuppi_subscription_invoices i where i.merchant_id=bp.merchant_id and i.status='overdue') overdue_cents from public.vuppi_store_billing_profiles bp join public.vuppi_members mb on mb.user_id=bp.merchant_id order by mb.name limit 500)x) else '[]'::jsonb end,
   'runs',case when adm then (select coalesce(jsonb_agg(r order by r.started_at desc),'[]') from (select * from public.vuppi_billing_runs limit 30)r) else '[]'::jsonb end,
   'dashboard',case when adm then (select jsonb_build_object('active',count(*),'exempt',count(*) filter(where status='exempt'),'past_due',count(*) filter(where status='past_due'),'expected_cents',coalesce(sum(monthly_fee_cents) filter(where status<>'cancelled'),0)) from public.vuppi_store_billing_profiles) else null end);
 end if;
 if not adm and not public.vuppi_finance_allowed(case when p_action like 'exemption_mass_%' then 'billing.exemption.mass' when p_action='exemption_revoke' then 'billing.exemption.revoke' when p_action='exemption_create' then 'billing.exemption.create' when p_action='withdrawal_approve' then 'withdrawal.approve' else 'billing.configure' end,v_city) then raise exception 'VUPPI_FINANCE: Permissão financeira necessária.';end if;
 if p_action='profile_create' then
  select id into merchant from auth.users where lower(email)=lower(trim(p_data->>'email'));perform public.vuppi_billing_profile_ensure(merchant);days:=greatest(0,least(coalesce((p_data->>'free_period_days')::int,0),3660));
  if days>0 then
   ends:=now()+make_interval(days=>days);insert into public.vuppi_billing_exemptions(merchant_id,city,type,starts_at,ends_at,reason,notes,created_by,approved_by,idempotency_key)
   select merchant,mb.city,'free_trial',now(),ends,'Período gratuito de cadastro',nullif(p_data->>'notes',''),uid,uid,'registration-free:'||merchant||':'||days from public.vuppi_members mb where mb.user_id=merchant on conflict(idempotency_key) do nothing;
   update public.vuppi_store_billing_profiles set status='exempt' where merchant_id=merchant;
  end if;return jsonb_build_object('ok',true,'merchant_id',merchant);
 elsif p_action='run_preview' then return public.vuppi_billing_run_execute(v_city,true,p_data->>'idempotency_key');
 elsif p_action='run_execute' then return public.vuppi_billing_run_execute(v_city,false,p_data->>'idempotency_key');
 elsif p_action='exemption_create' then
  if not public.vuppi_finance_step_up() then raise exception 'VUPPI_FINANCE: Autenticação reforçada necessária.';end if;merchant:=(p_data->>'merchant_id')::uuid;perform public.vuppi_billing_profile_ensure(merchant);
  ends:=case when nullif(p_data->>'ends_at','') is not null then (p_data->>'ends_at')::timestamptz else now()+make_interval(days=>greatest(1,least((p_data->>'days')::int,3660))) end;
  insert into public.vuppi_billing_exemptions(merchant_id,city,type,starts_at,ends_at,reason,notes,created_by,approved_by,idempotency_key,metadata)
  select merchant,mb.city,coalesce(nullif(p_data->>'type',''),'manual'),now(),ends,trim(p_data->>'reason'),nullif(p_data->>'notes',''),uid,uid,p_data->>'idempotency_key',jsonb_build_object('source','admin') from public.vuppi_members mb where mb.user_id=merchant returning id into eid;
  update public.vuppi_store_billing_profiles set status='exempt',updated_at=now() where merchant_id=merchant;
  insert into public.vuppi_financial_audit(actor_id,action,target_type,target_id,city,reason,details) values(uid,'billing_exemption_create','billing_exemption',eid::text,v_city,p_data->>'reason',jsonb_build_object('ends_at',ends));return jsonb_build_object('ok',true,'id',eid);
 elsif p_action='exemption_revoke' then
  if not public.vuppi_finance_step_up() then raise exception 'VUPPI_FINANCE: Autenticação reforçada necessária.';end if;
  update public.vuppi_billing_exemptions set revoked_at=now(),revoked_by=uid where id=(p_data->>'id')::uuid and revoked_at is null returning merchant_id into merchant;
  update public.vuppi_store_billing_profiles set status='active',updated_at=now() where merchant_id=merchant;return jsonb_build_object('ok',merchant is not null);
 elsif p_action in('exemption_mass_preview','exemption_mass_apply') then
  select coalesce(array_agg(value::uuid),'{}'::uuid[]) into ids from jsonb_array_elements_text(coalesce(p_data->'merchant_ids','[]'::jsonb));
  if cardinality(ids)=0 then raise exception 'VUPPI_FINANCE: Selecione ao menos um estabelecimento.';end if;
  if length(trim(coalesce(p_data->>'reason','')))<3 then raise exception 'VUPPI_FINANCE: Informe o motivo da isenção.';end if;
  select * into cfg from public.vuppi_finance_settings where city=v_city;
  if not coalesce(cfg.mass_billing_exemptions,false) then raise exception 'VUPPI_FINANCE: Isenção em massa está desativada.';end if;
  if p_action='exemption_mass_preview' then
   return jsonb_build_object('ok',true,'dry_run',true,'selected',cardinality(ids),'eligible',(select count(*) from public.vuppi_members where user_id=any(ids) and kind='merchant' and city=v_city));
  end if;
  if not public.vuppi_finance_step_up() then raise exception 'VUPPI_FINANCE: Autenticação reforçada necessária.';end if;
  days:=greatest(1,least(coalesce((p_data->>'days')::int,30),3660));ends:=now()+make_interval(days=>days);
  foreach item in array ids loop
   if exists(select 1 from public.vuppi_members where user_id=item and kind='merchant' and city=v_city) then
    perform public.vuppi_billing_profile_ensure(item);
    insert into public.vuppi_billing_exemptions(merchant_id,city,type,starts_at,ends_at,reason,notes,created_by,approved_by,idempotency_key,metadata)
    values(item,v_city,'mass_waiver',now(),ends,trim(p_data->>'reason'),nullif(p_data->>'notes',''),uid,uid,coalesce(nullif(p_data->>'idempotency_key',''),gen_random_uuid()::text)||':'||item,jsonb_build_object('source','mass_admin')) on conflict(idempotency_key) do nothing;
    update public.vuppi_store_billing_profiles set status='exempt',updated_at=now() where merchant_id=item;affected:=affected+1;
   end if;
  end loop;
  insert into public.vuppi_financial_audit(actor_id,action,target_type,target_id,city,reason,details) values(uid,'billing_exemption_mass','merchant_batch',coalesce(p_data->>'idempotency_key','mass'),v_city,p_data->>'reason',jsonb_build_object('merchant_ids',ids,'days',days,'affected',affected));
  return jsonb_build_object('ok',true,'affected',affected,'ends_at',ends);
 elsif p_action='withdrawal_approve' then
  if not public.vuppi_finance_allowed('withdrawal.approve',v_city) or not public.vuppi_finance_step_up() then raise exception 'VUPPI_FINANCE: Aprovação reforçada necessária.';end if;
  select w.* into wd from public.vuppi_withdrawals w join public.vuppi_wallets wa on wa.id=w.wallet_id where w.id=(p_data->>'id')::uuid and wa.city=v_city for update of w;
  if wd.id is null or wd.status not in('requested','under_review') then raise exception 'VUPPI_FINANCE: Saque não está disponível para aprovação.';end if;
  if wd.first_approved_by is null then update public.vuppi_withdrawals set first_approved_by=uid,first_approved_at=now(),status='under_review',reviewed_by=uid where id=wd.id;
  elsif wd.first_approved_by=uid then raise exception 'VUPPI_FINANCE: A segunda aprovação deve ser feita por outra pessoa.';
  else update public.vuppi_withdrawals set second_approved_by=uid,second_approved_at=now(),status='processing' where id=wd.id;end if;
  insert into public.vuppi_financial_audit(actor_id,action,target_type,target_id,city,reason,details) values(uid,'withdrawal_approve','withdrawal',wd.id::text,v_city,p_data->>'reason','{}');return jsonb_build_object('ok',true);
 elsif p_action='settings_save' then
  if not public.vuppi_finance_step_up() then raise exception 'VUPPI_FINANCE: Autenticação reforçada necessária.';end if;insert into public.vuppi_finance_settings(city) values(v_city) on conflict do nothing;
  update public.vuppi_finance_settings set merchant_monthly_fee_cents=coalesce((p_data->>'merchant_monthly_fee_cents')::bigint,merchant_monthly_fee_cents),merchant_monthly_billing=coalesce((p_data->>'merchant_monthly_billing')::boolean,merchant_monthly_billing),mass_billing_exemptions=coalesce((p_data->>'mass_billing_exemptions')::boolean,mass_billing_exemptions),withdrawal_risk_review=coalesce((p_data->>'withdrawal_risk_review')::boolean,withdrawal_risk_review),withdrawal_review_threshold_cents=coalesce(nullif(p_data->>'withdrawal_review_threshold_cents','')::bigint,withdrawal_review_threshold_cents),withdrawal_dual_approval_threshold_cents=coalesce(nullif(p_data->>'withdrawal_dual_approval_threshold_cents','')::bigint,withdrawal_dual_approval_threshold_cents),billing_grace_period_days=coalesce((p_data->>'billing_grace_period_days')::int,billing_grace_period_days),updated_by=uid,updated_at=now() where vuppi_finance_settings.city=v_city;
  return jsonb_build_object('ok',true);
 else raise exception 'VUPPI_FINANCE: Ação de billing desconhecida.';end if;
end;$$;

create or replace function public.vuppi_topup_allocate_subscription() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare merchant uuid;debt bigint:=0;mode text;
begin
 select owner_id into merchant from public.vuppi_wallets where id=new.wallet_id and owner_type='merchant';if merchant is null then return new;end if;
 select overdue_in_topup_mode into mode from public.vuppi_finance_settings where city=(select city from public.vuppi_wallets where id=new.wallet_id);
 if mode<>'none' then select coalesce(sum(amount_cents),0) into debt from public.vuppi_subscription_invoices where merchant_id=merchant and status='overdue';end if;
 if mode='oldest' then select coalesce(amount_cents,0) into debt from public.vuppi_subscription_invoices where merchant_id=merchant and status='overdue' order by due_at limit 1;end if;
 new.subscription_debt_cents:=debt;new.total_cents:=new.total_cents+debt;return new;
end;$$;
drop trigger if exists vuppi_topup_subscription_before on public.vuppi_topups;
create trigger vuppi_topup_subscription_before before insert on public.vuppi_topups for each row execute function public.vuppi_topup_allocate_subscription();

create or replace function public.vuppi_topup_create_allocations() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare remaining bigint:=new.subscription_debt_cents;i public.vuppi_subscription_invoices;part bigint;merchant uuid;
begin
 insert into public.vuppi_payment_allocations(topup_id,allocation_type,amount_cents) values(new.id,'wallet_recharge',new.credit_cents);
 select owner_id into merchant from public.vuppi_wallets where id=new.wallet_id;
 for i in select * from public.vuppi_subscription_invoices where merchant_id=merchant and status='overdue' order by due_at for update loop
  exit when remaining<=0;part:=least(remaining,i.amount_cents);insert into public.vuppi_payment_allocations(topup_id,allocation_type,invoice_id,amount_cents) values(new.id,'subscription_fee',i.id,part);remaining:=remaining-part;
 end loop;return new;
end;$$;
drop trigger if exists vuppi_topup_allocations_after on public.vuppi_topups;
create trigger vuppi_topup_allocations_after after insert on public.vuppi_topups for each row execute function public.vuppi_topup_create_allocations();

create or replace function public.vuppi_topup_settle_allocations() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare a public.vuppi_payment_allocations;pw uuid;city text;tx uuid;
begin
 if new.status<>'confirmed' or old.status='confirmed' then return new;end if;select w.city into city from public.vuppi_wallets w where w.id=new.wallet_id;pw:=public.vuppi_wallet_ensure('platform',null,city,'delivery');
 for a in select * from public.vuppi_payment_allocations where topup_id=new.id and allocation_type='subscription_fee' and status='pending' for update loop
  tx:=public.vuppi_post_transaction('subscription_revenue',city,a.amount_cents,(select id from public.vuppi_wallet_accounts where wallet_id=pw and bucket='pending'),(select id from public.vuppi_wallet_accounts where wallet_id=pw and bucket='available'),'subscription-topup:'||a.id,'Mensalidade Vuppi paga na recarga',jsonb_build_object('invoice_id',a.invoice_id,'revenue_category','subscription_revenue'));
  update public.vuppi_payment_allocations set status='posted',transaction_id=tx,posted_at=now() where id=a.id;update public.vuppi_subscription_invoices set status='paid',paid_at=now(),wallet_transaction_id=tx,external_payment_id=new.provider_reference,updated_at=now() where id=a.invoice_id and status='overdue';
 end loop;return new;
end;$$;
drop trigger if exists vuppi_topup_settle_after on public.vuppi_topups;
create trigger vuppi_topup_settle_after after update of status on public.vuppi_topups for each row execute function public.vuppi_topup_settle_allocations();

create or replace function public.vuppi_withdrawal_risk_gate() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare cfg public.vuppi_finance_settings;v_city text;recent_count integer:=0;
begin
 select city into v_city from public.vuppi_wallets where id=new.wallet_id;
 select * into cfg from public.vuppi_finance_settings where city=v_city;
 if tg_op='INSERT' and coalesce(cfg.withdrawal_risk_review,true) then
  select count(*) into recent_count from public.vuppi_withdrawals where wallet_id=new.wallet_id and created_at>now()-interval '30 days';
  new.risk_score:=least(100,(case when recent_count>=3 then 35 else recent_count*10 end)+(case when cfg.withdrawal_review_threshold_cents is not null and new.amount_cents>=cfg.withdrawal_review_threshold_cents then 50 else 0 end));
  new.risk_reasons:=jsonb_strip_nulls(jsonb_build_array(case when recent_count>=3 then 'frequent_withdrawals' end,case when cfg.withdrawal_review_threshold_cents is not null and new.amount_cents>=cfg.withdrawal_review_threshold_cents then 'amount_threshold' end));
  if new.risk_score>0 then new.status:='under_review';end if;
 elsif tg_op='UPDATE' and new.status='paid' and old.status<>'paid' then
  if cfg.withdrawal_dual_approval_threshold_cents is not null and new.amount_cents>=cfg.withdrawal_dual_approval_threshold_cents and (old.first_approved_by is null or old.second_approved_by is null or old.first_approved_by=old.second_approved_by) then
   raise exception 'VUPPI_FINANCE: Este saque exige duas aprovações independentes.';
  end if;
  if coalesce(cfg.withdrawal_risk_review,true) and cfg.withdrawal_review_threshold_cents is not null and new.amount_cents>=cfg.withdrawal_review_threshold_cents and old.first_approved_by is null then
   raise exception 'VUPPI_FINANCE: Este saque exige revisão antes do processamento.';
  end if;
 end if;
 return new;
end;$$;
drop trigger if exists vuppi_withdrawal_risk_before_insert on public.vuppi_withdrawals;
create trigger vuppi_withdrawal_risk_before_insert before insert on public.vuppi_withdrawals for each row execute function public.vuppi_withdrawal_risk_gate();
drop trigger if exists vuppi_withdrawal_risk_before_paid on public.vuppi_withdrawals;
create trigger vuppi_withdrawal_risk_before_paid before update of status on public.vuppi_withdrawals for each row execute function public.vuppi_withdrawal_risk_gate();

revoke all on function public.vuppi_finance_allowed(text,text),public.vuppi_finance_step_up(),public.vuppi_billing_profile_ensure(uuid),public.vuppi_active_billing_exemption(uuid,timestamptz),public.vuppi_billing_run_execute(text,boolean,text),public.vuppi_wallet_billing(text,jsonb),public.vuppi_withdrawal_risk_gate() from public,anon;
grant execute on function public.vuppi_wallet_billing(text,jsonb) to authenticated;
grant execute on function public.vuppi_billing_run_execute(text,boolean,text) to service_role;
commit;
