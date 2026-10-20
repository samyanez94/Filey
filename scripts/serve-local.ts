// Fallback for local CLI Edge Runtime issues. Production uses the two Edge Function entrypoints.
import { Backend, config } from "../supabase/functions/_shared/backend.ts";
import { createHandler } from "../supabase/functions/api/handler.ts";
import { createCleanupHandler } from "../supabase/functions/cleanup-uploads/handler.ts";
const backend = new Backend(config());
const api = createHandler(backend);
const cleanup = createCleanupHandler(backend);
Deno.serve(
  { hostname: "127.0.0.1", port: 56325 },
  (req) => new URL(req.url).pathname === "/functions/v1/cleanup-uploads" ? cleanup(req) : api(req),
);
