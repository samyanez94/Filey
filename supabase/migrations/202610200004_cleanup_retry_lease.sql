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
      where status in ('cancelled','expired') and cleanup_after <= now()
      order by cleanup_after,id
      limit least(greatest(coalesce(p_limit,100),1),100)
      for update skip locked
    )
    update public.files f set cleanup_after=now()+interval '15 minutes'
    from candidates c where f.id=c.id returning f.*;
end $$;
revoke all on function public.cleanup_candidates(integer) from public,anon,authenticated;
grant execute on function public.cleanup_candidates(integer) to service_role;
