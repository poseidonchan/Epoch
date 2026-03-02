<p align="center">
  <!-- TODO: Add Epoch logo at docs/images/epoch-logo.png -->
  <!-- <img src="docs/images/epoch-logo.png" alt="Epoch" width="120"> -->
  <h1 align="center">Epoch</h1>
  <p align="center">
    <strong>An AI programming workbench for computational science &mdash; from your iPhone to your HPC cluster.</strong>
  </p>
</p>

<p align="center">
  <a href="#license"><img src="https://img.shields.io/badge/license-GPLv3-blue.svg" alt="License: GPL v3"></a>
  <img src="https://img.shields.io/badge/iOS-17%2B-000000?logo=apple" alt="iOS 17+">
  <img src="https://img.shields.io/badge/Node.js-22%2B-339933?logo=node.js&logoColor=white" alt="Node.js 22+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey" alt="Platform: macOS | Linux">
</p>

---

Epoch is an open-source, iPhone-first workbench that pairs an AI coding agent with your research infrastructure. Organize projects, chat with an AI that writes and runs code, upload papers and data for context, approve execution plans before they run, submit Slurm jobs, and browse results &mdash; all from your phone.

<!-- TODO: Add hero screenshot (e.g., a composite showing chat + results views)
<p align="center">
  <img src="docs/images/screenshot-hero.png" alt="Epoch in action" width="800">
</p>
-->

## Why Epoch?

Computational science involves long feedback loops: write code, submit a job, wait, check results, iterate. Epoch shortens that loop by putting an AI agent and your cluster in your pocket.

- **AI agent that codes for you** &mdash; Describe what you need; the agent writes, runs, and iterates on code with your approval at every step.
- **HPC from your phone** &mdash; Submit and monitor Slurm jobs, browse workspace files, and view logs without SSHing into a head node.
- **Human-in-the-loop** &mdash; Every plan, command execution, and file change requires your explicit approval before it runs. You stay in control.
- **Rich context** &mdash; Upload papers (PDF with OCR), datasets, and code files. The agent uses them as context for better, grounded responses.
- **Mobile-native experience** &mdash; Voice input, streaming Markdown, syntax-highlighted code, Jupyter notebook preview, and diff views &mdash; designed for iPhone.

## Architecture

```
iPhone App (SwiftUI)              Hub (Node.js)                HPC Bridge (optional)
+-----------------------+    +------------------------+    +-----------------------+
|                       |    |                        |    |                       |
|  Projects & Sessions  +--->+  Fastify HTTP + WS     +--->+  Outbound WS to Hub  |
|  AI Chat Interface    |REST|  AI Agent Runtime      |WS  |  Slurm Integration   |
|  Voice Input          |    |  SQLite + JSONL Store   |    |  Filesystem Access   |
|  Artifact Browser     +--->+  File Indexing (PDF/OCR)|    |  Job Lifecycle Mgmt  |
|  Plan Approval        |WS  |  QR Pairing            |    |  Sandbox Policies    |
|                       |    |                        |    |                       |
+-----------------------+    +------------------------+    +-----------------------+
```

| Component | What it does |
|-----------|-------------|
| **iPhone App** | SwiftUI client for chat, project management, result browsing, and approvals. Connects to the Hub over WebSocket and REST. |
| **Hub** | Node.js daemon that orchestrates the AI agent, stores state (SQLite + append-only JSONL transcripts), indexes uploaded files, and serves the API. Runs on your Mac or a server. |
| **HPC Bridge** | Optional Node.js daemon that runs on (or near) your cluster. Connects outbound to the Hub and provides Slurm job submission, filesystem access, and runtime execution. Falls back to simulation mode if Slurm is not installed. |

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| **macOS** | 12+ | For building the iOS app (Xcode 15+) |
| **Node.js** | 22+ | Hub and HPC Bridge runtime |
| **pnpm** | 10+ | Use `corepack enable` to activate |
| **iOS device or simulator** | iOS 17+ | iPhone only |
| **Slurm** *(optional)* | Any | Only needed for HPC Bridge cluster integration |

