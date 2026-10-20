-- VUPPI 0.71: central de taxas por perfil e valor liquido do entregador.

create or replace function public.vuppi_finance_settings_admin(p_data jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
 uid uuid:=auth.uid();
 city_id text:=nullif(trim(p_data->>'city'),'');
 before_row public.vuppi_finance_settings;
 saved public.vuppi_finance_settings;
 topup_min bigint; topup_max bigint; withdrawal_min bigint; withdrawal_max bigint;
 topup_fee integer; courier_share integer; withdrawal_fee bigint; release_delay integer;
begin
 if not public.up_platform_is_admin() then raise exception 'UP_CAR: Acesso exclusivo do administrador.'; end if;
 if city_id is null or not exists(select 1 from public.up_cidades where id=city_id) then raise exception 'UP_CAR: Cidade financeira invalida.'; end if;
 insert into public.vuppi_finance_settings(city) values(city_id) on conflict(city) do nothing;
 select * into before_row from public.vuppi_finance_settings where city=city_id for update;

 topup_fee:=coalesce(nullif(p_data->>'topup_fee_bps','')::integer,before_row.topup_fee_bps);
 courier_share:=coalesce(nullif(p_data->>'courier_share_bps','')::integer,before_row.courier_share_bps);
 withdrawal_fee:=coalesce(nullif(p_data->>'withdrawal_fee_cents','')::bigint,before_row.withdrawal_fee_cents);
 topup_min:=coalesce(nullif(p_data->>'min_topup_cents','')::bigint,before_row.min_topup_cents);
 topup_max:=coalesce(nullif(p_data->>'max_topup_cents','')::bigint,before_row.max_topup_cents);
 withdrawal_min:=coalesce(nullif(p_data->>'min_withdrawal_cents','')::bigint,before_row.min_withdrawal_cents);
 withdrawal_max:=coalesce(nullif(p_data->>'max_withdrawal_cents','')::bigint,before_row.max_withdrawal_cents);
 release_delay:=coalesce(nullif(p_data->>'courier_release_delay_minutes','')::integer,before_row.courier_release_delay_minutes);
 if topup_fee not between 0 and 10000 or courier_share not between 0 and 10000 then raise exception 'UP_CAR: Percentual financeiro fora do intervalo permitido.'; end if;
 if withdrawal_fee<0 or topup_min<100 or topup_max<topup_min or withdrawal_min<100 or withdrawal_max<withdrawal_min then raise exception 'UP_CAR: Limites financeiros invalidos.'; end if;
 if release_delay not between 0 and 43200 then raise exception 'UP_CAR: Prazo de liberacao invalido.'; end if;

 update public.vuppi_finance_settings set
  topup_enabled=coalesce((p_data->>'topup_enabled')::boolean,topup_enabled),
  withdrawal_enabled=coalesce((p_data->>'withdrawal_enabled')::boolean,withdrawal_enabled),
  topup_fee_bps=topup_fee,
  topup_fee_mode=case when p_data->>'topup_fee_mode' in('add','deduct') then p_data->>'topup_fee_mode' else topup_fee_mode end,
  withdrawal_fee_cents=withdrawal_fee,
  withdrawal_weekday=greatest(0,least(6,coalesce(nullif(p_data->>'withdrawal_weekday','')::smallint,withdrawal_weekday))),
  min_topup_cents=topup_min,max_topup_cents=topup_max,
  min_withdrawal_cents=withdrawal_min,max_withdrawal_cents=withdrawal_max,
  merchant_minimum_balance_cents=greatest(0,coalesce(nullif(p_data->>'merchant_minimum_balance_cents','')::bigint,merchant_minimum_balance_cents)),
  courier_release_delay_minutes=release_delay,courier_share_bps=courier_share,
  negative_balance_enabled=coalesce((p_data->>'negative_balance_enabled')::boolean,negative_balance_enabled),
  updated_by=uid,updated_at=now()
 where city=city_id returning * into saved;

 insert into public.vuppi_financial_audit(actor_id,action,target_type,target_id,details)
 values(uid,'finance_settings_save','finance_settings',city_id,jsonb_build_object('before',to_jsonb(before_row),'after',to_jsonb(saved),'vuppi_share_bps',10000-saved.courier_share_bps));
 return to_jsonb(saved)||jsonb_build_object('vuppi_share_bps',10000-saved.courier_share_bps);
end;
$$;

create or replace function public.vuppi_courier_financial_rules()
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare m public.vuppi_members; cfg public.vuppi_finance_settings;
begin
 select * into m from public.vuppi_members where user_id=auth.uid() and kind='courier';
 if m.user_id is null then raise exception 'UP_CAR: Perfil de entregador nao encontrado.'; end if;
 select * into cfg from public.vuppi_finance_settings where city=m.city;
 return jsonb_build_object('courier_share_bps',coalesce(cfg.courier_share_bps,8500),'vuppi_share_bps',10000-coalesce(cfg.courier_share_bps,8500),'city',m.city);
end;
$$;

revoke all on function public.vuppi_finance_settings_admin(jsonb),public.vuppi_courier_financial_rules() from public,anon;
grant execute on function public.vuppi_finance_settings_admin(jsonb),public.vuppi_courier_financial_rules() to authenticated;

comment on function public.vuppi_finance_settings_admin(jsonb) is 'Salva todas as taxas e limites por cidade com validacao e auditoria.';
comment on function public.vuppi_courier_financial_rules() is 'Expoe ao entregador somente seu percentual liquido; nunca o custo comercial do estabelecimento.';
