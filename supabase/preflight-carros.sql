-- SOMENTE LEITURA. Execute antes de comparar/aplicar qualquer migração.
select current_database(), current_user, version();
select extname, n.nspname as schema from pg_extension e join pg_namespace n on n.oid=e.extnamespace where extname in ('postgis','pgcrypto');
select table_name,column_name,data_type from information_schema.columns where table_schema='public' and (table_name like 'up_%' or table_name ilike '%delivery%') order by table_name,ordinal_position;
select schemaname,tablename,policyname,permissive,roles,cmd,qual,with_check from pg_policies where schemaname in ('public','storage','realtime') order by schemaname,tablename,policyname;
select n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) as arguments from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'up_%';
select id,name,public,file_size_limit,allowed_mime_types from storage.buckets;
-- Confirme separadamente no painel o ambiente e faça backup. Esta consulta não
-- identifica com segurança se o banco é de produção. Não publica dados de usuários.
