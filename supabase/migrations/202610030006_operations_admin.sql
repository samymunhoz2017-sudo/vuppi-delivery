-- Central de Operações integrada à Administração VUPPI.
begin;
alter table public.vuppi_members add column if not exists member_status text not null default 'pending';
alter table public.vuppi_members add column if not exists status_reason text;
alter table public.vuppi_members add column if not exists updated_at timestamptz not null default now();
alter table public.vuppi_members drop constraint if exists vuppi_members_member_status_check;
alter table public.vuppi_members add constraint vuppi_members_member_status_check check(member_status in ('pending','active','suspended','inactive'));
update public.vuppi_members set member_status=case when approved then 'active' else 'pending' end where member_status='pending';
create table if not exists public.vuppi_delivery_events(id bigint generated always as identity primary key,delivery_id uuid not null references public.vuppi_deliveries(id) on delete cascade,actor_id uuid references auth.users(id),event_type text not null,details jsonb not null default '{}',created_at timestamptz not null default now());
create index if not exists vuppi_delivery_events_delivery on public.vuppi_delivery_events(delivery_id,created_at desc);
alter table public.vuppi_delivery_events enable row level security;
revoke all on public.vuppi_delivery_events from anon,authenticated;
create or replace function public.vuppi_delivery_admin(p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); target uuid; desired text; reason text;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 if not public.up_platform_is_admin() then raise exception 'UP_CAR: Acesso exclusivo do administrador.'; end if;
 if p_action<>'member_status' then raise exception 'UP_CAR: Ação administrativa desconhecida.'; end if;
 target:=(p_data->>'id')::uuid; desired:=p_data->>'status'; reason:=trim(coalesce(p_data->>'reason',''));
 if desired not in ('pending','active','suspended','inactive') then raise exception 'UP_CAR: Situação inválida.'; end if;
 if length(reason)<3 then raise exception 'UP_CAR: Informe o motivo da alteração.'; end if;
 update public.vuppi_members set member_status=desired,approved=(desired='active'),is_available=case when desired='active' then is_available else false end,status_reason=reason,updated_at=now() where user_id=target;
 if not found then raise exception 'UP_CAR: Cadastro não encontrado.'; end if;
 insert into public.up_platform_audit(actor_id,action,target,reason,details) values(uid,'delivery_member_status',target::text,reason,jsonb_build_object('status',desired));
 return jsonb_build_object('ok',true,'status',desired);
end;$$;
revoke all on function public.vuppi_delivery_admin(text,jsonb) from public,anon;
grant execute on function public.vuppi_delivery_admin(text,jsonb) to authenticated;
commit;
