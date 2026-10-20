-- All lifecycle mutations are service-only; API handlers supply verified owner IDs.
create domain public.display_name as text check (
  value = btrim(value) and char_length(value) between 1 and 255
  and value not in ('.', '..') and value !~ '[/\\[:cntrl:]]'
);

create table public.folders (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id),
  parent_id uuid,
  name public.display_name not null,
  created_at timestamptz not null default now(),
  unique(owner_id, id),
  foreign key(owner_id, parent_id) references public.folders(owner_id, id),
  check (parent_id is distinct from id)
);
create table public.files (
  id uuid primary key,
  owner_id uuid not null references auth.users(id),
  parent_id uuid,
  name public.display_name not null,
  content_type text not null check(content_type in
    ('image/jpeg','image/png','image/heic','image/heif','application/pdf')),
  byte_count bigint not null check(byte_count between 1 and 20000000),
  storage_key text generated always as (owner_id::text || '/' || id::text || '/original') stored unique,
  status text not null default 'pending' check(status in ('pending','ready','cancelled','expired')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  ready_at timestamptz,
  last_activity_at timestamptz not null default now(),
  last_upload_url_expires_at timestamptz,
  cleanup_after timestamptz,
  cleaned_at timestamptz,
  foreign key(owner_id, parent_id) references public.folders(owner_id, id)
);
create table public.idempotency_requests (
  owner_id uuid not null references auth.users(id),
  operation text not null,
  idempotency_key uuid not null,
  request_payload jsonb not null,
  resource_id uuid not null,
  response_status integer not null default 201,
  created_at timestamptz not null default now(),
  primary key(owner_id, operation, idempotency_key)
);
create index folders_listing on public.folders(owner_id, parent_id, lower(name::text) collate "C", id);
create index files_listing on public.files(owner_id, parent_id, lower(name::text) collate "C", id) where status = 'ready';
create index files_cleanup on public.files(status, cleanup_after);
create index files_activity on public.files(last_activity_at) where status = 'pending';

alter table public.folders enable row level security;
alter table public.files enable row level security;
alter table public.idempotency_requests enable row level security;
revoke all on public.folders, public.files, public.idempotency_requests from anon, authenticated;
grant select on public.folders, public.files to authenticated;
grant all on public.folders, public.files, public.idempotency_requests to service_role;
create policy owned_folders on public.folders for select to authenticated using(owner_id = (select auth.uid()));
create policy ready_owned_files on public.files for select to authenticated using(owner_id = (select auth.uid()) and status = 'ready');

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('files', 'files', false, 20000000, array['image/jpeg','image/png','image/heic','image/heif','application/pdf'])
on conflict(id) do update set public=false, file_size_limit=excluded.file_size_limit, allowed_mime_types=excluded.allowed_mime_types;
-- No storage.objects policies: clients only receive scoped signed URLs.

create function public.create_folder(p_owner uuid, p_key uuid, p_parent uuid, p_name text)
returns jsonb language plpgsql set search_path = '' as $$
declare saved public.idempotency_requests; item public.folders; payload jsonb;
begin
  payload := jsonb_build_object('parent_id', p_parent, 'name', p_name);
  perform pg_advisory_xact_lock(hashtextextended(p_owner::text || p_key::text, 0));
  select * into saved from public.idempotency_requests where owner_id=p_owner and operation='create_folder' and idempotency_key=p_key;
  if found then
    if saved.request_payload <> payload then raise exception 'idempotency_conflict'; end if;
    select * into item from public.folders where id=saved.resource_id and owner_id=p_owner;
    return jsonb_build_object('created', false, 'folder', to_jsonb(item));
  end if;
  if p_parent is not null and not exists(select 1 from public.folders where id=p_parent and owner_id=p_owner) then raise exception 'not_found'; end if;
  insert into public.folders(owner_id,parent_id,name) values(p_owner,p_parent,p_name) returning * into item;
  insert into public.idempotency_requests(owner_id,operation,idempotency_key,request_payload,resource_id)
  values(p_owner,'create_folder',p_key,payload,item.id);
  return jsonb_build_object('created', true, 'folder', to_jsonb(item));
end $$;

create function public.begin_upload(p_owner uuid, p_id uuid, p_parent uuid, p_name text, p_type text, p_bytes bigint)
returns jsonb language plpgsql set search_path = '' as $$
declare item public.files; created boolean := false;
begin
  -- Serialize globally by file UUID, including requests from different owners.
  perform pg_advisory_xact_lock(hashtextextended(p_id::text, 0));
  select * into item from public.files where id=p_id for update;
  if found then
    if item.owner_id <> p_owner then raise exception 'not_found'; end if;
    if item.parent_id is distinct from p_parent or item.name <> p_name or item.content_type <> p_type or item.byte_count <> p_bytes then raise exception 'upload_conflict'; end if;
    if item.status in ('cancelled','expired') then raise exception 'upload_%', item.status; end if;
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

create function public.confirm_upload_target(p_owner uuid,p_id uuid,p_expiry timestamptz)
returns boolean language plpgsql set search_path = '' as $$
begin
  update public.files set last_upload_url_expires_at=greatest(last_upload_url_expires_at,p_expiry)
  where id=p_id and owner_id=p_owner and status='pending';
  return found;
end $$;

create function public.transition_upload(p_owner uuid,p_id uuid,p_action text)
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
  if item.status in ('cancelled','expired') then
    if p_action='cancel' then return item; end if;
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

-- Invoker rights: listings run with the caller's JWT and the table RLS policies.
create function public.list_items(p_parent uuid default null, p_limit integer default 50,
 p_kind integer default null, p_name text default null, p_id uuid default null)
returns jsonb language plpgsql stable set search_path = '' as $$
declare result jsonb;
begin
  if p_limit not between 1 and 100 then raise exception 'invalid_request'; end if;
  if p_parent is not null and not exists(select 1 from public.folders where id=p_parent and owner_id=auth.uid()) then raise exception 'not_found'; end if;
  select coalesce(jsonb_agg(to_jsonb(items) order by sort_kind, sort_name collate "C", id),'[]'::jsonb) into result from (
    select * from (
      select id, 'folder'::text kind, parent_id, name::text, created_at, null::text content_type, null::bigint byte_count,
        0 sort_kind, lower(name::text) collate "C" sort_name from public.folders
        where owner_id=auth.uid() and parent_id is not distinct from p_parent
      union all
      select id, 'file', parent_id, name::text, created_at, content_type, byte_count,
        1, lower(name::text) collate "C" from public.files
        where owner_id=auth.uid() and parent_id is not distinct from p_parent and status='ready'
    ) combined where p_kind is null or (sort_kind,sort_name collate "C",id) > (p_kind,p_name collate "C",p_id)
    order by sort_kind,sort_name collate "C",id limit p_limit+1
  ) items;
  return result;
end $$;

create function public.cleanup_candidates(p_limit integer default 100)
returns setof public.files language plpgsql set search_path = '' as $$
begin
  update public.files set status='expired',updated_at=now(),
    cleanup_after=greatest(now(),coalesce(last_upload_url_expires_at,now()))+interval '15 minutes'
    where status='pending' and last_activity_at < now()-interval '24 hours';
  return query select * from public.files where status in ('cancelled','expired') and cleanup_after <= now()
    order by cleanup_after,id limit least(greatest(p_limit,1),100);
end $$;
create function public.mark_cleaned(p_owner uuid,p_id uuid)
returns void language sql set search_path = '' as $$
  update public.files set cleaned_at=now(),cleanup_after=now()+interval '1 hour'
  where id=p_id and owner_id=p_owner and status in ('cancelled','expired');
$$;

revoke all on function public.create_folder(uuid,uuid,uuid,text),
 public.begin_upload(uuid,uuid,uuid,text,text,bigint),public.confirm_upload_target(uuid,uuid,timestamptz),
 public.transition_upload(uuid,uuid,text),public.cleanup_candidates(integer),public.mark_cleaned(uuid,uuid)
 from public, anon, authenticated;
grant execute on function public.create_folder(uuid,uuid,uuid,text),
 public.begin_upload(uuid,uuid,uuid,text,text,bigint),public.confirm_upload_target(uuid,uuid,timestamptz),
 public.transition_upload(uuid,uuid,text),public.cleanup_candidates(integer),public.mark_cleaned(uuid,uuid)
 to service_role;
revoke all on function public.list_items(uuid,integer,integer,text,uuid) from public,anon;
grant execute on function public.list_items(uuid,integer,integer,text,uuid) to authenticated;
