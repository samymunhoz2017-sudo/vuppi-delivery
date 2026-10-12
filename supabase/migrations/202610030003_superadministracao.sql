-- Incremental. Preparada, NÃO aplicada. Revisar em desenvolvimento primeiro.
begin;
create table public.up_platform_admins (
 user_id uuid primary key references auth.users(id), active boolean not null default false,
 created_at timestamptz not null default now(), granted_by uuid references auth.users(id)
);
create table public.up_platform_audit (
 id bigint generated always as identity primary key, actor_id uuid references auth.users(id),
 action text not null, target text, reason text not null, details jsonb not null default '{}', created_at timestamptz not null default now()
);
alter table public.up_platform_admins enable row level security;
alter table public.up_platform_audit enable row level security;
revoke all on public.up_platform_admins,public.up_platform_audit from anon,authenticated;
create function public.up_platform_is_admin() returns boolean
language sql stable security definer set search_path=public as $$
 select exists(select 1 from up_platform_admins where user_id=auth.uid() and active);
$$;
create policy platform_admin_self on up_platform_admins for select to authenticated using(user_id=auth.uid());
create policy platform_audit_admin on up_platform_audit for select to authenticated using(up_platform_is_admin());
grant select on up_platform_admins,up_platform_audit to authenticated;

-- Gestor global de Carros sem alterar direitos de operadores locais.
create or replace function public.up_car_is_staff(p_city text,p_manage boolean default false) returns boolean
language sql stable security definer set search_path=public,extensions as $$
 select up_platform_is_admin() or exists(select 1 from up_car_staff where user_id=auth.uid() and city_id=p_city and active and (not p_manage or role='manager'));
$$;
create function public.up_platform_status() returns jsonb
language sql stable security definer set search_path=public as $$
 select jsonb_build_object('super_admin',up_platform_is_admin(),'car_staff',case when up_platform_is_admin() then
 coalesce((select jsonb_agg(jsonb_build_object('city_id',city_id,'role','manager','active',true)) from up_car_city_settings),'[]'::jsonb) else '[]'::jsonb end);
