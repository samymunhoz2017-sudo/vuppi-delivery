begin;

alter table public.vuppi_deliveries add column if not exists return_required boolean not null default false;
alter table public.vuppi_deliveries add column if not exists return_started_at timestamptz;
alter table public.vuppi_deliveries add column if not exists return_completed_at timestamptz;
alter table public.vuppi_deliveries add column if not exists completed_by uuid references auth.users(id);

create or replace function public.vuppi_delivery_details(p_quote uuid,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); d public.vuppi_deliveries; payment text:=coalesce(nullif(p_data->>'payment_method',''),'pix'); amount integer:=coalesce((nullif(p_data->>'cash_to_collect_cents',''))::integer,0);
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 select * into d from public.vuppi_deliveries where quote_id=p_quote for update;
 if d.id is null then raise exception 'UP_CAR: Entrega não encontrada.'; end if;
 if d.merchant<>uid and not public.up_platform_is_admin() then raise exception 'UP_CAR: Acesso não autorizado.'; end if;
 if payment not in ('pix','cash','credit','wallet') then raise exception 'UP_CAR: Forma de pagamento inválida.'; end if;
 if amount<0 or amount>1000000 then raise exception 'UP_CAR: Valor a cobrar inválido.'; end if;
 update public.vuppi_deliveries set external_order_number=nullif(left(trim(p_data->>'external_order_number'),60),''),payment_method=payment,cash_to_collect_cents=amount,notes=nullif(left(trim(p_data->>'notes'),500),''),return_required=coalesce((p_data->>'return_required')::boolean,false) where id=d.id returning * into d;
 return to_jsonb(d);
end;$$;

create or replace function public.vuppi_start_delivery_return(p_delivery uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); d public.vuppi_deliveries; m public.vuppi_members;
begin
 select * into d from public.vuppi_deliveries where id=p_delivery for update;
 select * into m from public.vuppi_members where user_id=uid;
 if d.id is null or d.courier is distinct from uid or d.status<>'collected' or not coalesce(m.approved,false) then raise exception 'UP_CAR: Etapa não permitida para esta conta.'; end if;
 if not d.return_required then return jsonb_build_object('return_required',false); end if;
 if d.return_started_at is null then
  update public.vuppi_deliveries set return_started_at=now(),updated_at=now() where id=d.id;
  insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details) values(d.id,uid,'return_started',jsonb_build_object('pickup_address',d.pickup_address));
 end if;
 return jsonb_build_object('return_required',true,'return_started',true,'pickup_address',d.pickup_address);
end;$$;

create or replace function public.vuppi_finalize_delivery_return(p_delivery uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); d public.vuppi_deliveries; adm boolean:=public.up_platform_is_admin();
begin
 select * into d from public.vuppi_deliveries where id=p_delivery for update;
 if d.id is null or not d.return_required or d.return_started_at is null or d.status<>'collected' then raise exception 'UP_CAR: Esta entrega não está aguardando confirmação de retorno.'; end if;
 if not adm and d.merchant is distinct from uid then raise exception 'UP_CAR: Somente o estabelecimento ou a central pode finalizar o retorno.'; end if;
 update public.vuppi_deliveries set status='delivered',return_completed_at=now(),completed_by=uid,updated_at=now() where id=d.id;
 update public.vuppi_members set is_available=true,updated_at=now() where user_id=d.courier;
 insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details) values(d.id,uid,'return_completed',jsonb_build_object('completed_by',uid));
 insert into public.up_platform_audit(actor_id,action,target,reason,details) values(uid,'delivery_return_complete',d.id::text,'Retorno confirmado pelo estabelecimento ou central',jsonb_build_object('courier',d.courier));
 return jsonb_build_object('ok',true,'status','delivered');
end;$$;

revoke all on function public.vuppi_start_delivery_return(uuid) from public,anon;
revoke all on function public.vuppi_finalize_delivery_return(uuid) from public,anon;
grant execute on function public.vuppi_start_delivery_return(uuid) to authenticated;
grant execute on function public.vuppi_finalize_delivery_return(uuid) to authenticated;

commit;
