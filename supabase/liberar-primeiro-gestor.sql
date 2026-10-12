-- Depois de cadastrar sua conta, substitua SEU_EMAIL_AQUI pelo seu e-mail.
-- Execute apenas no SQL Editor do Supabase, com sua sessão administrativa.
-- Esta liberação não depende de dados de perfil fornecidos pelo navegador.
do $$
declare usuario uuid;
begin
  select id into usuario from auth.users where lower(email) = lower('SEU_EMAIL_AQUI');
  if usuario is null then
    raise exception 'Conta não encontrada. Cadastre a conta antes de liberar o acesso.';
  end if;
  insert into public.up_acessos (usuario_id,cidade_id,papel,ativo)
  values (usuario,'pitangueiras-sp','gestor',true)
  on conflict (usuario_id,cidade_id) do update set papel='gestor',ativo=true;
end $$;
