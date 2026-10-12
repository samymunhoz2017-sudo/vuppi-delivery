
-- Proximidade de conclusao, antecedencia de despacho e permissao individual.
begin;
alter table public.vuppi_members add column if not exists allow_remote_completion boolean not null default false;
alter table public.vuppi_deliveries add column if not exists dispatch_at timestamptz;
create or replace function public.vuppi_delivery(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); adm boolean:=public.up_platform_is_admin(); m vuppi_members; d vuppi_deliveries; q vuppi_quotes; rider vuppi_members; v_user uuid; v_request_key uuid;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.';end if;
 select * into m from vuppi_members where user_id=uid;
 if p_action='state' then
  return jsonb_build_object('admin',adm,'profile',case when m.user_id is null then null when m.kind='courier' then to_jsonb(m)-array['lat','lng'] else to_jsonb(m) end,
   'cities',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',nome)),'[]') from up_cidades where ativa),
   'members',case when adm then (select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('email',u.email)),'[]') from (select * from vuppi_members order by created_at desc limit 200) x left join auth.users u on u.id=x.user_id) else '[]'::jsonb end,
   'orders',(select coalesce(jsonb_agg(case when adm or x.merchant=uid then to_jsonb(x) else (to_jsonb(x)-array['lat','lng','pickup_lat','pickup_lng'])||jsonb_build_object('pickup_nav','https://www.google.com/maps/dir/?api=1&destination='||x.pickup_lat||','||x.pickup_lng||'&travelmode=driving','delivery_nav','https://www.google.com/maps/dir/?api=1&destination='||x.lat||','||x.lng||'&travelmode=driving') end),'[]') from (select vd.*,cm.name as courier_name from vuppi_deliveries vd left join vuppi_members cm on cm.user_id=vd.courier where adm or vd.merchant=uid or vd.courier=uid order by vd.created_at desc limit 100) x),
   'offers',case when m.kind='courier' and m.approved and m.is_available then (select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (select id,city,merchant_name,pickup_address,destination,distance_m,price_cents,created_at from vuppi_deliveries where status='requested' and city=m.city and coalesce(dispatch_at,scheduled_for,created_at)<=now() order by created_at limit 50) x) else '[]'::jsonb end);
 end if;
 if p_action='admin_register' then
  if not adm then raise exception 'UP_CAR: Acesso exclusivo do administrador.';end if;
  select id into v_user from auth.users where lower(email)=lower(trim(p_data->>'email'));
  if v_user is null then raise exception 'UP_CAR: A conta informada ainda não existe. Peça ao responsável para criar uma conta no aplicativo.';end if;
  if exists(select 1 from vuppi_members where user_id=v_user) then raise exception 'UP_CAR: Essa conta já possui um cadastro de parceiro.';end if;
  if not exists(select 1 from up_cidades where id=p_data->>'city' and ativa) then raise exception 'UP_CAR: Cidade indisponível.';end if;
  insert into vuppi_members(user_id,kind,name,phone,city,address,lat,lng,approved,legal_name,cnpj,contract_number)
   values(v_user,'merchant',trim(p_data->>'name'),p_data->>'phone',p_data->>'city',trim(p_data->>'address'),(p_data->>'lat')::float8,(p_data->>'lng')::float8,coalesce((p_data->>'approved')::boolean,false),nullif(trim(p_data->>'legal_name'),''),nullif(regexp_replace(coalesce(p_data->>'cnpj',''), '[^0-9]','','g'),''),nullif(trim(p_data->>'contract_number'),''));
 elsif p_action='register' then
  if m.user_id is not null then raise exception 'UP_CAR: Cadastro já enviado. Solicite alterações à administração.';end if;
  if not exists(select 1 from up_cidades where id=p_data->>'city' and ativa) then raise exception 'UP_CAR: Cidade indisponível.';end if;
  insert into vuppi_members(user_id,kind,name,phone,city,address,lat,lng) values(uid,p_data->>'kind',trim(p_data->>'name'),p_data->>'phone',p_data->>'city',trim(p_data->>'address'),(p_data->>'lat')::float8,(p_data->>'lng')::float8);
 elsif p_action='availability' then
  if m.user_id is null or m.kind<>'courier' or not m.approved then raise exception 'UP_CAR: Apenas entregadores aprovados podem alterar a disponibilidade.';end if;
  if coalesce((p_data->>'available')::boolean,false) and exists(select 1 from vuppi_deliveries where courier=uid and status in ('assigned','collected')) then raise exception 'UP_CAR: Conclua sua entrega atual antes de ficar disponível.';end if;
  update vuppi_members set is_available=coalesce((p_data->>'available')::boolean,false) where user_id=uid;
 elsif p_action='approve' then
  if not adm then raise exception 'UP_CAR: Acesso exclusivo do administrador.';end if;
  update vuppi_members set approved=coalesce((p_data->>'approved')::boolean,false),is_available=false where user_id=(p_data->>'id')::uuid;
 elsif p_action='create' then
  if m.user_id is null or m.kind<>'merchant' or not m.approved then raise exception 'UP_CAR: Estabelecimento não aprovado.';end if;
  v_request_key:=nullif(p_data->>'client_request_key','')::uuid;
  if v_request_key is not null then
   perform pg_advisory_xact_lock(hashtextextended(uid::text||':'||v_request_key::text,0));
   select * into d from vuppi_deliveries where merchant=uid and client_request_key=v_request_key;
   if d.id is not null then return to_jsonb(d);end if;
  end if;
  select * into q from vuppi_quotes where id=(p_data->>'quote_id')::uuid and merchant=uid for update;
  if q.id is null then raise exception 'UP_CAR: Cotação inválida.';end if;
  select * into d from vuppi_deliveries where quote_id=q.id;
  if d.id is not null then return to_jsonb(d);end if;
  if q.expires_at<now() or q.city<>m.city or not exists(select 1 from up_cidades where id=m.city and ativa) then raise exception 'UP_CAR: Cotação vencida ou cidade indisponível.';end if;
  insert into vuppi_deliveries(quote_id,merchant,city,destination,recipient,phone,lat,lng,pickup_lat,pickup_lng,pickup_address,merchant_name,distance_m,price_cents,client_request_key)
   values(q.id,uid,m.city,trim(p_data->>'destination'),trim(p_data->>'recipient'),p_data->>'phone',q.lat,q.lng,m.lat,m.lng,m.address,m.name,q.distance_m,q.price_cents,v_request_key) returning * into d;
 else
  select * into d from vuppi_deliveries where id=(p_data->>'id')::uuid for update;
  if d.id is null then raise exception 'UP_CAR: Entrega não encontrada.';end if;
  if p_action in ('accept','assign') then
   if p_action='assign' and not adm then raise exception 'UP_CAR: Acesso exclusivo do administrador.';end if;
   select * into rider from vuppi_members where user_id=case when p_action='assign' then (p_data->>'courier')::uuid else uid end for update;
   if rider.user_id is null or rider.kind<>'courier' or not rider.approved or rider.city<>d.city or (p_action='accept' and not rider.is_available) or d.status<>'requested' or not exists(select 1 from up_cidades where id=d.city and ativa) then raise exception 'UP_CAR: Entrega ou entregador indisponível.';end if;
   if exists(select 1 from vuppi_deliveries where courier=rider.user_id and status in ('assigned','collected')) then raise exception 'UP_CAR: Entregador já possui entrega em andamento.';end if;
   update vuppi_deliveries set courier=rider.user_id,status='assigned',updated_at=now() where id=d.id;
   update vuppi_members set is_available=false where user_id=rider.user_id;
  elsif p_action in ('collect','complete') then
   if d.courier is distinct from uid or not coalesce(m.approved,false) or (p_action='collect' and d.status<>'assigned') or (p_action='complete' and d.status<>'collected') then raise exception 'UP_CAR: Etapa não permitida para esta conta.';end if;
   update vuppi_deliveries set status=case when p_action='collect' then 'collected' else 'delivered' end,updated_at=now() where id=d.id;
  elsif p_action='cancel' then
   if not adm and (d.merchant<>uid or d.status<>'requested') or d.status in ('delivered','cancelled') then raise exception 'UP_CAR: Cancelamento não permitido.';end if;
   update vuppi_deliveries set status='cancelled',updated_at=now() where id=d.id;
  else raise exception 'UP_CAR: Ação desconhecida.';
  end if;
 end if;
 insert into up_platform_audit(actor_id,action,target,reason,details) values(uid,'delivery_'||p_action,coalesce(d.id::text,p_data->>'id',uid::text),'Operação no aplicativo VUPPI',jsonb_build_object('city',coalesce(d.city,m.city)));
 return jsonb_build_object('ok',true);