## Quick Start

### 1. Clone and install

```bash
git clone https://github.com/TODO/Epoch.git
cd Epoch
corepack enable
pnpm install
pnpm -w build
```

### 2. Initialize the Hub

```bash
node packages/hub/dist/cli.js init
```

The interactive wizard will:
- Create the state directory (`~/.epoch/`)
- Run database migrations (embedded SQLite)
- Generate a shared authentication token
- Print a **QR code** for pairing with the iPhone app

Save the token &mdash; you'll need it to connect the app and the HPC Bridge.

<details>
<summary>Example output</summary>

```
================================
Epoch Hub Initialization
Create state/config, run migrations, and print pairing QR
================================
[1/4] OK Create or load Hub state directory
[2/4] OK Database migrations
[3/4] OK Hub config + token ready
State dir: /Users/you/.epoch
DB: /Users/you/.epoch/epoch.sqlite
Server ID: 8f3cbf9f-4a30-429c-9e17-52cdf27d9a46
Shared token (store this): 6-w2aCRIc2eWecJ-NH55Kxr_...

[4/4] OK Pairing QR generated
Scan this in Epoch iPhone app Settings > Gateway > Scan Hub QR
< QR code renders here >
```

</details>

### 3. Configure the Hub

```bash
node packages/hub/dist/cli.js config
```

The config wizard sets up:
- **AI backend** defaults (provider and model)
- **OpenAI API key** *(optional)* for file indexing, PDF OCR, and voice transcription

### 4. Start the Hub

```bash
node packages/hub/dist/cli.js start
```

Verify it's running:

```bash
node packages/hub/dist/cli.js status
```

The Hub listens on `http://0.0.0.0:8787` by default (HTTP + WebSocket).

### 5. Get the iPhone app

**Option A &mdash; TestFlight** *(recommended)*

<!-- TODO: Replace with actual TestFlight link -->
> Join the TestFlight beta: [TestFlight link coming soon]

**Option B &mdash; Build from source**

Requires macOS with Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen    # if not already installed
xcodegen generate
open Epoch.xcodeproj
```

In Xcode:
1. Select the **EpochApp** scheme
2. Choose your target (simulator or connected iPhone)
3. Build and run (`Cmd + R`)

### 6. Connect the app to your Hub

Open the app and go to **Settings > Gateway**:

| Method | How |
|--------|-----|
| **QR code** *(easiest)* | Tap **Scan Hub QR** and point your camera at the QR code from `init`. |
| **Manual entry** | Enter the WebSocket URL and token. |

**WebSocket URL reference:**

| Scenario | URL |
|----------|-----|
| Simulator on same Mac | `ws://127.0.0.1:8787/ws` |
| iPhone on same LAN | `ws://<your-mac-lan-ip>:8787/ws` |
| Remote server | `wss://your-server.example.com/ws` |

> The Hub prints your LAN IP during `init`. You can also find it with `ifconfig | grep "inet "`.

---

## HPC Bridge Setup *(optional)*

The HPC Bridge connects Epoch to a Slurm-managed cluster. Run it on the cluster head node (or any machine that can reach both the Hub and the Slurm commands).

### 1. Initialize and configure

```bash
node packages/hpc-bridge/dist/cli.js init
```

The wizard prompts for:
- **Hub WebSocket URL** &mdash; e.g., `ws://your-hub-host:8787/ws`
- **Shared token** &mdash; the token from `epoch-hub init`
- **Workspace root** &mdash; an absolute path where project files and job artifacts will live
- **Scheduler defaults** *(optional)* &mdash; partition, account, QOS, time limits, CPUs, memory, GPUs

You can also configure non-interactively:

```bash
node packages/hpc-bridge/dist/cli.js config \
  --hub ws://hub-host:8787/ws \
  --token YOUR_TOKEN \
  --workspace-root /scratch/epoch \
  --partition gpu \
  --time-mins 120 \
  --cpus 4 \
  --mem-mb 16000 \
  --gpus 1
```

