-- Vuppi Delivery: razão financeiro imutável.
-- MIGRAÇÃO PREPARADA, NÃO APLICADA: confirme desenvolvimento/homologação antes de executar.
begin;

create type public.vuppi_wallet_owner_type as enum ('merchant','courier','platform');
create type public.vuppi_balance_bucket as enum ('available','reserved','pending','promotional','blocked');
create type public.vuppi_financial_status as enum ('pending','posted','failed','cancelled','reversed','reconciliation_required');

create table public.vuppi_finance_settings(
 city text primary key references public.up_cidades(id), product text not null default 'delivery',
 currency text not null default 'BRL' check(currency='BRL'), topup_enabled boolean not null default true,
 withdrawal_enabled boolean not null default true, topup_fee_bps integer not null default 200 check(topup_fee_bps between 0 and 10000),
 topup_fee_mode text not null default 'add' check(topup_fee_mode in ('add','deduct')),
 withdrawal_fee_cents bigint not null default 150 check(withdrawal_fee_cents>=0), withdrawal_weekday smallint not null default 1 check(withdrawal_weekday between 0 and 6),
 min_topup_cents bigint not null default 1000, max_topup_cents bigint not null default 5000000,
 min_withdrawal_cents bigint not null default 1000, max_withdrawal_cents bigint not null default 5000000,
 merchant_minimum_balance_cents bigint not null default 0, courier_release_delay_minutes integer not null default 0,
 courier_share_bps integer not null default 8500 check(courier_share_bps between 0 and 10000),
 negative_balance_enabled boolean not null default false, updated_by uuid references auth.users(id), updated_at timestamptz not null default now()
);

create table public.vuppi_wallets(
 id uuid primary key default gen_random_uuid(), owner_type public.vuppi_wallet_owner_type not null,
 owner_id uuid, city text not null references public.up_cidades(id), product text not null default 'delivery', currency text not null default 'BRL' check(currency='BRL'),
 status text not null default 'active' check(status in ('active','blocked','closed')), minimum_balance_cents bigint not null default 0,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 check((owner_type='platform' and owner_id is null) or (owner_type<>'platform' and owner_id is not null)),
 unique nulls not distinct(owner_type,owner_id,city,product,currency)
);

create table public.vuppi_wallet_accounts(
 id uuid primary key default gen_random_uuid(), wallet_id uuid not null references public.vuppi_wallets(id),
 bucket public.vuppi_balance_bucket not null, balance_cents bigint not null default 0,
 updated_at timestamptz not null default now(), unique(wallet_id,bucket)
);

create table public.vuppi_financial_transactions(
 id uuid primary key default gen_random_uuid(), type text not null, status public.vuppi_financial_status not null default 'pending',
 city text not null references public.up_cidades(id), product text not null default 'delivery', currency text not null default 'BRL' check(currency='BRL'),
 amount_cents bigint not null check(amount_cents>0), delivery_id uuid references public.vuppi_deliveries(id),
 merchant_id uuid, courier_id uuid, topup_id uuid, withdrawal_id uuid, actor_id uuid references auth.users(id),
 description text not null, reason text, metadata jsonb not null default '{}'::jsonb,
 idempotency_key text not null, provider text, provider_reference text, original_transaction_id uuid references public.vuppi_financial_transactions(id),
 created_at timestamptz not null default now(), posted_at timestamptz, unique(city,product,idempotency_key)
);

create table public.vuppi_ledger_entries(
 id uuid primary key default gen_random_uuid(), transaction_id uuid not null references public.vuppi_financial_transactions(id),
 account_id uuid not null references public.vuppi_wallet_accounts(id), direction text not null check(direction in ('debit','credit')),
 amount_cents bigint not null check(amount_cents>0), balance_before_cents bigint not null, balance_after_cents bigint not null,
 created_at timestamptz not null default now(), unique(transaction_id,account_id,direction)
);

create table public.vuppi_topups(
 id uuid primary key default gen_random_uuid(), wallet_id uuid not null references public.vuppi_wallets(id),
 amount_cents bigint not null check(amount_cents>0), fee_cents bigint not null check(fee_cents>=0), total_cents bigint not null check(total_cents>0),
 credit_cents bigint not null check(credit_cents>0), fee_bps integer not null, fee_mode text not null check(fee_mode in ('add','deduct')),
 status text not null default 'pending' check(status in ('pending','awaiting_payment','confirmed','expired','cancelled','failed','refunded','reconciliation_required')),
 provider text not null default 'fake', provider_reference text, idempotency_key text not null unique,
 created_by uuid not null references auth.users(id), created_at timestamptz not null default now(), confirmed_at timestamptz, metadata jsonb not null default '{}'::jsonb
);

