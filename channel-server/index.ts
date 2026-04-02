#!/usr/bin/env node
/**
 * Cantrip Discord Channel Server
 *
 * A custom MCP channel server that connects Claude Code to Discord.
 * Unlike the official Discord plugin, this server passes ALL messages
 * through — including bot messages — enabling autonomous bot-to-bot
 * delegation (manager → worker).
 *
 * Environment variables:
 *   DISCORD_BOT_TOKEN     — Discord bot token (required)
 *   DISCORD_CHANNEL_IDS   — Comma-separated channel IDs to listen to (required)
 *   DISCORD_ALLOWED_USERS — Comma-separated user IDs allowed to trigger responses (optional)
 *   DISCORD_BOT_USER_ID   — This bot's own user ID, to avoid echoing own messages (optional, auto-detected)
 *
 * Usage:
 *   claude --dangerously-load-development-channels server:cantrip-discord
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import {
  Client,
  GatewayIntentBits,
  Events,
  type Message,
  type MessageReaction,
  type PartialMessageReaction,
  type User,
  type PartialUser,
} from "discord.js";

// --- Config from environment ---

const BOT_TOKEN = process.env.DISCORD_BOT_TOKEN;
if (!BOT_TOKEN) {
  console.error("DISCORD_BOT_TOKEN is required");
  process.exit(1);
}

const CHANNEL_IDS = (process.env.DISCORD_CHANNEL_IDS || "")
  .split(",")
  .map((id) => id.trim())
  .filter(Boolean);

if (CHANNEL_IDS.length === 0) {
  console.error("DISCORD_CHANNEL_IDS is required (comma-separated channel IDs)");
  process.exit(1);
}

const ALLOWED_USERS = (process.env.DISCORD_ALLOWED_USERS || "")
  .split(",")
  .map((id) => id.trim())
  .filter(Boolean);

let ownBotUserId = process.env.DISCORD_BOT_USER_ID || "";

// --- MCP Server ---

const mcp = new Server(
  { name: "cantrip-discord", version: "1.0.0" },
  {
    capabilities: {
      experimental: {
        "claude/channel": {},
        "claude/channel/permission": {},
      },
      tools: {},
    },
    instructions: [
      'Discord messages arrive as <channel source="cantrip-discord" ...> events.',
      "Each event includes channel_id, channel_name, author, author_id, and is_bot metadata.",
      "Use the discord_reply tool to send messages back to Discord channels.",
      "You may receive messages from both humans and other bots.",
      "Permission requests are relayed to Discord — users can approve/deny tool calls remotely.",
    ].join(" "),
  }
);

// --- Tools: discord_reply ---

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "discord_reply",
      description:
        "Send a message to a Discord channel. Use this to respond to Discord messages or post updates.",
      inputSchema: {
        type: "object" as const,
        properties: {
          channel_id: {
            type: "string",
            description: "The Discord channel ID to send the message to",
          },
          content: {
            type: "string",
            description:
              "The message content to send (max 2000 chars, will be split if longer)",
          },
        },
        required: ["channel_id", "content"],
      },
    },
  ],
}));

mcp.setRequestHandler(CallToolRequestSchema, async (req) => {
  if (req.params.name === "discord_reply") {
    const { channel_id, content } = req.params.arguments as {
      channel_id: string;
      content: string;
    };

    try {
      const channel = await discord.channels.fetch(channel_id);
      if (!channel || !("send" in channel)) {
        return {
          content: [{ type: "text" as const, text: `Channel ${channel_id} not found or not a text channel` }],
          isError: true,
        };
      }

      // Discord has a 2000 char limit — split long messages
      const chunks: string[] = [];
      let remaining = content;
      while (remaining.length > 0) {
        if (remaining.length <= 2000) {
          chunks.push(remaining);
          break;
        }
        // Split at last newline before 2000, or hard split at 2000
        const slice = remaining.slice(0, 2000);
        const lastNewline = slice.lastIndexOf("\n");
        const splitAt = lastNewline > 1500 ? lastNewline : 2000;
        chunks.push(remaining.slice(0, splitAt));
        remaining = remaining.slice(splitAt);
      }

      for (const chunk of chunks) {
        await (channel as any).send(chunk);
      }

      return {
        content: [{ type: "text" as const, text: `Sent ${chunks.length} message(s) to channel ${channel_id}` }],
      };
    } catch (err: any) {
      return {
        content: [{ type: "text" as const, text: `Failed to send message: ${err.message}` }],
        isError: true,
      };
    }
  }

  return {
    content: [{ type: "text" as const, text: `Unknown tool: ${req.params.name}` }],
    isError: true,
  };
});

// --- Permission Relay ---

// Track which channel each permission request should be answered in
const pendingPermissions = new Map<string, string>(); // request_id → channel_id

// Regex to detect permission verdicts: "yes abcde" or "no abcde"
const PERMISSION_VERDICT_RE = /^\s*(y|yes|n|no)\s+([a-km-z]{5})\s*$/i;

// Handle incoming permission requests from Claude Code
const PermissionRequestSchema = z.object({
  method: z.literal("notifications/claude/channel/permission_request"),
  params: z.object({
    request_id: z.string(),
    tool_name: z.string(),
    description: z.string(),
    input_preview: z.string(),
  }),
});

mcp.setNotificationHandler(PermissionRequestSchema, async ({ params }) => {
  const { request_id, tool_name, description, input_preview } = params;

  // Find the first channel to post the permission prompt in
  // (use the first configured channel — typically the bot's project channel)
  const targetChannel = CHANNEL_IDS[0];
  if (!targetChannel) return;

  pendingPermissions.set(request_id, targetChannel);

  // Format the permission prompt
  const preview =
    input_preview.length > 300
      ? input_preview.slice(0, 300) + "..."
      : input_preview;

  const prompt = [
    `**Permission Request** — \`${tool_name}\``,
    `> ${description}`,
    "```",
    preview,
    "```",
    `Reply **yes ${request_id}** to approve or **no ${request_id}** to deny.`,
  ].join("\n");

  try {
    const channel = await discord.channels.fetch(targetChannel);
    if (channel && "send" in channel) {
      await (channel as any).send(prompt);
    }
  } catch {
    // Channel unavailable — user can still approve from terminal
  }
});

// --- Discord Client ---

const discord = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.MessageContent,
    GatewayIntentBits.GuildMessageReactions,
  ],
});

function shouldProcess(msg: Message): boolean {
  // Ignore own messages
  if (msg.author.id === ownBotUserId) return false;

  // Only process messages from configured channels
  if (!CHANNEL_IDS.includes(msg.channelId)) return false;

  // If allowlist is set, filter by sender (but allow ALL bot messages through)
  if (ALLOWED_USERS.length > 0 && !msg.author.bot) {
    if (!ALLOWED_USERS.includes(msg.author.id)) return false;
  }

  return true;
}

// --- Image attachment handling ---

const IMAGE_EXTENSIONS = new Set([".png", ".jpg", ".jpeg", ".gif", ".webp"]);
const MAX_IMAGE_SIZE = 10 * 1024 * 1024; // 10MB limit

async function fetchImageAsBase64(
  url: string
): Promise<{ base64: string; mimeType: string } | null> {
  try {
    const res = await fetch(url);
    if (!res.ok) return null;

    const contentType = res.headers.get("content-type") || "image/png";
    const buffer = await res.arrayBuffer();

    if (buffer.byteLength > MAX_IMAGE_SIZE) return null;

    const base64 = Buffer.from(buffer).toString("base64");
    return { base64, mimeType: contentType };
  } catch {
    return null;
  }
}

function isImageAttachment(name: string, contentType?: string): boolean {
  if (contentType?.startsWith("image/")) return true;
  const ext = name.toLowerCase().slice(name.lastIndexOf("."));
  return IMAGE_EXTENSIONS.has(ext);
}

// --- Message handling ---

discord.on(Events.MessageCreate, async (msg: Message) => {
  if (!shouldProcess(msg)) return;

  // Check if this is a permission verdict from a human user
  if (!msg.author.bot) {
    const match = PERMISSION_VERDICT_RE.exec(msg.content);
    if (match) {
      const verdict = match[1].toLowerCase().startsWith("y") ? "allow" : "deny";
      const requestId = match[2].toLowerCase();

      // Only process if we have a pending request with this ID
      if (pendingPermissions.has(requestId)) {
        pendingPermissions.delete(requestId);
        try {
          await mcp.notification({
            method: "notifications/claude/channel/permission",
            params: {
              request_id: requestId,
              behavior: verdict,
            },
          });
          // React to confirm we processed the verdict
          await msg.react(verdict === "allow" ? "\u2705" : "\u274C").catch(() => {});
        } catch {
          // MCP connection may have closed
        }
        return; // Don't forward verdict as a regular message
      }
    }
  }

  // Build a human-readable message for Claude
  const channelName =
    "name" in msg.channel ? (msg.channel as any).name : msg.channelId;
  const authorTag = msg.author.bot
    ? `${msg.author.username} [BOT]`
    : msg.author.username;

  // Process attachments: images get downloaded as base64, others just get URLs
  const attachmentLines: string[] = [];
  const imageAttachments: Array<{ base64: string; mimeType: string }> = [];

  for (const [, attachment] of msg.attachments) {
    if (isImageAttachment(attachment.name || "", attachment.contentType || undefined)) {
      const imgData = await fetchImageAsBase64(attachment.url);
      if (imgData) {
        imageAttachments.push(imgData);
        attachmentLines.push(`[Image: ${attachment.name}]`);
      } else {
        attachmentLines.push(`[Image: ${attachment.name} — ${attachment.url}]`);
      }
    } else {
      attachmentLines.push(`[Attachment: ${attachment.name} — ${attachment.url}]`);
    }
  }

  const body = [
    `#${channelName} | ${authorTag}:`,
    msg.content,
    ...attachmentLines,
  ]
    .filter(Boolean)
    .join("\n");

  try {
    await mcp.notification({
      method: "notifications/claude/channel",
      params: {
        content: body,
        meta: {
          channel_id: msg.channelId,
          channel_name: channelName,
          author: msg.author.username,
          author_id: msg.author.id,
          is_bot: String(msg.author.bot),
          message_id: msg.id,
          // Include base64 image data if any (Claude can process these)
          ...(imageAttachments.length > 0
            ? {
                images: JSON.stringify(
                  imageAttachments.map((img) => ({
                    type: "base64",
                    media_type: img.mimeType,
                    data: img.base64,
                  }))
                ),
              }
            : {}),
        },
      },
    });
  } catch {
    // MCP connection may have closed — ignore silently
  }
});

// --- Reaction handling ---

discord.on(
  Events.MessageReactionAdd,
  async (
    reaction: MessageReaction | PartialMessageReaction,
    user: User | PartialUser
  ) => {
    // Fetch partial data if needed
    if (reaction.partial) {
      try {
        reaction = await reaction.fetch();
      } catch {
        return;
      }
    }

    // Ignore own reactions
    if (user.id === ownBotUserId) return;

    // Only process reactions in configured channels
    if (!CHANNEL_IDS.includes(reaction.message.channelId)) return;

    // If allowlist is set, filter human users
    if (ALLOWED_USERS.length > 0 && !user.bot) {
      if (!ALLOWED_USERS.includes(user.id)) return;
    }

    const channelName =
      "name" in reaction.message.channel
        ? (reaction.message.channel as any).name
        : reaction.message.channelId;

    const emoji =
      reaction.emoji.name || reaction.emoji.toString();
    const targetAuthor = reaction.message.author?.username || "unknown";
    const targetPreview = reaction.message.content
      ? reaction.message.content.slice(0, 100)
      : "(no text)";

    const body = [
      `#${channelName} | ${user.username} reacted ${emoji} to ${targetAuthor}'s message:`,
      `> ${targetPreview}`,
    ].join("\n");

    try {
      await mcp.notification({
        method: "notifications/claude/channel",
        params: {
          content: body,
          meta: {
            channel_id: reaction.message.channelId,
            channel_name: channelName,
            author: user.username || "unknown",
            author_id: user.id,
            is_bot: String(user.bot || false),
            message_id: reaction.message.id,
            reaction: emoji,
            reaction_target_author: targetAuthor,
          },
        },
      });
    } catch {
      // MCP connection may have closed
    }
  }
);

discord.once(Events.ClientReady, (client) => {
  // Auto-detect own bot user ID
  ownBotUserId = client.user.id;
  // Log to stderr (stdout is reserved for MCP stdio transport)
  console.error(
    `[cantrip-discord] Connected as ${client.user.tag} (${client.user.id})`
  );
  console.error(
    `[cantrip-discord] Listening on channels: ${CHANNEL_IDS.join(", ")}`
  );
});

// --- Startup ---

async function main() {
  // Connect MCP first (stdio transport)
  const transport = new StdioServerTransport();
  await mcp.connect(transport);

  // Then connect to Discord
  await discord.login(BOT_TOKEN);
}

main().catch((err) => {
  console.error("[cantrip-discord] Fatal:", err);
  process.exit(1);
});
