-- API-key clients never access application tables directly. Preserve existing data/owners.
revoke all on public.folders, public.files, public.idempotency_requests from anon, authenticated;
drop policy if exists owned_folders on public.folders;
drop policy if exists ready_owned_files on public.files;
revoke all on function public.list_items(uuid,integer,integer,text,uuid) from public, anon, authenticated;

create function public.list_demo_items(p_owner uuid, p_parent uuid default null, p_limit integer default 50,
 p_kind integer default null, p_name text default null, p_id uuid default null)
returns jsonb language plpgsql stable set search_path = '' as $$
declare result jsonb;
begin
  if p_limit not between 1 and 100 then raise exception 'invalid_request'; end if;
  if p_parent is not null and not exists(select 1 from public.folders where id=p_parent and owner_id=p_owner) then raise exception 'not_found'; end if;
  select coalesce(jsonb_agg(to_jsonb(items) order by sort_kind, sort_name collate "C", id),'[]'::jsonb) into result from (
    select * from (
      select id, 'folder'::text kind, parent_id, name::text, created_at, null::text content_type, null::bigint byte_count,
        0 sort_kind, lower(name::text) collate "C" sort_name from public.folders
        where owner_id=p_owner and parent_id is not distinct from p_parent
      union all
      select id, 'file', parent_id, name::text, created_at, content_type, byte_count,
        1, lower(name::text) collate "C" from public.files
        where owner_id=p_owner and parent_id is not distinct from p_parent and status='ready'
    ) combined where p_kind is null or (sort_kind,sort_name collate "C",id) > (p_kind,p_name collate "C",p_id)
    order by sort_kind,sort_name collate "C",id limit p_limit+1
  ) items;
  return result;
end $$;
revoke all on function public.list_demo_items(uuid,uuid,integer,integer,text,uuid) from public, anon, authenticated;
grant execute on function public.list_demo_items(uuid,uuid,integer,integer,text,uuid) to service_role;
