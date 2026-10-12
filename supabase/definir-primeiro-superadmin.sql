-- Execução exclusiva por administrador confiável do banco, após revisar ambiente.
-- Substitua o UUID pela identidade de SUA conta autenticada. E-mail isolado não
-- prova titularidade quando confirmação de e-mail está desativada.
-- Não existe endpoint público para obter o primeiro acesso administrativo.
begin;
do $$ declare target uuid:='00000000-0000-0000-0000-000000000000';begin
 perform pg_advisory_xact_lock(827001,3);
 if exists(select 1 from public.up_platform_admins where active) then raise exception 'Superadmin já definido. Use o painel de permissões.';end if;
 if not exists(select 1 from auth.users where id=target) then raise exception 'Informe o UUID verificado da sua conta.';end if;
 if not exists(select 1 from auth.users where id=target and lower(email)='samymunhoz2017@gmail.com') then raise exception 'A conta escolhida não corresponde ao titular informado.';end if;
 insert into public.up_platform_admins(user_id,active) values(target,true);
 insert into public.up_platform_audit(actor_id,action,target,reason) values(target,'bootstrap_superadmin',target::text,'Titular da plataforma definido pelo administrador do banco');
end $$;
commit;
