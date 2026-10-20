import {
  ApiError,
  decodeCursor,
  encodeCursor,
  name,
  publicUpload,
  tokenExpiry,
  Upload,
  uploadInput,
  uuid,
} from "../functions/_shared/core.ts";
import { Backend, Config } from "../functions/_shared/backend.ts";
import { createHandler } from "../functions/api/handler.ts";
import { createCleanupHandler } from "../functions/cleanup-uploads/handler.ts";
function assert(value: unknown, message = "Assertion failed"): asserts value {
  if (!value) throw Error(message);
}
function rejects(fn: () => unknown, code: string) {
  try {
    fn();
  } catch (e) {
    assert(e instanceof ApiError && e.code === code);
    return;
  }
  throw Error(`Expected ${code}`);
}
const id = "10000000-0000-4000-8000-000000000001";
Deno.test("validation rejects unsafe names, invalid IDs, unsupported types and sizes", () => {
  for (const value of ["", " ", ".", "..", "a/b", "a\\b", "a\n", "x".repeat(256)]) {
    rejects(() => name(value), "invalid_name");
  }
  rejects(() => name("a\nb"), "invalid_name");
  assert(name(" résumé.pdf ") === "résumé.pdf");
  rejects(() => uuid("x"), "invalid_request");
  const input = { name: "A.pdf", content_type: "application/pdf", byte_count: 20_000_000 };
  assert(uploadInput(input).byte_count === 20_000_000);
  rejects(() => uploadInput({ ...input, byte_count: 20_000_001 }), "file_too_large");
  rejects(() => uploadInput({ ...input, byte_count: 0 }), "invalid_request");
  rejects(() => uploadInput({ ...input, content_type: "text/html" }), "unsupported_type");
});
Deno.test("cursor round trips Unicode and rejects cross-folder replay", () => {
  const c = { v: 1, parent: null, kind: 0, name: "写真 résumé", id };
  assert(decodeCursor(encodeCursor(c), null)?.name === c.name);
  rejects(() => decodeCursor(encodeCursor(c), id), "invalid_cursor");
  rejects(() => decodeCursor("not-json", null), "invalid_cursor");
});
Deno.test("upload serialization never returns private storage keys or owner IDs", () => {
  const item = {
    id,
    owner_id: id,
    name: "a",
    parent_id: null,
    created_at: "now",
    status: "ready",
    storage_key: "secret",
    byte_count: 1,
    content_type: "image/png",
  } as Upload;
  const text = JSON.stringify(publicUpload(item));
  assert(!text.includes("secret") && !text.includes("owner_id") && text.includes('"file"'));
});
Deno.test("expiry comes from the provider token", () => {
  const token = `x.${btoa(JSON.stringify({ exp: 2000000000 }))}.x`;
  assert(tokenExpiry(token) === new Date(2000000000000).toISOString());
  rejects(() => tokenExpiry("invalid"), "temporarily_unavailable");
});
const cfg: Config = {
  url: "https://example.test",
  publicURL: "https://public.test",
  anonKey: "publishable",
  serviceKey: "secret",
  demoID: id,
  cleanupSecret: "x".repeat(32),
};
Deno.test("API rejects requests before any privileged access", async () => {
  let calls = 0;
  const backend = new Backend(cfg, () => {
    calls++;
    return Promise.resolve(new Response("{}", { status: 401 }));
  });
  const handler = createHandler(backend);
  assert((await handler(new Request("https://example.test/api/v1/items"))).status === 401);
  assert(calls === 0);
  assert(
    (await handler(
      new Request("https://example.test/api/v1/items", {
        headers: { Authorization: "Bearer bad" },
      }),
    )).status === 401,
  );
});
Deno.test("authenticated other accounts are forbidden", async () => {
  const backend = new Backend(cfg, () => Promise.resolve(Response.json({ id: "other" })));
  assert(
    (await createHandler(backend)(
      new Request("https://example.test/api/v1/items", {
        headers: { Authorization: "Bearer valid" },
      }),
    )).status === 403,
  );
});
Deno.test("cleanup rejects user tokens and missing server secret", async () => {
  const backend = new Backend(cfg, () => {
    throw Error("Must not access storage");
  });
  const response = await createCleanupHandler(backend)(
    new Request("https://example.test/cleanup-uploads", {
      method: "POST",
      headers: { Authorization: "Bearer user" },
    }),
  );
  assert(response.status === 401);
});

Deno.test("Storage adapter reads actual HTTP info fields and does not confuse MIME with size", async () => {
  const backend = new Backend(
    cfg,
    () => Promise.resolve(Response.json({ size: 68, content_type: "image/png", metadata: {} })),
  );
  const info = await backend.objectInfo("owner/file/original");
  assert(info.size === 68 && info.contentType === "image/png");
});
Deno.test("cleanup failure remains retryable and is not marked cleaned", async () => {
  const item = { id, owner_id: id, status: "cancelled", storage_key: "owner/file/original" };
  let marked = false;
  const backend = new Backend(cfg, (input) => {
    const path = String(input);
    if (path.includes("cleanup_candidates")) return Promise.resolve(Response.json([item]));
    if (path.includes("/rest/v1/files")) return Promise.resolve(Response.json([item]));
    if (path.includes("mark_cleaned")) marked = true;
    return Promise.resolve(Response.json({}, { status: 503 }));
  });
  const response = await createCleanupHandler(backend)(
    new Request("https://example.test/cleanup-uploads", {
      method: "POST",
      headers: { Authorization: `Bearer ${cfg.cleanupSecret}` },
    }),
  );
  assert(response.status === 503 && !marked);
  const result = await response.json();
  assert(result.failed === 1 && result.removed === 0);
});
