create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;
-- Deployment tooling installs the hourly job after server secrets have been configured.
create function public.configure_cleanup_schedule(p_url text, p_secret text)
returns void language plpgsql security definer set search_path = '' as $$
declare old_id bigint; secret_id uuid;
begin
  if p_url !~ '^https?://' or length(p_secret) < 32 then raise exception 'invalid_request'; end if;
  select id into secret_id from vault.secrets where name='fileexplorer_cleanup_secret';
  if secret_id is null then
    perform vault.create_secret(p_secret,'fileexplorer_cleanup_secret');
  else
    perform vault.update_secret(secret_id,p_secret);
  end if;
  select jobid into old_id from cron.job where jobname='fileexplorer-cleanup';
  if old_id is not null then perform cron.unschedule(old_id); end if;
  perform cron.schedule('fileexplorer-cleanup','0 * * * *',format(
    'select net.http_post(url := %L, headers := jsonb_build_object(''Content-Type'',''application/json'',''Authorization'',''Bearer '' || (select decrypted_secret from vault.decrypted_secrets where name=''fileexplorer_cleanup_secret'')), body := ''{}''::jsonb, timeout_milliseconds := 120000);',
    p_url || '/functions/v1/cleanup-uploads'));
end $$;
revoke all on function public.configure_cleanup_schedule(text,text) from public,anon,authenticated;
grant execute on function public.configure_cleanup_schedule(text,text) to service_role;
