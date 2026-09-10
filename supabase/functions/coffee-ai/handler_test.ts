import { createHandler, type Runtime } from "./handler.ts";

function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

function fixture() {
  const rows = new Map<string, Record<string, unknown>>();
  const tasks: Promise<unknown>[] = [];
  const state = {
    providerCalls: 0,
    patches: 0,
    countStatus: 200,
    patchStatuses: [] as number[],
    providerStatuses: [] as number[],
    cancelDuringGeneration: false,
    loseWriteAcknowledgement: false,
  };
  const runtime: Runtime = {
    env: (
      name,
    ) => ({
      SUPABASE_URL: "https://database.test",
      SUPABASE_ANON_KEY: "public",
      SUPABASE_SERVICE_ROLE_KEY: "secret",
      GEMINI_API_KEY: "provider",
    }[name]),
    waitUntil: (task) => {
      tasks.push(task);
    },
    sleep: () => Promise.resolve(),
    fetch: async (input, options) => {
      await Promise.resolve();
      const url = new URL(String(input));
      if (url.pathname === "/auth/v1/user") {
        return Response.json({ id: "user" });
      }
      if (url.hostname === "generativelanguage.googleapis.com") {
        state.providerCalls++;
        if (state.cancelDuringGeneration) {
          for (const row of rows.values()) {
            row.status = "cancelled";
            row.consumed_at = "now";
          }
        }
        return Response.json({ recipe: "provider result" }, {
          status: state.providerStatuses.shift() ?? 200,
        });
      }
      if (options?.method === "HEAD") {
        return new Response(null, {
          status: state.countStatus,
          headers: { "content-range": `*/${rows.size}` },
        });
      }
      if (options?.method === "POST") {
        const row = JSON.parse(String(options.body));
        if (rows.has(row.request_id)) {
          return new Response(null, { status: 409 });
        }
        rows.set(row.request_id, { ...row, consumed_at: null });
        return new Response(null, { status: 201 });
      }
      const id = url.searchParams.get("request_id")?.slice(3) ?? "";
      const row = rows.get(id);
      if (options?.method === "PATCH") {
        state.patches++;
        equal(url.searchParams.get("status"), "eq.started");
        equal(url.searchParams.get("consumed_at"), "is.null");
        const status = state.patchStatuses.shift() ?? 200;
        if (status !== 200) return new Response(null, { status });
        if (!row || row.status !== "started" || row.consumed_at) {
          return Response.json([]);
        }
        Object.assign(row, JSON.parse(String(options.body)));
        if (state.loseWriteAcknowledgement) {
          state.loseWriteAcknowledgement = false;
          throw new TypeError("Connection lost after commit");
        }
        return Response.json([{ request_id: id }]);
      }
      return Response.json(row ? [row] : []);
    },
  };
  const handler = createHandler(runtime);
  const request = (id: string | null = crypto.randomUUID(), action = "generateRecipe") =>
    new Request("https://function.test", {
      method: "POST",
      headers: {
        authorization: "Bearer user",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        requestID: id ?? undefined,
        action,
        model: "gemini-test",
        body: {},
        context: {},
      }),
    });
  return { handler, request, state, rows, tasks };
}

Deno.test("retries a failed result write without generating a second recipe", async () => {
  const f = fixture();
  f.state.patchStatuses = [503, 200];
  equal((await f.handler(f.request())).status, 202);
  await Promise.all(f.tasks);
  equal(f.state.providerCalls, 1);
  equal(f.state.patches, 2);
  equal([...f.rows.values()][0].status, "succeeded");
});

Deno.test("exhausted result writes reject the background task instead of reporting success", async () => {
  const f = fixture();
  f.state.patchStatuses = [503, 503, 503];
  equal((await f.handler(f.request())).status, 202);
  const results = await Promise.allSettled(f.tasks);
  equal(results[0].status, "rejected");
  equal(f.state.providerCalls, 1);
  equal(f.state.patches, 3);
  equal([...f.rows.values()][0].status, "started");
});

Deno.test("lost database acknowledgement converges to the already saved result", async () => {
  const f = fixture();
  f.state.loseWriteAcknowledgement = true;
  await f.handler(f.request());
  await Promise.all(f.tasks);
  equal(f.state.providerCalls, 1);
  equal([...f.rows.values()][0].status, "succeeded");
});

Deno.test("finishing worker cannot overwrite cancellation", async () => {
  const f = fixture();
  f.state.cancelDuringGeneration = true;
  await f.handler(f.request());
  await Promise.all(f.tasks);
  const row = [...f.rows.values()][0];
  equal(row.status, "cancelled");
  equal(row.response, undefined);
});

Deno.test("duplicate request IDs produce one provider call", async () => {
  const f = fixture();
  const id = crypto.randomUUID();
  const responses = await Promise.all([
    f.handler(f.request(id)),
    f.handler(f.request(id)),
  ]);
  equal(responses.map((response) => response.status), [202, 202]);
  await Promise.all(f.tasks);
  equal(f.rows.size, 1);
  equal(f.state.providerCalls, 1);
});

Deno.test("failed quota lookup does not spend provider quota", async () => {
  const f = fixture();
  f.state.countStatus = 503;
  equal((await f.handler(f.request())).status, 503);
  equal(f.state.providerCalls, 0);
  equal(f.rows.size, 0);
});

Deno.test("transient provider failures retry and persist the successful response", async () => {
  const f = fixture();
  f.state.providerStatuses = [503, 200];
  await f.handler(f.request());
  await Promise.all(f.tasks);
  equal(f.state.providerCalls, 2);
  equal([...f.rows.values()][0].status, "succeeded");
});

Deno.test("synchronous callers still receive the recipe when usage logging fails", async () => {
  const f = fixture();
  f.state.patchStatuses = [503, 503, 503];
  const response = await f.handler(f.request(null));
  equal(response.status, 200);
  equal(await response.json(), { recipe: "provider result" });
  await Promise.all(f.tasks);
  equal(f.state.providerCalls, 1);
});

Deno.test("feedback enhancement returns a job and persists its result", async () => {
  const f = fixture();
  const id = crypto.randomUUID();
  equal((await f.handler(f.request(id, "enhanceRecipe"))).status, 202);
  equal(f.tasks.length, 1);
  await Promise.all(f.tasks);
  equal(f.rows.get(id)?.action, "enhanceRecipe");
  equal(f.rows.get(id)?.status, "succeeded");
  equal(JSON.parse(String(f.rows.get(id)?.response)), { recipe: "provider result" });
});

Deno.test("older enhancement clients without a job ID still receive a response", async () => {
  const f = fixture();
  const response = await f.handler(f.request(null, "enhanceRecipe"));
  equal(response.status, 200);
  equal(await response.json(), { recipe: "provider result" });
  await Promise.all(f.tasks);
});
