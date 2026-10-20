export function env(key: string): string {
  const value = Deno.env.get(key);
  if (!value) throw Error(`Missing ${key}; load .env.local first.`);
  return value;
}
export const apiOrigin = () => (Deno.env.get("FUNCTIONS_ORIGIN") || origin()).replace(/\/$/, "");
export const origin = () => env("SUPABASE_URL").replace(/\/$/, "");
export function keyHeaders(key: string): Record<string, string> {
  return {
    apikey: key,
    "Content-Type": "application/json",
    ...(key.startsWith("eyJ") ? { Authorization: `Bearer ${key}` } : {}),
  };
}
export async function call(path: string, method = "GET", body?: unknown, token?: string) {
  const headers = token
    ? {
      apikey: env("SUPABASE_ANON_KEY"),
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    }
    : keyHeaders(env("SUPABASE_SERVICE_ROLE_KEY"));
  const response = await fetch(origin() + path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  if (!response.ok) throw Error(`${method} ${path.split("?")[0]} failed (${response.status})`);
  return text ? JSON.parse(text) : null;
}
export async function login() {
  const response = await fetch(origin() + "/auth/v1/token?grant_type=password", {
    method: "POST",
    headers: keyHeaders(env("SUPABASE_ANON_KEY")),
    body: JSON.stringify({ email: env("DEMO_EMAIL"), password: env("DEMO_PASSWORD") }),
  });
  if (!response.ok) {
    await response.body?.cancel();
    throw Error(`Demo sign-in failed (${response.status})`);
  }
  return await response.json();
}
export async function api(
  path: string,
  method: string,
  token: string,
  body?: unknown,
  extra: Record<string, string> = {},
) {
  const response = await fetch(apiOrigin() + "/functions/v1/api/v1" + path, {
    method,
    headers: {
      ...keyHeaders(env("SUPABASE_ANON_KEY")),
      Authorization: `Bearer ${token}`,
      ...extra,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = await response.json();
  if (!response.ok) {
    throw Error(`API ${method} ${path} failed: ${data.error?.code ?? response.status}`);
  }
  return data;
}