create table public.vuppi_withdrawals(
 id uuid primary key default gen_random_uuid(), wallet_id uuid not null references public.vuppi_wallets(id),
 amount_cents bigint not null check(amount_cents>0), fee_cents bigint not null check(fee_cents>=0), net_cents bigint not null check(net_cents>0),
 status text not null default 'requested' check(status in ('requested','under_review','processing','paid','rejected','failed','cancelled','reconciliation_required')),
 pix_key_masked text, provider text not null default 'fake', provider_reference text, idempotency_key text not null unique,
 requested_by uuid not null references auth.users(id), reviewed_by uuid references auth.users(id), reason text,
 created_at timestamptz not null default now(), processed_at timestamptz, metadata jsonb not null default '{}'::jsonb
);

create table public.vuppi_financial_benefits(
 id uuid primary key default gen_random_uuid(), wallet_id uuid not null references public.vuppi_wallets(id), title text not null,
 amount_cents bigint not null check(amount_cents>0), withdrawable boolean not null default false, expires_at timestamptz,
 status text not null default 'active' check(status in ('active','used','expired','cancelled')), created_by uuid not null references auth.users(id),
 idempotency_key text not null unique, created_at timestamptz not null default now()
);

create table public.vuppi_financial_audit(
 id bigint generated always as identity primary key, actor_id uuid references auth.users(id), action text not null,
 target_type text not null, target_id text not null, city text, reason text, details jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);

create index vuppi_wallet_owner_idx on public.vuppi_wallets(owner_id,city);
create index vuppi_tx_delivery_idx on public.vuppi_financial_transactions(delivery_id,created_at desc);
create index vuppi_tx_status_idx on public.vuppi_financial_transactions(status,created_at desc);
create index vuppi_entries_account_idx on public.vuppi_ledger_entries(account_id,created_at desc);
create index vuppi_topup_status_idx on public.vuppi_topups(status,created_at desc);
create index vuppi_withdrawal_status_idx on public.vuppi_withdrawals(status,created_at desc);

alter table public.vuppi_finance_settings enable row level security;
alter table public.vuppi_wallets enable row level security;
alter table public.vuppi_wallet_accounts enable row level security;
alter table public.vuppi_financial_transactions enable row level security;
alter table public.vuppi_ledger_entries enable row level security;
alter table public.vuppi_topups enable row level security;
alter table public.vuppi_withdrawals enable row level security;
alter table public.vuppi_financial_benefits enable row level security;
alter table public.vuppi_financial_audit enable row level security;
revoke all on public.vuppi_finance_settings,public.vuppi_wallets,public.vuppi_wallet_accounts,public.vuppi_financial_transactions,public.vuppi_ledger_entries,public.vuppi_topups,public.vuppi_withdrawals,public.vuppi_financial_benefits,public.vuppi_financial_audit from anon,authenticated;

create function public.vuppi_reject_ledger_mutation() returns trigger language plpgsql as $$begin raise exception 'VUPPI_FINANCE: Razão financeiro imutável.';end;$$;
create trigger vuppi_tx_immutable before update or delete on public.vuppi_financial_transactions for each row execute function public.vuppi_reject_ledger_mutation();
create trigger vuppi_entry_immutable before update or delete on public.vuppi_ledger_entries for each row execute function public.vuppi_reject_ledger_mutation();

create function public.vuppi_wallet_ensure(p_owner_type public.vuppi_wallet_owner_type,p_owner uuid,p_city text,p_product text default 'delivery') returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare wid uuid;b public.vuppi_balance_bucket;
begin
 insert into vuppi_wallets(owner_type,owner_id,city,product) values(p_owner_type,p_owner,p_city,p_product)
 on conflict(owner_type,owner_id,city,product,currency) do update set updated_at=now() returning id into wid;
 foreach b in array enum_range(null::public.vuppi_balance_bucket) loop insert into vuppi_wallet_accounts(wallet_id,bucket) values(wid,b) on conflict do nothing;end loop;
 return wid;
end;$$;

