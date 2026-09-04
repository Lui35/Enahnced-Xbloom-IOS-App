/// Supabase's background-task API. Declared here because Deno's own types do
/// not carry it, and a request that returns before its work finishes has no
/// other way to keep the isolate alive.
declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void };

type Action = "testConnection" | "importBean" | "generateRecipe" | "enhanceRecipe";

interface CoffeeAIRequest {
  action: Action;
  model: string;
  body: Record<string, unknown>;
  /// Supplied by the app so a retry lands on the row it already created
  /// instead of paying Gemini twice. Absent from older builds, which still
  /// use the synchronous path.
  requestID?: string;
  /// Opaque to this function: what the app needs to rebuild the recipe from
  /// `response` after a relaunch, when the closure that started the request is
  /// long gone.
  context?: Record<string, unknown>;
}

const JSON_HEADERS = { "content-type": "application/json" };
const ACTIONS = new Set<Action>([
  "testConnection",
  "importBean",
  "generateRecipe",
  "enhanceRecipe",
]);
const MODEL_PATTERN = /^gemini-[a-z0-9.-]{1,64}$/;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_REQUEST_BYTES = 20_000_000;
const REQUESTS_PER_MINUTE = 20;

/// What Google returns when it is overloaded rather than when anything is
/// wrong with the request: RESOURCE_EXHAUSTED, INTERNAL, UNAVAILABLE. These are
/// worth one more try; a 400 never is.
const RETRY_STATUSES = new Set([429, 500, 503]);
const RETRY_DELAY_MS = 12_000;
const GEMINI_TIMEOUT_MS = 75_000;
/// Shorter than the first attempt so the whole background task stays inside
/// the runtime's wall-clock budget even when a slow request is what failed.
/// Observed generations land in under 30s, so this is not a real ceiling.
const GEMINI_RETRY_TIMEOUT_MS = 45_000;

/// The one action the app no longer waits for. Recipe design is the long call
/// (tens of seconds) and the only one whose result is worth keeping when the
/// phone goes away mid-flight; `testConnection` is a connectivity check the
/// user is watching, and bean import still answers inline.
const BACKGROUND_ACTIONS = new Set<Action>(["generateRecipe"]);

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
  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (request.method !== "POST") return json(405, { error: "Method not allowed" });
  if (contentLength > MAX_REQUEST_BYTES) {
    return json(413, { error: "Request is too large" });
  }

  const authorization = request.headers.get("authorization");
  const accessToken = authorization?.replace(/^Bearer\s+/i, "");
  if (!authorization || !accessToken) return json(401, { error: "Authentication required" });

  const supabaseURL = Deno.env.get("SUPABASE_URL");
  const publishableKey = readNamedKey("SUPABASE_PUBLISHABLE_KEYS")
    ?? Deno.env.get("SUPABASE_ANON_KEY");
  const secretKey = readNamedKey("SUPABASE_SECRET_KEYS")
    ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const geminiKey = Deno.env.get("GEMINI_API_KEY");
  if (!supabaseURL || !publishableKey || !secretKey || !geminiKey) {
    return json(503, { error: "AI service is not configured" });
  }

  const userResponse = await fetch(`${supabaseURL}/auth/v1/user`, {
    headers: { Authorization: authorization, apikey: publishableKey },
  });
  if (!userResponse.ok) return json(401, { error: "Invalid session" });
  const user = await userResponse.json() as { id?: string };
  if (!user.id) return json(401, { error: "Invalid session" });

  let payload: CoffeeAIRequest;
  try {
    payload = await request.json();
  } catch {
    return json(400, { error: "Invalid JSON" });
  }
  if (!ACTIONS.has(payload.action) || !MODEL_PATTERN.test(payload.model) || !payload.body) {
    return json(400, { error: "Invalid AI request" });
  }
  if (payload.requestID !== undefined && !UUID_PATTERN.test(payload.requestID)) {
    return json(400, { error: "Invalid request id" });
  }
  const requestID = payload.requestID ?? crypto.randomUUID();
  const background = BACKGROUND_ACTIONS.has(payload.action) && payload.requestID !== undefined;

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
    return json(429, { error: "Too many AI requests. Try again shortly." });
  }

  const encodedBody = JSON.stringify(payload.body);
  if (new TextEncoder().encode(encodedBody).byteLength > MAX_REQUEST_BYTES) {
    return json(413, { error: "Request is too large" });
  }

  const insertResponse = await fetch(`${supabaseURL}/rest/v1/ai_request_usage`, {
    method: "POST",
    headers: adminHeaders,
    body: JSON.stringify({
      user_id: user.id,
      request_id: requestID,
      action: payload.action,
      model: payload.model,
      status: "started",
      input_bytes: encodedBody.length,
      context: payload.context ?? null,
    }),
  });
  // `unique (user_id, request_id)` turns a resent request into a conflict,
  // which is the answer: the job is already running or already done, and
  // starting Gemini a second time would bill the user for a duplicate.
  if (insertResponse.status === 409) {
    return json(202, { requestID, duplicate: true });
  }
  if (!insertResponse.ok) {
    return json(503, { error: "Could not record the AI request", requestID });
  }

  const run = () =>
    callGemini(supabaseURL, secretKey, geminiKey, user.id!, requestID, payload.model, encodedBody, background);

  if (background) {
    // Returning ends the request; without this the isolate can be torn down
    // with the Gemini call still in flight, which is the whole failure this
    // change exists to remove.
    EdgeRuntime.waitUntil(run());
    return json(202, { requestID });
  }
  return await run();
});

