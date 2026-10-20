import { call, env, origin } from "./common.ts";
const target = Deno.args[Deno.args.indexOf("--confirm-project") + 1];
if (!Deno.args.includes("--confirm-project") || target !== new URL(origin()).host) {
  throw Error(
    "Pass --confirm-project <exact SUPABASE_URL host:port>. This removes the demo dataset.",
  );
}
const owner = env("DEMO_USER_ID");
if (!/^[\da-f-]{36}$/i.test(owner)) throw Error("Invalid DEMO_USER_ID");
// Stop issuing uploads during reset. Wait for capabilities to expire before deleting tombstones.
const active = await call(
  `/rest/v1/files?owner_id=eq.${owner}&last_upload_url_expires_at=gt.${
    encodeURIComponent(new Date(Date.now() - 15 * 60_000).toISOString())
  }&select=id&limit=1`,
);
if (active.length) {
  throw Error(
    "Outstanding upload capabilities exist. Stop client traffic and wait until their expiry plus 15 minutes before reset.",
  );
}
while (true) {
  const rows = await call(`/rest/v1/files?owner_id=eq.${owner}&select=id,storage_key&limit=100`);
  if (!rows.length) break;
  await call("/storage/v1/object/files", "DELETE", {
    prefixes: rows.map((r: { storage_key: string }) => r.storage_key),
  });
  await call(
    `/rest/v1/files?owner_id=eq.${owner}&id=in.(${
      rows.map((r: { id: string }) => r.id).join(",")
    })`,
    "DELETE",
  );
}
await call(`/rest/v1/idempotency_requests?owner_id=eq.${owner}`, "DELETE");
// A single statement removes the hierarchy without violating parent references.
await call(`/rest/v1/folders?owner_id=eq.${owner}`, "DELETE");
console.log("Removed demo content. Demo owner record was preserved.");
