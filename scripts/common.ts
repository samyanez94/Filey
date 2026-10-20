export function env(key: string): string {
  const value = Deno.env.get(key);
  if (!value) throw Error(`Missing ${key}; load the appropriate env file first.`);
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
export async function call(path: string, method = "GET", body?: unknown) {
  const headers = keyHeaders(env("SUPABASE_SERVICE_ROLE_KEY"));
  const response = await fetch(origin() + path, {
    method,
    signal: AbortSignal.timeout(30_000),
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  if (!response.ok) throw Error(`${method} ${path.split("?")[0]} failed (${response.status})`);
  return text ? JSON.parse(text) : null;
}
export async function api(
  path: string,
  method: string,
  body?: unknown,
  extra: Record<string, string> = {},
) {
  const response = await fetch(apiOrigin() + "/functions/v1/api/v1" + path, {
    method,
    signal: AbortSignal.timeout(30_000),
    headers: {
      "Content-Type": "application/json",
      "X-Filey-API-Key": env("FILEY_API_KEY"),
      ...extra,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let data;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    throw Error(`API ${method} ${path.split("?")[0]} returned non-JSON (${response.status})`);
  }
  if (!response.ok) {
    throw Error(
      `API ${method} ${path.split("?")[0]} failed: ${data?.error?.code ?? response.status}`,
    );
  }
  return data;
}
