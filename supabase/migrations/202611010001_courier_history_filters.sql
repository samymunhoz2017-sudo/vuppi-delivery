begin;
create or replace function public.vuppi_courier_day_history(p_date date) returns jsonb
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); result jsonb; share integer;
begin
 if uid is null or not exists(select 1 from public.vuppi_members where user_id=uid and kind='courier') then raise exception 'Acesso exclusivo do entregador.'; end if;
 if p_date is null or p_date > (now() at time zone 'America/Sao_Paulo')::date then raise exception 'Data inválida.'; end if;
 select greatest(0,least(10000,coalesce((public.vuppi_courier_financial_rules()->>'courier_share_bps')::integer,8500))) into share;
 select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'external_order_number',d.external_order_number,'status',d.status,'created_at',d.created_at,'updated_at',d.updated_at,'merchant_name',d.merchant_name,'pickup_address',d.pickup_address,'destination',d.destination,'recipient',d.recipient,'phone',d.phone,'notes',d.notes,'route_group_id',d.route_group_id,'route_sequence',d.route_sequence,'return_required',d.return_required,'price_cents',floor(greatest(0,coalesce(d.price_cents,0))*share/10000.0)) order by d.created_at desc),'[]'::jsonb) into result from public.vuppi_deliveries d where d.courier=uid and d.created_at >= (p_date::timestamp at time zone 'America/Sao_Paulo') and d.created_at < ((p_date+1)::timestamp at time zone 'America/Sao_Paulo');
 return result;
end;$$;
create or replace function public.vuppi_courier_statement_period(p_period text) returns jsonb
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); start_day date; end_day date:=(now() at time zone 'America/Sao_Paulo')::date+1; result jsonb;
begin
 if uid is null or not exists(select 1 from public.vuppi_members where user_id=uid and kind='courier') then raise exception 'Acesso exclusivo do entregador.'; end if;
 case p_period when 'today' then start_day:=end_day-1; when 'yesterday' then start_day:=end_day-2;end_day:=end_day-1; when '7days' then start_day:=end_day-7; when '30days' then start_day:=end_day-30; else raise exception 'Período inválido.'; end case;
 select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into result from (select e.id,e.direction,e.amount_cents,e.created_at,t.type,t.description,t.status,t.delivery_id,t.id transaction_id from public.vuppi_ledger_entries e join public.vuppi_wallet_accounts a on a.id=e.account_id join public.vuppi_wallets w on w.id=a.wallet_id join public.vuppi_financial_transactions t on t.id=e.transaction_id where w.owner_id=uid and w.owner_type='courier' and w.product='delivery' and e.created_at >= (start_day::timestamp at time zone 'America/Sao_Paulo') and e.created_at < (end_day::timestamp at time zone 'America/Sao_Paulo') order by e.created_at desc) x;
 return result;
end;$$;
revoke all on function public.vuppi_courier_day_history(date),public.vuppi_courier_statement_period(text) from public,anon;
grant execute on function public.vuppi_courier_day_history(date),public.vuppi_courier_statement_period(text) to authenticated;
commit;
