-- Finalização de retorno pelo entregador, controlada individualmente pela central.
begin;

alter table public.vuppi_members
  add column if not exists allow_courier_return_completion boolean not null default false;

create or replace function public.vuppi_set_courier_return_completion(p_courier uuid,p_enabled boolean) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if not public.up_platform_is_admin() then raise exception 'UP_CAR: Acesso exclusivo do administrador.'; end if;
 update public.vuppi_members
 set allow_courier_return_completion=coalesce(p_enabled,false),updated_at=now()
 where user_id=p_courier and kind='courier';
 if not found then raise exception 'UP_CAR: Entregador não encontrado.'; end if;
 return jsonb_build_object('ok',true,'enabled',coalesce(p_enabled,false));
end;$$;

create or replace function public.vuppi_finalize_delivery_return(p_delivery uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); d public.vuppi_deliveries; m public.vuppi_members; adm boolean:=public.up_platform_is_admin();
begin
 select * into d from public.vuppi_deliveries where id=p_delivery for update;
 select * into m from public.vuppi_members where user_id=uid;
 if d.id is null then raise exception 'UP_CAR: Entrega não encontrada.'; end if;
 if d.status='delivered' then return jsonb_build_object('ok',true,'status','delivered','already_completed',true); end if;
 if not d.return_required or d.return_started_at is null or d.status<>'collected' then raise exception 'UP_CAR: Esta entrega não está aguardando confirmação de retorno.'; end if;
 if not adm and d.merchant is distinct from uid and not (d.courier=uid and coalesce(m.allow_courier_return_completion,false)) then
  raise exception 'UP_CAR: A central ainda não liberou a finalização de retorno para este entregador.';
 end if;
 update public.vuppi_deliveries set status='delivered',return_completed_at=now(),completed_by=uid,updated_at=now() where id=d.id and status='collected';
 update public.vuppi_members set is_available=true,updated_at=now() where user_id=d.courier;
 insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details)
 values(d.id,uid,'return_completed',jsonb_build_object('completed_by',uid,'courier_completion',d.courier=uid));
 insert into public.up_platform_audit(actor_id,action,target,reason,details)
 values(uid,'delivery_return_complete',d.id::text,'Retorno confirmado',jsonb_build_object('courier',d.courier,'completed_by_courier',d.courier=uid));
 return jsonb_build_object('ok',true,'status','delivered');
end;$$;

revoke all on function public.vuppi_set_courier_return_completion(uuid,boolean),public.vuppi_finalize_delivery_return(uuid) from public,anon;
grant execute on function public.vuppi_set_courier_return_completion(uuid,boolean),public.vuppi_finalize_delivery_return(uuid) to authenticated;

commit;
