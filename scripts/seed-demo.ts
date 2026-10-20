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
  const folder = await api("/folders", "POST", { parent_id: null, name: "Sample Files" }, {
    "Idempotency-Key": "10000000-0000-4000-8000-000000000001",
  });
  const nested = await api("/folders", "POST", {
    parent_id: folder.id,
    name: "Interview Notes",
  }, { "Idempotency-Key": "10000000-0000-4000-8000-000000000002" });
  // Valid tiny PNG and a generated one-page PDF; no external downloads or libraries.
  const png = Uint8Array.from(
    atob(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGMwqTgJAAJZAXbPjnORAAAAAElFTkSuQmCC",
    ),
    (c) => c.charCodeAt(0),
  );
  // Keep fixture byte length stable so existing seed IDs remain replayable.
  const title = "Filey demo PDF".padEnd(21);
  const stream = `BT /F1 18 Tf 50 750 Td (${title}) Tj ET`;
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    `<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`,
  ];
  let pdf = "%PDF-1.4\n";
  const offsets = [0];
  for (const [i, object] of objects.entries()) {
    offsets.push(pdf.length);
    pdf += `${i + 1} 0 obj\n${object}\nendobj\n`;
  }
  const xref = pdf.length;
  pdf += `xref\n0 6\n0000000000 65535 f \n${
    offsets.slice(1).map((n) => `${String(n).padStart(10, "0")} 00000 n \n`).join("")
  }trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  const fixtures = [
    {
      id: "20000000-0000-4000-8000-000000000001",
      parent_id: folder.id,
      name: "Sample Photo.png",
      type: "image/png",
      bytes: png,
    },
    {
      id: "20000000-0000-4000-8000-000000000002",
      parent_id: nested.id,
      name: "Interview Notes.pdf",
      type: "application/pdf",
      bytes: new TextEncoder().encode(pdf),
    },
  ];
  for (const f of fixtures) {
    const upload = await api(`/uploads/${f.id}`, "PUT", {
      parent_id: f.parent_id,
      name: f.name,
      content_type: f.type,
      byte_count: f.bytes.length,
    });
    if (upload.status === "ready") continue;
    const target = upload.upload_target;
    const response = await fetch(target.url, {
      method: target.method,
      headers: target.headers,
      body: f.bytes,
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
  console.log("Seeded nested folders, a PNG, and a PDF through the application API.");
}
