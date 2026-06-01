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
 *   HONCHO_ASSISTANT_NAME — defaults to "Assistant"
 */
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createClient } from "./config.js";
import { createServer } from "./server.js";
import type { HonchoConfig } from "./config.js";

const baseUrl = process.env.HONCHO_API_URL?.trim();
if (!baseUrl) {
  console.error("ERROR: HONCHO_API_URL env var is required (e.g. http://localhost:8000)");
  process.exit(1);
}

const userName = process.env.X_HONCHO_USER_NAME?.trim();
if (!userName) {
  console.error("ERROR: X_HONCHO_USER_NAME env var is required");
  process.exit(1);
}

const config: HonchoConfig = {
  apiKey: process.env.HONCHO_API_KEY?.trim() || "local",
  userName,
  assistantName: process.env.HONCHO_ASSISTANT_NAME?.trim() || "Assistant",
  baseUrl,
  workspaceId: process.env.HONCHO_WORKSPACE_ID?.trim() || "default",
};

const honcho = createClient(config);
const server = createServer({ honcho, config });

const transport = new StdioServerTransport();
await server.connect(transport);
