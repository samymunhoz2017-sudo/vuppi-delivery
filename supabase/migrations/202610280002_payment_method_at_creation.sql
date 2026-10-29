begin;

-- Aplica a forma escolhida antes da validação e da reserva financeira.
create or replace function public.vuppi_validate_merchant_payment() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare m public.vuppi_members; requested_payment text;
begin
 if tg_op='INSERT' then
  requested_payment:=nullif(current_setting('vuppi.requested_payment_method',true),'');
  if requested_payment is not null then new.payment_method:=requested_payment;end if;
 end if;
 select * into m from public.vuppi_members where user_id=new.merchant and kind='merchant';
 if m.user_id is null then raise exception 'UP_CAR: Estabelecimento inválido.';end if;
 if new.payment_method='wallet' and not m.payment_wallet_enabled then raise exception 'UP_CAR: Carteira de créditos desativada para este estabelecimento.';end if;
 if new.payment_method='cash' and not m.payment_cash_enabled then raise exception 'UP_CAR: Pagamento em dinheiro desativado para este estabelecimento.';end if;
 if new.payment_method='pix' and not m.payment_pix_enabled then raise exception 'UP_CAR: Pagamento Pix na entrega desativado para este estabelecimento.';end if;
 if new.payment_method='credit' and not m.payment_credit_enabled then raise exception 'UP_CAR: Pagamento em cartão desativado para este estabelecimento.';end if;
 return new;
end;$$;

create or replace function public.vuppi_create_delivery_transaction(p_data jsonb) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare d public.vuppi_deliveries; scheduled_at timestamptz; lead integer;
begin
 if auth.uid() is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 if nullif(p_data->>'quote_id','') is null then raise exception 'UP_CAR: Cotação não informada.'; end if;
 scheduled_at:=nullif(p_data->>'scheduled_for','')::timestamptz;
 lead:=greatest(0,least(coalesce(nullif(p_data->>'dispatch_lead_minutes','')::integer,0),120));
 if scheduled_at is not null and scheduled_at<=now()+interval '5 seconds' then
  raise exception 'UP_CAR: Escolha um horário futuro para chamar o entregador.';
 end if;
 if coalesce(nullif(p_data->>'payment_method',''),'pix') not in ('wallet','cash','pix','credit') then raise exception 'UP_CAR: Forma de pagamento inválida.';end if;
 perform set_config('vuppi.requested_payment_method',coalesce(nullif(p_data->>'payment_method',''),'pix'),true);
 if public.up_platform_is_admin() and nullif(p_data->>'merchant','') is not null then
  perform public.vuppi_admin_create_delivery(p_data);
 else
  perform public.vuppi_delivery('create',p_data);
 end if;
 perform set_config('vuppi.requested_payment_method','',true);
 perform public.vuppi_delivery_details((p_data->>'quote_id')::uuid,p_data);
 select * into d from public.vuppi_deliveries where quote_id=(p_data->>'quote_id')::uuid for update;
 if d.id is null then raise exception 'UP_CAR: Não foi possível concluir a criação da entrega.';end if;
 if scheduled_at is not null then
  update public.vuppi_deliveries set scheduled_for=scheduled_at,dispatch_at=scheduled_at-make_interval(mins=>lead),updated_at=now() where id=d.id returning * into d;
 else
  update public.vuppi_deliveries set scheduled_for=null,dispatch_at=coalesce(dispatch_at,now()),updated_at=now() where id=d.id returning * into d;
 end if;
 return to_jsonb(d);
end;$$;

commit;
