# Cantrip: Ship Software from Chat

A private, self-hosted system that runs multiple Claude Code instances — coordinated through Discord — to build, test, and deploy software projects using natural language.

**The simplest spell for shipping software.** Create a project, build a web app, and deploy it to Vercel — all from Discord.

## How It Works

Cantrip uses Claude Code's [Channels feature](https://code.claude.com/docs/en/channels.md) to connect Claude Code sessions to a private Discord server. A **Manager Bot** oversees all projects and delegates work to a pool of **Worker Bots** (your familiars) that are attuned to projects on demand.

```
You (Discord)
    ↓
Manager Bot (always running, sees all channels)
    ↓ delegates via Discord messages
Worker Pool (4 familiars, attuned to projects as needed)
    ↓ codes, commits, pushes, deploys
Your Projects (isolated folders with full Claude Code access)
```

### Key Concepts

- **Worker Pool**: 4 pre-registered worker bots (familiars) that can be attuned to any project. With 10 projects, 4 can be worked on simultaneously.
- **Manager Bot**: Always running, reads all projects (never writes to them), manages worker attunement, creates repos, maintains docs.
- **Channel Isolation**: Workers only see their attuned project's Discord channel (enforced by Discord permissions).
- **Full Dev Cycle**: Workers push branches, create PRs, wait for your `[MERGE]` confirmation, then merge and deploy.
- **Persistent Memory**: Daily transcript files let bots pick up context from previous sessions.

## Quick Start

1. Set up the Discord server → see `config/discord-setup.md`
2. Fill in `config/settings.json` with your Discord IDs, bot tokens, and API keys
3. Start the system: `./config/scripts/start-all.sh`
4. Post in `#manager`: `create a new project called my-app`

## Directory Structure

```
cantrip/
├── README.md                           # This file
├── CLAUDE.md                           # Manager bot context (read by Claude Code)
├── config/
│   ├── settings.json                    # All config: tokens, IDs, keys (fill this out first)
│   ├── bots.json                       # Runtime state: familiar attunements + project registry
│   ├── discord-setup.md                # Discord setup guide
│   └── scripts/
│       ├── create-project.sh            # Cast a new project (folder + repo + channel + config)
│       ├── remove-project.sh           # Remove a project (stop worker + cleanup)
│       ├── start-manager.sh            # Launch manager bot
│       ├── start-worker.sh             # Attune a familiar to a project
│       ├── stop-worker.sh              # Stop a familiar
│       ├── start-all.sh                # Launch everything
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
| Worker Bots | 4 (pool) | Full R/W in assigned project only | Assigned channel only |
| Projects | Unlimited | — | One channel each |

For the full design, trade-offs, and security model, see `docs/ARCHITECTURE.md`.

## Requirements

- macOS (prototype host) with tmux
- Claude Code v2.1.80+ with `claude.ai` Max plan login
- Discord channel plugin: `/plugin install discord@claude-plugins-official`
- `gh` CLI (authenticated) for GitHub operations
- `vercel` CLI for deployments
- `jq` for parsing config in scripts
- Bun (required by Discord plugin): `brew install oven-sh/bun/bun`
- Node.js for project scaffolding
