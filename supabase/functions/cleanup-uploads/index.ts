import { Backend, config } from "../_shared/backend.ts";
import { createCleanupHandler } from "./handler.ts";
Deno.serve(createCleanupHandler(new Backend(config())));
