-- VUPPI DELIVERY: piloto de testes. Nenhuma cobrança ou repasse financeiro.
begin;
create table public.vuppi_members (
 user_id uuid primary key references auth.users(id), kind text not null check(kind in ('merchant','courier')),
 name text not null check(length(name) between 2 and 100), phone text not null check(length(phone) between 10 and 20),
 city text not null references public.up_cidades(id), address text not null check(length(address) between 5 and 250),
 lat double precision not null check(lat between -90 and 90), lng double precision not null check(lng between -180 and 180),
 approved boolean not null default false, created_at timestamptz not null default now()
);
create table public.vuppi_quotes (
 id uuid primary key,merchant uuid not null references public.vuppi_members(user_id),city text not null references public.up_cidades(id),
 lat double precision not null check(lat between -90 and 90),lng double precision not null check(lng between -180 and 180),
 distance_m integer not null check(distance_m between 1 and 30000),price_cents integer not null check(price_cents between 800 and 5000),
 expires_at timestamptz not null,created_at timestamptz not null default now()
);
create table public.vuppi_deliveries (
 id uuid primary key default gen_random_uuid(),quote_id uuid not null unique references public.vuppi_quotes(id),
 merchant uuid not null references public.vuppi_members(user_id),courier uuid references public.vuppi_members(user_id),
 city text not null references public.up_cidades(id),destination text not null check(length(destination) between 5 and 250),
 recipient text not null check(length(recipient) between 2 and 100), phone text not null check(length(phone) between 10 and 20),
 lat double precision not null,lng double precision not null,pickup_lat double precision not null,pickup_lng double precision not null,
 pickup_address text not null,merchant_name text not null,distance_m integer not null,price_cents integer not null,
 status text not null default 'requested' check(status in ('requested','assigned','collected','delivered','cancelled')),
 created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create unique index vuppi_one_active_delivery on public.vuppi_deliveries(courier) where status in ('assigned','collected');
create index vuppi_deliveries_city on public.vuppi_deliveries(city,created_at desc);
alter table public.vuppi_members enable row level security;
alter table public.vuppi_quotes enable row level security;
alter table public.vuppi_deliveries enable row level security;
revoke all on public.vuppi_members,public.vuppi_quotes,public.vuppi_deliveries from anon,authenticated;
grant insert on public.vuppi_quotes to service_role;
-- Todas as leituras e alterações autenticadas passam pela função abaixo.
create function public.vuppi_delivery(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); adm boolean:=public.up_platform_is_admin(); m vuppi_members; d vuppi_deliveries; q vuppi_quotes; rider vuppi_members; result jsonb;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.';end if;
 select * into m from vuppi_members where user_id=uid;
 if p_action='state' then
  return jsonb_build_object('admin',adm,'profile',case when m.user_id is null then null else to_jsonb(m) end,
   'cities',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',nome)),'[]') from up_cidades where ativa),
   'members',case when adm then (select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (select * from vuppi_members order by created_at desc limit 200) x) else '[]'::jsonb end,
   'orders',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (select * from vuppi_deliveries where adm or merchant=uid or courier=uid order by created_at desc limit 100) x),
   'offers',case when m.kind='courier' and m.approved then (select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (select id,city,merchant_name,distance_m,price_cents,created_at from vuppi_deliveries where status='requested' and city=m.city order by created_at limit 50) x) else '[]'::jsonb end);
 end if;
 if p_action='register' then
  if m.user_id is not null then raise exception 'UP_CAR: Cadastro já enviado. Solicite alterações à administração.';end if;
  if not exists(select 1 from up_cidades where id=p_data->>'city' and ativa) then raise exception 'UP_CAR: Cidade indisponível.';end if;
  insert into vuppi_members(user_id,kind,name,phone,city,address,lat,lng) values(uid,p_data->>'kind',trim(p_data->>'name'),p_data->>'phone',p_data->>'city',trim(p_data->>'address'),(p_data->>'lat')::float8,(p_data->>'lng')::float8);
 elsif p_action='approve' then
  if not adm then raise exception 'UP_CAR: Acesso exclusivo do administrador.';end if;
  update vuppi_members set approved=coalesce((p_data->>'approved')::boolean,false) where user_id=(p_data->>'id')::uuid;
 elsif p_action='create' then
  if m.user_id is null or m.kind<>'merchant' or not m.approved then raise exception 'UP_CAR: Estabelecimento não aprovado.';end if;
  select * into q from vuppi_quotes where id=(p_data->>'quote_id')::uuid and merchant=uid for update;
  if q.id is null then raise exception 'UP_CAR: Cotação inválida.';end if;
  select * into d from vuppi_deliveries where quote_id=q.id;
  if d.id is not null then return to_jsonb(d);end if;
  if q.expires_at<now() or q.city<>m.city or not exists(select 1 from up_cidades where id=m.city and ativa) then raise exception 'UP_CAR: Cotação vencida ou cidade indisponível.';end if;
  insert into vuppi_deliveries(quote_id,merchant,city,destination,recipient,phone,lat,lng,pickup_lat,pickup_lng,pickup_address,merchant_name,distance_m,price_cents)
   values(q.id,uid,m.city,trim(p_data->>'destination'),trim(p_data->>'recipient'),p_data->>'phone',q.lat,q.lng,m.lat,m.lng,m.address,m.name,q.distance_m,q.price_cents) returning * into d;
 else
  select * into d from vuppi_deliveries where id=(p_data->>'id')::uuid for update;
  if d.id is null then raise exception 'UP_CAR: Entrega não encontrada.';end if;
  if p_action in ('accept','assign') then
   if p_action='assign' and not adm then raise exception 'UP_CAR: Acesso exclusivo do administrador.';end if;
   select * into rider from vuppi_members where user_id=case when p_action='assign' then (p_data->>'courier')::uuid else uid end for update;
   if rider.user_id is null or rider.kind<>'courier' or not rider.approved or rider.city<>d.city or d.status<>'requested' or not exists(select 1 from up_cidades where id=d.city and ativa) then raise exception 'UP_CAR: Entrega ou entregador indisponível.';end if;
   if exists(select 1 from vuppi_deliveries where courier=rider.user_id and status in ('assigned','collected')) then raise exception 'UP_CAR: Entregador já possui entrega em andamento.';end if;
   update vuppi_deliveries set courier=rider.user_id,status='assigned',updated_at=now() where id=d.id;
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
revoke all on function public.vuppi_delivery(text,jsonb) from public,anon;
grant execute on function public.vuppi_delivery(text,jsonb) to authenticated;
commit;
