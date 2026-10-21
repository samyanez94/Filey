-- Keep deleted rows so retries cannot recreate a file with the same upload ID.
alter table public.files drop constraint files_status_check;
alter table public.files add constraint files_status_check
  check(status in ('pending','ready','cancelled','expired','deleted'));

create function public.delete_file(p_owner uuid,p_id uuid)
returns void language plpgsql set search_path = '' as $$
declare item public.files;
begin
  select * into item from public.files where id=p_id and owner_id=p_owner for update;
  if not found then raise exception 'not_found'; end if;
  if item.status='deleted' then return; end if;
  if item.status <> 'ready' then raise exception 'file_not_ready'; end if;
  update public.files set status='deleted',updated_at=now(),cleaned_at=null,
    cleanup_after=greatest(now(),coalesce(last_upload_url_expires_at,now()))+interval '15 minutes'
    where id=p_id;
end $$;
revoke all on function public.delete_file(uuid,uuid) from public,anon,authenticated;
grant execute on function public.delete_file(uuid,uuid) to service_role;

create or replace function public.begin_upload(p_owner uuid, p_id uuid, p_parent uuid, p_name text, p_type text, p_bytes bigint)
returns jsonb language plpgsql set search_path = '' as $$
declare item public.files; created boolean := false;
begin
  -- Serialize globally by file UUID, including requests from different owners.
  perform pg_advisory_xact_lock(hashtextextended(p_id::text, 0));
  select * into item from public.files where id=p_id for update;
  if found then
    if item.owner_id <> p_owner then raise exception 'not_found'; end if;
    if item.parent_id is distinct from p_parent or item.name <> p_name or item.content_type <> p_type or item.byte_count <> p_bytes then raise exception 'upload_conflict'; end if;
    if item.status in ('cancelled','expired','deleted') then raise exception 'upload_%', item.status; end if;
  else
    if p_parent is not null and not exists(select 1 from public.folders where id=p_parent and owner_id=p_owner) then raise exception 'not_found'; end if;
    insert into public.files(id,owner_id,parent_id,name,content_type,byte_count)
    values(p_id,p_owner,p_parent,p_name,p_type,p_bytes) returning * into item;
    created := true;
  end if;
  if item.status='pending' then
    -- Reserve a conservative issuance window BEFORE making a nontransactional Storage call.
    -- Storage targets last two hours; requests are bounded to 30s. Three hours covers issuance.
    update public.files set last_activity_at=now(), updated_at=now(),
      last_upload_url_expires_at=greatest(coalesce(last_upload_url_expires_at, now()), now()+interval '3 hours')
      where id=p_id returning * into item;
  end if;
  return jsonb_build_object('created', created, 'upload', to_jsonb(item));
end $$;

create or replace function public.transition_upload(p_owner uuid,p_id uuid,p_action text)
returns public.files language plpgsql set search_path = '' as $$
declare item public.files;
begin
  select * into item from public.files where id=p_id and owner_id=p_owner for update;
  if not found then raise exception 'not_found'; end if;
  if p_action not in ('complete','cancel','invalid') then raise exception 'invalid_request'; end if;
  if item.status='ready' then
    if p_action <> 'complete' then raise exception 'already_completed'; end if;
    return item;
  end if;
  if item.status in ('cancelled','expired','deleted') then
    if p_action='cancel' and item.status <> 'deleted' then return item; end if;
    raise exception 'upload_%',item.status;
  end if;
  update public.files set
    status=case when p_action='complete' then 'ready' else 'cancelled' end,
    ready_at=case when p_action='complete' then now() else null end,
    updated_at=now(),
    cleanup_after=case when p_action='complete' then null else greatest(now(),coalesce(last_upload_url_expires_at,now()))+interval '15 minutes' end
    where id=p_id returning * into item;
  return item;
end $$;

-- Claim a bounded batch atomically. Failed removals must not monopolize future batches.
create or replace function public.cleanup_candidates(p_limit integer default 100)
returns setof public.files language plpgsql set search_path = '' as $$
begin
  update public.files set status='expired',updated_at=now(),
    cleanup_after=greatest(now(),coalesce(last_upload_url_expires_at,now()))+interval '15 minutes'
    where status='pending' and last_activity_at < now()-interval '24 hours';
  return query
    with candidates as (
      select id from public.files
      where status in ('cancelled','expired','deleted') and cleanup_after <= now()
      order by cleanup_after,id
      limit least(greatest(coalesce(p_limit,100),1),100)
      for update skip locked
    )
    update public.files f set cleanup_after=now()+interval '15 minutes'
    from candidates c where f.id=c.id returning f.*;
end $$;
revoke all on function public.cleanup_candidates(integer) from public,anon,authenticated;
grant execute on function public.cleanup_candidates(integer) to service_role;

create or replace function public.mark_cleaned(p_owner uuid,p_id uuid)
returns void language sql set search_path = '' as $$
  update public.files set cleaned_at=now(),cleanup_after=now()+interval '1 hour'
  where id=p_id and owner_id=p_owner and status in ('cancelled','expired','deleted');
$$;