end;$$;
create or replace function public.vuppi_schedule_delivery(p_quote uuid,p_scheduled_for timestamptz,p_lead_minutes integer default 10) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); d public.vuppi_deliveries; lead integer:=greatest(0,least(coalesce(p_lead_minutes,10),120));
begin
 select * into d from public.vuppi_deliveries where quote_id=p_quote for update;
 if d.id is null or (d.merchant<>uid and not public.up_platform_is_admin()) then raise exception 'UP_CAR: Entrega n?o encontrada ou acesso negado.'; end if;
 if p_scheduled_for is not null and p_scheduled_for<now()+interval '10 minutes' then raise exception 'UP_CAR: Programe com pelo menos 10 minutos de anteced?ncia.'; end if;
 update public.vuppi_deliveries set scheduled_for=p_scheduled_for,dispatch_at=p_scheduled_for-make_interval(mins=>lead) where id=d.id returning * into d;
 return to_jsonb(d);
end;$$;
revoke all on function public.vuppi_schedule_delivery(uuid,timestamptz,integer) from public,anon;
grant execute on function public.vuppi_schedule_delivery(uuid,timestamptz,integer) to authenticated;
create or replace function public.vuppi_set_remote_completion(p_courier uuid,p_enabled boolean) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if not public.up_platform_is_admin() then raise exception 'UP_CAR: Acesso exclusivo do administrador.'; end if;
 update public.vuppi_members set allow_remote_completion=coalesce(p_enabled,false),updated_at=now() where user_id=p_courier and kind='courier';
 if not found then raise exception 'UP_CAR: Entregador n?o encontrado.'; end if;
 return jsonb_build_object('ok',true,'enabled',coalesce(p_enabled,false));
