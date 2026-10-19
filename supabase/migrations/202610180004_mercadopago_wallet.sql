-- Checkout Pro Mercado Pago: vinculação da preferência e liquidação idempotente.
begin;

create or replace function public.vuppi_mercadopago_link(p_topup uuid,p_preference_id text,p_checkout_url text,p_live_mode boolean) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare t public.vuppi_topups;
begin
 if p_preference_id is null or length(p_preference_id)>180 or p_checkout_url not like 'https://%' then raise exception 'VUPPI_FINANCE: Preferência de pagamento inválida.';end if;
 select * into t from public.vuppi_topups where id=p_topup for update;if t.id is null then raise exception 'VUPPI_FINANCE: Recarga não encontrada.';end if;
 if t.status not in('pending','awaiting_payment') then raise exception 'VUPPI_FINANCE: Recarga não aceita pagamento.';end if;
 update public.vuppi_topups set provider='mercadopago',provider_reference=p_preference_id,metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('checkout_url',left(p_checkout_url,1000),'preference_id',p_preference_id,'live_mode',p_live_mode) where id=t.id returning * into t;
 return to_jsonb(t);
end;$$;

create or replace function public.vuppi_mercadopago_settle(p_topup uuid,p_payment_id text,p_status text,p_amount_cents bigint,p_currency text,p_live_mode boolean,p_details jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare t public.vuppi_topups;platform_wallet uuid;city_value text;merchant_value uuid;
begin
 select * into t from public.vuppi_topups where id=p_topup for update;if t.id is null then raise exception 'VUPPI_FINANCE: Recarga não encontrada.';end if;
 if t.provider<>'mercadopago' then raise exception 'VUPPI_FINANCE: Provedor da recarga divergente.';end if;
 if p_amount_cents<>t.total_cents or p_currency<>'BRL' then raise exception 'VUPPI_FINANCE: Pagamento divergente da recarga.';end if;
 if coalesce((t.metadata->>'live_mode')::boolean,false) is distinct from p_live_mode then raise exception 'VUPPI_FINANCE: Ambiente do pagamento divergente.';end if;
 if p_status<>'approved' then return jsonb_build_object('ok',true,'settled',false,'status',p_status);end if;
 if t.status='confirmed' then return jsonb_build_object('ok',true,'settled',true,'duplicate',true);end if;
 if t.status not in('pending','awaiting_payment') then raise exception 'VUPPI_FINANCE: Recarga não pode ser confirmada.';end if;
 select w.city,w.owner_id into city_value,merchant_value from public.vuppi_wallets w where w.id=t.wallet_id;
 platform_wallet:=public.vuppi_wallet_ensure('platform',null,city_value,'delivery');
 perform public.vuppi_post_transaction('topup_credit',city_value,t.credit_cents,(select id from public.vuppi_wallet_accounts where wallet_id=platform_wallet and bucket='pending'),(select id from public.vuppi_wallet_accounts where wallet_id=t.wallet_id and bucket='available'),'topup-credit:'||t.id,'Recarga Mercado Pago confirmada',jsonb_build_object('merchant_id',merchant_value,'payment_id',p_payment_id));
 if t.fee_cents>0 then perform public.vuppi_post_transaction('topup_fee',city_value,t.fee_cents,(select id from public.vuppi_wallet_accounts where wallet_id=platform_wallet and bucket='pending'),(select id from public.vuppi_wallet_accounts where wallet_id=platform_wallet and bucket='available'),'topup-fee:'||t.id,'Taxa de recarga Mercado Pago',jsonb_build_object('payment_id',p_payment_id));end if;
 update public.vuppi_topups set status='confirmed',confirmed_at=now(),provider_reference=p_payment_id,metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('payment_id',p_payment_id,'payment',coalesce(p_details,'{}'::jsonb)) where id=t.id;
 insert into public.vuppi_financial_audit(actor_id,action,target_type,target_id,city,details) values(null,'mercadopago_webhook','topup',t.id::text,city_value,jsonb_build_object('payment_id',p_payment_id,'status',p_status));
 return jsonb_build_object('ok',true,'settled',true,'duplicate',false);
end;$$;

revoke all on function public.vuppi_mercadopago_link(uuid,text,text,boolean) from public,anon,authenticated;
revoke all on function public.vuppi_mercadopago_settle(uuid,text,text,bigint,text,boolean,jsonb) from public,anon,authenticated;
grant execute on function public.vuppi_mercadopago_link(uuid,text,text,boolean) to service_role;
grant execute on function public.vuppi_mercadopago_settle(uuid,text,text,bigint,text,boolean,jsonb) to service_role;

commit;
