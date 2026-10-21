# File deletion

`DELETE /files/{fileID}` uses the shared `X-Filey-API-Key` and takes no body.
It returns `204 No Content` for a ready file or a file already marked deleted.
Unknown IDs (including another owner's files) return `404`; pending, cancelled,
and expired uploads return `409 file_not_ready`. Use `DELETE /uploads/{fileID}`
to cancel an unfinished upload. Invalid UUIDs return `400`; invalid keys return `401`.

The database locks the file row and marks it `deleted`. Folder listings, file
metadata, and new download URL requests only return ready files, so deletion
hides the file immediately. `GET /uploads/{fileID}` still reports its deleted
status. Resuming or completing the old upload returns `409 upload_deleted`
(with unchanged metadata); changed metadata may return `409 upload_conflict`.
Cancelling a deleted upload also returns `409 upload_deleted`.

The existing cleanup worker removes the Storage object asynchronously. Cleanup
waits until outstanding upload URLs expire, plus a 15-minute grace period, so an
old upload cannot restore the bytes after removal. Failed attempts retain their
15-minute retry lease; successful cleanup retains the existing hourly recheck.
The database row stays as a deletion record, making retries safe and preventing
reuse of the upload UUID. There is no restore or folder deletion endpoint.

Already downloaded previews are unaffected. Previously issued download URLs
may remain usable until expiry or storage cleanup. The client should remove a
row after a successful response and keep it visible on failure.

## Rollout and checks

Apply migration `202610210001_delete_files.sql`, then deploy both `api` and
`cleanup-uploads`. No new environment variables or scheduled jobs are needed.
Run `deno task check`, `deno task test`, and `supabase/tests/database.sql` against
a migrated local database. SQL tests roll back their fixtures.

The full HTTP contract is in [openapi.yaml](openapi.yaml).
