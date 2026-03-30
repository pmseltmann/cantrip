# Runbook: Casting a New Project

## Prerequisites

- Cantrip system set up per `config/discord-setup.md`
- Manager bot running
- `gh` CLI authenticated

## Via Discord (Preferred)

Post in `#manager`:

```
@Manager create a new project called my-app.
Tech stack: Next.js.
Deploy target: Vercel.
```

The manager bot will run `create-project.sh` which handles everything automatically, then suggest attuning a familiar.

## Via Script (Manual)

If doing it yourself, the `create-project.sh` script does it all in one command:

```bash
./config/scripts/create-project.sh my-app \
  --tech-stack "Next.js" \
  --deploy-target "Vercel" \
  --deploy-command "vercel --prod --token \$VERCEL_TOKEN"
```

This creates the folder, writes CLAUDE.md from template, creates the GitHub repo, creates the Discord channel via API, updates bots.json, and adds the channel to access.json.

Use `--no-repo` or `--no-channel` to skip those steps if needed.

### Attune a Familiar

Via Discord (natural language works fine):
```
@Manager assign a worker to my-app
```

Or manually:
```bash
./config/scripts/start-worker.sh worker-1 my-app
```

## Removing a Project

1. Stop any assigned worker: `./config/scripts/stop-worker.sh worker-N`
2. Remove from `config/bots.json`
3. Delete the Discord channel
4. Archive the GitHub repo (optional)
5. Move or delete `projects/my-app/`
