# Epoch

Epoch is an AI programming workbench for computational science.

This repository contains the open-source server/tooling:
- `packages/hub`: the direct-connect Epoch service that runs on each HPC host
- `packages/protocol`: the shared protocol schema

The iOS app source code is private and maintained separately.

## Epoch Is Now One Piece of Software

Epoch no longer expects a new deployment to be split across separate public `hub` and `bridge` CLIs.

For new setups, think about Epoch like this:
- you run one `epoch` service on the machine you want to work on
- EpochApp connects directly to that machine over `ws://` or `wss://`
- pairing, SQLite state, projects, sessions, runtime tools, and file indexing all live in that one service
- there is no separate public `epoch-hub` or `epoch-bridge` command you need to install for normal direct-connect use

If you have older notes that mention `epoch-hub`, `epoch-bridge`, or a separate bridge deployment, those notes are outdated for the current direct-connect model.

## What You Install

Today this repository is installed from source.

Recommended target machine:
- an HPC login node
- a workstation
- a server the phone can reach over Tailscale, LAN, or a public `wss://` endpoint

Prerequisites:
- Node.js `>=22`
- `pnpm@10.30.1` via `corepack`
- Linux or macOS

## Install From Source

```bash
git clone https://github.com/poseidonchan/Epoch.git
cd Epoch

corepack enable
corepack prepare pnpm@10.30.1 --activate
pnpm install
pnpm -w build
```

The CLI binary in this repo is `epoch`, provided by `packages/hub`.

All commands below use `epoch` for readability. If you are running directly from this checkout, the equivalent command is:

```bash
node packages/hub/dist/cli.js <command>
```

Examples:

```bash
node packages/hub/dist/cli.js init
node packages/hub/dist/cli.js config
node packages/hub/dist/cli.js start
```

## Quick Start

For a first deployment, the normal flow is:

1. Build the repo on the host machine.
2. Run `epoch init`.
3. Run `epoch config`.
4. Run `epoch start`.
5. Run `epoch status --qr`.
6. In EpochApp, scan the QR and connect.

The rest of this README explains each step in detail.

## First-Time Setup

### 1. Initialize Epoch State

Run:

```bash
epoch init
```

This creates or prepares:
- `~/.epoch/config.json`
- `~/.epoch/epoch.sqlite`
- a generated `serverId`
- a generated shared token used for pairing/auth
- a pairing QR payload

What `epoch init` does in practice:
- creates the local Epoch state directory
- runs SQLite migrations
- resolves a pairing WebSocket URL
- prints a QR that EpochApp can scan

If Tailscale is available, Epoch tries to auto-detect the Tailscale hostname and uses that for pairing output. Otherwise it falls back to loopback until you configure a better phone-reachable address.

Important:
- `epoch init` gets the service ready
- `epoch config` is where you set the human-facing name, workspace root, pairing URL, and keys

### 2. Configure Epoch

Run:

```bash
epoch config
```

This is the main setup wizard for the new all-in-one Epoch deployment.

The wizard asks for:

| Setting | What it means | Recommended value |
|---|---|---|
| Display name | The server name shown in EpochApp | A machine label users recognize, such as `GPU Login 01` |
| Default workspace root | Where new Epoch-managed projects will be created on the host | A writable path such as `/data/epoch-workspace` or `~/.epoch/workspace` |
| Pairing WS URL | The WebSocket URL the phone should connect to | Leave blank if Tailscale auto-detect is correct; otherwise set `ws://host:8787/ws` or `wss://host.example.com/ws` |
| `OPENAI_API_KEY` | OpenAI key used by Epoch's OpenAI-powered runtime paths | Configure this unless you intentionally inject it through the shell environment |

After `epoch config`, the config file normally lives at:

```bash
~/.epoch/config.json
```

## How To Set the OpenAI Key

If someone on your team says "set the APC key", check what they mean.

In the current Epoch codebase:
- there is no config field literally named `APC key`
- the OpenAI credential you usually want is `OPENAI_API_KEY`
- there is no Apple push key or `.p8` setup in the current direct-connect product path

### Option A: Set It In `epoch config` (recommended)

Run:

```bash
epoch config
```

When prompted, paste your `OPENAI_API_KEY`.

This stores the key inside Epoch's local state so the service can use it after restarts.

Use this path when:
- you want the host to keep working after reboot/login without manually exporting a shell variable each time
- you are setting up a shared server and want the key attached to that Epoch instance

### Option B: Set It In the Environment

You can also provide the key at runtime:

```bash
export OPENAI_API_KEY="sk-..."
epoch start
```

This is useful when:
- you do not want the key stored in `~/.epoch/config.json`
- you inject secrets through a scheduler, secrets manager, or shell profile

### What the OpenAI Key Is Used For

In the current direct-connect Epoch service, `OPENAI_API_KEY` is used for OpenAI-backed features such as:
- running OpenAI-powered Epoch turns when the runtime needs it
- file indexing / embedding / OCR-related flows that depend on OpenAI
- some generated metadata such as AI-created titles

If the key is missing, Epoch may still start, but OpenAI-backed actions will fail.

### Verify the Key

Run:

```bash
epoch doctor
```

You should see a model line without the "no credentials detected" warning.

## How Live Sessions Behave

Epoch now treats Codex turns as server-owned background work.

That means:
- once a turn starts, the `epoch` service keeps running it until it reaches `completed`, `failed`, or `waiting for approval`
- the iPhone app being backgrounded, suspended, disconnected, or fully closed does not stop the server-side turn
- when EpochApp reconnects, it asks the server what changed and then pulls the latest session/thread state