end;$$;
revoke all on function public.vuppi_set_remote_completion(uuid,boolean) from public,anon;
grant execute on function public.vuppi_set_remote_completion(uuid,boolean) to authenticated;
create or replace function public.vuppi_complete_delivery(p_delivery uuid,p_lat double precision,p_lng double precision,p_confirm_remote boolean default false) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); d public.vuppi_deliveries; m public.vuppi_members; meters double precision;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 if p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'UP_CAR: Ative uma localiza??o v?lida para concluir.'; end if;
 select * into d from public.vuppi_deliveries where id=p_delivery for update;
 select * into m from public.vuppi_members where user_id=uid;
 if d.id is null or d.courier is distinct from uid or d.status<>'collected' or not coalesce(m.approved,false) then raise exception 'UP_CAR: Etapa n?o permitida para esta conta.'; end if;
 meters:=6371000*2*asin(sqrt(power(sin(radians(d.lat-p_lat)/2),2)+cos(radians(p_lat))*cos(radians(d.lat))*power(sin(radians(d.lng-p_lng)/2),2)));
 if meters>200 and not coalesce(m.allow_remote_completion,false) then raise exception 'UP_CAR: Voce esta a aproximadamente % metros do destino. A conclusao antecipada nao esta liberada pela central.',round(meters); end if;
 if meters>200 and not coalesce(p_confirm_remote,false) then raise exception 'UP_CAR_DISTANCE: %',round(meters); end if;
 update public.vuppi_deliveries set status='delivered',updated_at=now() where id=d.id;
 update public.vuppi_members set lat=p_lat,lng=p_lng,last_active_at=now(),updated_at=now() where user_id=uid;
 insert into public.up_platform_audit(actor_id,action,target,reason,details) values(uid,'delivery_complete',d.id::text,'Conclus?o validada por proximidade',jsonb_build_object('distance_m',round(meters),'remote',meters>200));
 return jsonb_build_object('ok',true,'distance_m',round(meters));
end;$$;
revoke all on function public.vuppi_complete_delivery(uuid,double precision,double precision,boolean) from public,anon;
grant execute on function public.vuppi_complete_delivery(uuid,double precision,double precision,boolean) to authenticated;
commit;

