import { Backend } from "../_shared/backend.ts";
import { ApiError, errorResponse, json, Upload } from "../_shared/core.ts";
export function createCleanupHandler(backend: Backend) {
  return async (req: Request) => {
    const requestID = crypto.randomUUID();
    try {
      if (req.method !== "POST") throw new ApiError(405, "method_not_allowed");
      const secret = backend.cfg.cleanupSecret;
      if (secret.length < 32 || req.headers.get("Authorization") !== `Bearer ${secret}`) {
        throw new ApiError(401, "unauthenticated");
      }
      const candidates = await backend.rpc<Upload[]>("cleanup_candidates", { p_limit: 100 });
      let removed = 0, failed = 0;
      // Bounded concurrency; repeated removal is safe because terminal states cannot become ready.
      for (let offset = 0; offset < candidates.length; offset += 5) {
        await Promise.all(
          candidates.slice(offset, offset + 5).map(async (candidate) => {
            try {
              const current = await backend.one<Upload>("files", candidate.id, candidate.owner_id);
              if (!["cancelled", "expired"].includes(current.status)) return;
              await backend.removeObject(current.storage_key);
              await backend.rpc("mark_cleaned", { p_owner: current.owner_id, p_id: current.id });
              removed++;
            } catch {
              failed++;
            }
          }),
        );
      }
      console.log(JSON.stringify({ request_id: requestID, operation: "cleanup", removed, failed }));
      return json({ removed, failed, request_id: requestID }, failed ? 503 : 200);
    } catch (e) {
      return errorResponse(e, requestID);
    }
  };
}
