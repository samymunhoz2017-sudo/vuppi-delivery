-- Após validar o ambiente e aplicar a migração, substitua o e-mail.
-- Apenas administrador do banco. Não libera outras cidades nem Delivery.
begin;
do $$ declare target uuid; begin
 select id into target from auth.users where lower(email)=lower('SUBSTITUA_PELO_EMAIL_DO_GESTOR');
 if target is null then raise exception 'Informe o e-mail de uma conta existente.'; end if;
 insert into public.up_car_staff(user_id,city_id,role,active) values(target,'pitangueiras-sp','manager',true)
 on conflict(user_id,city_id) do update set role='manager',active=true;
end $$;
commit;