create function public.vuppi_post_transaction(p_type text,p_city text,p_amount bigint,p_debit uuid,p_credit uuid,p_key text,p_description text,p_context jsonb default '{}') returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare tid uuid;db bigint;cb bigint;debit_owner public.vuppi_wallet_owner_type;allow_negative boolean:=false;
begin
 if p_amount<=0 then raise exception 'VUPPI_FINANCE: Valor inválido.';end if;
 select id into tid from vuppi_financial_transactions where city=p_city and product='delivery' and idempotency_key=p_key;
 if tid is not null then return tid;end if;
 perform 1 from vuppi_wallet_accounts where id in(p_debit,p_credit) order by id for update;
 select balance_cents into db from vuppi_wallet_accounts where id=p_debit;select balance_cents into cb from vuppi_wallet_accounts where id=p_credit;
 if db is null or cb is null then raise exception 'VUPPI_FINANCE: Conta inválida.';end if;
 select w.owner_type into debit_owner from vuppi_wallet_accounts a join vuppi_wallets w on w.id=a.wallet_id where a.id=p_debit;
 select coalesce(s.negative_balance_enabled,false) into allow_negative from vuppi_wallet_accounts a join vuppi_wallets w on w.id=a.wallet_id left join vuppi_finance_settings s on s.city=w.city where a.id=p_debit;
 if db<p_amount and debit_owner<>'platform' and not allow_negative then raise exception 'VUPPI_FINANCE: Saldo disponível insuficiente.';end if;
 insert into vuppi_financial_transactions(type,status,city,amount_cents,delivery_id,merchant_id,courier_id,actor_id,description,reason,metadata,idempotency_key,posted_at)
 values(p_type,'posted',p_city,p_amount,nullif(p_context->>'delivery_id','')::uuid,nullif(p_context->>'merchant_id','')::uuid,nullif(p_context->>'courier_id','')::uuid,auth.uid(),p_description,p_context->>'reason',p_context,p_key,now()) returning id into tid;
 update vuppi_wallet_accounts set balance_cents=balance_cents-p_amount,updated_at=now() where id=p_debit;
 update vuppi_wallet_accounts set balance_cents=balance_cents+p_amount,updated_at=now() where id=p_credit;
 insert into vuppi_ledger_entries(transaction_id,account_id,direction,amount_cents,balance_before_cents,balance_after_cents) values(tid,p_debit,'debit',p_amount,db,db-p_amount),(tid,p_credit,'credit',p_amount,cb,cb+p_amount);
 return tid;
end;$$;