### 2. Start the Bridge

```bash
node packages/hpc-bridge/dist/cli.js start
```

The Bridge connects outbound to the Hub. If Slurm commands (`sbatch`, `squeue`, etc.) are not found, it runs in **simulation mode** &mdash; useful for development and testing.

---

## CLI Reference

Both `epoch-hub` and `epoch-bridge` share a consistent set of lifecycle commands:

| Command | Description |
|---------|-------------|
| `init` | First-time setup &mdash; creates config, runs migrations (Hub), generates pairing info |
| `config` | Interactive configuration wizard (AI backend, credentials, scheduler defaults) |
| `start` | Start the daemon in the background (use `--foreground` for debug) |
| `stop` | Gracefully stop the daemon |
| `restart` | Stop + start |
| `status` | Show current config and daemon state |
| `doctor` | Run diagnostic checks |

**Hub:**

```bash
node packages/hub/dist/cli.js <command>
```

**HPC Bridge:**

```bash
node packages/hpc-bridge/dist/cli.js <command>
```

> The HPC Bridge also supports `pair` as a backward-compatible alias for `config`.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `EPOCH_STATE_DIR` | `~/.epoch` | Hub state directory (config, DB, projects) |
| `EPOCH_HOST` | `0.0.0.0` | Hub listen address |
| `EPOCH_PORT` | `8787` | Hub listen port |
| `EPOCH_DB_PATH` | `$EPOCH_STATE_DIR/epoch.sqlite` | SQLite database path |
| `EPOCH_PAIR_WS_URL` | Auto-detected LAN IP | Override the WebSocket URL in QR pairing |
| `OPENAI_API_KEY` | *(none)* | Used for file embeddings, PDF OCR, and voice transcription |

## Project Structure

```
Epoch/
  Sources/
    EpochApp/              SwiftUI views (Home, Session Chat, Results, Settings)
    EpochCore/             App state, models, networking, services
  Tests/
    EpochCoreTests/        Swift unit tests
    EpochE2ETests/         UI tests (Xcode simulator)
  packages/
    hub/                   Hub daemon (Fastify + SQLite + AI agent)
      migrations/          SQL migration files
    hpc-bridge/            HPC Bridge daemon (Slurm integration)
    protocol/              Shared TypeBox schema (generates Swift models)
    cli-utils/             Shared CLI formatting utilities
  tools/
    codegen-swift/         Schema-to-Swift code generator
  project.yml             XcodeGen project definition (source of truth)
  CLAUDE.md               Developer reference (architecture, conventions)
```

**Hub state directory** (`~/.epoch/`):

```
~/.epoch/
  config.json              Hub configuration
  epoch.sqlite             SQLite database
  hub.log                  Daemon log
  projects/
    <projectId>/
      sessions/
        <sessionId>.jsonl  Canonical session transcript (append-only)
      uploads/             User-uploaded files
      cache/generated/     AI-generated artifacts
```

## Development

```bash
# Build all packages
pnpm -w build

# Type-check all packages
pnpm -w typecheck

# Run all JS/TS tests
pnpm -w test

# Run Swift unit tests
swift test

# Run a single Swift test
swift test --filter EpochCoreTests/AppStoreSemanticsTests/testDeleteSessionKeepsArtifacts

# Regenerate Swift models from protocol schema
pnpm -w protocol:gen:swift

# Regenerate Xcode project from project.yml
xcodegen generate
```

### Key conventions

- **Swift**: Targets iOS 17+, Swift 6. All public types are `Sendable`. `AppStore` is the single `@MainActor` state container.
- **TypeScript**: ESM (`"type": "module"`), built with `tsup`. Node.js 22+.
- **State**: Append-only JSONL transcripts are the canonical source of truth; SQLite mirrors for query performance.
- **Xcode**: Never edit `Epoch.xcodeproj` by hand &mdash; use `project.yml` with XcodeGen.

## License

Epoch is licensed under the [GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html).

```
Copyright (C) 2025 Epoch Contributors

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.
```
