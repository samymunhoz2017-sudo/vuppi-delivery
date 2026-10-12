begin;
alter table public.vuppi_deliveries add column if not exists external_order_number text;
alter table public.vuppi_deliveries add column if not exists payment_method text not null default 'pix';
alter table public.vuppi_deliveries add column if not exists cash_to_collect_cents integer not null default 0;
alter table public.vuppi_deliveries add column if not exists notes text;
alter table public.vuppi_deliveries drop constraint if exists vuppi_deliveries_payment_method_check;
alter table public.vuppi_deliveries add constraint vuppi_deliveries_payment_method_check check(payment_method in ('pix','cash','credit','wallet'));
alter table public.vuppi_deliveries drop constraint if exists vuppi_deliveries_cash_to_collect_check;
alter table public.vuppi_deliveries add constraint vuppi_deliveries_cash_to_collect_check check(cash_to_collect_cents between 0 and 1000000);
create or replace function public.vuppi_delivery_details(p_quote uuid,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); d public.vuppi_deliveries; payment text:=coalesce(nullif(p_data->>'payment_method',''),'pix'); amount integer:=coalesce((nullif(p_data->>'cash_to_collect_cents',''))::integer,0);
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 select * into d from public.vuppi_deliveries where quote_id=p_quote for update;
 if d.id is null then raise exception 'UP_CAR: Entrega não encontrada.'; end if;
 if d.merchant<>uid and not public.up_platform_is_admin() then raise exception 'UP_CAR: Acesso não autorizado.'; end if;
 if payment not in ('pix','cash','credit','wallet') then raise exception 'UP_CAR: Forma de pagamento inválida.'; end if;
 if amount<0 or amount>1000000 then raise exception 'UP_CAR: Valor a cobrar inválido.'; end if;
 update public.vuppi_deliveries set external_order_number=nullif(left(trim(p_data->>'external_order_number'),60),''),payment_method=payment,cash_to_collect_cents=amount,notes=nullif(left(trim(p_data->>'notes'),500),'') where id=d.id returning * into d;
 return to_jsonb(d);
end;$$;
revoke all on function public.vuppi_delivery_details(uuid,jsonb) from public,anon;
grant execute on function public.vuppi_delivery_details(uuid,jsonb) to authenticated;
create or replace function public.vuppi_log_delivery_event() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if tg_op='INSERT' then insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details) values(new.id,auth.uid(),'created',jsonb_build_object('status',new.status));
 elsif old.status is distinct from new.status then insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details) values(new.id,auth.uid(),'status_changed',jsonb_build_object('from',old.status,'to',new.status)); end if;
 return new;
end;$$;
drop trigger if exists vuppi_delivery_event_trigger on public.vuppi_deliveries;
create trigger vuppi_delivery_event_trigger after insert or update of status on public.vuppi_deliveries for each row execute function public.vuppi_log_delivery_event();
commit;
