-- Amplia a gestão auditada de OS para ocorrências e correções durante a rota.
begin;

create or replace function public.vuppi_admin_manage_delivery(p_action text,p_delivery uuid,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare d public.vuppi_deliveries;old_courier uuid;new_price integer;delta bigint;mw uuid;actor uuid:=auth.uid();
begin
 if not public.up_platform_is_admin() then raise exception 'UP_CAR: Acesso exclusivo do administrador.'; end if;
 select * into d from public.vuppi_deliveries where id=p_delivery for update;
 if d.id is null then raise exception 'UP_CAR: Entrega não encontrada.'; end if;
 if p_action='edit' then
  if d.status not in ('requested','assigned','collected') then raise exception 'UP_CAR: Uma OS encerrada não pode ter valor alterado.'; end if;
  new_price:=greatest(800,least(1000000,coalesce(nullif(p_data->>'price_cents','')::integer,d.price_cents)));
  if d.payment_method='wallet' and new_price<>d.price_cents then
   mw:=public.vuppi_wallet_ensure('merchant',d.merchant,d.city,'delivery'); delta:=new_price-d.price_cents;
   if delta>0 then
    perform public.vuppi_post_transaction('delivery_price_increase',d.city,delta,
     (select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),
     (select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),
     'delivery-price-increase:'||d.id||':'||new_price,'Aumento do valor da OS',jsonb_build_object('delivery_id',d.id,'merchant_id',d.merchant,'reason',p_data->>'reason'));
   else
    perform public.vuppi_post_transaction('delivery_price_decrease',d.city,-delta,
     (select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),
     (select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),
     'delivery-price-decrease:'||d.id||':'||new_price,'Redução do valor da OS',jsonb_build_object('delivery_id',d.id,'merchant_id',d.merchant,'reason',p_data->>'reason'));
   end if;
  end if;
  update public.vuppi_deliveries set
   recipient=left(trim(coalesce(nullif(p_data->>'recipient',''),recipient)),100),
   phone=left(trim(coalesce(nullif(p_data->>'phone',''),phone)),30),
   external_order_number=coalesce(nullif(left(trim(p_data->>'external_order_number'),60),''),external_order_number),
   notes=nullif(left(trim(coalesce(p_data->>'notes',notes)),500),''),
   cash_to_collect_cents=greatest(0,least(1000000,coalesce(nullif(p_data->>'cash_to_collect_cents','')::integer,cash_to_collect_cents))),
   price_cents=new_price,updated_at=now() where id=d.id returning * into d;
 elsif p_action='redistribute' then
  if d.status not in ('assigned','collected') then raise exception 'UP_CAR: Apenas entregas aceitas ou em andamento podem ser redistribuídas.'; end if;
  old_courier:=d.courier;
  update public.vuppi_deliveries set courier=null,status='requested',pickup_arrived_at=null,
   redistributed_count=redistributed_count+1,last_redistributed_at=now(),last_redistributed_by=actor,updated_at=now()
   where id=d.id returning * into d;
  if old_courier is not null then update public.vuppi_members set is_available=true,updated_at=now() where user_id=old_courier and approved; end if;
 elsif p_action='record_issue' then
  if length(trim(coalesce(p_data->>'reason','')))<3 then raise exception 'UP_CAR: Descreva a ocorrência.'; end if;
  if coalesce(nullif(trim(p_data->>'issue_type'),''),'')='' then raise exception 'UP_CAR: Selecione a categoria da ocorrência.'; end if;
 elsif p_action='finalize' then
  if d.status not in ('assigned','collected') or d.courier is null then raise exception 'UP_CAR: A OS precisa ter um entregador antes da finalização.'; end if;
  update public.vuppi_deliveries set status='delivered',updated_at=now() where id=d.id returning * into d;
  update public.vuppi_members set is_available=true,updated_at=now() where user_id=d.courier and approved;
 else raise exception 'UP_CAR: Ação administrativa de OS inválida.';
 end if;
 insert into public.up_platform_audit(actor_id,action,target,reason,details)
 values(actor,'delivery_admin_'||p_action,d.id::text,coalesce(nullif(trim(p_data->>'reason'),''),'Gestão da OS pela central'),p_data||jsonb_build_object('status',d.status));
 insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details)
 values(d.id,actor,'admin_'||p_action,p_data||jsonb_build_object('status',d.status));
 return to_jsonb(d);
end;$$;


revoke all on function public.vuppi_admin_manage_delivery(text,uuid,jsonb) from public,anon;
grant execute on function public.vuppi_admin_manage_delivery(text,uuid,jsonb) to authenticated;

commit;

