# Discord Server Setup Guide

Step-by-step guide to setting up the Discord server and bot accounts for Cantrip.

## Step 1: Create the Discord Server

1. Open Discord → click "+" → "Create My Own" → "For me and my friends"
2. Name it "Cantrip Workspace" (or your preference)
3. Keep it private — do not share the invite link

## Step 2: Create Channel Categories and Channels

| Channel | Category | Purpose |
|---------|----------|---------|
| `#general` | General | Casual coordination |
| `#manager` | System | Talk to the manager: create projects, assign workers, check status |
| `#project-1` | Projects | Project-1 workspace |
| `#project-2` | Projects | Project-2 workspace |

Add more `#project-<name>` channels as you create projects. The manager bot can create channels via Discord API once configured.

## Step 3: Create Discord Roles

Create these roles (Server Settings → Roles):

| Role | Purpose | Assign To |
|------|---------|-----------|
| `Bot-Manager` | Manager bot identity | Manager bot |
| `Bot-Worker-1` | Worker 1 identity | Worker-1 bot |
| `Bot-Worker-2` | Worker 2 identity | Worker-2 bot |
| ... | Add more as needed | ... |

Create one role per worker bot. You can start with 1–2 workers and add more later — just register a new Discord bot application, add its token and user ID to `settings.json`, and create a matching role.

The manager role should have "Manage Channels" and "Manage Roles" permissions so it can toggle worker channel visibility via API.

## Step 4: Register Discord Bot Applications

Go to the [Discord Developer Portal](https://discord.com/developers/applications). Create **1 manager application + 1 application per worker** (e.g., 1 manager + 2 workers = 3 applications). Add more worker applications any time you want to scale up:

For each:

1. Click "New Application", name it (e.g., "Cantrip-Manager", "Cantrip-Worker-1")
2. **Bot tab**: Click "Reset Token" → save the token securely
3. **Bot tab**: Enable **"Message Content Intent"** under Privileged Gateway Intents
4. **OAuth2 → URL Generator**:
   - Scopes: `bot`
   - Bot Permissions: View Channels, Send Messages, Send Messages in Threads, Read Message History, Attach Files, Add Reactions
   - For the manager bot, also add: Manage Channels, Manage Roles
5. Use the generated URL to invite the bot to your server
6. In the server, assign each bot the corresponding role

### Bot naming suggestions:
- Give each bot a distinct avatar (colors, numbers, etc.)
- Manager: professional/neutral avatar
- Workers: numbered or color-coded avatars

## Step 5: Set Default Channel Permissions

For project channels (`#project-1`, `#project-2`, etc.):

1. Edit channel → Permissions
2. `@everyone`: Deny "View Channel"
3. `Bot-Manager` role: Allow "View Channel" + "Send Messages"
4. All `Bot-Worker-*` roles: Allow "View Channel" + "Send Messages"

Workers can see all project channels by default, but the **Channels plugin** only delivers messages from channels they can see. When a worker is assigned to a project, the manager bot will programmatically toggle which channel the worker's role can view — this is the primary isolation mechanism.

Alternatively, start with all workers having view access everywhere, and rely on CLAUDE.md instructions for isolation. Tighten permissions once you've prototyped and confirmed the Discord API approach works.

## Step 6: Store Bot Tokens and IDs

Add all tokens and IDs to `config/settings.json`:

```json
{
  "discord": {
    "server_id": "your-server-id"
  },
  "user": {
    "discord_user_id": "your-discord-user-id"
  },
  "tokens": {
    "manager": "your-manager-bot-token",
    "worker-1": "your-worker-1-bot-token",
    "worker-2": "your-worker-2-bot-token"
  },
  "bots": {
    "manager": { "discord_user_id": "manager-bot-user-id" },
    "worker-1": { "discord_user_id": "worker-1-bot-user-id" },
    "worker-2": { "discord_user_id": "worker-2-bot-user-id" }
  }
}
```

Add more `worker-N` entries to both `tokens` and `bots` for each additional worker.

All scripts read from this file — no environment variables needed.

## Step 7: Install the Discord Channel Plugin

In any Claude Code session:

```
/plugin install discord@claude-plugins-official
```

One-time per machine.

## Step 8: Pair Each Bot

**Note**: Pairing is per-bot but the access policy is shared across all bots on the same machine (same `access.json`). You must run the configure + pair flow for each bot's token, but you only need to set the access policy once.

For each bot (manager + all workers), start a temporary Claude Code session with that bot's token (copy from `settings.json`):

```bash
# Paste the bot's token from settings.json
DISCORD_BOT_TOKEN="paste-token-here" claude --channels plugin:discord@claude-plugins-official
```

Inside the session, configure with the same token:
```
/discord:configure paste-token-here
```

In Discord, DM the bot → it sends a pairing code → enter it:
```
/discord:access pair <code>
```

Lock access:
```
/discord:access policy allowlist
```

Exit the session. Repeat for each bot.

## Step 9: Record All IDs

Make sure `config/settings.json` has:
- `discord.server_id` — right-click server name → "Copy Server ID"
- `discord.manager_channel_id` — right-click #manager → "Copy Channel ID"
- `user.discord_user_id` — right-click your username → "Copy User ID"
- `bots.*.discord_user_id` — right-click each bot → "Copy User ID"
- `bots.*.discord_role_id` — (optional) for channel permission management

**Tip**: Enable Developer Mode first (Settings → Advanced → Developer Mode).

## Step 10: Test

```bash
# Start the system
./config/scripts/start-all.sh

# Check status
./config/scripts/status.sh

# Post in #manager — manager should respond
# Assign a worker to a project
# Post in #project-1 — worker should respond
```

## Troubleshooting

**Bot not responding**: Check tmux session is running (`tmux ls`), verify token is correct, ensure Message Content Intent is enabled, check channel permissions, and verify `access.json` (see below).

**Auth errors**: Re-authenticate Claude Code with `claude login`. Must use `claude.ai` login (not Console/API key).

**Multiple bots same token**: Each bot MUST have a unique token. Check `config/settings.json`.

**Bot sees wrong channels**: Verify Discord role permissions. The manager bot should be the only one managing channel visibility.

**caffeinate not working**: Run `caffeinate -dims &` manually, or add to your launchd plist.

### access.json — the hidden dependency

The file `~/.claude/channels/discord/access.json` controls which Discord channels Claude Code will listen to. **Bots will silently ignore messages from channels not listed here.**

- **Location**: `~/.claude/channels/discord/access.json`
- **Shared by all bots** on the same machine (same file regardless of which bot token is active)
- **Managed automatically** by `start-worker.sh` and `create-project.sh` — you shouldn't need to edit it manually
- **Format**: Each channel ID maps to `requireMention` (whether the bot needs an @mention) and `allowFrom` (list of Discord user IDs that can talk to the bot)

**To inspect**:
```bash
cat ~/.claude/channels/discord/access.json | jq .
```

**Example entry**:
```json
{
  "groups": {
    "1487709515141873815": {
      "requireMention": false,
      "allowFrom": ["422111263808684032"]
    }
  }
}
```

**Common issues**:
- Channel not in `access.json` → bot ignores all messages in that channel. Fix: re-run `start-worker.sh` for the project, or add the channel manually.
- Wrong `allowFrom` user ID → bot ignores your messages. The ID must be your Discord user ID (not the bot's).
- File doesn't exist → run `/discord:configure` in a Claude Code session to initialize it.
