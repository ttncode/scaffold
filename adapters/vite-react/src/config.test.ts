import { afterEach, expect, test, vi } from "vitest";

import { loadConfig } from "./config";

afterEach(() => {
  vi.unstubAllGlobals();
});

test("loadConfig returns the served config", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => Response.json({ apiUrl: "https://api.example" })),
  );
  await expect(loadConfig()).resolves.toEqual({
    apiUrl: "https://api.example",
  });
});

test("loadConfig rejects when the server has no config", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => new Response(null, { status: 404 })),
  );
  await expect(loadConfig()).rejects.toThrow("/config.json answered 404");
});
