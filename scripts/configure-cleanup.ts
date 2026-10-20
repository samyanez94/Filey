import { call, env, origin } from "./common.ts";
// From local Postgres, Docker's host gateway reaches the local API port.
const url = Deno.env.get("CLEANUP_API_URL") || origin();
await call("/rest/v1/rpc/configure_cleanup_schedule", "POST", {
  p_url: url,
  p_secret: env("CLEANUP_SECRET"),
});
console.log("Installed hourly cleanup schedule; its credential is stored in Vault.");
