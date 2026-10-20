import { ApiError, tokenExpiry } from "./core.ts";
export interface Config {
  url: string;
  publicURL: string;
  anonKey: string;
  serviceKey: string;
  demoID: string;
  cleanupSecret: string;
}
export function config(): Config {
  function required(key: string) {
    const value = Deno.env.get(key);
    if (!value) throw Error(`Missing ${key}`);
    return value;
  }
  const url = required("SUPABASE_URL").replace(/\/$/, "");
  return {
    url,
    publicURL: (Deno.env.get("PUBLIC_SUPABASE_URL") || url).replace(/\/$/, ""),
    anonKey: required("SUPABASE_ANON_KEY"),
    serviceKey: required("SUPABASE_SERVICE_ROLE_KEY"),
    demoID: required("DEMO_USER_ID"),
    cleanupSecret: Deno.env.get("CLEANUP_SECRET") || "",
  };
}
const domainCodes: Record<string, number> = {
  not_found: 404,
  idempotency_conflict: 409,
  upload_conflict: 409,
  already_completed: 409,
  upload_cancelled: 409,
  upload_expired: 409,
  invalid_request: 400,
};
export class Backend {
  constructor(public cfg: Config, private transport: typeof fetch = fetch) {}
  async request<T>(path: string, method: string, data?: unknown, token?: string): Promise<T> {
    const key = token ? this.cfg.anonKey : this.cfg.serviceKey;
    const headers: Record<string, string> = { apikey: key, "Content-Type": "application/json" };
    // Modern secret keys are API keys, not JWTs. Legacy local keys remain valid bearer JWTs.
    if (token || key.startsWith("eyJ")) headers.Authorization = `Bearer ${token || key}`;
    let response: Response;
    try {
      response = await this.transport(this.cfg.url + path, {
        method,
        headers,
        body: data === undefined ? undefined : JSON.stringify(data),
        signal: AbortSignal.timeout(30_000),
      });
    } catch {
      throw new ApiError(
        503,
        "temporarily_unavailable",
        "The backend is temporarily unavailable.",
        true,
      );
    }
    const text = await response.text();
    let result;
    try {
      result = text ? JSON.parse(text) : null;
    } catch {
      throw new ApiError(503, "temporarily_unavailable", undefined, true);
    }
    if (!response.ok) {
      if (
        path.startsWith("/storage/v1/object/upload/sign/") &&
        (result?.code === "KeyAlreadyExists" || result?.error === "Duplicate")
      ) {
        throw new ApiError(409, "upload_object_exists");
      }
      const message = result?.message;
      if (typeof message === "string" && domainCodes[message]) {
        throw new ApiError(domainCodes[message], message);
      }
      if (result?.code === "23503") throw new ApiError(404, "not_found");
      if (["23514", "23502", "22P02"].includes(result?.code)) {
        throw new ApiError(400, "invalid_request");
      }
      if (response.status === 429) throw new ApiError(429, "rate_limited", undefined, true);
      if (response.status === 404 || result?.code === "NoSuchKey" || result?.statusCode === "404") {
        throw new ApiError(404, "not_found");
      }
      throw new ApiError(503, "temporarily_unavailable", "A backend operation failed.", true);
    }
    return result as T;
  }
  async authenticate(req: Request): Promise<{ id: string; token: string }> {
    const header = req.headers.get("authorization");
    if (!header?.startsWith("Bearer ") || header.length < 8) {
      throw new ApiError(401, "unauthenticated");
    }
    const token = header.slice(7);
    let response: Response;
    try {
      response = await this.transport(`${this.cfg.url}/auth/v1/user`, {
        headers: { apikey: this.cfg.anonKey, Authorization: `Bearer ${token}` },
        signal: AbortSignal.timeout(10_000),
      });
    } catch {
      throw new ApiError(503, "temporarily_unavailable", undefined, true);
    }
    if (!response.ok) {
      await response.body?.cancel();
      if (response.status === 429) throw new ApiError(429, "rate_limited", undefined, true);
      if (response.status >= 500) {
        throw new ApiError(503, "temporarily_unavailable", undefined, true);
      }
      throw new ApiError(401, "unauthenticated");
    }
    const user = await response.json();
    if (user.id !== this.cfg.demoID) throw new ApiError(403, "forbidden");
    return { id: user.id, token };
  }
  rpc<T>(name: string, data: unknown, token?: string) {
    return this.request<T>(`/rest/v1/rpc/${name}`, "POST", data, token);
  }
  async one<T>(table: string, id: string, owner: string, token?: string): Promise<T> {
    const rows = await this.request<T[]>(
      `/rest/v1/${table}?id=eq.${id}&owner_id=eq.${owner}&select=*`,
      "GET",
      undefined,
      token,
    );
    if (!rows.length) throw new ApiError(404, "not_found");
    return rows[0];
  }
  storagePath(key: string) {
    return "files/" + key.split("/").map(encodeURIComponent).join("/");
  }
  publicStorageURL(path: string) {
    // Provider response is relative to /storage/v1; do not accept a different origin.
    if (!path.startsWith("/") || path.startsWith("//")) {
      throw new ApiError(503, "temporarily_unavailable", undefined, true);
    }
    return `${this.cfg.publicURL}/storage/v1${path}`;
  }
  async uploadTarget(key: string, mime: string) {
    const result = await this.request<{ url: string }>(
      `/storage/v1/object/upload/sign/${this.storagePath(key)}`,
      "POST",
      {},
    );
    const url = this.publicStorageURL(result.url);
    const token = new URL(url).searchParams.get("token");
    if (!token) throw new ApiError(503, "temporarily_unavailable", undefined, true);
    return {
      url,
      method: "PUT",
      headers: { "Content-Type": mime, "x-upsert": "false", "Cache-Control": "max-age=3600" },
      body_encoding: "raw",
      expires_at: tokenExpiry(token),
    };
  }
  async objectInfo(key: string): Promise<{ size: number; contentType: string }> {
    const result = await this.request<
      {
        metadata?: { size?: number; mimetype?: string };
        size?: number;
        contentType?: string;
        content_type?: string;
      }
    >(
      `/storage/v1/object/info/${this.storagePath(key)}`,
      "GET",
    );
    return {
      size: Number(result.metadata?.size ?? result.size),
      contentType: result.metadata?.mimetype ?? result.content_type ?? result.contentType ?? "",
    };
  }
  async downloadTarget(key: string) {
    const result = await this.request<{ signedURL: string }>(
      `/storage/v1/object/sign/${this.storagePath(key)}`,
      "POST",
      { expiresIn: 900 },
    );
    const url = this.publicStorageURL(result.signedURL);
    const token = new URL(url).searchParams.get("token");
    if (!token) throw new ApiError(503, "temporarily_unavailable", undefined, true);
    return { url, expires_at: tokenExpiry(token) };
  }
  removeObject(key: string) {
    return this.request("/storage/v1/object/files", "DELETE", { prefixes: [key] });
  }
}
