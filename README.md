# Epoch

Epoch is an AI programming workbench for computational science.

This repository is the open-source backend/tooling part of Epoch:
- `packages/hub` (Hub server)
- `packages/hpc-bridge` (HPC Bridge)
- `packages/protocol` (shared protocol schema)

The iOS app source code is private and maintained in a separate repository.

## What You Get Here

- Hub service with WebSocket + HTTP APIs
- Pairing token + QR generation for the iPhone app
- Optional HPC Bridge that connects outbound to Hub and integrates with Slurm

## Prerequisites

- Node.js `>=22`
- `pnpm@10.30.1` (recommended via `corepack`)
- Linux/macOS
- Optional: Slurm environment (for real HPC job execution)

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

If `pnpm` is not found:

```bash
# Option A (recommended)
corepack enable
corepack prepare pnpm@10.30.1 --activate

# Option B (fallback)
npx -y pnpm@10.30.1 install
```

### 2. Initialize Hub

```bash
node packages/hub/dist/cli.js init
```

This creates:
- `~/.epoch/config.json` (contains shared token)
- `~/.epoch/epoch.sqlite`

### 3. Start Hub

```bash
EPOCH_HOST=0.0.0.0 EPOCH_PORT=8787 node packages/hub/dist/cli.js start
```

Check status:

```bash
node packages/hub/dist/cli.js status
ss -lntp | rg ':8787'
```

## Connect the iPhone App

In iPhone app: `Settings -> Gateway`

- `WS URL`: one of the valid forms below
- `Shared token`: from `~/.epoch/config.json`

Common URL examples:
- Same machine/simulator: `ws://127.0.0.1:8787/ws`
- Tailscale: `ws://100.x.y.z:8787/ws`
- Public test: `ws://<public-ip>:8787/ws`
- Production (recommended): `wss://hub.yourdomain.com/ws`

## Network Modes (Recommended Order)

1. Tailscale (best for private setups)
2. Public `wss://` via reverse proxy (best for production)
3. Public plain `ws://` on `8787` (temporary/testing only)

## AWS Security Group Setup

### If using plain `ws://<public-ip>:8787/ws`

Inbound:
- Type: `Custom TCP`
- Port: `8787`
- Source: start with your HPC egress IP `/32` (or temporary `0.0.0.0/0` for testing)

### If using `wss://hub.yourdomain.com/ws` (recommended)

Inbound:
- `HTTP` port `80` from `0.0.0.0/0` (for certificate issuance)
- `HTTPS` port `443` from `0.0.0.0/0`

Do not keep accidental invalid rules (for example port `0`).

## Reverse Proxy (Caddy, recommended)

1. Point DNS `hub.yourdomain.com` to your EC2 public IP.
2. Keep Hub running on localhost only:

```bash
EPOCH_HOST=127.0.0.1 EPOCH_PORT=8787 node packages/hub/dist/cli.js start
```

3. Install and configure Caddy:

```bash
sudo apt update
sudo apt install -y caddy

sudo tee /etc/caddy/Caddyfile >/dev/null <<'CFG'
hub.yourdomain.com {
    reverse_proxy 127.0.0.1:8787
}
CFG

sudo systemctl restart caddy
sudo systemctl status caddy --no-pager
```

4. Verify:

```bash
curl -i https://hub.yourdomain.com/status/resources
```

`401 unauthorized` here is expected and means network path is working.

## HPC Bridge Setup

Run on HPC/head node:

```bash
node packages/hpc-bridge/dist/cli.js init
```

When prompted:
- `Hub WS URL`: use your reachable hub URL (for example `ws://18.x.x.x:8787/ws` or `wss://hub.yourdomain.com/ws`)
- `Shared token`: paste token from Hub `config.json`
- `Workspace root`: absolute writable path on HPC

Then start:

```bash
node packages/hpc-bridge/dist/cli.js start
```

## Connectivity Verification Commands

### From any remote machine (or HPC)

```bash
nc -vz <hub-host> 8787
curl -i http://<hub-host>:8787/status/resources
```

Interpretation:
- TCP success + `401 unauthorized`: network OK, auth missing (expected without token)
- `Connection refused`: Hub not listening
- Timeout: SG/firewall/routing issue

With token:

```bash
TOKEN=$(jq -r .token ~/.epoch/config.json)
curl -i -H "Authorization: Bearer $TOKEN" http://<hub-host>:8787/status/resources
```

Expected: `200` with JSON payload.

## Troubleshooting (Real-World)

### `pnpm: command not found`

Use:

```bash
corepack enable
corepack prepare pnpm@10.30.1 --activate
```

### Hub QR scans but app still cannot connect

- Confirm QR/manual URL is actually reachable from phone
- For Docker/bridge environments, auto-detected `172.x.x.x` may be wrong for iPhone
- Override QR URL generation:

```bash
EPOCH_PAIR_WS_URL=ws://<reachable-host>:8787/ws node packages/hub/dist/cli.js init
```

### iPhone shows `401 unauthorized`

- This usually means network path is good
- Re-check and re-paste shared token

### iPhone shows ATS error (`NSURLErrorDomain -1022`)

- Use `wss://...` URL
- Or use an app build that explicitly allows non-TLS dev WS

### iOS install error `CoreDeviceError 3002` (for source-built private app)

Usually signing/provisioning mismatch:
- Bundle identifier in app must match provisioning profile
- Development Team must be configured
- Rebuild and reinstall after fixing signing

## CLI Commands

Hub:

```bash
node packages/hub/dist/cli.js <init|config|start|restart|stop|status|doctor>
```

HPC Bridge:

```bash
node packages/hpc-bridge/dist/cli.js <init|config|start|restart|stop|status|doctor>
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `EPOCH_STATE_DIR` | `~/.epoch` | Hub state directory |
| `EPOCH_HOST` | `0.0.0.0` | Hub listen address |
| `EPOCH_PORT` | `8787` | Hub listen port |
| `EPOCH_DB_PATH` | `$EPOCH_STATE_DIR/epoch.sqlite` | DB path |
| `EPOCH_PAIR_WS_URL` | auto-detected LAN IP | Override pairing WS URL |
| `OPENAI_API_KEY` | none | Used for OCR/embeddings/transcription features |

## Development

```bash
pnpm -w build
pnpm -w typecheck
pnpm -w test
```

## License

GPL-3.0
