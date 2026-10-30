-- Materializa apenas grupos ainda não aceitos. Não movimenta carteiras.
begin;
create function public.vuppi_route_prepare_group(p_route uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); anchor public.vuppi_deliveries; route public.vuppi_route_operations; merchant_profile public.vuppi_members;
 stop record; n integer; needs_return boolean; fee bigint; distinct_fees integer; gross bigint:=0; seq integer:=0;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_route::text,0));
 select * into anchor from public.vuppi_deliveries where route_group_id=p_route order by id limit 1;
 if anchor.id is null then raise exception 'UP_CAR: Grupo não encontrado.'; end if;
 if uid is distinct from anchor.merchant and not coalesce(public.up_platform_is_admin(),false) then raise exception 'UP_CAR: Rota não autorizada.'; end if;
 if uid=anchor.merchant and not exists(select 1 from public.vuppi_members where user_id=uid and kind='merchant' and approved and member_status='active') then raise exception 'UP_CAR: Estabelecimento indisponível.'; end if;
 select * into route from public.vuppi_route_operations where id=p_route;
 if route.id is not null then return jsonb_build_object('ok',true,'already_prepared',true,'route_id',p_route,'state',route.state); end if;
 perform 1 from public.vuppi_deliveries where route_group_id=p_route order by id for update;
 select count(*),bool_or(return_required) into n,needs_return from public.vuppi_deliveries where route_group_id=p_route;
 if n<2 or n>24 then raise exception 'UP_CAR: O grupo precisa ter entre 2 e 24 entregas.'; end if;
 if exists(select 1 from public.vuppi_deliveries where route_group_id=p_route and
  (merchant is distinct from anchor.merchant or city is distinct from anchor.city or payment_method is distinct from anchor.payment_method or courier is not null or status not in ('requested','pending'))) then
  raise exception 'UP_CAR: O grupo possui entregas aceitas ou dados de loja, cidade ou pagamento incompatíveis.';
 end if;
 if exists(select 1 from public.vuppi_deliveries d left join public.vuppi_quotes q on q.id=d.quote_id where d.route_group_id=p_route and
  (q.id is null or d.price_cents<0 or (d.return_required and coalesce(q.pricing_snapshot->>'return_cents','') !~ '^[0-9]{1,9}$'))) then
  raise exception 'UP_CAR: Há cotação ou snapshot de retorno ausente.';
 end if;
 select count(distinct (q.pricing_snapshot->>'return_cents')::bigint),coalesce(max((q.pricing_snapshot->>'return_cents')::bigint),0)
  into distinct_fees,fee from public.vuppi_deliveries d join public.vuppi_quotes q on q.id=d.quote_id where d.route_group_id=p_route and d.return_required;
 if distinct_fees>1 then raise exception 'UP_CAR: Taxas de retorno diferentes exigem revisão administrativa.'; end if;
 select * into merchant_profile from public.vuppi_members where user_id=anchor.merchant and kind='merchant';
 if needs_return and nullif(trim(merchant_profile.address),'') is null then raise exception 'UP_CAR: Endereço de retorno do estabelecimento não está configurado.'; end if;
 insert into public.vuppi_route_operations(id,merchant_id,city,state,requires_return,return_fee_cents,return_address,return_lat,return_lng)
 values(p_route,anchor.merchant,anchor.city,'dispatching',coalesce(needs_return,false),fee,case when needs_return then merchant_profile.address end,case when needs_return then merchant_profile.lat end,case when needs_return then merchant_profile.lng end);
 for stop in select d.*,q.pricing_snapshot from public.vuppi_deliveries d join public.vuppi_quotes q on q.id=d.quote_id
  where d.route_group_id=p_route order by coalesce(d.route_sequence,2147483647),d.created_at,d.id
 loop
  seq:=seq+1;
  insert into public.vuppi_route_stops(route_id,delivery_id,kind,sequence,frozen_price_cents,frozen_return_cents,tariff_snapshot)
  values(p_route,stop.id,'delivery',seq,stop.price_cents,case when stop.return_required then (stop.pricing_snapshot->>'return_cents')::bigint else 0 end,stop.pricing_snapshot);
  gross:=gross+stop.price_cents-case when stop.return_required then (stop.pricing_snapshot->>'return_cents')::bigint else 0 end;
 end loop;
 if needs_return then insert into public.vuppi_route_stops(route_id,kind,sequence) values(p_route,'return',seq+1); end if;
 return jsonb_build_object('ok',true,'already_prepared',false,'route_id',p_route,'state','dispatching','delivery_count',n,'requires_return',needs_return,'return_fee_cents',fee,'gross_cents',gross+fee);
end;$$;
revoke all on function public.vuppi_route_prepare_group(uuid) from public,anon;
grant execute on function public.vuppi_route_prepare_group(uuid) to authenticated;
commit;
