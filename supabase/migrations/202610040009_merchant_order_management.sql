-- Ferramentas do estabelecimento: edição, despacho direto, junção e ordem de rota.
begin;
alter table public.vuppi_deliveries add column if not exists route_group_id uuid;
alter table public.vuppi_deliveries add column if not exists route_sequence integer;

create or replace function public.vuppi_merchant_manage_delivery(p_action text,p_delivery uuid default null,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); d public.vuppi_deliveries; rider public.vuppi_members; ids uuid[]; group_id uuid:=gen_random_uuid(); requested_at timestamptz; lead integer; assigned_count integer;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 if not exists(select 1 from public.vuppi_members where user_id=uid and kind='merchant' and approved) then raise exception 'UP_CAR: Acesso exclusivo do estabelecimento aprovado.'; end if;
 if p_action='couriers' then
  select * into d from public.vuppi_deliveries where id=p_delivery and merchant=uid;
  if d.id is null then raise exception 'UP_CAR: Entrega não encontrada.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'name',m.name,'is_available',m.is_available) order by m.is_available desc,m.name)
    from public.vuppi_members m where m.kind='courier' and m.approved and m.city=d.city),'[]'::jsonb);
 end if;
 if p_action='join' then
  select array_agg(value::uuid) into ids from jsonb_array_elements_text(coalesce(p_data->'ids','[]'::jsonb));
  if coalesce(array_length(ids,1),0)<2 then raise exception 'UP_CAR: Selecione pelo menos duas entregas.'; end if;
  if exists(select 1 from unnest(ids) x left join public.vuppi_deliveries v on v.id=x where v.id is null or v.merchant<>uid or v.status not in ('requested','assigned')) then raise exception 'UP_CAR: Uma das entregas não pode ser agrupada.'; end if;
  select count(distinct courier) into assigned_count from public.vuppi_deliveries where id=any(ids) and courier is not null;
  if assigned_count>1 then raise exception 'UP_CAR: Não é possível juntar entregas aceitas por entregadores diferentes.'; end if;
  update public.vuppi_deliveries set route_group_id=group_id,route_sequence=x.seq,updated_at=now()
   from (select id,row_number() over(order by coalesce(scheduled_for,created_at),created_at)::int seq from public.vuppi_deliveries where id=any(ids)) x where vuppi_deliveries.id=x.id;
  insert into public.up_platform_audit(actor_id,action,target,reason,details) values(uid,'delivery_join',group_id::text,'Rotas agrupadas pelo estabelecimento',jsonb_build_object('deliveries',ids));
  return jsonb_build_object('ok',true,'route_group_id',group_id,'count',array_length(ids,1));
 end if;
 select * into d from public.vuppi_deliveries where id=p_delivery and merchant=uid for update;
 if d.id is null then raise exception 'UP_CAR: Entrega não encontrada.'; end if;
 if p_action='assign' then
  if d.status<>'requested' then raise exception 'UP_CAR: Somente entregas aguardando aceite podem receber um entregador.'; end if;
  select * into rider from public.vuppi_members where user_id=(p_data->>'courier')::uuid for update;
  if rider.user_id is null or rider.kind<>'courier' or not rider.approved or not rider.is_available or rider.city<>d.city then raise exception 'UP_CAR: Entregador indisponível.'; end if;
  if exists(select 1 from public.vuppi_deliveries where courier=rider.user_id and status in ('assigned','collected')) then raise exception 'UP_CAR: Entregador já possui uma entrega em andamento.'; end if;
  update public.vuppi_deliveries set courier=rider.user_id,status='assigned',updated_at=now() where id=d.id;
  update public.vuppi_members set is_available=false,updated_at=now() where user_id=rider.user_id;
 elsif p_action='edit' then
  if d.status<>'requested' then raise exception 'UP_CAR: A edição fica disponível antes do aceite do entregador.'; end if;
  lead:=greatest(0,least(99,coalesce(nullif(p_data->>'dispatch_minutes','')::int,10)));
  if p_data->>'dispatch_mode'='schedule' then requested_at:=nullif(p_data->>'scheduled_for','')::timestamptz;
  elsif p_data->>'dispatch_mode'='minutes' then requested_at:=now()+make_interval(mins=>lead);
  else requested_at:=null; end if;
  if requested_at is not null and requested_at<now()+interval '1 minute' then raise exception 'UP_CAR: Escolha um horário futuro para o despacho.'; end if;
  update public.vuppi_deliveries set recipient=left(trim(coalesce(p_data->>'recipient',recipient)),100),phone=left(trim(coalesce(p_data->>'phone',phone)),30),
   external_order_number=nullif(left(trim(p_data->>'external_order_number'),60),''),notes=nullif(left(trim(p_data->>'notes'),500),''),scheduled_for=requested_at,
   dispatch_at=case when requested_at is null then null else requested_at end,updated_at=now() where id=d.id;
 elsif p_action='optimize' then
  if d.route_group_id is null then update public.vuppi_deliveries set route_group_id=group_id,route_sequence=1,updated_at=now() where id=d.id;
  else
   select array_agg(value::uuid) into ids from jsonb_array_elements_text(coalesce(p_data->'ordered_ids','[]'::jsonb));
   if coalesce(array_length(ids,1),0)<>(select count(*) from public.vuppi_deliveries where route_group_id=d.route_group_id) or
      exists(select 1 from unnest(ids) x left join public.vuppi_deliveries v on v.id=x where v.id is null or v.route_group_id<>d.route_group_id or v.merchant<>uid)
   then raise exception 'UP_CAR: A sequência otimizada é inválida.'; end if;
   update public.vuppi_deliveries set route_sequence=x.seq,updated_at=now()
   from (select id,ord::int seq from unnest(ids) with ordinality as t(id,ord)) x where vuppi_deliveries.id=x.id;
  end if;
 else raise exception 'UP_CAR: Operação desconhecida.';
 end if;
 insert into public.up_platform_audit(actor_id,action,target,reason,details) values(uid,'merchant_delivery_'||p_action,d.id::text,'Gestão do pedido pelo estabelecimento',coalesce(p_data,'{}'::jsonb));
 return jsonb_build_object('ok',true);
end;$$;
revoke all on function public.vuppi_merchant_manage_delivery(text,uuid,jsonb) from public,anon;
grant execute on function public.vuppi_merchant_manage_delivery(text,uuid,jsonb) to authenticated;
commit;
