# Cantrip: Ship Software from Chat

A private, self-hosted system that runs multiple Claude Code instances — coordinated through Discord — to build, test, and deploy software projects using natural language.

**The simplest spell for shipping software.** Create a project, build a web app, and deploy it to Vercel — all from Discord.

## How It Works

Cantrip uses Claude Code's [Channels feature](https://code.claude.com/docs/en/channels.md) to connect Claude Code sessions to a private Discord server. A **Manager Bot** oversees all projects and delegates work to a pool of **Worker Bots** (your familiars) that are attuned to projects on demand.

```
You (Discord)
    ↓
Manager Bot (always running, sees all channels)
    ↓ delegates autonomously via Discord messages
Worker Pool (familiars, attuned to projects as needed)
    ↓ codes, commits, pushes, deploys
Your Projects (isolated folders with full Claude Code access)
```

### Key Concepts

- **Worker Pool**: A scalable pool of worker bots (familiars) that can be attuned to any project. Register as many as your hardware can handle — with N familiars and 10 projects, N can be worked on simultaneously.
- **Manager Bot**: Always running, reads all projects (never writes to them), manages worker attunement, creates repos, maintains docs.
- **Channel Isolation**: Workers only see their attuned project's Discord channel (enforced by Discord permissions).
- **Full Dev Cycle**: Workers push branches, create PRs, wait for your `[MERGE]` confirmation, then merge and deploy.
- **Persistent Memory**: Daily transcript files let bots pick up context from previous sessions.

## Setup Overview

**Estimated time**: 30-60 minutes for first-time setup. Requires a Claude Max plan (~$100/mo).

### Prerequisites

Install these before starting:

| Tool | Install | Required? |
|------|---------|-----------|
| Claude Code v2.1.80+ | `npm install -g @anthropic-ai/claude-code` | Yes |
| tmux | `brew install tmux` | Yes |
| jq | `brew install jq` | Yes |
| Bun | `brew install oven-sh/bun/bun` | Yes (Discord plugin) |
| gh CLI | `brew install gh` && `gh auth login` | Yes |
| Node.js | `brew install node` | Yes |
| Vercel CLI | `npm install -g vercel` | Optional (deploys) |

### Interactive Setup (recommended)

Run the setup wizard — it guides you through every step:

```bash
./config/scripts/setup.sh
```

### Manual Setup Steps

1. **Install prerequisites** (see table above)
2. **Create Discord server** with `#manager` and project channels → `config/discord-setup.md` Steps 1-2
3. **Create Discord roles** (one per bot) → Step 3
4. **Register bot applications** in Discord Developer Portal (1 manager + N workers) → Step 4
5. **Set channel permissions** → Step 5
6. **Copy config**: `cp config/settings.json.example config/settings.json` and `cp config/bots.json.example config/bots.json`
7. **Fill in `settings.json`** with bot tokens, Discord IDs, and API keys → Steps 6, 9
8. **Fill in `bots.json`** with project channel IDs
9. **Install Discord plugin**: `/plugin install discord@claude-plugins-official` → Step 7
10. **Pair each bot** (temporary Claude Code session per bot) → Step 8
11. **Validate setup**: `./config/scripts/validate.sh`
12. **Start the system**: `./config/scripts/start-all.sh`
13. **Test**: Post in `#manager` → `create a new project called my-app`

For the full walkthrough, follow `config/discord-setup.md` end to end.

## Directory Structure

```
cantrip/
├── README.md                           # This file
├── CLAUDE.md                           # Manager bot context (read by Claude Code)
├── channel-server/                     # Custom Discord MCP channel (enables bot-to-bot messaging)
│   ├── index.ts                        # MCP server: discord.js + @modelcontextprotocol/sdk
│   └── package.json
├── config/
│   ├── settings.json                    # All config: tokens, IDs, keys (fill this out first)
│   ├── bots.json                       # Runtime state: familiar attunements + project registry
│   ├── discord-setup.md                # Discord setup guide
│   └── scripts/
│       ├── lib.sh                       # Shared library (config readers, locking, utilities)
│       ├── create-project.sh            # Cast a new project (folder + repo + channel + config)
│       ├── remove-project.sh           # Remove a project (stop worker + cleanup)
│       ├── start-manager.sh            # Launch manager bot
│       ├── start-worker.sh             # Attune a familiar to a project
│       ├── stop-worker.sh              # Stop a familiar
│       ├── start-all.sh                # Launch everything
│       ├── stop-all.sh                 # Stop everything + cleanup
│       ├── setup.sh                    # Interactive setup wizard (start here)
│       ├── validate.sh                 # Preflight checks before first launch
│       └── status.sh                   # Check what's running
├── docs/
│   ├── ARCHITECTURE.md                 # Full system design + decisions
│   ├── STATUS.md                       # Live status dashboard (manager-maintained)
│   ├── ACTIVITY.md                     # Activity log (manager-maintained)
│   ├── memory/
│   │   └── manager/                    # Manager daily transcripts
│   │       └── YYYY-MM-DD.md
│   ├── templates/
│   │   └── project-claude-md.md        # Template for new project CLAUDE.md
│   └── runbooks/
│       ├── setup-new-project.md        # How to add a project
│       └── memory-convention.md        # How bots use memory files
└── projects/
    ├── project-1/
    │   ├── CLAUDE.md                   # Worker context for this project
    │   └── .memory/                    # Worker daily transcripts
    │       └── YYYY-MM-DD.md
    └── project-2/
        ├── CLAUDE.md
        └── .memory/
```

## Architecture Summary

| Component | Count | Permissions | Discord |
|-----------|-------|-------------|---------|
| Manager Bot | 1 (always on) | Read all projects, write docs/ | All channels |
| Worker Bots | 1–N (pool) | Full R/W in assigned project only | Assigned channel only |
| Projects | Unlimited | — | One channel each |

For the full design, trade-offs, and security model, see `docs/ARCHITECTURE.md`.

## Requirements

- **macOS** (uses `caffeinate`, `tmux`; Linux support possible with minor changes)
- **Claude Max plan** (~$100/mo) — required for Claude Code with Channels
- **Discord account** — free; you'll create a private server
- **GitHub account** — free; for repo creation via `gh` CLI

See the prerequisites table in Setup Overview above for CLI tools.
