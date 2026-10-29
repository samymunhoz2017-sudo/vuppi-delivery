begin;
-- O comprovante fica no mesmo armazenamento privado da chave Pix, protegido por RLS.
alter table public.vuppi_withdrawal_payout_secrets add column if not exists receipt_mime text;
alter table public.vuppi_withdrawal_payout_secrets add column if not exists receipt_base64 text;

create or replace function public.vuppi_guard_manual_withdrawal() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if old.status is distinct from new.status and coalesce(old.metadata->>'manual_claimed_by','')<>'' and coalesce(current_setting('vuppi.manual_withdrawal_record',true),'')<>'on' then raise exception 'VUPPI_FINANCE: Saque reservado para processamento manual.';end if;
 return new;
end;$$;
do $$ begin if not exists(select 1 from pg_trigger where tgrelid='public.vuppi_withdrawals'::regclass and tgname='vuppi_guard_manual_withdrawal' and not tgisinternal) then create trigger vuppi_guard_manual_withdrawal before update of status on public.vuppi_withdrawals for each row execute function public.vuppi_guard_manual_withdrawal(); end if; end $$;
revoke all on function public.vuppi_guard_manual_withdrawal() from public,anon,authenticated;

create or replace function public.vuppi_withdrawal_review(p_id uuid,p_reason text)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
 uid uuid:=auth.uid();
 wd public.vuppi_withdrawals;
 cfg public.vuppi_finance_settings;
 v_city text;
 dual_required boolean:=false;
 next_status text;
begin
 if uid is null then raise exception 'VUPPI_FINANCE: Entre para continuar.';end if;
 if length(trim(coalesce(p_reason,'')))<3 then raise exception 'VUPPI_FINANCE: Informe o motivo da aprovação.';end if;

 select w.* into wd from public.vuppi_withdrawals w where w.id=p_id for update;
 if wd.id is null or wd.status not in('requested','under_review') then
  raise exception 'VUPPI_FINANCE: Saque não está disponível para aprovação.';
 end if;
 if coalesce(wd.metadata->>'manual_claimed_by','')<>'' and coalesce(current_setting('vuppi.manual_withdrawal_record',true),'')<>'on' then raise exception 'VUPPI_FINANCE: Saque reservado para processamento manual.';end if;
 select wa.city into v_city from public.vuppi_wallets wa where wa.id=wd.wallet_id;
 if not public.vuppi_finance_allowed('withdrawal.approve',v_city) then
  raise exception 'VUPPI_FINANCE: Permissão para aprovar saque necessária.';
 end if;
 -- A matriz já passou pela autenticação e autorização administrativa do portal.
 -- Operadores financeiros delegados continuam obrigados a usar AAL2.
 if not public.up_platform_is_admin() and not public.vuppi_finance_step_up() then
  raise exception 'VUPPI_FINANCE: Autenticação reforçada necessária.';
 end if;

 select * into cfg from public.vuppi_finance_settings where city=v_city;
 dual_required:=coalesce(cfg.withdrawal_dual_approval_threshold_cents,0)>0
  and wd.amount_cents>=cfg.withdrawal_dual_approval_threshold_cents;

 if not dual_required then
  update public.vuppi_withdrawals
  set first_approved_by=coalesce(first_approved_by,uid),
      first_approved_at=coalesce(first_approved_at,now()),
      reviewed_by=uid,status='processing',reason=trim(p_reason)
  where id=wd.id;
  next_status:='processing';
 elsif wd.first_approved_by is null then
  update public.vuppi_withdrawals
  set first_approved_by=uid,first_approved_at=now(),reviewed_by=uid,
      status='under_review',reason=trim(p_reason)
  where id=wd.id;
  next_status:='under_review';
 elsif wd.first_approved_by=uid then
  raise exception 'VUPPI_FINANCE: A segunda aprovação deve ser feita por outra pessoa.';
 else
  update public.vuppi_withdrawals
  set second_approved_by=uid,second_approved_at=now(),reviewed_by=uid,
      status='processing',reason=trim(p_reason)
  where id=wd.id;
  next_status:='processing';
 end if;

 insert into public.vuppi_financial_audit(actor_id,action,target_type,target_id,city,reason,details)
 values(uid,'withdrawal_review','withdrawal',wd.id::text,v_city,trim(p_reason),
  jsonb_build_object('dual_approval_required',dual_required,'threshold_cents',cfg.withdrawal_dual_approval_threshold_cents,'result_status',next_status));
 return jsonb_build_object('ok',true,'status',next_status,'dual_approval_required',dual_required);
