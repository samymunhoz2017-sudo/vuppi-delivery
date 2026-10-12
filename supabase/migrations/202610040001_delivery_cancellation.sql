begin;
alter table public.vuppi_deliveries add column if not exists cancelled_by_role text check(cancelled_by_role in ('central','establishment','courier'));
alter table public.vuppi_deliveries add column if not exists cancel_reason text;
alter table public.vuppi_deliveries add column if not exists cancelled_at timestamptz;

create or replace function public.vuppi_cancel_delivery(p_delivery uuid,p_reason text default null) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
 uid uuid:=auth.uid(); adm boolean:=public.up_platform_is_admin(); d public.vuppi_deliveries; m public.vuppi_members; origin text; reason text:=nullif(left(trim(coalesce(p_reason,'')),300),'');
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 select * into d from public.vuppi_deliveries where id=p_delivery for update;
 if d.id is null then raise exception 'UP_CAR: Entrega não encontrada.'; end if;
 if d.status in ('delivered','cancelled') then raise exception 'UP_CAR: Esta entrega já foi encerrada.'; end if;
 select * into m from public.vuppi_members where user_id=uid;
 if adm then origin:='central';
 elsif d.merchant=uid and m.kind='merchant' then origin:='establishment';
 elsif d.courier=uid and m.kind='courier' then origin:='courier';
 else raise exception 'UP_CAR: Você não pode cancelar esta entrega.';
 end if;
 update public.vuppi_deliveries set status='cancelled',cancelled_by_role=origin,cancel_reason=reason,cancelled_at=now(),updated_at=now() where id=d.id returning * into d;
 if d.courier is not null then update public.vuppi_members set is_available=true,updated_at=now() where user_id=d.courier and kind='courier' and approved; end if;
 insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details) values(d.id,uid,'cancelled',jsonb_build_object('origin',origin,'reason',reason));
 insert into public.up_platform_audit(actor_id,action,target,reason,details) values(uid,'delivery_cancel',d.id::text,coalesce(reason,'Cancelamento solicitado'),jsonb_build_object('city',d.city,'origin',origin));
 return to_jsonb(d);
end;$$;
revoke all on function public.vuppi_cancel_delivery(uuid,text) from public,anon;
grant execute on function public.vuppi_cancel_delivery(uuid,text) to authenticated;
commit;
