# Epoch

Epoch is an AI programming workbench for computational science.

This repository contains the open-source backend/tooling:
- `packages/hub`: the direct-connect Epoch service that runs on each HPC host
- `packages/protocol`: shared protocol schema

The iOS app source code is private and maintained separately.

## Direct-Connect Model

Epoch now runs as a single service on each HPC machine:
- the phone connects directly to that HPC host over `ws://` or `wss://`
- pairing, SQLite state, projects, sessions, and runtime tools all live in one service
- no outbound bridge connection is required for new deployments

The default workspace root is configured once in `epoch config`, but each project can also choose any writable folder on the HPC host. When a project provides its own folder, that folder becomes the workspace for that project instead of the default root.

`/status/resources` is intentionally slim in this model. It reports single-machine status only:
- `computeConnected`
- `storageTotalBytes`
- `storageUsedBytes`
- `storageAvailableBytes`
- `storageUsedPercent`
- `cpuPercent`
- `ramPercent`
- `gpuPercent` when available

## Prerequisites

- Node.js `>=22`
- `pnpm@10.30.1` via `corepack`
- Linux or macOS

## Quick Start

### 1. Clone and install

```bash
git clone https://github.com/poseidonchan/Epoch.git
cd Epoch

corepack enable
corepack prepare pnpm@10.30.1 --activate
pnpm install
pnpm -w build
```

### 2. Initialize Epoch on the HPC host

```bash
epoch init
```

This creates:
- `~/.epoch/config.json`
- `~/.epoch/epoch.sqlite`

The init/config flow now asks for:
- a default workspace root on the HPC host
- an explicit public pairing WebSocket URL for the phone to use
- optional OpenAI credentials

### 3. Start the direct-connect service

```bash
EPOCH_HOST=0.0.0.0 EPOCH_PORT=8787 epoch start
```

Check status:

```bash
epoch status
ss -lntp | rg ':8787'
```

## Pair With EpochApp

In the app, connect to the HPC host directly.

Examples:
- local testing: `ws://127.0.0.1:8787/ws`
- Tailscale: `ws://100.x.y.z:8787/ws`
- public test: `ws://<public-ip>:8787/ws`
- production: `wss://hpc.yourdomain.com/ws`

The pairing token is stored in `~/.epoch/config.json`.

Important:
- pairing URL generation no longer guesses a LAN IP
- set the public/reachable URL explicitly in `epoch config`
- `EPOCH_PAIR_WS_URL` can still override pairing output for one-off runs

## Project Folders

There are two supported workspace modes:

1. Default root
   Projects are created under the configured workspace root, typically:
   `~/.epoch/workspace/projects/<project-id>`

2. Explicit project folder
   The app can send a `workspacePath` for a project, and Epoch will use that exact folder on the HPC host.

Requirements for explicit project folders:
- the path must be writable by the Epoch process
- Epoch will create `artifacts/`, `runs/`, and `logs/` inside that folder if needed
- runtime tools are scoped to that chosen folder

This is the preferred model when users want to work inside an existing project checkout instead of a fixed Epoch-managed root.

## Reverse Proxy

For public access, put the service behind HTTPS and point the phone at the public `wss://.../ws` URL.

Example with Caddy:

```bash
sudo tee /etc/caddy/Caddyfile >/dev/null <<'CFG'
hpc.yourdomain.com {
    reverse_proxy 127.0.0.1:8787
}
CFG

sudo systemctl restart caddy
```

## Connectivity Checks

Without token:

```bash
curl -i http://<host>:8787/status/resources
```

With token:

```bash
TOKEN=$(jq -r .token ~/.epoch/config.json)
curl -i -H "Authorization: Bearer $TOKEN" http://<host>:8787/status/resources
```

Expected result with token: `200` and a JSON payload.

## CLI

Primary CLI:

```bash
epoch <init|config|start|restart|stop|status|doctor>
```

Repo-local equivalent while developing in this monorepo:

```bash
node packages/hub/dist/cli.js <init|config|start|restart|stop|status|doctor>
```

There is no separate public `epoch-hub` or `epoch-bridge` CLI anymore. Use `epoch` everywhere.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `EPOCH_STATE_DIR` | `~/.epoch` | State directory |
| `EPOCH_HOST` | `0.0.0.0` | Listen address |
| `EPOCH_PORT` | `8787` | Listen port |
| `EPOCH_DB_PATH` | `$EPOCH_STATE_DIR/epoch.sqlite` | SQLite path |
| `EPOCH_WORKSPACE_ROOT` | unset | Overrides configured default workspace root |
| `EPOCH_HPC_WORKSPACE_ROOT` | unset | Legacy compatibility alias for workspace root |
| `EPOCH_PAIR_WS_URL` | unset | Overrides pairing WebSocket URL |
| `OPENAI_API_KEY` | unset | OpenAI API key |

## Development

```bash
pnpm -w build
pnpm -w typecheck
pnpm -w test
```

## License

GPL-3.0
