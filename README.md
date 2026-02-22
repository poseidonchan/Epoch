# LabOS (v0.1) — iPhone UI + Hub Gateway + HPC Bridge

LabOS is an iPhone-first SwiftUI app backed by:

- **LabOS Hub** (`@labos/hub`): a single long-running gateway/orchestrator daemon (Fastify HTTP + `ws`)
- **LabOS HPC Bridge** (`@labos/hpc-bridge`): a node client that connects outbound to the Hub and provides Slurm/fs/logs/artifacts

Hub ↔ clients speak an OpenClaw-like WebSocket protocol:

- `req` / `res` / `event` framing
- `connect.challenge` then `connect` (shared token + HMAC nonce signature)
- streaming assistant output (`agent.stream.assistant_delta`)
- plan approval popups (`exec.approval.requested` / `exec.approval.resolve`)

Session memory is persisted as **append-only JSONL transcripts** (canonical) and mirrored into **SQLite** for fast indexing/querying.

## Repo layout

- `Sources/LabOSCore`: models, app state, gateway client
- `Sources/LabOSApp`: SwiftUI app + settings UI
- `Tests/LabOSCoreTests`: semantics + deep-link tests (mock backend)
- `packages/protocol`: `@labos/protocol` (TypeBox schema + `dist/schema.json`)
- `packages/hub`: `@labos/hub` (Hub daemon)
- `packages/hpc-bridge`: `@labos/hpc-bridge` (HPC Bridge daemon)
- `tools/codegen-swift`: Swift model generation from `schema.json`

## Requirements (backend)

- Node **>= 22**
- pnpm (recommended via `corepack`)
- SQLite (embedded; no separate service required)

## Install JS deps

```bash
corepack enable
pnpm -w install
```

## Run Hub

SQLite DB path (optional; defaults to `~/.labos/labos.sqlite`):

```bash
export LABOS_DB_PATH="$HOME/.labos/labos.sqlite"
```

Build + init (creates `~/.labos/config.json`, runs DB migrations, prints token):

```bash
pnpm -C packages/hub build
node packages/hub/dist/cli.js init
```

Configure provider + model (wizard):

```bash
node packages/hub/dist/cli.js config
```

The wizard lets you pick:

- provider + default model (from `@mariozechner/pi-ai`)
- auth:
  - `openai`: API key
  - `openai-codex`: Codex OAuth (reuse `~/.codex/auth.json` or browser login)
  - other providers: API key (when supported by the wizard)

Environment variables are still supported as a fallback (advanced):

```bash
export LABOS_MODEL_PRIMARY="openai/gpt-4o-mini"
export OPENAI_API_KEY="..."
```

Start (runs in the background; logs go to `~/.labos/hub.log`):

```bash
node packages/hub/dist/cli.js start
```

Restart:

```bash
node packages/hub/dist/cli.js restart
```

Defaults / env:

- HTTP: `http://0.0.0.0:8787`
- WS: `ws://0.0.0.0:8787/ws`
- `LABOS_HOST`, `LABOS_PORT`, `LABOS_STATE_DIR`
- `LABOS_REPAIR_ON_START=0` disables JSONL→SQLite replay on startup

## Run HPC Bridge

Pair (writes `~/.labos-hpc-bridge/config.json`):

```bash
pnpm -C packages/hpc-bridge build
node packages/hpc-bridge/dist/cli.js pair --hub ws://127.0.0.1:8787/ws --token <TOKEN> --workspace-root /tmp/labos
```

Start:

```bash
node packages/hpc-bridge/dist/cli.js start
```

Notes:

- If Slurm commands (`sbatch`, `squeue`, `sacct`, `scancel`) aren’t available, the bridge uses a small SIM mode so the end-to-end flow still works.
- v0.1 assumes a single connected node.

## Open and run iPhone app

1. Open `/Users/chan/Documents/GitHub/LabOS/LabOS.xcodeproj` in Xcode.
2. Select scheme `LabOSApp`.
3. Select an iOS simulator destination (for example `iPhone 17 Pro (iOS 26.2)`).
4. Run (`Cmd+R`).

Then in the app: **Home → Settings → Gateway**

- WS URL: `ws://127.0.0.1:8787/ws` (simulator) or `ws://<your-mac-lan-ip>:8787/ws` (physical device)
- Token: printed by `labos-hub init`

Messages that look like “run/build/execute/analyze…” trigger a plan approval sheet; assistant output streams as deltas.

## Regenerate Xcode project

The checked-in project is generated from `project.yml`.

```bash
xcodegen generate
```

## Tests

```bash
swift test
pnpm -w test
```

## Regenerate Swift protocol models

```bash
pnpm -w protocol:gen:swift
```

## Internal deep-link routes

- `app://project/<projectId>/artifact?path=<urlencodedPath>`
- `app://project/<projectId>/run/<runId>`
- `app://project/<projectId>/session/<sessionId>`
