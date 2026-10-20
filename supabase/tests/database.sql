begin;
-- Transactional assertions need no pgTAP dependency and leave no fixtures behind.
do $$
declare owner uuid := gen_random_uuid(); other uuid := gen_random_uuid(); folder uuid; file_id uuid := gen_random_uuid(); item public.files;
begin
  insert into auth.users(id) values(owner),(other);
  insert into public.folders(owner_id,name) values(owner,'Owned') returning id into folder;
  begin
    insert into public.files(id,owner_id,parent_id,name,content_type,byte_count) values(file_id,other,folder,'Bad','application/pdf',1);
    raise exception 'cross-owner parent was accepted';
  exception when foreign_key_violation then null; end;
  perform public.begin_upload(owner,file_id,folder,'Good','application/pdf',1);
  if has_function_privilege('authenticated','public.transition_upload(uuid,uuid,text)','execute') then raise exception 'authenticated can finalize directly'; end if;
  if has_table_privilege('authenticated','public.files','UPDATE') then raise exception 'authenticated can update directly'; end if;
  update public.files set last_activity_at=now()-interval '25 hours' where id=file_id;
  perform public.cleanup_candidates();
  select * into item from public.files where id=file_id;
  if item.status <> 'expired' then raise exception 'abandoned upload did not expire'; end if;
  if item.cleanup_after < item.last_upload_url_expires_at then raise exception 'cleanup precedes signed capability expiry'; end if;
  begin
    perform public.transition_upload(owner,file_id,'complete');
    raise exception 'expired upload completed';
  exception when raise_exception then
    if sqlerrm <> 'upload_expired' then raise; end if;
  end;
end $$;
-- Failed cleanup entries are leased so subsequent batches can make progress.
do $$
declare owner uuid := gen_random_uuid(); first_id uuid := gen_random_uuid(); second_id uuid := gen_random_uuid(); claimed uuid; next_claim uuid;
begin
  insert into auth.users(id) values(owner);
  update public.files set cleanup_after=now()+interval '1 day' where status in ('cancelled','expired');
  insert into public.files(id,owner_id,name,content_type,byte_count,status,cleanup_after)
  values(first_id,owner,'First','application/pdf',1,'cancelled',now()-interval '2 hours'),
        (second_id,owner,'Second','application/pdf',1,'cancelled',now()-interval '1 hour');
  select id into claimed from public.cleanup_candidates(1);
  select id into next_claim from public.cleanup_candidates(1);
  if claimed is distinct from first_id or next_claim is distinct from second_id then
    raise exception 'cleanup batch did not advance past a leased entry';
  end if;
  if exists(select 1 from public.cleanup_candidates(100)) then
    raise exception 'cleanup reissued leased entries';
  end if;
end $$;
rollback;
