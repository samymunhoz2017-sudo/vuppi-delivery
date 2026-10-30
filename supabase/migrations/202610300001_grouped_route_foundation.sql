-- Preparação aditiva; não aplicada. Não altera OS ou lançamentos existentes.
-- As tabelas ficam fechadas à Data API até existirem RPCs autorizadas.
begin;
create table public.vuppi_route_operations (
 id uuid primary key,
 merchant_id uuid not null references public.vuppi_members(user_id),
 courier_id uuid references public.vuppi_members(user_id),
 city text not null references public.up_cidades(id),
 state text not null check(state in ('draft','dispatching','pending','accepted','collecting','picked_up','delivering','returning','awaiting_return_confirmation','settlement_pending','completed','cancelled')),
 pricing_model text not null default 'individual_sum_with_single_return' check(pricing_model='individual_sum_with_single_return'),
 requires_return boolean not null default false,
 return_address text,
 return_lat double precision check(return_lat between -90 and 90),
 return_lng double precision check(return_lng between -180 and 180),
 return_fee_cents bigint not null default 0 check(return_fee_cents>=0),
 return_fee_applied boolean not null default false,
 return_completed_at timestamptz,
 return_completed_by uuid references auth.users(id),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 check(requires_return or (return_address is null and return_lat is null and return_lng is null and return_fee_cents=0 and not return_fee_applied and return_completed_at is null and return_completed_by is null)),
 check((return_completed_at is null)=(return_completed_by is null))
);
create table public.vuppi_route_stops (
 id uuid primary key default gen_random_uuid(),
 route_id uuid not null references public.vuppi_route_operations(id),
 delivery_id uuid references public.vuppi_deliveries(id),
 kind text not null check(kind in ('delivery','return')),
 sequence integer not null check(sequence>0),
 status text not null default 'pending' check(status in ('pending','active','arrived','confirmed','failed','cancelled')),
 frozen_price_cents bigint check(frozen_price_cents>=0),
 frozen_return_cents bigint check(frozen_return_cents>=0),
 tariff_snapshot jsonb not null default '{}'::jsonb,
 confirmed_at timestamptz, confirmed_by uuid references auth.users(id),
 created_at timestamptz not null default now(),
 unique(route_id,sequence), unique(delivery_id),
 check((kind='delivery' and delivery_id is not null and frozen_price_cents is not null and frozen_return_cents is not null and frozen_return_cents<=frozen_price_cents) or (kind='return' and delivery_id is null and frozen_price_cents is null and frozen_return_cents is null)),
 check((confirmed_at is null)=(confirmed_by is null)),
 check(status<>'confirmed' or confirmed_at is not null)
);
create unique index vuppi_route_one_return_stop on public.vuppi_route_stops(route_id) where kind='return';
create unique index vuppi_route_one_active_stop on public.vuppi_route_stops(route_id) where status in ('active','arrived');
create function public.vuppi_validate_route_stop() returns trigger
language plpgsql set search_path=public,pg_temp as $$
declare delivery_count integer; route_state text; route_has_return boolean;
begin
 if tg_op='DELETE' then raise exception 'Paradas não podem ser excluídas; registre uma ação auditada.'; end if;
 if tg_op='UPDATE' and old.status='confirmed' and
    (old.route_id is distinct from new.route_id or old.sequence is distinct from new.sequence or
     old.kind is distinct from new.kind or old.delivery_id is distinct from new.delivery_id or old.status is distinct from new.status) then
  raise exception 'Uma parada confirmada não pode ser reordenada ou alterada.';
 end if;
 if tg_op='UPDATE' and (old.frozen_price_cents is distinct from new.frozen_price_cents or old.frozen_return_cents is distinct from new.frozen_return_cents or old.tariff_snapshot is distinct from new.tariff_snapshot) then
  raise exception 'O snapshot financeiro da parada é imutável.';
 end if;
 select state,requires_return into route_state,route_has_return from public.vuppi_route_operations where id=new.route_id for update;
 if route_state is null then raise exception 'Rota não encontrada.'; end if;
 if new.kind='return' and not route_has_return then raise exception 'Esta rota não possui retorno.'; end if;
 if new.status in ('active','arrived','confirmed') and exists(
   select 1 from public.vuppi_route_stops where route_id=new.route_id and id<>new.id
    and sequence<new.sequence and status not in ('confirmed','cancelled')
 ) then raise exception 'A parada anterior ainda não foi concluída.'; end if;
 if new.kind='return' and new.status in ('active','arrived','confirmed') and exists(
   select 1 from public.vuppi_route_stops where route_id=new.route_id and kind='delivery'
    and status not in ('confirmed','cancelled')
 ) then raise exception 'O retorno só pode iniciar após a última entrega.'; end if;
 if tg_op='UPDATE' and new.status='confirmed' and old.status not in ('active','arrived','confirmed') then
  raise exception 'A parada precisa estar ativa antes da confirmação.';
 end if;
 if new.kind='delivery' and route_state in ('returning','awaiting_return_confirmation','completed','cancelled') and
    (tg_op='INSERT' or old.route_id is distinct from new.route_id or old.sequence is distinct from new.sequence) then
  raise exception 'Não é possível adicionar entregas após o início do retorno ou fim da rota.';
 end if;
 if new.kind='delivery' then
  select count(*) into delivery_count from public.vuppi_route_stops
   where route_id=new.route_id and kind='delivery' and id<>new.id;
  if delivery_count>=24 then raise exception 'A rota não pode ultrapassar 24 entregas.'; end if;
  if exists(select 1 from public.vuppi_route_stops where route_id=new.route_id and kind='return' and sequence<=new.sequence and id<>new.id) then
   raise exception 'O retorno precisa permanecer depois de todas as entregas.';
  end if;
 else
  if exists(select 1 from public.vuppi_route_stops where route_id=new.route_id and kind='delivery' and sequence>=new.sequence and id<>new.id) then
   raise exception 'O retorno precisa permanecer depois de todas as entregas.';
  end if;
 end if;
 return new;
