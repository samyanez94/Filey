import { api, call, env } from "./common.ts";

// Account provisioning is separate so functions can be restarted with the resulting demo UUID.
if (Deno.args.includes("--account")) {
  let user: { id: string } | undefined;
  for (let page = 1; !user; page++) {
    const result = await call(`/auth/v1/admin/users?page=${page}&per_page=100`);
    user = result.users.find((u: { email: string }) => u.email === env("DEMO_EMAIL"));
    if (result.users.length < 100) break;
  }
  if (!user) {
    user = await call("/auth/v1/admin/users", "POST", {
      email: env("DEMO_EMAIL"),
      password: crypto.randomUUID() + crypto.randomUUID(),
      email_confirm: true,
    });
  }
  console.log(`Demo account ID: ${user!.id}`);
  console.log("Set DEMO_USER_ID in .env.local and the Edge Function environment to this ID.");
} else {
  // Read and validate every asset before creating any remote content.
  const manifest = JSON.parse(
    await Deno.readTextFile(new URL("./seed-assets/manifest.json", import.meta.url)),
  ) as {
    folders: { key: string; name: string; parent: string | null; idempotencyKey: string }[];
    files: {
      id: string;
      name: string;
      parent: string | null;
      contentType: string;
      byteCount: number;
      sha256: string;
    }[];
  };
  const fixtures = await Promise.all(manifest.files.map(async (file) => {
    const bytes = await Deno.readFile(
      new URL(
        "./seed-assets/" + encodeURIComponent(file.name),
        import.meta.url,
      ),
    );
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
    const hash = Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
    if (bytes.length !== file.byteCount || hash !== file.sha256) {
      throw Error("Seed asset changed: " + file.name + ". Use new upload IDs for revised assets.");
    }
    return { ...file, bytes };
  }));
  const folders = new Map<string, string>();
  const parentID = (key: string | null): string | null => {
    if (key === null) return null;
    const id = folders.get(key);
    if (!id) throw Error("Unknown seed parent: " + key);
    return id;
  };
  for (const folder of manifest.folders) {
    const created = await api("/folders", "POST", {
      parent_id: parentID(folder.parent),
      name: folder.name,
    }, { "Idempotency-Key": folder.idempotencyKey });
    folders.set(folder.key, created.id);
  }
  for (const f of fixtures) {
    const upload = await api(`/uploads/${f.id}`, "PUT", {
      parent_id: parentID(f.parent),
      name: f.name,
      content_type: f.contentType,
      byte_count: f.bytes.length,
    });
    if (upload.status === "ready") continue;
    const target = upload.upload_target;
    const response = await fetch(target.url, {
      method: target.method,
      headers: target.headers,
      body: f.bytes,
      signal: AbortSignal.timeout(60_000),
    });
    const ok = response.ok;
    await response.body?.cancel();
    // Completion also recovers a previously uploaded object when seed is rerun.
    try {
      await api(`/uploads/${f.id}/complete`, "POST");
    } catch (e) {
      if (!ok) throw Error("Seed upload failed; inspect server state before retrying.");
      throw e;
    }
  }
  console.log(
    "Seeded " + manifest.folders.length + " folders and " + fixtures.length +
      " real files through the application API.",
  );
}