create function public.vuppi_finance(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid();m vuppi_members;adm boolean:=public.up_platform_is_admin();wid uuid;cfg vuppi_finance_settings;a bigint;fee bigint;credit bigint;total bigint;wday integer;top vuppi_topups;wd vuppi_withdrawals;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.';end if;
 select * into m from vuppi_members where user_id=uid;
 if m.user_id is not null then wid:=public.vuppi_wallet_ensure(m.kind::text::public.vuppi_wallet_owner_type,uid,m.city,'delivery');end if;
 if p_action='state' then
  return jsonb_build_object('enabled',true,'role',case when adm then 'admin' else m.kind end,'wallet',case when wid is null then null else (select jsonb_build_object('id',w.id,'owner_type',w.owner_type,'city',w.city,'status',w.status,'minimum_balance_cents',w.minimum_balance_cents,'balances',(select jsonb_object_agg(bucket,balance_cents) from vuppi_wallet_accounts where wallet_id=w.id)) from vuppi_wallets w where w.id=wid) end,
   'wallets',case when adm then (select coalesce(jsonb_agg(x),'[]') from (select w.id,w.owner_type,w.owner_id,w.city,w.status,coalesce(m2.name,'Vuppi Delivery') name,(select jsonb_object_agg(bucket,balance_cents) from vuppi_wallet_accounts where wallet_id=w.id) balances from vuppi_wallets w left join vuppi_members m2 on m2.user_id=w.owner_id order by w.created_at desc limit 500)x) else '[]'::jsonb end,
   'topups',case when adm then (select coalesce(jsonb_agg(t order by t.created_at desc),'[]') from (select * from vuppi_topups limit 200)t) else (select coalesce(jsonb_agg(t order by t.created_at desc),'[]') from (select * from vuppi_topups where wallet_id=wid limit 100)t) end,
   'withdrawals',case when adm then (select coalesce(jsonb_agg(x order by x.created_at desc),'[]') from (select * from vuppi_withdrawals limit 200)x) else (select coalesce(jsonb_agg(x order by x.created_at desc),'[]') from (select * from vuppi_withdrawals where wallet_id=wid limit 100)x) end,
   'settings',case when adm then (select coalesce(jsonb_agg(s),'[]') from vuppi_finance_settings s) else (select to_jsonb(s) from vuppi_finance_settings s where s.city=m.city) end,
   'provider',jsonb_build_object('name','fake','enabled',false,'live_operations',false));
 elsif p_action='statement' then
  if (p_data->>'wallet_id')::uuid is distinct from wid and not adm then raise exception 'UP_CAR: Carteira não autorizada.';end if;
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (select e.id,e.direction,e.amount_cents,e.balance_before_cents,e.balance_after_cents,e.created_at,t.type,t.description,t.status,t.delivery_id,t.id transaction_id from vuppi_ledger_entries e join vuppi_wallet_accounts a on a.id=e.account_id join vuppi_financial_transactions t on t.id=e.transaction_id where a.wallet_id=(p_data->>'wallet_id')::uuid order by e.created_at desc limit least(200,greatest(1,coalesce((p_data->>'limit')::int,50))))x),'[]'::jsonb);
 end if;
 if m.user_id is null and not adm then raise exception 'UP_CAR: Perfil financeiro não encontrado.';end if;
 if p_action in ('topup_quote','topup_request','withdraw_request') then
  if m.city is null then raise exception 'UP_CAR: Cidade financeira não encontrada.';end if;
  insert into vuppi_finance_settings(city) values(m.city) on conflict do nothing;
  select * into cfg from vuppi_finance_settings where city=m.city;
 elsif p_action='settings_save' then
  if nullif(p_data->>'city','') is null then raise exception 'UP_CAR: Informe a cidade.';end if;
  insert into vuppi_finance_settings(city) values(p_data->>'city') on conflict do nothing;
  select * into cfg from vuppi_finance_settings where city=p_data->>'city';
 end if;
 if p_action='topup_quote' then
  a:=(p_data->>'amount_cents')::bigint;if a<cfg.min_topup_cents or a>cfg.max_topup_cents then raise exception 'UP_CAR: Valor fora dos limites de recarga.';end if;
  fee:=ceil(a*cfg.topup_fee_bps::numeric/10000);credit:=case when cfg.topup_fee_mode='deduct' then a-fee else a end;total:=case when cfg.topup_fee_mode='add' then a+fee else a end;
  return jsonb_build_object('amount_cents',a,'fee_cents',fee,'credit_cents',credit,'total_cents',total,'fee_bps',cfg.topup_fee_bps,'fee_mode',cfg.topup_fee_mode);
 elsif p_action='topup_request' then
  if m.kind<>'merchant' or not cfg.topup_enabled then raise exception 'UP_CAR: Recarga indisponível.';end if;
  a:=(p_data->>'amount_cents')::bigint;if a<cfg.min_topup_cents or a>cfg.max_topup_cents then raise exception 'UP_CAR: Valor fora dos limites de recarga.';end if;
  fee:=ceil(a*cfg.topup_fee_bps::numeric/10000);credit:=case when cfg.topup_fee_mode='deduct' then a-fee else a end;total:=case when cfg.topup_fee_mode='add' then a+fee else a end;
  insert into vuppi_topups(wallet_id,amount_cents,fee_cents,total_cents,credit_cents,fee_bps,fee_mode,status,idempotency_key,created_by) values(wid,a,fee,total,credit,cfg.topup_fee_bps,cfg.topup_fee_mode,'awaiting_payment',p_data->>'idempotency_key',uid) on conflict(idempotency_key) do update set idempotency_key=excluded.idempotency_key returning * into top;
  return to_jsonb(top);
 elsif p_action='withdraw_request' then
  if m.kind<>'courier' or not cfg.withdrawal_enabled then raise exception 'UP_CAR: Saque indisponível.';end if;
  wday:=extract(dow from now() at time zone 'America/Sao_Paulo');if wday<>cfg.withdrawal_weekday then raise exception 'UP_CAR: Saques disponíveis somente às segundas-feiras.';end if;
  a:=(p_data->>'amount_cents')::bigint;if a<cfg.min_withdrawal_cents or a>cfg.max_withdrawal_cents then raise exception 'UP_CAR: Valor fora dos limites de saque.';end if;
  if exists(select 1 from vuppi_withdrawals where wallet_id=wid and status in('requested','under_review','processing','reconciliation_required')) then raise exception 'UP_CAR: Já existe um saque pendente.';end if;
  select balance_cents into credit from vuppi_wallet_accounts where wallet_id=wid and bucket='available' for update;if credit<a then raise exception 'UP_CAR: Saldo disponível insuficiente.';end if;
  fee:=cfg.withdrawal_fee_cents;if a<=fee then raise exception 'UP_CAR: O saque precisa ser maior que a taxa.';end if;
  perform vuppi_post_transaction('withdrawal_reserve',m.city,a,(select id from vuppi_wallet_accounts where wallet_id=wid and bucket='available'),(select id from vuppi_wallet_accounts where wallet_id=wid and bucket='reserved'),'withdrawal-reserve:'||(p_data->>'idempotency_key'),'Reserva de saque',jsonb_build_object('courier_id',uid));
  insert into vuppi_withdrawals(wallet_id,amount_cents,fee_cents,net_cents,pix_key_masked,idempotency_key,requested_by) values(wid,a,fee,a-fee,left(p_data->>'pix_key_masked',120),p_data->>'idempotency_key',uid) on conflict(idempotency_key) do update set idempotency_key=excluded.idempotency_key returning * into wd;
  return to_jsonb(wd);
 elsif p_action in ('admin_adjust','admin_confirm_topup','admin_process_withdrawal','settings_save','benefit_create','reconcile') then
  if not adm then raise exception 'UP_CAR: Acesso exclusivo do administrador.';end if;
  insert into vuppi_financial_audit(actor_id,action,target_type,target_id,city,reason,details) values(uid,p_action,'finance',coalesce(p_data->>'id','settings'),p_data->>'city',p_data->>'reason',p_data);
  if p_action='settings_save' then update vuppi_finance_settings set topup_enabled=coalesce((p_data->>'topup_enabled')::boolean,topup_enabled),withdrawal_enabled=coalesce((p_data->>'withdrawal_enabled')::boolean,withdrawal_enabled),topup_fee_bps=coalesce((p_data->>'topup_fee_bps')::int,topup_fee_bps),topup_fee_mode=coalesce(p_data->>'topup_fee_mode',topup_fee_mode),withdrawal_fee_cents=coalesce((p_data->>'withdrawal_fee_cents')::bigint,withdrawal_fee_cents),withdrawal_weekday=coalesce((p_data->>'withdrawal_weekday')::smallint,withdrawal_weekday),courier_share_bps=coalesce((p_data->>'courier_share_bps')::int,courier_share_bps),updated_by=uid,updated_at=now() where city=p_data->>'city';
  elsif p_action='admin_confirm_topup' then
   select * into top from vuppi_topups where id=(p_data->>'id')::uuid for update;if top.status='confirmed' then return to_jsonb(top);end if;if top.status not in('pending','awaiting_payment') then raise exception 'UP_CAR: Recarga não pode ser confirmada.';end if;
   wid:=public.vuppi_wallet_ensure('platform',null,(select city from vuppi_wallets where id=top.wallet_id),'delivery');
   perform vuppi_post_transaction('topup_credit',(select city from vuppi_wallets where id=top.wallet_id),top.credit_cents,(select id from vuppi_wallet_accounts where wallet_id=wid and bucket='pending'),(select id from vuppi_wallet_accounts where wallet_id=top.wallet_id and bucket='available'),'topup-credit:'||top.id,'Recarga confirmada',jsonb_build_object('merchant_id',(select owner_id from vuppi_wallets where id=top.wallet_id)));
   if top.fee_cents>0 then perform vuppi_post_transaction('topup_fee',(select city from vuppi_wallets where id=top.wallet_id),top.fee_cents,(select id from vuppi_wallet_accounts where wallet_id=wid and bucket='pending'),(select id from vuppi_wallet_accounts where wallet_id=wid and bucket='available'),'topup-fee:'||top.id,'Taxa de recarga','{}');end if;
   update vuppi_topups set status='confirmed',confirmed_at=now(),provider_reference=coalesce(p_data->>'provider_reference',provider_reference) where id=top.id;
  elsif p_action='admin_process_withdrawal' then
   select * into wd from vuppi_withdrawals where id=(p_data->>'id')::uuid for update;if wd.status='paid' then return to_jsonb(wd);end if;if wd.status not in('requested','under_review','processing') then raise exception 'UP_CAR: Saque não pode ser processado.';end if;
   wid:=public.vuppi_wallet_ensure('platform',null,(select city from vuppi_wallets where id=wd.wallet_id),'delivery');
   perform vuppi_post_transaction('withdrawal_paid',(select city from vuppi_wallets where id=wd.wallet_id),wd.net_cents,(select id from vuppi_wallet_accounts where wallet_id=wd.wallet_id and bucket='reserved'),(select id from vuppi_wallet_accounts where wallet_id=wid and bucket='pending'),'withdrawal-paid:'||wd.id,'Saque processado','{}');
   if wd.fee_cents>0 then perform vuppi_post_transaction('withdrawal_fee',(select city from vuppi_wallets where id=wd.wallet_id),wd.fee_cents,(select id from vuppi_wallet_accounts where wallet_id=wd.wallet_id and bucket='reserved'),(select id from vuppi_wallet_accounts where wallet_id=wid and bucket='available'),'withdrawal-fee:'||wd.id,'Taxa de saque','{}');end if;
   update vuppi_withdrawals set status='paid',reviewed_by=uid,processed_at=now(),provider_reference=coalesce(p_data->>'provider_reference',provider_reference) where id=wd.id;
  end if;
  return jsonb_build_object('ok',true,'simulation',true);
 else raise exception 'UP_CAR: Ação financeira desconhecida.';end if;
