begin;
alter table public.vuppi_quotes alter column id set default gen_random_uuid();
create or replace function public.vuppi_create_quote(p_data jsonb) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $fn$
declare uid uuid:=auth.uid(); target uuid:=auth.uid(); adm boolean:=public.up_platform_is_admin(); m vuppi_members; q vuppi_quotes; dist integer;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 if adm and nullif(p_data->>'merchant','') is not null then target:=(p_data->>'merchant')::uuid; end if;
 select * into m from vuppi_members where user_id=target and kind='merchant';
 if m.user_id is null or not m.approved or (adm and not m.quick_delivery_enabled) then raise exception 'UP_CAR: Estabelecimento n?o aprovado ou modalidade indispon?vel.'; end if;
 if not adm and target<>uid then raise exception 'UP_CAR: Estabelecimento inv?lido.'; end if;
 dist:=(p_data->>'distance_m')::integer;
 if dist<=0 or dist>30000 then raise exception 'UP_CAR: Dist?ncia fora da ?rea permitida.'; end if;
 insert into vuppi_quotes(id,merchant,city,lat,lng,distance_m,price_cents,expires_at) values(gen_random_uuid(),target,m.city,(p_data->>'lat')::float8,(p_data->>'lng')::float8,dist,800+ceil(greatest(0,dist-2000)::numeric/1000)::integer*150,now()+interval '5 minutes') returning * into q;
 return to_jsonb(q);
end;
$fn$;
grant execute on function public.vuppi_create_quote(jsonb) to authenticated;
commit;
