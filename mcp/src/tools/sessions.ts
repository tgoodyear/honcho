import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { ToolContext } from "../types.js";
import {
  textResult,
  errorResult,
  formatMessage,
  formatMessages,
  formatSessionSummaries,
  workspaceIdSchema,
} from "../types.js";

export function register(server: McpServer, ctx: ToolContext) {
  // ── create_session ──────────────────────────────────────────────────
  server.registerTool(
    "create_session",
    {
      description: [
        "Get or create a session with the given ID.",
        "Use this to create or get a session with the given ID.",
        "Returns the session ID.",
      ].join("\n"),
      inputSchema: {
        workspace_id: workspaceIdSchema(ctx),
        session_id: z.string().describe("Unique identifier for the session."),
      },
    },
    async ({ workspace_id, session_id }) => {
      try {
        const session = await ctx.clientFor(workspace_id).session(session_id);
        return textResult({ session_id: session.id });
      } catch (e) {
        return errorResult(
          `Failed to create session: ${e instanceof Error ? e.message : String(e)}`,
        );
      }
    },
  );

  // ── list_sessions ───────────────────────────────────────────────────
  server.registerTool(
    "list_sessions",
    {
      description: [
        "List sessions in the given workspace (paginated).",
        "Use this to discover existing conversations.",
        "Returns session IDs with pagination metadata.",
      ].join("\n"),
      inputSchema: {
        workspace_id: workspaceIdSchema(ctx),
      },
    },
    async ({ workspace_id }) => {
      try {
        const page = await ctx.clientFor(workspace_id).sessions();
        return textResult({
          sessions: page.items.map((s) => ({ id: s.id })),
          total: page.total,
          page: page.page,
          pages: page.pages,
        });
      } catch (e) {
        return errorResult(
          `Failed to list sessions: ${e instanceof Error ? e.message : String(e)}`,
        );
      }
    },
  );

  // ── delete_session ──────────────────────────────────────────────────
  server.registerTool(
    "delete_session",
    {
      description: [
        "Delete a session and all its messages.",
        "This cannot be undone.",
      ].join("\n"),
      inputSchema: {
        workspace_id: workspaceIdSchema(ctx),
        session_id: z.string().describe("The session to delete."),
      },
    },
    async ({ workspace_id, session_id }) => {
      try {
        const session = await ctx.clientFor(workspace_id).session(session_id);
        await session.delete();
        return textResult("Session deleted successfully");
      } catch (e) {
        return errorResult(
          `Failed to delete session: ${e instanceof Error ? e.message : String(e)}`,
        );
      }
    },
  );

  // ── clone_session ───────────────────────────────────────────────────
  server.registerTool(
    "clone_session",
    {
      description: [
        "Clone a session, optionally up to a specific message.",
        "Use this to fork a conversation — e.g. to explore a different branch.",
        "Returns the new cloned session ID.",
      ].join("\n"),
      inputSchema: {
        workspace_id: workspaceIdSchema(ctx),
        session_id: z.string().describe("The session to clone."),
        message_id: z
          .string()
          .optional()
          .describe(
            "Optional: clone only up to and including this message. Omit to clone everything.",
          ),
      },
    },
    async ({ workspace_id, session_id, message_id }) => {
      try {
        const session = await ctx.clientFor(workspace_id).session(session_id);
        const cloned = await session.clone(message_id);
        return textResult({ session_id: cloned.id });
      } catch (e) {
        return errorResult(
          `Failed to clone session: ${e instanceof Error ? e.message : String(e)}`,
        );
      }
    },
  );

  // ── add_peers_to_session ────────────────────────────────────────────
  server.registerTool(
    "add_peers_to_session",
    {
      description: [
        "Add one or more peers to a session.",
        "Use this to bring participants into a conversation.",
      ].join("\n"),
      inputSchema: {
        workspace_id: workspaceIdSchema(ctx),
        session_id: z.string().describe("The session to add peers to."),
        peers: z
          .array(
            z.union([
              z.string().describe("Peer ID with default config."),
              z.object({
                peer_id: z.string().describe("Peer ID."),
                observe_me: z
                  .boolean()
                  .nullable()
                  .optional()
                  .describe("Whether this peer's messages trigger derivation in this session."),
                observe_others: z
                  .boolean()
                  .nullable()
                  .optional()
                  .describe("Whether this peer observes other peers' messages in this session."),
              }).describe("Peer with per-session config."),
            ]),
          )
          .describe("Peers to add — plain IDs or objects with per-session config."),
      },
    },
    async ({ workspace_id, session_id, peers }) => {
      try {
        const honcho = ctx.clientFor(workspace_id);
        const session = await honcho.session(session_id);
        const additions = peers.map((p) => {
          if (typeof p === "string") return p;
          const config: { observeMe?: boolean | null; observeOthers?: boolean | null } = {};
          if (p.observe_me !== undefined) config.observeMe = p.observe_me;
          if (p.observe_others !== undefined) config.observeOthers = p.observe_others;
          return Object.keys(config).length > 0
            ? [p.peer_id, config] as [string, typeof config]
            : p.peer_id;
        });
        await session.addPeers(additions);
        return textResult("Peers added to session successfully");
      } catch (e) {
        return errorResult(
          `Failed to add peers: ${e instanceof Error ? e.message : String(e)}`,
        );
      }
    },
  );

  // ── remove_peers_from_session ───────────────────────────────────────
  server.registerTool(
    "remove_peers_from_session",
    {
      description: [
        "Remove one or more peers from a session.",
      ].join("\n"),
      inputSchema: {
        workspace_id: workspaceIdSchema(ctx),
        session_id: z.string().describe("The session to remove peers from."),
        peer_ids: z
          .array(z.string())
          .describe("Peer IDs to remove."),
      },
    },
    async ({ workspace_id, session_id, peer_ids }) => {
      try {
        const session = await ctx.clientFor(workspace_id).session(session_id);
        await session.removePeers(peer_ids);
        return textResult("Peers removed from session successfully");
      } catch (e) {
        return errorResult(
          `Failed to remove peers: ${e instanceof Error ? e.message : String(e)}`,
        );
      }
    },
  );

  // ── get_session_peers ───────────────────────────────────────────────
  server.registerTool(
    "get_session_peers",
    {
      description: [
        "Get all peers participating in a session.",
        "Use this to see who is in a conversation.",
        "Returns an array of peer IDs.",
      ].join("\n"),
      inputSchema: {
        workspace_id: workspaceIdSchema(ctx),
        session_id: z.string().describe("The session to query."),
      },
    },
    async ({ workspace_id, session_id }) => {
      try {
        const session = await ctx.clientFor(workspace_id).session(session_id);
        const peers = await session.peers();
        return textResult(peers.map((p) => p.id));
      } catch (e) {
        return errorResult(
          `Failed to get session peers: ${e instanceof Error ? e.message : String(e)}`,
        );
      }
    },
  );

  // ── inspect_session ─────────────────────────────────────────────────
  server.registerTool(
    "inspect_session",
    {
      description: [
        "Inspect a session at a glance.",
        "Aggregates peer IDs, message count, and available summaries.",
        "Returns a single JSON object.",
      ].join("\n"),
      inputSchema: {
        workspace_id: workspaceIdSchema(ctx),
        session_id: z.string().describe("The session to inspect."),
      },
    },
    async ({ workspace_id, session_id }) => {
      try {
        const session = await ctx.clientFor(workspace_id).session(session_id);
        const [peers, messagePage, summaries] = await Promise.all([
          session.peers(),
          session.messages(),
          session.summaries(),
        ]);

        return textResult({
          session_id,
          peers: peers.map((peer) => ({ id: peer.id })),
          message_count: messagePage.total,
          summaries: formatSessionSummaries(summaries),
        });
      } catch (e) {
        return errorResult(
          `Failed to inspect session: ${e instanceof Error ? e.message : String(e)}`,
        );
      }
    },
  );

  // ── add_messages_to_session ─────────────────────────────────────────
  server.registerTool(
    "add_messages_to_session",
    {
      description: [
        "Add messages to a session from specific peers.",
        "Use this to record conversation turns and durable notes.",
        "",
        "Exact call shape — both identifiers matter:",
        '  { "session_id": "<session>", "messages": [ { "peer_id": "<author>", "content": "<text>" } ] }',
        "",
        "session_id is TOP-LEVEL, not inside a message.",
        "peer_id is PER-MESSAGE and names the author (an agent or person), not a role.",
        "Do not send {role, content} — that is a chat-completions shape and will not attribute correctly.",
        "peer_name and peer are accepted as aliases for peer_id.",
        "If session_id or peer_id is missing the message is still stored, filed under a fallback and",
        "tagged with metadata session_id_inferred / peer_id_inferred so the gap stays auditable.",
        "Always supply both explicitly when you know them — inferred attribution is lossy.",
      ].join("\n"),
      inputSchema: {
        workspace_id: workspaceIdSchema(ctx),
        session_id: z
          .string()
          .optional()
          .describe(
            "The session to add messages to. Top-level, not per-message. Supply this whenever known; " +
              "if omitted it falls back to HONCHO_DEFAULT_SESSION_ID or 'agent-memory' and the messages " +
              "are tagged session_id_inferred.",
          ),
        messages: z
          .array(
            z.object({
              peer_id: z
                .string()
                .optional()
                .describe(
                  "Peer ID authoring this message. Supply this whenever known; if omitted it falls back " +
                    "to HONCHO_DEFAULT_PEER_ID or the configured assistant name and the message is " +
                    "tagged peer_id_inferred.",
                ),
              peer_name: z
                .string()
                .optional()
                .describe("Alias for peer_id. Used only when peer_id is absent."),
              peer: z
                .string()
                .optional()
                .describe("Alias for peer_id. Used only when peer_id and peer_name are absent."),
              content: z.string().describe("Message text."),
              metadata: z
                .record(z.string(), z.unknown())
                .optional()
                .describe("Optional metadata."),
            }),
          )
          .describe("Messages to add."),
      },
    },
    async ({ workspace_id, session_id, messages }) => {
      try {
        // First non-blank value wins; trims and treats "" / whitespace as absent.
        const pick = (...vals: (string | undefined)[]): string | undefined =>
          vals.find((v) => typeof v === "string" && v.trim().length > 0)?.trim();

        // Read env without referencing `process` directly, so this stays safe
        // under both the local stdio runtime and the Workers bundle.
        const envDefault = (key: string): string | undefined =>
          (globalThis as { process?: { env?: Record<string, string | undefined> } })
            .process?.env?.[key];

        const explicitSessionId = pick(session_id);
        const resolvedSessionId =
          explicitSessionId ??
          pick(envDefault("HONCHO_DEFAULT_SESSION_ID")) ??
          "agent-memory";
        const sessionInferred = explicitSessionId === undefined;

        const honcho = ctx.clientFor(workspace_id);
        const session = await honcho.session(resolvedSessionId);
        const peerCache = new Map<string, Awaited<ReturnType<typeof honcho.peer>>>();
        const sessionMessages = [];
        let inferredPeerCount = 0;

        for (const msg of messages) {
          const explicitPeerId = pick(msg.peer_id, msg.peer_name, msg.peer);
          const peerId =
            explicitPeerId ??
            pick(envDefault("HONCHO_DEFAULT_PEER_ID")) ??
            ctx.config.assistantName;
          if (explicitPeerId === undefined) inferredPeerCount++;

          let peer = peerCache.get(peerId);
          if (!peer) {
            peer = await honcho.peer(peerId);
            peerCache.set(peerId, peer);
          }

          // Record inferred attribution so a guessed author is visible, never silent.
          const provenance: Record<string, unknown> = {};
          if (explicitPeerId === undefined) provenance.peer_id_inferred = true;
          if (sessionInferred) provenance.session_id_inferred = true;

          const metadata =
            msg.metadata || Object.keys(provenance).length > 0
              ? { ...(msg.metadata ?? {}), ...provenance }
              : undefined;

          sessionMessages.push(
            metadata
              ? peer.message(msg.content, { metadata })
              : peer.message(msg.content),
          );
        }

        await session.addMessages(sessionMessages);
        return textResult({
          status: "Messages added to session successfully",
          session_id: resolvedSessionId,
          message_count: sessionMessages.length,
          ...(sessionInferred ? { session_id_inferred: true } : {}),
          ...(inferredPeerCount > 0
            ? { peer_id_inferred_count: inferredPeerCount }
            : {}),
        });
      } catch (e) {
        return errorResult(
          `Failed to add messages: ${e instanceof Error ? e.message : String(e)}`,
        );
      }
    },
  );

  // ── get_session_messages ────────────────────────────────────────────
  server.registerTool(
    "get_session_messages",
    {
      description: [
        "Get messages from a session (paginated), with optional metadata filtering.",
        "Use this to read the conversation history.",
        "Returns the first page of messages with pagination metadata.",
      ].join("\n"),
      inputSchema: {
        workspace_id: workspaceIdSchema(ctx),
        session_id: z.string().describe("The session to get messages from."),
        filters: z
          .record(z.string(), z.unknown())
          .optional()
          .describe("Optional metadata filter criteria."),
      },
    },
    async ({ workspace_id, session_id, filters }) => {
      try {
        const session = await ctx.clientFor(workspace_id).session(session_id);
        const page = await session.messages(filters);
        return textResult({
          messages: formatMessages(page.items),
          total: page.total,
          page: page.page,
          pages: page.pages,
        });
      } catch (e) {
        return errorResult(
          `Failed to get messages: ${e instanceof Error ? e.message : String(e)}`,
        );
      }
    },
  );

  // ── get_session_message ─────────────────────────────────────────────
  server.registerTool(
    "get_session_message",
    {
      description: [
        "Get a single message from a session by ID.",
        "Use this when you already know the message ID and need the exact record.",
        "Returns the message object.",
      ].join("\n"),
      inputSchema: {
        workspace_id: workspaceIdSchema(ctx),
        session_id: z.string().describe("The session the message belongs to."),
        message_id: z.string().describe("The message ID to fetch."),
      },
    },
    async ({ workspace_id, session_id, message_id }) => {
      try {
        const session = await ctx.clientFor(workspace_id).session(session_id);
        const message = await session.getMessage(message_id);
        return textResult(formatMessage(message));
      } catch (e) {
        return errorResult(
          `Failed to get message: ${e instanceof Error ? e.message : String(e)}`,
        );
      }
    },
  );

  // ── get_session_context ─────────────────────────────────────────────
  server.registerTool(
    "get_session_context",
    {
      description: [
        "Get optimized context for a session, suitable for LLM prompts.",
        "Includes recent messages and an optional summary of older ones.",
        "Use this to build a context window for the next LLM call.",
        "Returns messages, summary, and session ID.",
      ].join("\n"),
      inputSchema: {
        workspace_id: workspaceIdSchema(ctx),
        session_id: z.string().describe("The session to get context for."),
        summary: z
          .boolean()
          .optional()
          .describe("Include a summary of older messages? Default: true."),
        tokens: z
          .number()
          .optional()
          .describe("Target token budget for the context window."),
      },
    },
    async ({ workspace_id, session_id, summary, tokens }) => {
      try {
        const session = await ctx.clientFor(workspace_id).session(session_id);
        const context = await session.context({ summary, tokens });
        return textResult({
          session_id: context.sessionId,
          summary: context.summary,
          messages: formatMessages(context.messages),
        });
      } catch (e) {
        return errorResult(
          `Failed to get context: ${e instanceof Error ? e.message : String(e)}`,
        );
      }
    },
  );
}
