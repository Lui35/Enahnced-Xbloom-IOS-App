type Action = "testConnection" | "importBean" | "generateRecipe" | "enhanceRecipe";

interface CoffeeAIRequest {
  action: Action;
  model: string;
  body: Record<string, unknown>;
}

const JSON_HEADERS = { "content-type": "application/json" };
const ACTIONS = new Set<Action>([
  "testConnection",
  "importBean",
  "generateRecipe",
  "enhanceRecipe",
]);
const MODEL_PATTERN = /^gemini-[a-z0-9.-]{1,64}$/;
const MAX_REQUEST_BYTES = 20_000_000;
const REQUESTS_PER_MINUTE = 20;

function json(status: number, value: unknown): Response {
  return new Response(JSON.stringify(value), { status, headers: JSON_HEADERS });
}

function readNamedKey(variable: string): string | undefined {
  const raw = Deno.env.get(variable);
  if (!raw) return undefined;
  try {
    return JSON.parse(raw).default;
  } catch {
    return undefined;
  }
}

Deno.serve(async (request: Request) => {
  const requestID = crypto.randomUUID();
  if (request.method !== "POST") return json(405, { error: "Method not allowed", requestID });

  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > MAX_REQUEST_BYTES) {
    return json(413, { error: "Request is too large", requestID });
  }

  const authorization = request.headers.get("authorization");
  const accessToken = authorization?.replace(/^Bearer\s+/i, "");
  if (!authorization || !accessToken) return json(401, { error: "Authentication required", requestID });

  const supabaseURL = Deno.env.get("SUPABASE_URL");
  const publishableKey = readNamedKey("SUPABASE_PUBLISHABLE_KEYS")
    ?? Deno.env.get("SUPABASE_ANON_KEY");
  const secretKey = readNamedKey("SUPABASE_SECRET_KEYS")
    ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const geminiKey = Deno.env.get("GEMINI_API_KEY");
  if (!supabaseURL || !publishableKey || !secretKey || !geminiKey) {
    return json(503, { error: "AI service is not configured", requestID });
  }

  const userResponse = await fetch(`${supabaseURL}/auth/v1/user`, {
    headers: { Authorization: authorization, apikey: publishableKey },
  });
  if (!userResponse.ok) return json(401, { error: "Invalid session", requestID });
  const user = await userResponse.json() as { id?: string };
  if (!user.id) return json(401, { error: "Invalid session", requestID });

  let payload: CoffeeAIRequest;
  try {
    payload = await request.json();
  } catch {
    return json(400, { error: "Invalid JSON", requestID });
  }
  if (!ACTIONS.has(payload.action) || !MODEL_PATTERN.test(payload.model) || !payload.body) {
    return json(400, { error: "Invalid AI request", requestID });
  }

  const since = new Date(Date.now() - 60_000).toISOString();
  const adminHeaders = { apikey: secretKey, "content-type": "application/json" };
  const countURL = new URL(`${supabaseURL}/rest/v1/ai_request_usage`);
  countURL.searchParams.set("select", "id");
  countURL.searchParams.set("user_id", `eq.${user.id}`);
  countURL.searchParams.set("created_at", `gte.${since}`);
  const countResponse = await fetch(countURL, {
    method: "HEAD",
    headers: { ...adminHeaders, Prefer: "count=exact" },
  });
  const count = Number(countResponse.headers.get("content-range")?.split("/").at(-1) ?? "0");
  if (count >= REQUESTS_PER_MINUTE) {
    return json(429, { error: "Too many AI requests. Try again shortly.", requestID });
  }

  const encodedBody = JSON.stringify(payload.body);
  if (new TextEncoder().encode(encodedBody).byteLength > MAX_REQUEST_BYTES) {
    return json(413, { error: "Request is too large", requestID });
  }
  await fetch(`${supabaseURL}/rest/v1/ai_request_usage`, {
    method: "POST",
    headers: adminHeaders,
    body: JSON.stringify({
      user_id: user.id,
      request_id: requestID,
      action: payload.action,
      model: payload.model,
      status: "started",
      input_bytes: encodedBody.length,
    }),
  });

  try {
    const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(payload.model)}:generateContent`;
    const geminiResponse = await fetch(endpoint, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-goog-api-key": geminiKey,
      },
      body: encodedBody,
      signal: AbortSignal.timeout(75_000),
    });
    const responseBody = await geminiResponse.text();

    await updateUsage(supabaseURL, secretKey, user.id, requestID, {
      status: geminiResponse.ok ? "succeeded" : "failed",
      error_code: geminiResponse.ok ? null : `gemini_http_${geminiResponse.status}`,
    });

    return new Response(responseBody, {
      status: geminiResponse.status,
      headers: { ...JSON_HEADERS, "x-request-id": requestID },
    });
  } catch (error) {
    const code = error instanceof DOMException && error.name === "TimeoutError"
      ? "timeout"
      : "upstream_error";
    await updateUsage(supabaseURL, secretKey, user.id, requestID, {
      status: "failed",
      error_code: code,
    });
    return json(code === "timeout" ? 504 : 502, {
      error: code === "timeout" ? "Gemini timed out" : "Gemini request failed",
      requestID,
    });
  }
});

async function updateUsage(
  supabaseURL: string,
  secretKey: string,
  userID: string,
  requestID: string,
  values: Record<string, unknown>,
): Promise<void> {
  const url = new URL(`${supabaseURL}/rest/v1/ai_request_usage`);
  url.searchParams.set("user_id", `eq.${userID}`);
  url.searchParams.set("request_id", `eq.${requestID}`);
  await fetch(url, {
    method: "PATCH",
    headers: { apikey: secretKey, "content-type": "application/json" },
    body: JSON.stringify(values),
  });
}
