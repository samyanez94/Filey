export const MIME_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/heic",
  "image/heif",
  "application/pdf",
]);
export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    message = code,
    public retryable = false,
  ) {
    super(message);
  }
}
export function uuid(value: unknown): string {
  if (
    typeof value !== "string" ||
    !/^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/i.test(value)
  ) {
    throw new ApiError(400, "invalid_request", "Expected a UUID.");
  }
  return value.toLowerCase();
}
export function parent(value: unknown): string | null {
  return value == null ? null : uuid(value);
}
export function name(value: unknown): string {
  if (typeof value !== "string") throw new ApiError(400, "invalid_name");
  const clean = value.trim();
  if (
    !clean || [...clean].length > 255 || /^[.]{1,2}$/.test(clean) ||
    /[/\\]/.test(clean) ||
    [...value].some((c) =>
      c.codePointAt(0)! < 32 || (c.codePointAt(0)! >= 127 && c.codePointAt(0)! <= 159)
    )
  ) {
    throw new ApiError(400, "invalid_name");
  }
  return clean;
}
export async function body(req: Request, allowed: string[]): Promise<Record<string, unknown>> {
  if (req.headers.get("content-type")?.split(";")[0].trim() !== "application/json") {
    throw new ApiError(415, "unsupported_type", "Expected application/json.");
  }
  // Stream with a bound instead of trusting Content-Length.
  const reader = req.body?.getReader();
  if (!reader) throw new ApiError(400, "invalid_request");
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      length += value.length;
      if (length > 8192) {
        await reader.cancel();
        throw new ApiError(413, "request_too_large");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  let data;
  try {
    data = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new ApiError(400, "invalid_request");
  }
  if (
    !data || typeof data !== "object" || Array.isArray(data) ||
    Object.keys(data).some((k) => !allowed.includes(k))
  ) {
    throw new ApiError(400, "invalid_request");
  }
  return data;
}
export function uploadInput(data: Record<string, unknown>) {
  const result = {
    parent_id: parent(data.parent_id),
    name: name(data.name),
    content_type: data.content_type,
    byte_count: data.byte_count,
  };
  if (typeof result.content_type !== "string" || !MIME_TYPES.has(result.content_type)) {
    throw new ApiError(415, "unsupported_type");
  }
  if (
    typeof result.byte_count !== "number" || !Number.isSafeInteger(result.byte_count) ||
    result.byte_count <= 0
  ) throw new ApiError(400, "invalid_request");
  if (result.byte_count > 20_000_000) {
    throw new ApiError(413, "file_too_large", "The maximum file size is 20 MB.");
  }
  return {
    ...result,
    content_type: result.content_type as string,
    byte_count: result.byte_count as number,
  };
}
export interface Item {
  id: string;
  owner_id?: string;
  parent_id: string | null;
  name: string;
  created_at: string;
  content_type?: string;
  byte_count?: number;
  kind?: string;
  sort_kind?: number;
  sort_name?: string;
}
export interface Upload extends Item {
  owner_id: string;
  content_type: string;
  byte_count: number;
  storage_key: string;
  status: "pending" | "ready" | "cancelled" | "expired" | "deleted";
}
export function publicItem(item: Item, kind: "file" | "folder") {
  return {
    id: item.id,
    kind,
    parent_id: item.parent_id,
    name: item.name,
    created_at: item.created_at,
    ...(kind === "file" ? { content_type: item.content_type, byte_count: item.byte_count } : {}),
  };
}
export function publicUpload(item: Upload) {
  return {
    file_id: item.id,
    status: item.status,
    parent_id: item.parent_id,
    name: item.name,
    content_type: item.content_type,
    byte_count: item.byte_count,
    ...(item.status === "ready" ? { file: publicItem(item, "file") } : {}),
  };
}
export interface Cursor {
  v: number;
  parent: string | null;
  kind: number;
  name: string;
  id: string;
}
export function encodeCursor(value: Cursor): string {
  return btoa(String.fromCharCode(...new TextEncoder().encode(JSON.stringify(value)))).replaceAll(
    "+",
    "-",
  ).replaceAll("/", "_").replace(/=+$/, "");
}
export function decodeCursor(raw: string | null, folder: string | null): Cursor | null {
  if (raw === null) return null;
  try {
    if (raw.length > 4096 || !/^[A-Za-z0-9_-]+$/.test(raw)) throw Error();
    const decoded = atob(raw.replaceAll("-", "+").replaceAll("_", "/"));
    const c = JSON.parse(
      new TextDecoder().decode(Uint8Array.from(decoded, (x) => x.charCodeAt(0))),
    );
    if (
      c.v !== 1 || c.parent !== folder || ![0, 1].includes(c.kind) || typeof c.name !== "string" ||
      [...c.name].length > 255
    ) throw Error();
    return { ...c, id: uuid(c.id) };
  } catch {
    throw new ApiError(400, "invalid_cursor");
  }
}
export function tokenExpiry(token: string): string {
  try {
    const payload = JSON.parse(atob(token.split(".")[1].replaceAll("-", "+").replaceAll("_", "/")));
    if (!Number.isFinite(payload.exp)) throw Error();
    return new Date(payload.exp * 1000).toISOString();
  } catch {
    throw new ApiError(503, "temporarily_unavailable", "Storage returned an invalid expiry.", true);
  }
}
export function pending(item: Upload) {
  if (item.status !== "pending") {
    throw new ApiError(
      409,
      item.status === "ready" ? "already_completed" : `upload_${item.status}`,
    );
  }
}
export function json(value: unknown, status = 200): Response {
  return new Response(status === 204 ? null : JSON.stringify(value), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}
export function errorResponse(error: unknown, requestID: string): Response {
  const e = error instanceof ApiError
    ? error
    : new ApiError(500, "internal_error", "An unexpected error occurred.", true);
  const response = json({
    error: { code: e.code, message: e.message, retryable: e.retryable },
    request_id: requestID,
  }, e.status);
  if (e.status === 429) response.headers.set("Retry-After", "60");
  return response;
}
