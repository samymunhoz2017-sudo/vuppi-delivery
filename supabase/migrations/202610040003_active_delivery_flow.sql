begin;

create or replace function public.vuppi_restore_courier_availability() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if new.courier is not null
    and new.status in ('delivered','cancelled')
    and old.status is distinct from new.status
    and not exists (
      select 1 from public.vuppi_deliveries d
      where d.courier=new.courier and d.id<>new.id and d.status in ('assigned','collected')
    ) then
   update public.vuppi_members
      set is_available=true
    where user_id=new.courier and kind='courier' and approved=true;
 end if;
 return new;
end;$$;

drop trigger if exists vuppi_restore_courier_availability_trigger on public.vuppi_deliveries;
create trigger vuppi_restore_courier_availability_trigger
after update of status on public.vuppi_deliveries
for each row execute function public.vuppi_restore_courier_availability();

revoke all on function public.vuppi_restore_courier_availability() from public,anon,authenticated;
commit;
