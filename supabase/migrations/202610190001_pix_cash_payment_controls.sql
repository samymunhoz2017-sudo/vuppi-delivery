-- VUPPI 0.70: Pix direto, meios de pagamento por loja e taxa de plataforma no dinheiro.
begin;

alter table public.vuppi_members add column if not exists payment_wallet_enabled boolean not null default true;
alter table public.vuppi_members add column if not exists payment_cash_enabled boolean not null default true;
alter table public.vuppi_members add column if not exists payment_pix_enabled boolean not null default false;
alter table public.vuppi_members add column if not exists payment_credit_enabled boolean not null default false;
alter table public.vuppi_members add column if not exists cash_platform_fee_bps integer;
alter table public.vuppi_members drop constraint if exists vuppi_members_cash_platform_fee_bps_check;
alter table public.vuppi_members add constraint vuppi_members_cash_platform_fee_bps_check check(cash_platform_fee_bps is null or cash_platform_fee_bps between 0 and 10000);

create or replace function public.vuppi_validate_merchant_payment() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare m public.vuppi_members;
begin
 select * into m from public.vuppi_members where user_id=new.merchant and kind='merchant';
 if m.user_id is null then raise exception 'UP_CAR: Estabelecimento inválido.';end if;
 if new.payment_method='wallet' and not m.payment_wallet_enabled then raise exception 'UP_CAR: Carteira de créditos desativada para este estabelecimento.';end if;
 if new.payment_method='cash' and not m.payment_cash_enabled then raise exception 'UP_CAR: Pagamento em dinheiro desativado para este estabelecimento.';end if;
 if new.payment_method='pix' and not m.payment_pix_enabled then raise exception 'UP_CAR: Pagamento Pix na entrega desativado para este estabelecimento.';end if;
 if new.payment_method='credit' and not m.payment_credit_enabled then raise exception 'UP_CAR: Pagamento em cartão desativado para este estabelecimento.';end if;
 return new;
end;$$;
drop trigger if exists vuppi_delivery_validate_payment on public.vuppi_deliveries;
create trigger vuppi_delivery_validate_payment before insert or update of payment_method,merchant on public.vuppi_deliveries
for each row execute function public.vuppi_validate_merchant_payment();

-- Dinheiro é recebido diretamente pelo entregador. A taxa da plataforma vira um
-- débito auditável na carteira dele e pode formar saldo devedor sem bloquear a OS.
create or replace function public.vuppi_post_cash_platform_fee(p_delivery public.vuppi_deliveries,p_fee bigint) returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare tid uuid;cw uuid;pw uuid;debit_id uuid;credit_id uuid;db bigint;cb bigint;
begin
 if p_fee<=0 then return null;end if;
 select id into tid from public.vuppi_financial_transactions where city=p_delivery.city and product='delivery' and idempotency_key='cash-platform-fee:'||p_delivery.id;
 if tid is not null then return tid;end if;
 cw:=public.vuppi_wallet_ensure('courier',p_delivery.courier,p_delivery.city,'delivery');
 pw:=public.vuppi_wallet_ensure('platform',null,p_delivery.city,'delivery');
 select id into debit_id from public.vuppi_wallet_accounts where wallet_id=cw and bucket='available';
 select id into credit_id from public.vuppi_wallet_accounts where wallet_id=pw and bucket='available';
 perform 1 from public.vuppi_wallet_accounts where id in(debit_id,credit_id) order by id for update;
 select balance_cents into db from public.vuppi_wallet_accounts where id=debit_id;
 select balance_cents into cb from public.vuppi_wallet_accounts where id=credit_id;
 insert into public.vuppi_financial_transactions(type,status,city,amount_cents,delivery_id,merchant_id,courier_id,description,metadata,idempotency_key,posted_at)
 values('cash_platform_fee','posted',p_delivery.city,p_fee,p_delivery.id,p_delivery.merchant,p_delivery.courier,'Taxa da plataforma · pagamento em dinheiro',jsonb_build_object('payment_method','cash','allows_fee_debt',true),'cash-platform-fee:'||p_delivery.id,now()) returning id into tid;
 update public.vuppi_wallet_accounts set balance_cents=balance_cents-p_fee,updated_at=now() where id=debit_id;
 update public.vuppi_wallet_accounts set balance_cents=balance_cents+p_fee,updated_at=now() where id=credit_id;
 insert into public.vuppi_ledger_entries(transaction_id,account_id,direction,amount_cents,balance_before_cents,balance_after_cents)
 values(tid,debit_id,'debit',p_fee,db,db-p_fee),(tid,credit_id,'credit',p_fee,cb,cb+p_fee);
 return tid;
