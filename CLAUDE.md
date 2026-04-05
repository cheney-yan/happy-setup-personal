# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

**Happy** is a mobile/web client for Claude Code and Codex that enables remote control and push notifications via end-to-end encryption. Run `happy claude` on your desktop; control it from your phone.

## Monorepo Structure

Yarn 1 monorepo. Six packages:

| Package | npm name | Purpose |
|---|---|---|
| `packages/happy-cli` | `happy` | CLI wrapper for Claude Code / Codex (published to npm) |
| `packages/happy-app` | `happy-app` | React Native + Expo mobile/web client |
| `packages/happy-server` | `happy-server` | Fastify 5 backend (Prisma + PGlite/Postgres) |
| `packages/happy-agent` | `happy-agent` | Remote agent control CLI |
| `packages/happy-wire` | `@slopus/happy-wire` | Shared Zod wire types (published to npm) |
| `packages/happy-app-logs` | `happy-app-logs` | Dev-only log aggregation server |

Each package has its own `CLAUDE.md` with package-specific guidelines — read those when working in a specific package.

## Key Commands

```bash
# Install all packages
yarn install

# Run CLI directly (no build needed)
yarn cli                          # or: yarn workspace happy cli

# Start local server (standalone, no Docker/Postgres/Redis needed)
yarn workspace happy-server standalone:dev   # runs on localhost:3005

# Run web app (point at local server)
EXPO_PUBLIC_HAPPY_SERVER_URL=http://localhost:3005 yarn web

# Start everything together
yarn env:up    # uses environments/ system (see below)
```

### CLI development
```bash
cd packages/happy-cli
yarn build           # tsc typecheck + pkgroll bundle
yarn test            # build then vitest run
yarn dev             # tsx src/index.ts (no build)
yarn link:dev        # create global `happy-dev` symlink
yarn dev:daemon:start  # start daemon pointing at dev data (~/.happy-dev/)
```

### App development
```bash
yarn workspace happy-app start          # Expo dev server
yarn workspace happy-app ios:dev        # iOS simulator
yarn workspace happy-app android:dev    # Android emulator
yarn workspace happy-app typecheck      # type-check after changes
yarn workspace happy-app tauri:dev      # macOS desktop (Tauri)
```

### Server development
```bash
yarn workspace happy-server standalone:dev   # embedded PGlite, loads .env.dev
yarn workspace happy-server build            # TypeScript type-check only
yarn workspace happy-server generate         # regenerate Prisma client
yarn workspace happy-server test             # vitest run
```

## Environments System

`environments/` provides a multi-environment management layer. Use `yarn env:up` to bring up a local dev environment (server + dependencies). This is the recommended way to start local development instead of starting services manually.

## Architecture: How the Pieces Connect

```
Mobile/Web App  ←──Socket.IO──→  happy-server  ←──Socket.IO──→  happy-cli (daemon)
                                      │                                │
                                  PostgreSQL                    Claude Code SDK
                                    Redis                           (PTY)
```

1. **CLI** wraps Claude Code. In remote mode, it reads/writes messages through the server via Socket.IO.
2. **Server** stores encrypted session messages and relays them between CLI and mobile. It never sees plaintext — keys stay on devices.
3. **App** decrypts and displays messages, sends user input back through the server.
4. **Daemon**: The CLI runs a background daemon (`~/.happy/` for stable, `~/.happy-dev/` for dev). Multiple CLI invocations talk to this daemon.

### Encryption boundary

All session message content is E2E encrypted with TweetNaCl before leaving the device. The server stores encrypted blobs and only sees metadata (IDs, sequence numbers, timestamps).

### Session resumption (`--resume`)

`claude --resume <id>` creates a **new** session file with a new session ID. The new file contains the full history with all message sessionIds rewritten to the new ID. The original file stays unchanged. The CLI tracks both IDs.

## Code Style (applies across all packages)

- TypeScript strict mode throughout
- No classes where functional patterns work
- No enums — use const maps instead
- `@/` alias for `src/` imports (absolute imports only)
- 4-space indentation (server); 2-space (CLI/app — check per package)
- Test files: `.test.ts` (CLI) or `.spec.ts` (server), colocated with source
- No mocking in tests — make real calls

## Stable vs Dev Isolation (CLI)

| | Stable | Dev |
|---|---|---|
| Data dir | `~/.happy/` | `~/.happy-dev/` |
| Command | `happy` | `happy-dev` (after `yarn link:dev`) |
| Daemon start | `yarn stable:daemon:start` | `yarn dev:daemon:start` |

Run `yarn setup:dev` once to initialize dev data directory.

## Local Server Environment Variables

Standalone mode (`.env.dev`) only requires:
- `HANDY_MASTER_SECRET` — master secret for auth/encryption
- `PORT` — default 3005

To point CLI at local server: `HAPPY_SERVER_URL=http://localhost:3005`

## Debugging

Server logs go to `.logs/` in `packages/happy-server/`, named `MM-DD-HH-MM-SS.log`.  
CLI/daemon logs go to `~/.happy-dev/logs/YYYY-MM-DD-HH-MM-SS-daemon.log`.  
Enable verbose server logging: `DANGEROUSLY_LOG_TO_SERVER_FOR_AI_AUTO_DEBUGGING=true`.

```bash
# Server: watch logs live
tail -f packages/happy-server/.logs/*.log

# CLI: check latest daemon log
ls -t ~/.happy-dev/logs/ | head -1 | xargs -I{} tail -f ~/.happy-dev/logs/{}
```

## Build & Release

- CLI is published to npm as `happy` — `prepublishOnly` runs build + tests
- Mobile apps use EAS Build (Expo)
- Three app build variants: `dev` / `preview` / `production` — all installable simultaneously
- CI: GitHub Actions runs typecheck + smoke tests (Node 20/24, Linux/Windows)
