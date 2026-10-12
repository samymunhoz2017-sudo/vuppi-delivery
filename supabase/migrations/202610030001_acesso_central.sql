-- Aplicar no SQL Editor do projeto Supabase. Não modifica confirmação de e-mail.
-- Cadastros de usuários não geram acesso à central automaticamente.
begin;
create table public.up_cidades (
  id text primary key,
  nome text not null,
  uf text not null check (length(uf) = 2),
  ativa boolean not null default true
);
create table public.up_acessos (
  usuario_id uuid not null references auth.users(id) on delete cascade,
  cidade_id text not null references public.up_cidades(id),
  papel text not null check (papel in ('master','gestor','central')),
  ativo boolean not null default false,
  criado_em timestamptz not null default now(),
  primary key (usuario_id,cidade_id)
);
alter table public.up_cidades enable row level security;
alter table public.up_acessos enable row level security;
revoke all on public.up_cidades, public.up_acessos from anon, authenticated;
grant select on public.up_cidades, public.up_acessos to authenticated;
create policy up_acesso_proprio on public.up_acessos
for select to authenticated using (usuario_id = (select auth.uid()));
create policy up_cidade_autorizada on public.up_cidades
for select to authenticated using (exists (
  select 1 from public.up_acessos a
  where a.cidade_id = up_cidades.id and a.usuario_id = (select auth.uid()) and a.ativo
));
insert into public.up_cidades (id,nome,uf) values ('pitangueiras-sp','Pitangueiras','SP');
comment on table public.up_acessos is 'Permissões gerenciadas pelo administrador no servidor; sem gravação pelo navegador.';
commit;
