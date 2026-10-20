import { Backend } from "../_shared/backend.ts";
import {
  ApiError,
  body,
  decodeCursor,
  encodeCursor,
  errorResponse,
  Item,
  json,
  name,
  parent,
  pending,
  publicItem,
  publicUpload,
  Upload,
  uploadInput,
  uuid,
} from "../_shared/core.ts";

async function completeUpload(backend: Backend, owner: string, id: string): Promise<Upload> {
  let item = await backend.one<Upload>("files", id, owner);
  if (item.status !== "ready") {
    pending(item);
    let info;
    try {
      info = await backend.objectInfo(item.storage_key);
    } catch (e) {
      if (e instanceof ApiError && e.status === 404) {
        throw new ApiError(
          409,
          "upload_incomplete",
          "The uploaded object is not available yet.",
          true,
        );
      }
      throw e;
    }
    if (info.size !== item.byte_count || info.contentType !== item.content_type) {
      await backend.rpc("transition_upload", {
        p_owner: owner,
        p_id: id,
        p_action: "invalid",
      });
      throw new ApiError(422, "upload_validation_failed");
    }
    item = await backend.rpc<Upload>("transition_upload", {
      p_owner: owner,
      p_id: id,
      p_action: "complete",
    });
  }
  return item;
}

async function uploadResponse(
  backend: Backend,
  owner: string,
  result: { created: boolean; upload: Upload },
): Promise<Response> {
  const item = result.upload;
  if (item.status === "ready") return json(publicUpload(item));
  let target;
  try {
    target = await backend.uploadTarget(item.storage_key, item.content_type);
  } catch (error) {
    if (!(error instanceof ApiError) || error.code !== "upload_object_exists") throw error;
    // Storage accepted a previous transfer. Reuse completion's verification and locking.
    return json(publicUpload(await completeUpload(backend, owner, item.id)));
  }
  const confirmed = await backend.rpc<boolean>("confirm_upload_target", {
    p_owner: owner,
    p_id: item.id,
    p_expiry: target.expires_at,
  });
  if (!confirmed) {
    const current = await backend.one<Upload>("files", item.id, owner);
    if (current.status === "ready") return json(publicUpload(current));
    pending(current);
    throw new ApiError(409, "upload_conflict");
  }
  return json({ ...publicUpload(item), upload_target: target }, result.created ? 201 : 200);
}

export function createHandler(backend: Backend) {
  return async (req: Request): Promise<Response> => {
    const requestID = crypto.randomUUID();
    const started = performance.now();
    let response: Response;
    let route = "unknown";
    try {
      const { id: owner, token } = await backend.authenticate(req);
      const url = new URL(req.url);
      const match = url.pathname.match(/^(?:\/functions\/v1)?\/api\/v1(\/.*)?$/);
      if (!match) throw new ApiError(404, "not_found");
      const path = match[1] || "/";
      route = path.replace(/[\da-f]{8}-[\da-f-]{27,}/gi, ":id");
      const parts = path.split("/").filter(Boolean);
      if (path === "/items" && req.method === "GET") {
        const folder = parent(url.searchParams.get("parent_id"));
        const rawLimit = url.searchParams.get("limit") ?? "50";
        if (!/^\d+$/.test(rawLimit) || +rawLimit < 1 || +rawLimit > 100) {
          throw new ApiError(400, "invalid_request");
        }
        const limit = +rawLimit;
        const cursor = decodeCursor(url.searchParams.get("cursor"), folder);
        const rows = await backend.rpc<Item[]>("list_items", {
          p_parent: folder,
          p_limit: limit,
          p_kind: cursor?.kind ?? null,
          p_name: cursor?.name ?? null,
          p_id: cursor?.id ?? null,
        }, token);
        const page = rows.slice(0, limit);
        const last = page.at(-1);
        response = json({
          items: page.map((r) => publicItem(r, r.kind as "folder" | "file")),
          next_cursor: rows.length > limit && last
            ? encodeCursor({
              v: 1,
              parent: folder,
              kind: last.sort_kind!,
              name: last.sort_name!,
              id: last.id,
            })
            : null,
        });
      } else if (path === "/folders" && req.method === "POST") {
        const data = await body(req, ["parent_id", "name"]);
        const result = await backend.rpc<{ created: boolean; folder: Item }>("create_folder", {
          p_owner: owner,
          p_key: uuid(req.headers.get("Idempotency-Key")),
          p_parent: parent(data.parent_id),
          p_name: name(data.name),
        });
        response = json(publicItem(result.folder, "folder"), result.created ? 201 : 200);
      } else if (
        parts.length === 2 && ["folders", "files"].includes(parts[0]) && req.method === "GET"
      ) {
        const item = await backend.one<Item>(parts[0], uuid(parts[1]), owner, token);
        response = json(publicItem(item, parts[0] === "files" ? "file" : "folder"));
      } else if (parts[0] === "uploads" && parts.length === 2 && req.method === "PUT") {
        const id = uuid(parts[1]);
        const input = uploadInput(
          await body(req, ["parent_id", "name", "content_type", "byte_count"]),
        );
        const result = await backend.rpc<{ created: boolean; upload: Upload }>("begin_upload", {
          p_owner: owner,
          p_id: id,
          p_parent: input.parent_id,
          p_name: input.name,
          p_type: input.content_type,
          p_bytes: input.byte_count,
        });
        response = await uploadResponse(backend, owner, result);
      } else if (parts[0] === "uploads" && parts.length === 2 && req.method === "GET") {
        response = json(publicUpload(await backend.one<Upload>("files", uuid(parts[1]), owner)));
      } else if (parts[0] === "uploads" && parts.length === 2 && req.method === "DELETE") {
        await backend.rpc("transition_upload", {
          p_owner: owner,
          p_id: uuid(parts[1]),
          p_action: "cancel",
        });
        response = json(null, 204);
      } else if (
        parts[0] === "uploads" && parts.length === 3 && parts[2] === "complete" &&
        req.method === "POST"
      ) {
        const id = uuid(parts[1]);
        const item = await completeUpload(backend, owner, id);
        response = json(publicItem(item, "file"));
      } else if (
        parts[0] === "files" && parts.length === 3 && parts[2] === "download-url" &&
        req.method === "POST"
      ) {
        const item = await backend.one<Upload>("files", uuid(parts[1]), owner, token);
        response = json({
          ...await backend.downloadTarget(item.storage_key),
          content_type: item.content_type,
          byte_count: item.byte_count,
        });
      } else throw new ApiError(404, "not_found");
    } catch (error) {
      response = errorResponse(error, requestID);
    }
    response.headers.set("X-Request-ID", requestID);
    console.log(
      JSON.stringify({
        request_id: requestID,
        route,
        method: req.method,
        status: response.status,
        duration_ms: Math.round(performance.now() - started),
      }),
    );
    return response;
  };
}
