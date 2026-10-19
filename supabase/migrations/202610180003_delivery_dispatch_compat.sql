-- Restaura a coluna usada pelo despacho e pela leitura de estado do app.
begin;

alter table public.vuppi_deliveries
  add column if not exists dispatch_at timestamptz;

update public.vuppi_deliveries
set dispatch_at=coalesce(scheduled_for,created_at)
where dispatch_at is null;

create index if not exists vuppi_deliveries_dispatch_due_idx
  on public.vuppi_deliveries(city,dispatch_at,created_at)
  where status='requested';

commit;
