-- Recusa definitiva e idempotente de ofertas por entregador.
begin;

create table if not exists public.vuppi_delivery_offer_decisions(
  delivery_id uuid not null references public.vuppi_deliveries(id) on delete cascade,
  courier_id uuid not null references auth.users(id) on delete cascade,
  decision text not null check(decision in ('rejected')),
  decided_at timestamptz not null default now(),
  primary key(delivery_id,courier_id)
);
create index if not exists vuppi_delivery_offer_decisions_courier_idx
  on public.vuppi_delivery_offer_decisions(courier_id,decided_at desc);
alter table public.vuppi_delivery_offer_decisions enable row level security;
revoke all on public.vuppi_delivery_offer_decisions from public,anon,authenticated;

create or replace function public.vuppi_reject_delivery_offer(p_delivery uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); d public.vuppi_deliveries; m public.vuppi_members; inserted_count integer:=0;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_delivery::text,0));
 select * into m from public.vuppi_members where user_id=uid;
 select * into d from public.vuppi_deliveries where id=p_delivery for update;
 if m.user_id is null or m.kind<>'courier' or not m.approved then raise exception 'UP_CAR: Apenas entregadores aprovados podem recusar ofertas.'; end if;
 if d.id is null or d.city<>m.city then raise exception 'UP_CAR: Oferta não encontrada para este entregador.'; end if;
 if d.status<>'requested' then raise exception 'UP_CAR: Esta oferta não está mais disponível.'; end if;
 insert into public.vuppi_delivery_offer_decisions(delivery_id,courier_id,decision)
 values(d.id,uid,'rejected') on conflict(delivery_id,courier_id) do nothing;
 get diagnostics inserted_count=row_count;
 if inserted_count>0 then
  insert into public.up_platform_audit(actor_id,action,target,reason,details)
  values(uid,'delivery_offer_reject',d.id::text,'Oferta recusada pelo entregador',jsonb_build_object('city',d.city));
 end if;
 return jsonb_build_object('ok',true,'delivery_id',d.id,'rejected',true,'already_rejected',inserted_count=0);
end;$$;

create or replace function public.vuppi_accept_delivery_offer(p_delivery uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid();
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_delivery::text,0));
 if exists(select 1 from public.vuppi_delivery_offer_decisions where delivery_id=p_delivery and courier_id=uid and decision='rejected') then
  raise exception 'UP_CAR: Esta oferta já foi recusada por você.';
 end if;
 return public.vuppi_delivery('accept',jsonb_build_object('id',p_delivery));
end;$$;

create or replace function public.vuppi_delivery_state() returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); result jsonb; visible_offers jsonb;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 result:=public.vuppi_delivery('state','{}'::jsonb);
 select coalesce(jsonb_agg(item),'[]'::jsonb) into visible_offers
 from jsonb_array_elements(coalesce(result->'offers','[]'::jsonb)) item
 where not exists(
  select 1 from public.vuppi_delivery_offer_decisions d
  where d.delivery_id=(item->>'id')::uuid and d.courier_id=uid and d.decision='rejected'
 );
 return jsonb_set(result,'{offers}',visible_offers,true);
end;$$;

revoke all on function public.vuppi_reject_delivery_offer(uuid) from public,anon;
revoke all on function public.vuppi_accept_delivery_offer(uuid) from public,anon;
revoke all on function public.vuppi_delivery_state() from public,anon;
grant execute on function public.vuppi_reject_delivery_offer(uuid) to authenticated;
grant execute on function public.vuppi_accept_delivery_offer(uuid) to authenticated;
grant execute on function public.vuppi_delivery_state() to authenticated;

commit;
