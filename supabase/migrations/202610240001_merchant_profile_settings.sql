-- VUPPI 0.79: autonomia segura do estabelecimento.
begin;

create or replace function public.vuppi_update_merchant_profile(p_data jsonb default '{}')
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid();member public.vuppi_members;clean_phone text;clean_email text;next_lat double precision;next_lng double precision;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.';end if;
 select * into member from public.vuppi_members where user_id=uid for update;
 if member.user_id is null or member.kind<>'merchant' or not member.approved then raise exception 'UP_CAR: Estabelecimento ativo não encontrado.';end if;
 clean_phone:=left(trim(coalesce(p_data->>'phone',member.phone)),20);
 if length(regexp_replace(clean_phone,'[^0-9]','','g'))<10 then raise exception 'UP_CAR: Informe um telefone com DDD.';end if;
 clean_email:=nullif(lower(left(trim(coalesce(p_data->>'contact_email',member.contact_email)),254)),'');
 if clean_email is not null and clean_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'UP_CAR: Informe um e-mail de contato válido.';end if;
 next_lat:=coalesce(nullif(p_data->>'lat','')::double precision,member.lat);next_lng:=coalesce(nullif(p_data->>'lng','')::double precision,member.lng);
 if next_lat not between -90 and 90 or next_lng not between -180 and 180 then raise exception 'UP_CAR: Localização do estabelecimento inválida.';end if;
 update public.vuppi_members set
  name=left(trim(coalesce(nullif(p_data->>'name',''),name)),100),phone=clean_phone,
  contact_email=clean_email,address=left(trim(coalesce(nullif(p_data->>'address',''),address)),250),
  cep=left(regexp_replace(coalesce(p_data->>'cep',cep,''),'[^0-9]','','g'),8),
  address_number=left(trim(coalesce(p_data->>'address_number',address_number,'')),20),
  address_complement=left(trim(coalesce(p_data->>'address_complement',address_complement,'')),120),
  district=left(trim(coalesce(p_data->>'district',district,'')),100),
  responsible_name=left(trim(coalesce(p_data->>'responsible_name',responsible_name,'')),120),
  lat=next_lat,lng=next_lng,updated_at=now()
 where user_id=uid returning * into member;
 insert into public.up_platform_audit(actor_id,action,target,reason,details)
 values(uid,'merchant_profile_update',uid::text,'Atualização pelo painel do estabelecimento',jsonb_build_object('fields',(select jsonb_agg(key) from jsonb_object_keys(p_data) key)));
 return to_jsonb(member);
end;$$;

revoke all on function public.vuppi_update_merchant_profile(jsonb) from public,anon;
grant execute on function public.vuppi_update_merchant_profile(jsonb) to authenticated;
commit;
