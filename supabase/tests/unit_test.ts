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
  apiKey: "k".repeat(32),
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
Deno.test("shared key selects only the configured owner and uses server-scoped listing", async () => {
  let calls = 0;
  const backend = new Backend(cfg, (input, init) => {
    calls++;
    assert(String(input).endsWith("/rpc/list_demo_items"));
    assert(JSON.parse(String(init?.body)).p_owner === id);
    assert(new Headers(init?.headers).get("X-Filey-API-Key") === null);
    return Promise.resolve(Response.json([]));
  });
  const handler = createHandler(backend);
  for (const key of ["wrong", cfg.apiKey + "x"]) {
    assert(
      (await handler(
        new Request("https://example.test/api/v1/items", {
          headers: { "X-Filey-API-Key": key },
        }),
      )).status === 401,
    );
  }
  assert(calls === 0);
  assert(
    (await handler(
      new Request("https://example.test/api/v1/items", {
        headers: { "X-Filey-API-Key": cfg.apiKey },
      }),
    )).status === 200,
  );
  assert(Number(calls) === 1);
});
Deno.test("file reads and downloads only accept ready files", async () => {
  const backend = new Backend(cfg, (input) => {
    const path = String(input);
    assert(path.includes(`owner_id=eq.${id}`) && path.includes("status=eq.ready"));
    return Promise.resolve(Response.json([]));
  });
  for (const suffix of ["", "/download-url"]) {
    const response = await createHandler(backend)(
      new Request(
        `https://example.test/api/v1/files/${id}${suffix}`,
        { method: suffix ? "POST" : "GET", headers: { "X-Filey-API-Key": cfg.apiKey } },
      ),
    );
    assert(response.status === 404);
  }
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

Deno.test("upstream stream failures and non-JSON gateways remain retryable", async () => {
  const responses = [
    () =>
      new Response(
        new ReadableStream({
          start(controller) {
            controller.error(Error("disconnect"));
          },
        }),
      ),
    () => new Response("<html>Unavailable</html>", { status: 502 }),
    () => new Response("<html>Slow down</html>", { status: 429 }),
  ];
  for (const [index, response] of responses.entries()) {
    const backend = new Backend(cfg, () => Promise.resolve(response()));
    try {
      await backend.request("/rest/v1/files", "GET");
      throw Error("Expected upstream error");
    } catch (error) {
      assert(error instanceof ApiError && error.retryable);
      assert(error.status === (index === 2 ? 429 : 503));
    }
  }
});

Deno.test("file deletion uses the owner-scoped RPC and returns an empty response", async () => {
  let calls = 0;
  const handler = createHandler(
    new Backend(cfg, (input, init) => {
      calls++;
      assert(String(input).endsWith("/rpc/delete_file"));
      const args = JSON.parse(String(init?.body));
      assert(args.p_owner === cfg.demoID && args.p_id === id);
      return Promise.resolve(Response.json(null));
    }),
  );
  for (let retry = 0; retry < 2; retry++) {
    const response = await handler(
      new Request(`https://example.test/api/v1/files/${id}`, {
        method: "DELETE",
        headers: { "X-Filey-API-Key": cfg.apiKey },
      }),
    );
    assert(response.status === 204 && await response.text() === "");
  }
  assert(calls === 2);
  const invalid = await handler(
    new Request("https://example.test/api/v1/files/invalid", {
      method: "DELETE",
      headers: { "X-Filey-API-Key": cfg.apiKey },
    }),
  );
  assert(invalid.status === 400 && calls === 2);
});

Deno.test("file deletion preserves not-found and lifecycle errors", async () => {
  for (const [code, status] of [["not_found", 404], ["file_not_ready", 409]] as const) {
    const handler = createHandler(
      new Backend(cfg, () => Promise.resolve(Response.json({ message: code }, { status: 400 }))),
    );
    const response = await handler(
      new Request(`https://example.test/api/v1/files/${id}`, {
        method: "DELETE",
        headers: { "X-Filey-API-Key": cfg.apiKey },
      }),
    );
    assert(response.status === status);
    assert((await response.json()).error.code === code);
  }
});

Deno.test("deleted storage cleanup retries failures and marks successful removal", async () => {
  const item = { id, owner_id: id, status: "deleted", storage_key: "owner/file/original" };
  let fail = true;
  let marked = 0;
  const backend = new Backend(cfg, (input, init) => {
    const path = String(input);
    if (path.includes("cleanup_candidates") || path.includes("/rest/v1/files")) {
      return Promise.resolve(Response.json([item]));
    }
    if (path.includes("/storage/v1/object/files")) {
      assert(init?.method === "DELETE");
      assert(JSON.parse(String(init?.body)).prefixes[0] === item.storage_key);
      return Promise.resolve(Response.json([], { status: fail ? 503 : 200 }));
    }
    assert(path.includes("mark_cleaned"));
    marked++;
    return Promise.resolve(Response.json(null));
  });
  const run = () =>
    createCleanupHandler(backend)(
      new Request("https://example.test/cleanup-uploads", {
        method: "POST",
        headers: { Authorization: `Bearer ${cfg.cleanupSecret}` },
      }),
    );
  assert((await run()).status === 503 && marked === 0);
  fail = false;
  const response = await run();
  assert(response.status === 200 && Number(marked) === 1);
  assert((await response.json()).removed === 1);
});

Deno.test("deleted uploads cannot complete or issue another target", async () => {
  const item = { id, owner_id: id, status: "deleted" };
  const handler = createHandler(
    new Backend(cfg, (input) => {
      const path = String(input);
      if (path.includes("/rpc/begin_upload")) {
        return Promise.resolve(Response.json({ message: "upload_deleted" }, { status: 400 }));
      }
      assert(path.includes("/rest/v1/files"), "Deleted files must not reach Storage");
      return Promise.resolve(Response.json([item]));
    }),
  );
  for (const complete of [false, true]) {
    const response = await handler(
      new Request(
        `https://example.test/api/v1/uploads/${id}${complete ? "/complete" : ""}`,
        {
          method: complete ? "POST" : "PUT",
          headers: { "X-Filey-API-Key": cfg.apiKey, "Content-Type": "application/json" },
          body: complete
            ? undefined
            : JSON.stringify({ name: "test.pdf", content_type: "application/pdf", byte_count: 9 }),
        },
      ),
    );
    assert(response.status === 409 && (await response.json()).error.code === "upload_deleted");
  }
});