Current behavior to expect:
- foreground app: live updates continue over the normal WebSocket stream
- app backgrounded: connection continuity is best-effort only; iOS may suspend it at any time
- app killed or fully closed: Epoch does not send APNs, silent pushes, or visible system notifications
- app reopened later: EpochApp should resync changed sessions and messages from the server

Practical consequence:
- keep the `epoch` service running on the host if you want long Codex jobs to finish even when the phone is offline
- do not expect iPhone wakeups or system notifications from Epoch itself

## Start the Epoch Service

Once initialization and configuration are done, start Epoch:

```bash
epoch start
```

Default listen settings:
- `EPOCH_HOST=0.0.0.0`
- `EPOCH_PORT=8787`

By default `epoch start` daemonizes the service and writes logs under the Epoch state directory.

Important runtime behavior:
- `epoch start` runs the service independently from EpochApp
- active Codex turns keep running on the host even if the phone disconnects
- reconnecting the app later should resync any finished or changed sessions from server state

Useful commands:

```bash
epoch status
epoch status --qr
epoch doctor
epoch restart
epoch stop
```

For foreground development/debugging:

```bash
epoch start --foreground
```

To change host/port for a run:

```bash
EPOCH_HOST=0.0.0.0 EPOCH_PORT=8787 epoch start
```

## Pair With EpochApp

After the service is running, pair the iPhone app directly to this host.

Recommended pairing flow:

1. Run `epoch status --qr` on the host.
2. In the iPhone app, open `Settings > Servers > Scan Epoch QR`.
3. Scan the QR.
4. Connect.

Examples of valid pairing URLs:
- local testing: `ws://127.0.0.1:8787/ws`
- Tailscale: `ws://login01.your-tailnet.ts.net:8787/ws`
- public test: `ws://<public-ip>:8787/ws`
- production behind TLS: `wss://hpc.yourdomain.com/ws`

Important rules:
- the phone must be able to reach the host at the pairing URL
- `ws://127.0.0.1:8787/ws` only works for loopback/local scenarios, not for a remote phone
- if auto-detected pairing output is wrong, set the correct URL in `epoch config`
- `publicWsUrl` in config is the persistent way to override the pairing URL
- `EPOCH_PAIR_WS_URL` is a one-off environment override

The pairing token is stored in `~/.epoch/config.json`.

## Daily Usage

The normal operator workflow is:

1. Make sure the host is reachable from the phone.
2. Start Epoch with `epoch start`.
3. Open EpochApp and connect to the saved server.
4. Create a project or pick an existing one.
5. Work inside the configured default workspace root or an explicit project folder.

The normal maintenance workflow is:

```bash
epoch status
epoch doctor
epoch restart
```

## Project Folders and Workspace Behavior

Epoch supports two workspace modes.

### 1. Default Workspace Root

If a project does not specify its own folder, Epoch uses the configured workspace root.

Typical default:

```bash
~/.epoch/workspace
```

Projects are then created under an Epoch-managed area beneath that root.

### 2. Explicit Project Folder

A project can also point at a specific writable folder on the host.

This is the preferred mode when you want Epoch to work inside an existing checkout or research directory instead of an Epoch-managed project folder.

Requirements for explicit folders:
- the path must be writable by the Epoch process
- Epoch may create `artifacts/`, `runs/`, and `logs/` under that folder as needed
- runtime tools are scoped to that chosen project folder

## Connectivity and Validation Checks

### Check service state

```bash
epoch status
```

### Re-print the pairing QR

```bash
epoch status --qr
```

### Run a health-style check

```bash
epoch doctor
```

`epoch doctor` is the quickest way to confirm:
- config exists
- DB migrations are valid
- the workspace root resolves correctly
- a model is configured
- credentials are present

### Check the resource endpoint manually

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

## Public Access / Reverse Proxy

If the phone reaches Epoch through the public internet, terminate TLS in front of Epoch and pair the app with a `wss://.../ws` URL.

Example with Caddy:

```bash
sudo tee /etc/caddy/Caddyfile >/dev/null <<'CFG'
hpc.yourdomain.com {
    reverse_proxy 127.0.0.1:8787
}
CFG

sudo systemctl restart caddy
```

Then set the pairing URL in `epoch config` to:

```bash
wss://hpc.yourdomain.com/ws
```

## CLI Reference

Primary CLI:

```bash
epoch <init|config|start|restart|stop|status|doctor>
```

Repo-local equivalent:

```bash
node packages/hub/dist/cli.js <init|config|start|restart|stop|status|doctor>
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `EPOCH_STATE_DIR` | `~/.epoch` | State directory |
| `EPOCH_HOST` | `0.0.0.0` | Listen address |
| `EPOCH_PORT` | `8787` | Listen port |
| `EPOCH_DB_PATH` | `$EPOCH_STATE_DIR/epoch.sqlite` | SQLite path |
| `EPOCH_WORKSPACE_ROOT` | unset | Overrides the configured default workspace root |
| `EPOCH_HPC_WORKSPACE_ROOT` | unset | Legacy compatibility alias for workspace root |
| `EPOCH_PAIR_WS_URL` | unset | One-off override for pairing WebSocket output |
| `OPENAI_API_KEY` | unset | OpenAI credential for OpenAI-backed Epoch features |
| `EPOCH_PDF_OCR_MODEL` | `gpt-5.2` | Optional OCR model override for PDF OCR flows |

## Development

```bash
pnpm -w build
pnpm -w typecheck
pnpm -w test
```

## License

GPL-3.0
