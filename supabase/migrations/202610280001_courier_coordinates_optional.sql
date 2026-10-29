-- A conta do entregador pode ser analisada antes de obter uma posição GPS.
-- Estabelecimentos continuam obrigados a ter coordenadas de coleta válidas.
begin;
alter table public.vuppi_members alter column lat drop not null;
alter table public.vuppi_members alter column lng drop not null;
do $$ begin
 if not exists(select 1 from pg_constraint where conname='vuppi_members_location_pair' and conrelid='public.vuppi_members'::regclass) then
  alter table public.vuppi_members add constraint vuppi_members_location_pair check ((lat is null) = (lng is null));
 end if;
 if not exists(select 1 from pg_constraint where conname='vuppi_merchants_require_location' and conrelid='public.vuppi_members'::regclass) then
  alter table public.vuppi_members add constraint vuppi_merchants_require_location check (kind <> 'merchant' or (lat is not null and lng is not null));
 end if;
end $$;
commit;