end;$$;

create function public.vuppi_delivery_wallet_sync() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare mw uuid;cw uuid;pw uuid;share bigint;margin bigint;cfg vuppi_finance_settings;
begin
 if new.payment_method<>'wallet' then return new;end if;
 insert into vuppi_finance_settings(city) values(new.city) on conflict do nothing;select * into cfg from vuppi_finance_settings where city=new.city;
 mw:=vuppi_wallet_ensure('merchant',new.merchant,new.city,'delivery');pw:=vuppi_wallet_ensure('platform',null,new.city,'delivery');
 if tg_op='INSERT' then
  perform vuppi_post_transaction('delivery_reserve',new.city,new.price_cents,(select id from vuppi_wallet_accounts where wallet_id=mw and bucket='available'),(select id from vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),'delivery-reserve:'||new.id,'Reserva da OS',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant));
 elsif old.status is distinct from new.status and new.status='cancelled' then
  perform vuppi_post_transaction('delivery_release',new.city,new.price_cents,(select id from vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),(select id from vuppi_wallet_accounts where wallet_id=mw and bucket='available'),'delivery-release:'||new.id,'Liberação por cancelamento',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant));
 elsif old.status is distinct from new.status and new.status='delivered' then
  if new.courier is null then raise exception 'VUPPI_FINANCE: Entrega sem entregador não pode ser liquidada.';end if;
  cw:=vuppi_wallet_ensure('courier',new.courier,new.city,'delivery');share:=floor(new.price_cents*cfg.courier_share_bps::numeric/10000);margin:=new.price_cents-share;
  perform vuppi_post_transaction('delivery_courier_credit',new.city,share,(select id from vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),(select id from vuppi_wallet_accounts where wallet_id=cw and bucket=case when cfg.courier_release_delay_minutes>0 then 'pending'::vuppi_balance_bucket else 'available'::vuppi_balance_bucket end),'delivery-courier:'||new.id,'Crédito da entrega',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant,'courier_id',new.courier));
  if margin>0 then perform vuppi_post_transaction('delivery_platform_revenue',new.city,margin,(select id from vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),(select id from vuppi_wallet_accounts where wallet_id=pw and bucket='available'),'delivery-margin:'||new.id,'Receita da entrega',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant,'courier_id',new.courier));end if;
 end if;return new;
end;$$;
create trigger vuppi_delivery_wallet_after_insert after insert on public.vuppi_deliveries for each row execute function public.vuppi_delivery_wallet_sync();
create trigger vuppi_delivery_wallet_after_update after update of status on public.vuppi_deliveries for each row execute function public.vuppi_delivery_wallet_sync();

revoke all on function public.vuppi_finance(text,jsonb),public.vuppi_wallet_ensure(public.vuppi_wallet_owner_type,uuid,text,text),public.vuppi_post_transaction(text,text,bigint,uuid,uuid,text,text,jsonb) from public,anon;
grant execute on function public.vuppi_finance(text,jsonb) to authenticated;
commit;