$$;
create function public.up_platform_command(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare uid uuid:=auth.uid();target uuid;city text;reason text;result jsonb;offset_n integer;
begin
 if uid is null or not up_platform_is_admin() then raise exception 'UP_CAR: Acesso exclusivo do superadministrador.';end if;
 if p_action='overview' then
  return jsonb_build_object('users',(select count(*) from auth.users),'cities',(select count(*) from up_cidades),'administrators',(select count(*) from up_platform_admins where active),
   'rides',coalesce((select jsonb_object_agg(status,n) from (select status,count(*) n from up_car_rides group by status) counts),'{}'::jsonb),
   'drivers_pending',(select count(*) from up_car_drivers where state in ('analysis','pending')),
   'completed_amount_cents',(select coalesce(sum(price_cents),0) from up_car_rides where status='completed'),
   'delivery_state','local_demo','payments_state','not_integrated');
 end if;
 if p_action='cities' then return coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.nome,'uf',c.uf,'active',c.ativa,'car_enabled',coalesce(s.enabled,false),'car_configured',s.city_id is not null) order by c.nome) from up_cidades c left join up_car_city_settings s on s.city_id=c.id),'[]'::jsonb);end if;
 if p_action='users' then
  offset_n:=greatest(0,least(coalesce((p_data->>'offset')::integer,0),1000000));
  return jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(u)) from (
   select a.id,a.email,a.created_at,a.last_sign_in_at,coalesce(p.full_name,a.raw_user_meta_data->>'full_name','') as name,
   exists(select 1 from up_platform_admins g where g.user_id=a.id and g.active) as super_admin,
   coalesce((select jsonb_agg(jsonb_build_object('city_id',s.city_id,'role',s.role,'active',s.active)) from up_car_staff s where s.user_id=a.id),'[]'::jsonb) as car_roles,
   coalesce((select jsonb_agg(jsonb_build_object('city_id',x.cidade_id,'role',x.papel,'active',x.ativo)) from up_acessos x where x.usuario_id=a.id),'[]'::jsonb) as central_roles
   from auth.users a left join up_car_profiles p on p.user_id=a.id where coalesce(a.email,'') ilike '%'||left(coalesce(p_data->>'search',''),100)||'%' order by a.created_at,a.id limit 50 offset offset_n
  ) u),'[]'::jsonb),'offset',offset_n,'page_size',50);
 end if;
 if p_action='audit' then return coalesce((select jsonb_agg(to_jsonb(a)) from (select id,actor_id,action,target,reason,details,created_at from up_platform_audit order by id desc limit 200) a),'[]'::jsonb);end if;
 if p_action not in ('city_save','grant_superadmin','car_role','central_role') then raise exception 'UP_CAR: Ação administrativa inválida.';end if;
 reason:=trim(coalesce(p_data->>'reason',''));if length(reason) not between 3 and 200 then raise exception 'UP_CAR: Informe motivo entre 3 e 200 caracteres.';end if;
 perform pg_advisory_xact_lock(827001,3);
 if not up_platform_is_admin() then raise exception 'UP_CAR: Permissão administrativa revogada.';end if;
 if p_action='city_save' then
  city:=p_data->>'city_id';if city !~ '^[a-z0-9-]{3,60}$' or length(trim(coalesce(p_data->>'name',''))) not between 2 and 100 or (p_data->>'uf') !~ '^[A-Z]{2}$' then raise exception 'UP_CAR: Dados da cidade inválidos.';end if;
  insert into up_cidades(id,nome,uf,ativa) values(city,trim(p_data->>'name'),p_data->>'uf',coalesce((p_data->>'active')::boolean,false)) on conflict(id) do update set nome=excluded.nome,uf=excluded.uf,ativa=excluded.ativa;
  insert into up_car_city_settings(city_id) values(city) on conflict(city_id) do nothing;
  insert into up_car_categories(city_id,code,name) values(city,'standard','UP Carros') on conflict(city_id,code) do nothing;
 else
  target:=(p_data->>'user_id')::uuid;city:=p_data->>'city_id';
  if not exists(select 1 from auth.users where id=target) then raise exception 'UP_CAR: Conta não encontrada.';end if;
  if p_action='grant_superadmin' then
   if not coalesce((p_data->>'active')::boolean,false) and exists(select 1 from up_platform_admins where user_id=target and active) and (select count(*) from up_platform_admins where active)<=1 then raise exception 'UP_CAR: Não é permitido remover o último superadministrador.';end if;
   insert into up_platform_admins(user_id,active,granted_by) values(target,coalesce((p_data->>'active')::boolean,false),uid) on conflict(user_id) do update set active=excluded.active,granted_by=uid;
  elsif p_action='car_role' then
   if p_data->>'role' not in ('manager','operator') then raise exception 'UP_CAR: Papel de Carros inválido.';end if;
   insert into up_car_staff(user_id,city_id,role,active) values(target,city,p_data->>'role',coalesce((p_data->>'active')::boolean,false)) on conflict(user_id,city_id) do update set role=excluded.role,active=excluded.active;
  elsif p_action='central_role' then
   if p_data->>'role' not in ('master','gestor','central') then raise exception 'UP_CAR: Papel da central inválido.';end if;
   insert into up_acessos(usuario_id,cidade_id,papel,ativo) values(target,city,p_data->>'role',coalesce((p_data->>'active')::boolean,false)) on conflict(usuario_id,cidade_id) do update set papel=excluded.papel,ativo=excluded.ativo;
  end if;
 end if;
 insert into up_platform_audit(actor_id,action,target,reason,details) values(uid,p_action,coalesce(target::text,city),reason,p_data-'reason');
 return jsonb_build_object('saved',true);
end $$;
revoke all on function up_platform_is_admin(),up_platform_status(),up_platform_command(text,jsonb) from public,anon;
grant execute on function up_platform_is_admin(),up_platform_status(),up_platform_command(text,jsonb) to authenticated;
commit;
