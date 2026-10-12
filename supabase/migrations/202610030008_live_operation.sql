begin;
alter table public.vuppi_members add column if not exists last_active_at timestamptz;
alter table public.vuppi_deliveries add column if not exists scheduled_for timestamptz;
create or replace function public.vuppi_schedule_delivery(p_quote uuid,p_scheduled_for timestamptz) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); d public.vuppi_deliveries;
begin
 select * into d from public.vuppi_deliveries where quote_id=p_quote for update;
 if d.id is null or (d.merchant<>uid and not public.up_platform_is_admin()) then raise exception 'UP_CAR: Entrega não encontrada ou acesso negado.'; end if;
 if p_scheduled_for is not null and p_scheduled_for<now()+interval '10 minutes' then raise exception 'UP_CAR: Programe com pelo menos 10 minutos de antecedência.'; end if;
 update public.vuppi_deliveries set scheduled_for=p_scheduled_for where id=d.id returning * into d;return to_jsonb(d);
end;$$;
revoke all on function public.vuppi_schedule_delivery(uuid,timestamptz) from public,anon;
grant execute on function public.vuppi_schedule_delivery(uuid,timestamptz) to authenticated;
create or replace function public.vuppi_driver_location(p_lat double precision,p_lng double precision) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid();
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 if p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'UP_CAR: Localização inválida.'; end if;
 update public.vuppi_members set lat=p_lat,lng=p_lng,last_active_at=now(),updated_at=now() where user_id=uid and kind='courier' and approved and member_status='active';
 if not found then raise exception 'UP_CAR: Entregador não autorizado.'; end if;
 return jsonb_build_object('ok',true);
end;$$;
revoke all on function public.vuppi_driver_location(double precision,double precision) from public,anon;
grant execute on function public.vuppi_driver_location(double precision,double precision) to authenticated;
create or replace function public.vuppi_sync_member_status() returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
 if tg_op='INSERT' and new.approved then new.member_status:='active';
 elsif tg_op='UPDATE' and new.approved is distinct from old.approved and new.member_status=old.member_status then new.member_status:=case when new.approved then 'active' else 'pending' end; end if;
 return new;
end;$$;
drop trigger if exists vuppi_member_status_trigger on public.vuppi_members;
create trigger vuppi_member_status_trigger before insert or update of approved on public.vuppi_members for each row execute function public.vuppi_sync_member_status();
commit;
