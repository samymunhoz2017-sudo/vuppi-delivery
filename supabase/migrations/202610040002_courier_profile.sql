begin;

alter table public.vuppi_members add column if not exists avatar_data text;
alter table public.vuppi_members add column if not exists vehicle_model text;
alter table public.vuppi_members add column if not exists vehicle_plate text;
alter table public.vuppi_members add column if not exists document_cpf text;
alter table public.vuppi_members add column if not exists document_cnh text;

create or replace function public.vuppi_update_courier_profile(p_data jsonb default '{}')
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
 uid uuid:=auth.uid();
 member public.vuppi_members;
 avatar text:=nullif(p_data->>'avatar_data','');
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 select * into member from public.vuppi_members where user_id=uid for update;
 if member.user_id is null or member.kind<>'courier' then raise exception 'UP_CAR: Cadastro de entregador não encontrado.'; end if;
 if avatar is not null and (length(avatar)>550000 or avatar !~ '^data:image/jpeg;base64,') then raise exception 'UP_CAR: Foto inválida ou muito grande.'; end if;
 update public.vuppi_members set
  name=case when p_data ? 'name' then left(trim(p_data->>'name'),100) else name end,
  phone=case when p_data ? 'phone' then left(trim(p_data->>'phone'),20) else phone end,
  address=case when p_data ? 'address' then left(trim(p_data->>'address'),250) else address end,
  vehicle_model=case when p_data ? 'vehicle_model' then left(trim(p_data->>'vehicle_model'),80) else vehicle_model end,
  vehicle_plate=case when p_data ? 'vehicle_plate' then upper(left(regexp_replace(coalesce(p_data->>'vehicle_plate',''),'[^A-Za-z0-9]','','g'),8)) else vehicle_plate end,
  document_cpf=case when p_data ? 'document_cpf' then left(regexp_replace(coalesce(p_data->>'document_cpf',''),'[^0-9]','','g'),11) else document_cpf end,
  document_cnh=case when p_data ? 'document_cnh' then left(regexp_replace(coalesce(p_data->>'document_cnh',''),'[^0-9]','','g'),20) else document_cnh end,
  avatar_data=case when p_data ? 'avatar_data' then avatar else avatar_data end
 where user_id=uid;
 insert into public.up_platform_audit(actor_id,action,target,reason,details)
 values(uid,'courier_profile_update',uid::text,'Atualização pelo aplicativo do entregador',jsonb_build_object('fields',(select jsonb_agg(key) from jsonb_object_keys(p_data) key)));
 return jsonb_build_object('ok',true);
end;
$$;

revoke all on function public.vuppi_update_courier_profile(jsonb) from public;
grant execute on function public.vuppi_update_courier_profile(jsonb) to authenticated;

commit;
