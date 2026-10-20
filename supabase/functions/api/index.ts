import { Backend, config } from "../_shared/backend.ts";
import { createHandler } from "./handler.ts";
Deno.serve(createHandler(new Backend(config())));
