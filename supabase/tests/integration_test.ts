// Runs against a disposable, running local Supabase stack. No production target allowed.
import { api, apiOrigin, call, env, keyHeaders, origin } from "../../scripts/common.ts";
function assert(value: unknown, message = "Assertion failed"): asserts value {
  if (!value) throw Error(message);
}
Deno.test({
  name: "backend integration: permissions, pagination, Storage lifecycle and recovery",
  ignore: !Deno.env.get("RUN_INTEGRATION"),
  fn: async (t) => {
    assert(
      ["127.0.0.1", "localhost"].includes(new URL(origin()).hostname),
      "Integration tests require a local target",
    );
    assert(
      ["127.0.0.1", "localhost"].includes(new URL(apiOrigin()).hostname),
      "Integration functions must also be local",
    );
    const user = { id: env("DEMO_USER_ID") };
    const base = "/functions/v1/api/v1";
    const headers = { "Content-Type": "application/json", "X-Filey-API-Key": env("FILEY_API_KEY") };
    const folderIDs: string[] = [], fileIDs: string[] = [];
    const prefix = `Test-${crypto.randomUUID()}`;
    async function request(
      path: string,
      method = "GET",
      data?: unknown,
      extra: Record<string, string> = {},
    ) {
      const res = await fetch(apiOrigin() + base + path, {
        method,
        headers: { ...headers, ...extra },
        body: data === undefined ? undefined : JSON.stringify(data),
      });
      const text = await res.text();
      return { status: res.status, body: text ? JSON.parse(text) : null };
    }
    async function begin(size = 9, type = "application/pdf") {
      const id = crypto.randomUUID();
      fileIDs.push(id);
      const result = await request(`/uploads/${id}`, "PUT", {
        parent_id: folderIDs[0],
        name: "test.pdf",
        content_type: type,
        byte_count: size,
      });
      assert(result.status === 201, `begin: ${JSON.stringify(result)}`);
      return { id, ...result.body };
    }
    async function send(
      target: { url: string; method: string; headers: Record<string, string> },
      bytes = new TextEncoder().encode("%PDF-1.4\n"),
    ) {
      const res = await fetch(target.url, {
        method: target.method,
        headers: target.headers,
        body: bytes,
      });
      const status = res.status;
      await res.body?.cancel();
      return status;
    }
    try {
      await t.step("authentication and signup boundaries", async () => {
        const unauth = await fetch(apiOrigin() + base + "/items");
        assert(unauth.status === 401);
        await unauth.body?.cancel();
        const invalid = await request("/items", "GET", undefined, {
          "X-Filey-API-Key": "invalid",
        });
        assert(invalid.status === 401);
        const other = await call("/auth/v1/admin/users", "POST", {
          email: `${crypto.randomUUID()}@example.test`,
          password: "OtherUserPassword123!",
          email_confirm: true,
        });
        try {
          const loginRes = await fetch(origin() + "/auth/v1/token?grant_type=password", {
            method: "POST",
            headers: keyHeaders(env("SUPABASE_ANON_KEY")),
            body: JSON.stringify({ email: other.email, password: "OtherUserPassword123!" }),
          });
          const otherSession = await loginRes.json();
          assert(loginRes.ok);
          for (
            const path of [
              "/rest/v1/folders?select=id",
              "/rest/v1/files?select=id",
              "/rest/v1/rpc/list_demo_items",
            ]
          ) {
            const res = await fetch(origin() + path, {
              method: path.includes("rpc") ? "POST" : "GET",
              headers: {
                ...keyHeaders(env("SUPABASE_ANON_KEY")),
                Authorization: `Bearer ${otherSession.access_token}`,
              },
              body: path.includes("rpc") ? JSON.stringify({ p_owner: user.id }) : undefined,
            });
            assert(!res.ok, "Authenticated clients must not read application data directly");
            await res.body?.cancel();
          }
          assert(
            (await request("/items", "GET", undefined, {
              "X-Filey-API-Key": "",
              Authorization: `Bearer ${otherSession.access_token}`,
            })).status === 401,
          );
        } finally {
          await call(`/auth/v1/admin/users/${other.id}`, "DELETE");
        }
        const signup = await fetch(origin() + "/auth/v1/signup", {
          method: "POST",
          headers: keyHeaders(env("SUPABASE_ANON_KEY")),
          body: JSON.stringify({
            email: "unexpected@example.test",
            password: "UnexpectedPassword123!",
          }),
        });
        assert(!signup.ok);
        await signup.body?.cancel();
      });
      await t.step("concurrent idempotent folder creation and conflict", async () => {
        const key = crypto.randomUUID();
        const results = await Promise.all(
          Array.from(
            { length: 4 },
            () =>
              request("/folders", "POST", { name: prefix, parent_id: null }, {
                "Idempotency-Key": key,
              }),
          ),
        );
        assert(results.filter((r) => r.status === 201).length === 1, JSON.stringify(results));
        assert(new Set(results.map((r) => r.body.id)).size === 1);
        folderIDs.push(results[0].body.id);
        assert(
          (await request("/folders", "POST", { name: "different" }, { "Idempotency-Key": key }))
            .status === 409,
        );
      });
      await t.step("duplicate names paginate without skipping IDs", async () => {
        for (let i = 0; i < 3; i++) {
          const result = await request("/folders", "POST", {
            name: "Same",
            parent_id: folderIDs[0],
          }, { "Idempotency-Key": crypto.randomUUID() });
          assert(result.status === 201);
          folderIDs.push(result.body.id);
        }
        const seen: string[] = [];
        let cursor: string | null = null;
        do {
          const result = await request(
            `/items?parent_id=${folderIDs[0]}&limit=1${cursor ? `&cursor=${cursor}` : ""}`,
          );
          assert(result.status === 200);
          seen.push(...result.body.items.map((x: { id: string }) => x.id));
          cursor = result.body.next_cursor;
        } while (cursor);
        assert(new Set(seen).size === 3 && seen.length === 3);
        assert((await request("/items?limit=101")).status === 400);
      });
      await t.step("direct writes and internal RPCs cannot bypass API", async () => {
        for (
          const [path, body] of [["/rest/v1/folders", { owner_id: user.id, name: "bypass" }], [
            "/rest/v1/rpc/transition_upload",
            { p_owner: user.id, p_id: crypto.randomUUID(), p_action: "complete" },
          ]] as const
        ) {
          const res = await fetch(origin() + path, {
            method: "POST",
            headers: { ...headers, ...keyHeaders(env("SUPABASE_ANON_KEY")) },
            body: JSON.stringify(body),
          });
          assert(!res.ok);
          await res.body?.cancel();
        }
        const res = await fetch(origin() + `/storage/v1/object/files/${user.id}/bypass`, {
          method: "POST",
          headers: {
            ...headers,
            ...keyHeaders(env("SUPABASE_ANON_KEY")),
            "Content-Type": "application/pdf",
          },
          body: "bad",
        });
        assert(!res.ok);
        await res.body?.cancel();
      });
      await t.step(
        "raw signed upload, no overwrite, finalize retry, private download",
        async () => {
          const upload = await begin();
          assert(
            upload.upload_target.method === "PUT" && upload.upload_target.body_encoding === "raw",
          );
          assert(Date.parse(upload.upload_target.expires_at) > Date.now());
          const recovered = await request(`/uploads/${upload.id}`, "PUT", {
            parent_id: folderIDs[0],
            name: "test.pdf",
            content_type: "application/pdf",
            byte_count: 9,
          });
          assert(
            recovered.status === 200 && recovered.body.file_id === upload.id &&
              recovered.body.upload_target,
          );
          const conflict = await request(`/uploads/${upload.id}`, "PUT", {
            parent_id: folderIDs[0],
            name: "changed.pdf",
            content_type: "application/pdf",
            byte_count: 9,
          });
          assert(conflict.status === 409);
          assert((await request(`/files/${upload.id}`)).status === 404);
          assert(
            (await request(`/uploads/${upload.id}/complete`, "POST")).body.error.code ===
              "upload_incomplete",
          );
          assert((await send(upload.upload_target)) < 300, "raw upload failed");
          assert((await send(upload.upload_target)) >= 400, "overwrite must fail");
          assert(
            (await send({
              ...upload.upload_target,
              headers: { ...upload.upload_target.headers, "x-upsert": "true" },
            })) >= 400,
            "client must not override signed no-upsert capability",
          );
          const completed = await request(`/uploads/${upload.id}/complete`, "POST");
          assert(completed.status === 200, JSON.stringify(completed));
          const replay = await request(`/uploads/${upload.id}/complete`, "POST");
          assert(replay.body.id === upload.id);
          const retry = await request(`/uploads/${upload.id}`, "PUT", {
            parent_id: folderIDs[0],
            name: "test.pdf",
            content_type: "application/pdf",
            byte_count: 9,
          });
          assert(retry.body.status === "ready" && !retry.body.upload_target);
          assert(
            (await request(`/uploads/${upload.id}`, "DELETE")).body.error.code ===
              "already_completed",
          );
          const signed = await api(`/files/${upload.id}/download-url`, "POST");
          const download = await fetch(signed.url);
          assert(download.ok && await download.text() === "%PDF-1.4\n");
          assert(Date.parse(signed.expires_at) - Date.now() <= 900_000);
          const unsigned = await fetch(
            origin() + `/storage/v1/object/public/files/${user.id}/${upload.id}/original`,
          );
          assert(!unsigned.ok);
          await unsigned.body?.cancel();
        },
      );
      await t.step("begin recovers bytes uploaded before an interrupted completion", async () => {
        const upload = await begin();
        assert((await send(upload.upload_target)) < 300);
        const recovered = await request(`/uploads/${upload.id}`, "PUT", {
          parent_id: folderIDs[0],
          name: "test.pdf",
          content_type: "application/pdf",
          byte_count: 9,
        });
        assert(
          recovered.status === 200 && recovered.body.status === "ready",
          JSON.stringify(recovered),
        );
        assert(recovered.body.file.id === upload.id && !recovered.body.upload_target);
        assert((await request(`/files/${upload.id}`)).status === 200);
        const invalid = await begin(10);
        assert((await send(invalid.upload_target)) < 300);
        const rejected = await request(`/uploads/${invalid.id}`, "PUT", {
          parent_id: folderIDs[0],
          name: "test.pdf",
          content_type: "application/pdf",
          byte_count: 10,
        });
        assert(rejected.status === 422 && rejected.body.error.code === "upload_validation_failed");
      });
      await t.step("size mismatch cancels instead of publishing", async () => {
        const upload = await begin(10);
        assert((await send(upload.upload_target)) < 300);
        const result = await request(`/uploads/${upload.id}/complete`, "POST");
        assert(result.status === 422, JSON.stringify(result));
        assert((await request(`/files/${upload.id}`)).status === 404);
      });
      await t.step("cancellation racing completion produces one terminal state", async () => {
        const upload = await begin();
        await send(upload.upload_target);
        const [cancel, complete] = await Promise.all([
          request(`/uploads/${upload.id}`, "DELETE"),
          request(`/uploads/${upload.id}/complete`, "POST"),
        ]);
        const state = (await request(`/uploads/${upload.id}`)).body.status;
        assert(
          state === "ready"
            ? complete.status === 200 && cancel.status === 409
            : state === "cancelled" && cancel.status === 204 && complete.status === 409,
        );
      });
      await t.step("late uploads and cleanup retries never publish cancelled files", async () => {
        const upload = await begin();
        assert((await request(`/uploads/${upload.id}`, "DELETE")).status === 204);
        assert(await api(`/uploads/${upload.id}`, "DELETE") === null);
        await send(upload.upload_target);
        assert((await request(`/uploads/${upload.id}/complete`, "POST")).status === 409);
        // Advance cleanup eligibility with the operator role to avoid a multi-hour wait.
        await call(`/rest/v1/files?id=eq.${upload.id}`, "PATCH", {
          cleanup_after: "2000-01-01T00:00:00Z",
        });
        const cleanup = await fetch(apiOrigin() + "/functions/v1/cleanup-uploads", {
          method: "POST",
          headers: { Authorization: `Bearer ${env("CLEANUP_SECRET")}` },
        });
        const result = await cleanup.json();
        assert(cleanup.ok && result.removed >= 1, JSON.stringify(result));
        const info = await fetch(
          origin() + `/storage/v1/object/info/files/${user.id}/${upload.id}/original`,
          { headers: keyHeaders(env("SUPABASE_SERVICE_ROLE_KEY")) },
        );
        assert(!info.ok);
        await info.body?.cancel();
        // A still-valid capability can write again; the periodic recheck removes it again.
        await send(upload.upload_target);
        await call(`/rest/v1/files?id=eq.${upload.id}`, "PATCH", {
          cleanup_after: "2000-01-01T00:00:00Z",
        });
        const repeated = await fetch(apiOrigin() + "/functions/v1/cleanup-uploads", {
          method: "POST",
          headers: { Authorization: `Bearer ${env("CLEANUP_SECRET")}` },
        });
        assert(repeated.ok);
        await repeated.body?.cancel();
      });
      await t.step("validation rejects excessive size and unsupported MIME", async () => {
        assert(
          (await request(`/uploads/${crypto.randomUUID()}`, "PUT", {
            name: "x",
            byte_count: 20000001,
            content_type: "application/pdf",
          })).status === 413,
        );
        assert(
          (await request(`/uploads/${crypto.randomUUID()}`, "PUT", {
            name: "x",
            byte_count: 1,
            content_type: "text/html",
          })).status === 415,
        );
      });
    } finally {
      // Isolated test fixtures only. Never remove the shared seed data.
      for (const id of fileIDs) {
        await call("/storage/v1/object/files", "DELETE", {
          prefixes: [`${user.id}/${id}/original`],
        });
        await call(`/rest/v1/files?id=eq.${id}&owner_id=eq.${user.id}`, "DELETE");
      }
      for (const id of folderIDs.reverse()) {
        await call(
          `/rest/v1/idempotency_requests?resource_id=eq.${id}&owner_id=eq.${user.id}`,
          "DELETE",
        );
        await call(`/rest/v1/folders?id=eq.${id}&owner_id=eq.${user.id}`, "DELETE");
      }
    }
  },
});