end;
$$;


create or replace function public.vuppi_withdrawal_reject(p_id uuid,p_reason text)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
 uid uuid:=auth.uid();
 wd public.vuppi_withdrawals;
 v_city text;
 available_account uuid;
 reserved_account uuid;
begin
 if uid is null then raise exception 'VUPPI_FINANCE: Entre para continuar.';end if;
 if length(trim(coalesce(p_reason,'')))<5 then raise exception 'VUPPI_FINANCE: Informe o motivo da recusa.';end if;
 select w.* into wd from public.vuppi_withdrawals w where w.id=p_id for update;
 if wd.id is null or wd.status not in('requested','under_review') then
  raise exception 'VUPPI_FINANCE: Saque não está disponível para recusa.';
 end if;
 if coalesce(wd.metadata->>'manual_claimed_by','')<>'' and coalesce(current_setting('vuppi.manual_withdrawal_record',true),'')<>'on' then raise exception 'VUPPI_FINANCE: Saque reservado para processamento manual.';end if;
 select wa.city into v_city from public.vuppi_wallets wa where wa.id=wd.wallet_id;
 if not public.vuppi_finance_allowed('withdrawal.approve',v_city) then
  raise exception 'VUPPI_FINANCE: Permissão para recusar saque necessária.';
 end if;
 if not public.up_platform_is_admin() and not public.vuppi_finance_step_up() then
  raise exception 'VUPPI_FINANCE: Autenticação reforçada necessária.';
 end if;
 select id into available_account from public.vuppi_wallet_accounts where wallet_id=wd.wallet_id and bucket='available';
 select id into reserved_account from public.vuppi_wallet_accounts where wallet_id=wd.wallet_id and bucket='reserved';
 perform public.vuppi_post_transaction('withdrawal_rejected',v_city,wd.amount_cents,reserved_account,available_account,
  'withdrawal-rejected:'||wd.id,'Saque recusado',jsonb_build_object('reason',trim(p_reason),'courier_id',wd.requested_by));
 update public.vuppi_withdrawals
 set status='rejected',reviewed_by=uid,reason=trim(p_reason),processed_at=now()
 where id=wd.id;
 insert into public.vuppi_financial_audit(actor_id,action,target_type,target_id,city,reason,details)
 values(uid,'withdrawal_reject','withdrawal',wd.id::text,v_city,trim(p_reason),
  jsonb_build_object('amount_cents',wd.amount_cents,'balance_restored',true));
 return jsonb_build_object('ok',true,'status','rejected','balance_restored',true);
end;
$$;

