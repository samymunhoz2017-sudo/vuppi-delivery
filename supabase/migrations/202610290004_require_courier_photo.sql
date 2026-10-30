begin;
create or replace function public.vuppi_require_courier_photo_on_approval()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
 if new.kind='courier' and new.approved and new.member_status='active'
    and (tg_op='INSERT' or old.approved is distinct from new.approved or old.member_status is distinct from new.member_status or coalesce(old.avatar_data,'') <> '')
    and coalesce(new.avatar_data,'') !~ '^data:image/jpeg;base64,.' then
  raise exception 'UP_CAR: O entregador precisa cadastrar uma foto do rosto antes da aprovação.';
 end if;
 return new;
end;$$;
drop trigger if exists vuppi_require_courier_photo_on_approval on public.vuppi_members;
create trigger vuppi_require_courier_photo_on_approval before insert or update of approved,member_status,avatar_data on public.vuppi_members
 for each row execute function public.vuppi_require_courier_photo_on_approval();
revoke all on function public.vuppi_require_courier_photo_on_approval() from public,anon,authenticated;
commit;