async function callGemini(
  supabaseURL: string,
  secretKey: string,
  geminiKey: string,
  userID: string,
  requestID: string,
  model: string,
  encodedBody: string,
  background: boolean,
): Promise<Response> {
  try {
    let geminiResponse = await callModel(geminiKey, model, encodedBody, GEMINI_TIMEOUT_MS);
    // Only in the background: nobody is waiting, so a retry costs a later
    // recipe instead of a longer spinner. On the synchronous path the app
    // gives up at 85s, so retrying there would just guarantee it never sees
    // the answer. A timeout is never retried — the attempt already spent the
    // budget, and a returned status means the call came back fast.
    if (background && !geminiResponse.ok && RETRY_STATUSES.has(geminiResponse.status)) {
      await geminiResponse.body?.cancel();
      await new Promise((resolve) => setTimeout(resolve, RETRY_DELAY_MS));
      geminiResponse = await callModel(geminiKey, model, encodedBody, GEMINI_RETRY_TIMEOUT_MS);
    }
    const responseBody = await geminiResponse.text();

    const values: Record<string, unknown> = {
      status: geminiResponse.ok ? "succeeded" : "failed",
      error_code: geminiResponse.ok ? null : `gemini_http_${geminiResponse.status}`,
    };
    if (background && geminiResponse.ok) values.response = responseBody;
    await updateUsage(supabaseURL, secretKey, userID, requestID, values);

    return new Response(responseBody, {
      status: geminiResponse.status,
      headers: { ...JSON_HEADERS, "x-request-id": requestID },
    });
  } catch (error) {
    const code = error instanceof DOMException && error.name === "TimeoutError"
      ? "timeout"
      : "upstream_error";
    await updateUsage(supabaseURL, secretKey, userID, requestID, {
      status: "failed",
      error_code: code,
    });
    return json(code === "timeout" ? 504 : 502, {
      error: code === "timeout" ? "Gemini timed out" : "Gemini request failed",
      requestID,
    });
  }
}

function callModel(
  geminiKey: string,
  model: string,
  encodedBody: string,
  timeoutMS: number,
): Promise<Response> {
  const endpoint =
    `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`;
  return fetch(endpoint, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-goog-api-key": geminiKey,
    },
    body: encodedBody,
    signal: AbortSignal.timeout(timeoutMS),
  });
}

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
