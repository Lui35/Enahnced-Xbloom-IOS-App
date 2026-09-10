import { createHandler } from "./handler.ts";

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void };

Deno.serve(createHandler({
  fetch: globalThis.fetch,
  env: (name) => Deno.env.get(name),
  waitUntil: (task) => EdgeRuntime.waitUntil(task),
  sleep: (milliseconds) =>
    new Promise((resolve) => setTimeout(resolve, milliseconds)),
}));