end;$$;

create or replace function public.vuppi_delivery_wallet_sync() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare mw uuid;cw uuid;pw uuid;share bigint;margin bigint;fee_bps integer;cfg public.vuppi_finance_settings;reserve_exists boolean;
begin
 if tg_op='INSERT' and new.payment_method<>'wallet' then return new;end if;
 if tg_op='UPDATE' and old.payment_method<>'wallet' and new.payment_method<>'wallet' then
  if old.status is distinct from new.status and new.status='delivered' and new.payment_method='cash' then
   if new.courier is null then raise exception 'VUPPI_FINANCE: Entrega sem entregador não pode ser liquidada.';end if;
   insert into public.vuppi_finance_settings(city) values(new.city) on conflict do nothing;
   select * into cfg from public.vuppi_finance_settings where city=new.city;
   select coalesce(cash_platform_fee_bps,10000-cfg.courier_share_bps) into fee_bps from public.vuppi_members where user_id=new.merchant;
   margin:=floor(new.price_cents*fee_bps::numeric/10000);
   perform public.vuppi_post_cash_platform_fee(new,margin);
  end if;
  return new;
 end if;
 insert into public.vuppi_finance_settings(city) values(new.city) on conflict do nothing;
 select * into cfg from public.vuppi_finance_settings where city=new.city;
 mw:=public.vuppi_wallet_ensure('merchant',new.merchant,new.city,'delivery');pw:=public.vuppi_wallet_ensure('platform',null,new.city,'delivery');
 if tg_op='INSERT' or (tg_op='UPDATE' and old.payment_method<>'wallet' and new.payment_method='wallet') then
  perform public.vuppi_post_transaction('delivery_reserve',new.city,new.price_cents,(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),'delivery-reserve:'||new.id,'Reserva da OS',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant));
 elsif tg_op='UPDATE' and old.payment_method='wallet' and new.payment_method<>'wallet' and old.status not in('delivered','cancelled') then
  perform public.vuppi_post_transaction('delivery_release',new.city,old.price_cents,(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),'delivery-payment-release:'||new.id,'Liberação por troca de pagamento',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant));
 elsif tg_op='UPDATE' and old.status is distinct from new.status and new.status='cancelled' and new.payment_method='wallet' then
  perform public.vuppi_post_transaction('delivery_release',new.city,new.price_cents,(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),'delivery-release:'||new.id,'Liberação por cancelamento',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant));
 elsif tg_op='UPDATE' and old.status is distinct from new.status and new.status='delivered' and new.payment_method='wallet' then
  if new.courier is null then raise exception 'VUPPI_FINANCE: Entrega sem entregador não pode ser liquidada.';end if;
  select exists(select 1 from public.vuppi_financial_transactions where city=new.city and product='delivery' and idempotency_key='delivery-reserve:'||new.id) into reserve_exists;
  if not reserve_exists then perform public.vuppi_post_transaction('delivery_reserve',new.city,new.price_cents,(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),'delivery-reserve:'||new.id,'Reserva reconciliada na conclusão da OS',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant,'reconciled_on_completion',true));end if;
  cw:=public.vuppi_wallet_ensure('courier',new.courier,new.city,'delivery');share:=floor(new.price_cents*cfg.courier_share_bps::numeric/10000);margin:=new.price_cents-share;
  if share>0 then perform public.vuppi_post_transaction('delivery_courier_credit',new.city,share,(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),(select id from public.vuppi_wallet_accounts where wallet_id=cw and bucket=case when cfg.courier_release_delay_minutes>0 then 'pending'::public.vuppi_balance_bucket else 'available'::public.vuppi_balance_bucket end),'delivery-courier:'||new.id,'Crédito da entrega',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant,'courier_id',new.courier));end if;
  if margin>0 then perform public.vuppi_post_transaction('delivery_platform_revenue',new.city,margin,(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),(select id from public.vuppi_wallet_accounts where wallet_id=pw and bucket='available'),'delivery-margin:'||new.id,'Receita da entrega',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant,'courier_id',new.courier));end if;
 end if;
 return new;
end;$$;

revoke all on function public.vuppi_post_cash_platform_fee(public.vuppi_deliveries,bigint),public.vuppi_validate_merchant_payment() from public,anon,authenticated;
commit;
