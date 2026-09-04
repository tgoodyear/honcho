#!/usr/bin/env node
/**
 * Local stdio MCP entry point for Honcho.
 * Replaces the Cloudflare Worker transport with standard MCP stdio,
 * so this server can run locally via `bun run src/stdio.ts` or `node`.
 *
 * Required env vars:
 *   HONCHO_API_URL       — e.g. http://localhost:8000
 *   X_HONCHO_USER_NAME   — e.g. "Trevor Goodyear"
 *
 * Optional env vars:
 *   HONCHO_API_KEY        — defaults to "local" (self-hosted doesn't need a real key)
 *   HONCHO_WORKSPACE_ID   — defaults to "default"
 */
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  createClientFactory,
  createUnscopedClient,
} from "./config.js";
import { createServer } from "./server.js";
import type { HonchoConfig } from "./config.js";

const runtimeProcess = (
  globalThis as {
    process?: {
      env?: Record<string, string | undefined>;
      exit(code: number): never;
    };
  }
).process;
const env = runtimeProcess?.env;

const baseUrl = env?.HONCHO_API_URL?.trim();
if (!baseUrl) {
  console.error("ERROR: HONCHO_API_URL env var is required (e.g. http://localhost:8000)");
  runtimeProcess?.exit(1);
  throw new Error("HONCHO_API_URL is required");
}

const userName = env?.X_HONCHO_USER_NAME?.trim();
if (!userName) {
  console.error("ERROR: X_HONCHO_USER_NAME env var is required");
  runtimeProcess?.exit(1);
  throw new Error("X_HONCHO_USER_NAME is required");
}

const config: HonchoConfig = {
  apiKey: env?.HONCHO_API_KEY?.trim() || "local",
  baseUrl,
  workspaceId: env?.HONCHO_WORKSPACE_ID?.trim() || "default",
};

const server = createServer({
  config,
  clientFor: createClientFactory(config),
  unscoped: createUnscopedClient(config),
});

const transport = new StdioServerTransport();
await server.connect(transport);
