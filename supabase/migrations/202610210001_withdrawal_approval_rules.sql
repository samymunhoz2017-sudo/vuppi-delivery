-- Vuppi Delivery 0.75.0: revisão de saques conforme os limites financeiros.
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

 select w into wd from public.vuppi_withdrawals w where w.id=p_id for update;
 select wa.city into v_city from public.vuppi_wallets wa where wa.id=wd.wallet_id;

 if wd.id is null or wd.status not in('requested','under_review') then
  raise exception 'VUPPI_FINANCE: Saque não está disponível para aprovação.';
 end if;
 if not public.vuppi_finance_allowed('withdrawal.approve',v_city) or not public.vuppi_finance_step_up() then
  raise exception 'VUPPI_FINANCE: Aprovação reforçada necessária.';
 end if;

 select * into cfg from public.vuppi_finance_settings where city=v_city;
 dual_required:=coalesce(cfg.withdrawal_dual_approval_threshold_cents,0)>0
  and wd.amount_cents>=cfg.withdrawal_dual_approval_threshold_cents;

 if not dual_required then
  update public.vuppi_withdrawals
  set first_approved_by=coalesce(first_approved_by,uid),
      first_approved_at=coalesce(first_approved_at,now()),
      reviewed_by=uid,status='processing'
  where id=wd.id;
  next_status:='processing';
 elsif wd.first_approved_by is null then
  update public.vuppi_withdrawals
  set first_approved_by=uid,first_approved_at=now(),reviewed_by=uid,status='under_review'
  where id=wd.id;
  next_status:='under_review';
 elsif wd.first_approved_by=uid then
  raise exception 'VUPPI_FINANCE: A segunda aprovação deve ser feita por outra pessoa.';
 else
  update public.vuppi_withdrawals
  set second_approved_by=uid,second_approved_at=now(),reviewed_by=uid,status='processing'
  where id=wd.id;
  next_status:='processing';
 end if;

 insert into public.vuppi_financial_audit(actor_id,action,target_type,target_id,city,reason,details)
 values(uid,'withdrawal_review','withdrawal',wd.id::text,v_city,trim(p_reason),
  jsonb_build_object('dual_approval_required',dual_required,'threshold_cents',cfg.withdrawal_dual_approval_threshold_cents,'result_status',next_status));
 return jsonb_build_object('ok',true,'status',next_status,'dual_approval_required',dual_required);
end;
$$;

revoke all on function public.vuppi_withdrawal_review(uuid,text) from public,anon;
grant execute on function public.vuppi_withdrawal_review(uuid,text) to authenticated;
