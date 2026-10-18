-- Corrige o estado da precificação para o schema real de cidades (nome/ativa).
begin;

create or replace function public.vuppi_pricing_admin(p_action text,p_data jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare t public.vuppi_delivery_tariffs;merchant_id uuid;city_id text;distance_value integer;result jsonb;
begin
 if not public.up_platform_is_admin() then raise exception 'UP_CAR: Acesso exclusivo do administrador.'; end if;
 if p_action='state' then
  return jsonb_build_object(
   'tariffs',coalesce((select jsonb_agg(to_jsonb(x) order by city,merchant nulls first) from public.vuppi_delivery_tariffs x),'[]'::jsonb),
   'cities',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.nome,'uf',c.uf,'active',c.ativa) order by c.nome) from public.up_cidades c),'[]'::jsonb),
   'merchants',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'name',m.name,'city',m.city) order by m.name) from public.vuppi_members m where m.kind='merchant' and m.approved),'[]'::jsonb)
  );
 end if;
 city_id:=nullif(trim(p_data->>'city'),'');merchant_id:=nullif(p_data->>'merchant','')::uuid;
 if p_action='test' then
  distance_value:=round(coalesce((p_data->>'distance_m')::numeric,0))::integer;
  if merchant_id is null then select user_id into merchant_id from public.vuppi_members where kind='merchant' and approved and city=city_id order by created_at limit 1; end if;
  if merchant_id is null then raise exception 'VUPPI_PRICE: Selecione um estabelecimento aprovado para simular.'; end if;
  return public.vuppi_calculate_delivery_price(merchant_id,city_id,distance_value,coalesce((p_data->>'return_required')::boolean,false));
 end if;
 if p_action='save' then
  if city_id is null then raise exception 'VUPPI_PRICE: Selecione a cidade.'; end if;
  if merchant_id is not null and not exists(select 1 from public.vuppi_members where user_id=merchant_id and kind='merchant' and city=city_id) then raise exception 'VUPPI_PRICE: O estabelecimento não pertence à cidade selecionada.'; end if;
  if merchant_id is null then
   insert into public.vuppi_delivery_tariffs(city,merchant,name,enabled,base_distance_m,base_cents,additional_step_m,additional_step_cents,minimum_cents,maximum_distance_m,return_cents,updated_by)
   values(city_id,null,left(coalesce(nullif(trim(p_data->>'name'),''),'Tarifa padrão'),80),coalesce((p_data->>'enabled')::boolean,true),
    (p_data->>'base_distance_m')::integer,(p_data->>'base_cents')::integer,(p_data->>'additional_step_m')::integer,
    (p_data->>'additional_step_cents')::integer,(p_data->>'minimum_cents')::integer,(p_data->>'maximum_distance_m')::integer,
    (p_data->>'return_cents')::integer,auth.uid())
   on conflict(city) where merchant is null do update set name=excluded.name,enabled=excluded.enabled,version=vuppi_delivery_tariffs.version+1,
    base_distance_m=excluded.base_distance_m,base_cents=excluded.base_cents,additional_step_m=excluded.additional_step_m,
    additional_step_cents=excluded.additional_step_cents,minimum_cents=excluded.minimum_cents,maximum_distance_m=excluded.maximum_distance_m,
    return_cents=excluded.return_cents,updated_at=now(),updated_by=auth.uid()
   returning * into t;
  else
   insert into public.vuppi_delivery_tariffs(city,merchant,name,enabled,base_distance_m,base_cents,additional_step_m,additional_step_cents,minimum_cents,maximum_distance_m,return_cents,updated_by)
   values(city_id,merchant_id,left(coalesce(nullif(trim(p_data->>'name'),''),'Tarifa personalizada'),80),coalesce((p_data->>'enabled')::boolean,true),
    (p_data->>'base_distance_m')::integer,(p_data->>'base_cents')::integer,(p_data->>'additional_step_m')::integer,
    (p_data->>'additional_step_cents')::integer,(p_data->>'minimum_cents')::integer,(p_data->>'maximum_distance_m')::integer,
    (p_data->>'return_cents')::integer,auth.uid())
   on conflict(city,merchant) where merchant is not null do update set name=excluded.name,enabled=excluded.enabled,version=vuppi_delivery_tariffs.version+1,
    base_distance_m=excluded.base_distance_m,base_cents=excluded.base_cents,additional_step_m=excluded.additional_step_m,
    additional_step_cents=excluded.additional_step_cents,minimum_cents=excluded.minimum_cents,maximum_distance_m=excluded.maximum_distance_m,
    return_cents=excluded.return_cents,updated_at=now(),updated_by=auth.uid()
   returning * into t;
  end if;
  insert into public.up_platform_audit(actor_id,action,target,reason,details) values(auth.uid(),'delivery_pricing_save',t.id::text,'Configuração de tarifa',to_jsonb(t));
  return jsonb_build_object('ok',true,'tariff',to_jsonb(t));
 end if;
 if p_action='delete_override' then
  if merchant_id is null then raise exception 'VUPPI_PRICE: A tarifa padrão da cidade não pode ser excluída.'; end if;
  delete from public.vuppi_delivery_tariffs where city=city_id and merchant=merchant_id returning * into t;
  if t.id is null then raise exception 'VUPPI_PRICE: Tarifa personalizada não encontrada.'; end if;
  insert into public.up_platform_audit(actor_id,action,target,reason,details) values(auth.uid(),'delivery_pricing_delete',t.id::text,'Remoção de tarifa personalizada',to_jsonb(t));
  return jsonb_build_object('ok',true);
 end if;
 raise exception 'VUPPI_PRICE: Ação de precificação inválida.';
end;$$;

revoke all on function public.vuppi_pricing_admin(text,jsonb) from public,anon;
grant execute on function public.vuppi_pricing_admin(text,jsonb) to authenticated;

commit;