end;$$;
create trigger vuppi_validate_route_stop before insert or update or delete on public.vuppi_route_stops
 for each row execute function public.vuppi_validate_route_stop();
create table public.vuppi_route_settlements (
 id uuid primary key default gen_random_uuid(),
 route_id uuid not null references public.vuppi_route_operations(id),
 version integer not null check(version>0),
 idempotency_key text not null unique,
 status text not null check(status in ('pending','completed','failed')),
 gross_cents bigint not null check(gross_cents>=0),
 return_fee_cents bigint not null check(return_fee_cents>=0 and return_fee_cents<=gross_cents),
 created_at timestamptz not null default now(),completed_at timestamptz,
 unique(route_id,version), unique(id,route_id),
 check((status='completed')=(completed_at is not null))
);
create unique index vuppi_route_one_completed_settlement on public.vuppi_route_settlements(route_id) where status='completed';
-- A relação aponta para o razão existente; não cria nem altera lançamentos.
create table public.vuppi_route_settlement_movements (
 id uuid primary key default gen_random_uuid(),
 route_id uuid not null,
 settlement_id uuid not null,
 financial_transaction_id uuid not null unique references public.vuppi_financial_transactions(id),
 component text not null check(component in ('delivery','return_fee','courier_credit','platform_revenue','fee','discount','adjustment')),
 created_at timestamptz not null default now(),
 foreign key(settlement_id,route_id) references public.vuppi_route_settlements(id,route_id)
);
create unique index vuppi_route_one_return_fee on public.vuppi_route_settlement_movements(route_id) where component='return_fee';
create function public.vuppi_validate_route_operation() returns trigger
language plpgsql set search_path=public,pg_temp as $$
begin
 if old.state not in ('draft','dispatching','pending') and
    (old.requires_return is distinct from new.requires_return or old.return_address is distinct from new.return_address or old.return_lat is distinct from new.return_lat or old.return_lng is distinct from new.return_lng or old.return_fee_cents is distinct from new.return_fee_cents or old.pricing_model is distinct from new.pricing_model) then
  raise exception 'Os valores e a regra de retorno estão congelados durante a rota.';
 end if;
 if not new.requires_return and exists(select 1 from public.vuppi_route_stops where route_id=new.id and kind='return') then
  raise exception 'Uma rota sem retorno não pode possuir parada de retorno.';
 end if;
 if new.return_fee_applied and not exists(select 1 from public.vuppi_route_settlement_movements where route_id=new.id and component='return_fee') then
  raise exception 'A taxa de retorno requer um lançamento financeiro associado.';
 end if;
 if new.state='completed' and old.state is distinct from 'completed' then
  if exists(select 1 from public.vuppi_route_stops where route_id=new.id and kind='delivery' and status not in ('confirmed','cancelled')) or
     (new.requires_return and new.return_completed_at is null) or
     not exists(select 1 from public.vuppi_route_settlements where route_id=new.id and status in ('pending','completed')) then
   raise exception 'A rota ainda possui etapas ou liquidação pendentes de registro.';
  end if;
 end if;
 return new;
end;$$;
create trigger vuppi_validate_route_operation before update on public.vuppi_route_operations
 for each row execute function public.vuppi_validate_route_operation();
alter table public.vuppi_route_operations enable row level security;
alter table public.vuppi_route_stops enable row level security;
alter table public.vuppi_route_settlements enable row level security;
alter table public.vuppi_route_settlement_movements enable row level security;
revoke all on public.vuppi_route_operations,public.vuppi_route_stops,public.vuppi_route_settlements,public.vuppi_route_settlement_movements from public,anon,authenticated;
revoke all on function public.vuppi_validate_route_stop() from public,anon,authenticated;
revoke all on function public.vuppi_validate_route_operation() from public,anon,authenticated;
commit;
