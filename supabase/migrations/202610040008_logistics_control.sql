create table if not exists public.vuppi_operation_settings(
 id text primary key default 'default', dispatch_lead_minutes integer not null default 10,
 pickup_deadline_minutes integer not null default 10, offer_radius_km integer not null default 15,
 route_grouping_enabled boolean not null default true, multi_pickup_enabled boolean not null default false,
 max_group_deliveries integer not null default 3, completion_radius_m integer not null default 250,
 confirm_outside_radius boolean not null default true, single_active_delivery boolean not null default true,
 updated_at timestamptz not null default now(), updated_by uuid
);
insert into public.vuppi_operation_settings(id) values('default') on conflict do nothing;
create table if not exists public.vuppi_delivery_types(
 code text primary key, name text not null, description text not null default '', enabled boolean not null default true,
 priority integer not null default 10, updated_at timestamptz not null default now(), updated_by uuid
);
insert into public.vuppi_delivery_types(code,name,description,enabled,priority) values
 ('standard','Entrega padrão','Coleta no estabelecimento e entrega direta ao cliente.',true,10),
 ('express','Entrega expressa','Prioridade maior na fila de despacho.',true,1),
 ('scheduled','Entrega agendada','Disparo automático conforme a antecedência configurada.',true,20),
 ('grouped','Rota agrupada','Duas ou mais entregas organizadas em uma única rota.',true,15)
on conflict(code) do nothing;
alter table public.vuppi_operation_settings enable row level security;
alter table public.vuppi_delivery_types enable row level security;
create or replace function public.vuppi_logistics_admin(p_action text,p_data jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare s vuppi_operation_settings; t vuppi_delivery_types;
begin
 if not public.up_platform_is_admin() then raise exception 'UP_CAR: Acesso exclusivo do administrador.'; end if;
 if p_action='state' then return jsonb_build_object('settings',(select to_jsonb(x) from vuppi_operation_settings x where id='default'),'types',coalesce((select jsonb_agg(to_jsonb(x) order by priority,name) from vuppi_delivery_types x),'[]'::jsonb)); end if;
 if p_action='save_settings' then
  update vuppi_operation_settings set dispatch_lead_minutes=greatest(0,least(120,coalesce((p_data->>'dispatch_lead_minutes')::int,10))),pickup_deadline_minutes=greatest(1,least(120,coalesce((p_data->>'pickup_deadline_minutes')::int,10))),offer_radius_km=greatest(1,least(50,coalesce((p_data->>'offer_radius_km')::int,15))),route_grouping_enabled=coalesce((p_data->>'route_grouping_enabled')::boolean,true),multi_pickup_enabled=coalesce((p_data->>'multi_pickup_enabled')::boolean,false),max_group_deliveries=greatest(1,least(10,coalesce((p_data->>'max_group_deliveries')::int,3))),completion_radius_m=greatest(30,least(5000,coalesce((p_data->>'completion_radius_m')::int,250))),confirm_outside_radius=coalesce((p_data->>'confirm_outside_radius')::boolean,true),single_active_delivery=coalesce((p_data->>'single_active_delivery')::boolean,true),updated_at=now(),updated_by=auth.uid() where id='default' returning * into s;
  return jsonb_build_object('ok',true,'settings',to_jsonb(s));
 end if;
 if p_action='save_type' then
  update vuppi_delivery_types set enabled=coalesce((p_data->>'enabled')::boolean,enabled),priority=greatest(1,least(99,coalesce((p_data->>'priority')::int,priority))),updated_at=now(),updated_by=auth.uid() where code=p_data->>'code' returning * into t;
  if t.code is null then raise exception 'UP_CAR: Tipo de entrega não encontrado.'; end if; return jsonb_build_object('ok',true,'type',to_jsonb(t));
 end if;
 raise exception 'UP_CAR: Ação logística inválida.';
end;$$;
grant execute on function public.vuppi_logistics_admin(text,jsonb) to authenticated;