create or replace function public.vuppi_manual_withdrawal_detail(p_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare w public.vuppi_withdrawals; s public.vuppi_withdrawal_payout_secrets; city_id text; cfg public.vuppi_finance_settings;
begin
 select * into w from public.vuppi_withdrawals where id=p_id for update;
 if w.id is null then raise exception 'VUPPI_FINANCE: Saque não encontrado.'; end if;
 select city into city_id from public.vuppi_wallets where id=w.wallet_id;
 if auth.uid() is null or not public.vuppi_finance_allowed('withdrawal.approve',city_id) or (not public.up_platform_is_admin() and not public.vuppi_finance_step_up()) then raise exception 'VUPPI_FINANCE: Acesso não autorizado.'; end if;
 select * into cfg from public.vuppi_finance_settings where city=city_id;
 if coalesce(cfg.withdrawal_dual_approval_threshold_cents,0)>0 and w.amount_cents>=cfg.withdrawal_dual_approval_threshold_cents then raise exception 'VUPPI_FINANCE: Saque exige dupla aprovação e não está disponível para transferência manual.';end if;
 select * into s from public.vuppi_withdrawal_payout_secrets where withdrawal_id=w.id;
 if s.withdrawal_id is null then raise exception 'VUPPI_FINANCE: Chave Pix integral indisponível. Recuse e solicite um novo saque.';end if;
 if w.status not in ('requested','under_review') or w.provider_reference is not null or coalesce(w.metadata->>'submitted_at','')<>'' then raise exception 'VUPPI_FINANCE: Saque não elegível para pagamento manual; verifique possíveis transferências em andamento.';end if;
 if coalesce(w.metadata->>'manual_claimed_by','')<>'' and w.metadata->>'manual_claimed_by'<>auth.uid()::text then raise exception 'VUPPI_FINANCE: Outro administrador já iniciou este pagamento manual.';end if;
 update public.vuppi_withdrawals set metadata=metadata||jsonb_build_object('manual_claimed_by',auth.uid(),'manual_claimed_at',now()) where id=w.id;
 return jsonb_build_object('id',w.id,'net_cents',w.net_cents,'pix_key',s.pix_key,'pix_type',s.pix_type,'status',w.status);
end;$$;

create or replace function public.vuppi_manual_withdrawal_record(p_id uuid,p_reference text,p_mime text,p_content text) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare w public.vuppi_withdrawals; city_id text; platform_wallet uuid; reserved_id uuid; review jsonb;
begin
 if length(trim(coalesce(p_reference,'')))<5 or length(p_reference)>150 then raise exception 'VUPPI_FINANCE: Informe a referência do comprovante.';end if;
 if p_mime not in ('image/jpeg','image/png','application/pdf') or length(coalesce(p_content,''))<16 or length(p_content)>700000 or p_content !~ '^[A-Za-z0-9+/]+={0,2}$' then raise exception 'VUPPI_FINANCE: Comprovante inválido.';end if;
 perform pg_advisory_xact_lock(hashtextextended('manual-pix:'||trim(p_reference),0));
 select * into w from public.vuppi_withdrawals where id=p_id for update;
 if w.id is null then raise exception 'VUPPI_FINANCE: Saque não encontrado.';end if;
 select city into city_id from public.vuppi_wallets where id=w.wallet_id;
 if auth.uid() is null or not public.vuppi_finance_allowed('withdrawal.approve',city_id) or (not public.up_platform_is_admin() and not public.vuppi_finance_step_up()) then raise exception 'VUPPI_FINANCE: Acesso não autorizado.'; end if;
 if w.status='paid' and w.provider='manual' and w.provider_reference=trim(p_reference) then return jsonb_build_object('ok',true,'status','paid');end if;
 if exists(select 1 from public.vuppi_withdrawals where id<>w.id and status='paid' and provider='manual' and provider_reference=trim(p_reference)) then raise exception 'VUPPI_FINANCE: Referência já utilizada em outro saque.';end if;
 if w.status not in ('requested','under_review') or w.provider_reference is not null or coalesce(w.metadata->>'submitted_at','')<>'' then raise exception 'VUPPI_FINANCE: Transferência automática pode estar em andamento; não registre manualmente.';end if;
 if coalesce(w.metadata->>'manual_claimed_by','')<>auth.uid()::text then raise exception 'VUPPI_FINANCE: Inicie a revisão manual antes de registrar o pagamento.';end if;
 if not exists(select 1 from public.vuppi_withdrawal_payout_secrets where withdrawal_id=w.id) then raise exception 'VUPPI_FINANCE: Chave Pix integral não disponível.';end if;
 perform set_config('vuppi.manual_withdrawal_record','on',true);
 review:=public.vuppi_withdrawal_review(w.id,'Pagamento manual confirmado: '||left(trim(p_reference),100));
 if review->>'status'<>'processing' then raise exception 'VUPPI_FINANCE: Saque precisa de segunda aprovação antes da liquidação manual.';end if;
 select * into w from public.vuppi_withdrawals where id=p_id for update;
 select id into reserved_id from public.vuppi_wallet_accounts where wallet_id=w.wallet_id and bucket='reserved';
 platform_wallet:=public.vuppi_wallet_ensure('platform',null,city_id,'delivery');
 update public.vuppi_withdrawal_payout_secrets set receipt_mime=p_mime,receipt_base64=p_content where withdrawal_id=w.id;
 perform public.vuppi_post_transaction('withdrawal_paid',city_id,w.net_cents,reserved_id,(select id from public.vuppi_wallet_accounts where wallet_id=platform_wallet and bucket='pending'),'withdrawal-paid:'||w.id,'Saque pago manualmente',jsonb_build_object('courier_id',w.requested_by,'provider','manual'));
 if w.fee_cents>0 then perform public.vuppi_post_transaction('withdrawal_fee',city_id,w.fee_cents,reserved_id,(select id from public.vuppi_wallet_accounts where wallet_id=platform_wallet and bucket='available'),'withdrawal-fee:'||w.id,'Taxa de saque','{}');end if;
 update public.vuppi_withdrawals set status='paid',provider='manual',provider_reference=trim(p_reference),processed_at=now(),reviewed_by=auth.uid(),metadata=metadata||jsonb_build_object('manual_receipt',true,'settled_at',now()) where id=w.id;
 perform set_config('vuppi.manual_withdrawal_record','',true);

 insert into public.vuppi_financial_audit(actor_id,action,target_type,target_id,city,reason,details) values(auth.uid(),'withdrawal_manual_paid','withdrawal',w.id::text,city_id,'Transferência manual confirmada',jsonb_build_object('reference',trim(p_reference)));
 return jsonb_build_object('ok',true,'status','paid');
end;$$;

create or replace function public.vuppi_manual_withdrawal_receipt(p_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare w public.vuppi_withdrawals; r public.vuppi_withdrawal_payout_secrets; city_id text;
begin
 select * into w from public.vuppi_withdrawals where id=p_id and status='paid';
 if w.id is null or auth.uid() is null then raise exception 'VUPPI_FINANCE: Comprovante indisponível.';end if;
 select city into city_id from public.vuppi_wallets where id=w.wallet_id;
 if w.requested_by<>auth.uid() and not public.vuppi_finance_allowed('withdrawal.approve',city_id) then raise exception 'VUPPI_FINANCE: Acesso não autorizado.';end if;
 select * into r from public.vuppi_withdrawal_payout_secrets where withdrawal_id=w.id;
 if r.withdrawal_id is null or r.receipt_base64 is null then raise exception 'VUPPI_FINANCE: Comprovante indisponível.';end if;
 return jsonb_build_object('mime_type',r.receipt_mime,'content_base64',r.receipt_base64,'reference',w.provider_reference,'created_at',r.created_at);
end;$$;
create or replace function public.vuppi_manual_withdrawal_release(p_id uuid,p_reason text) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare w public.vuppi_withdrawals; city_id text;
begin
 select * into w from public.vuppi_withdrawals where id=p_id for update;
 if w.id is null or w.status not in ('requested','under_review') then raise exception 'VUPPI_FINANCE: Saque indisponível.';end if;
 select city into city_id from public.vuppi_wallets where id=w.wallet_id;
 if auth.uid() is null or not public.vuppi_finance_allowed('withdrawal.approve',city_id) or (not public.up_platform_is_admin() and not public.vuppi_finance_step_up()) then raise exception 'VUPPI_FINANCE: Acesso não autorizado.';end if;
 if length(trim(coalesce(p_reason,'')))<5 then raise exception 'VUPPI_FINANCE: Informe por que não houve transferência.';end if;
 if coalesce(w.metadata->>'manual_claimed_by','')='' then return jsonb_build_object('ok',true);end if;
 update public.vuppi_withdrawals set metadata=metadata-'manual_claimed_by'-'manual_claimed_at' where id=w.id;
 insert into public.vuppi_financial_audit(actor_id,action,target_type,target_id,city,reason) values(auth.uid(),'withdrawal_manual_release','withdrawal',w.id::text,city_id,trim(p_reason));
 return jsonb_build_object('ok',true);
end;$$;
revoke all on function public.vuppi_manual_withdrawal_release(uuid,text),public.vuppi_manual_withdrawal_detail(uuid),public.vuppi_manual_withdrawal_record(uuid,text,text,text),public.vuppi_manual_withdrawal_receipt(uuid) from public,anon;
grant execute on function public.vuppi_manual_withdrawal_release(uuid,text),public.vuppi_manual_withdrawal_detail(uuid),public.vuppi_manual_withdrawal_record(uuid,text,text,text),public.vuppi_manual_withdrawal_receipt(uuid) to authenticated;
commit;
