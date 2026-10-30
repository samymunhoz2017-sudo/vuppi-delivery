begin;

create or replace function public.vuppi_collect_group_at_pickup(p_delivery uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); anchor public.vuppi_deliveries; stop public.vuppi_deliveries; collected uuid[]:=array[]::uuid[];
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 select * into anchor from public.vuppi_deliveries where id=p_delivery;
 if anchor.id is null or anchor.courier is distinct from uid or anchor.status<>'assigned' or anchor.pickup_arrived_at is null then
  raise exception 'UP_CAR: Confirme a chegada ao estabelecimento antes da coleta.';
 end if;
 perform pg_advisory_xact_lock(hashtextextended(coalesce(anchor.route_group_id,anchor.id)::text,0));
 for stop in select * from public.vuppi_deliveries d
  where d.courier=uid and d.status='assigned' and
   (d.id=anchor.id or (anchor.route_group_id is not null and d.route_group_id=anchor.route_group_id
    and d.merchant=anchor.merchant and d.pickup_address=anchor.pickup_address))
  order by d.id for update
 loop
  if stop.pickup_arrived_at is null then perform public.vuppi_delivery_pickup_arrive(stop.id); end if;
  perform public.vuppi_delivery('collect',jsonb_build_object('id',stop.id));
  collected:=array_append(collected,stop.id);
 end loop;
 if not anchor.id=any(collected) then raise exception 'UP_CAR: Esta coleta já foi alterada. Atualize e tente novamente.'; end if;
 return jsonb_build_object('ok',true,'collected_ids',to_jsonb(collected),'count',cardinality(collected));
end;$$;
revoke all on function public.vuppi_collect_group_at_pickup(uuid) from public,anon;
grant execute on function public.vuppi_collect_group_at_pickup(uuid) to authenticated;
commit;
