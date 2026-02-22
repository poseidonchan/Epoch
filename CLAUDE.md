# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

LabOS is an iPhone-first SwiftUI app backed by a Node.js gateway daemon (Hub) and an optional HPC Bridge. The iPhone app talks to the Hub over WebSocket using a custom request/response/event framing protocol. The Hub orchestrates an AI agent loop and persists state as append-only JSONL transcripts mirrored to SQLite.

## Commands

### iOS App

Build and run via Xcode (scheme: `LabOSApp`, target: iOS simulator or device):

```bash
xcodegen generate          # Regenerate LabOS.xcodeproj from project.yml
swift test                 # Run unit tests (LabOSCoreTests)
```

Run a single Swift test:
```bash
swift test --filter LabOSCoreTests/AppStoreSemanticsTests/testDeleteSessionKeepsArtifacts
```

E2E tests (`LabOSE2ETests`) are UI tests — run from Xcode with a simulator, not `swift test`.

### Backend (JS/TS)

```bash
corepack enable
pnpm -w install            # Install all JS deps

pnpm -w build              # Build all packages
pnpm -w typecheck          # Type-check all packages
pnpm -w test               # Run all JS tests

# Individual packages
pnpm -C packages/hub build
pnpm -C packages/hub typecheck
pnpm -C packages/protocol build
pnpm -C packages/hpc-bridge build

# Regenerate Swift protocol models from schema
pnpm -w protocol:gen:swift
```

### Hub daemon

```bash
node packages/hub/dist/cli.js init      # First-time setup: creates config, runs migrations, prints token
node packages/hub/dist/cli.js config    # Wizard: set provider/model/auth
node packages/hub/dist/cli.js start     # Start daemon (background, logs → ~/.labos/hub.log)
node packages/hub/dist/cli.js restart   # Restart daemon
```

## Architecture

### Data flow

```
iPhone App (SwiftUI)
  └─ AppStore (@MainActor ObservableObject)
       ├─ BackendClient  →  HTTP REST to Hub  (projects, sessions, artifacts, runs)
       └─ GatewayClient  →  WebSocket to Hub  (streaming events, chat)

Hub (Fastify + ws)
  ├─ HTTP routes  (REST CRUD for projects/sessions/artifacts/runs)
  ├─ WebSocket    (operator and node roles, HMAC auth)
  ├─ Agent runtime (pi-agent-core + pi-ai, tool execution)
  ├─ SQLite DB    (better-sqlite3, WAL mode, SQL migrations in packages/hub/migrations/)
  └─ JSONL transcripts  (~/.labos/projects/<id>/sessions/<id>.jsonl, canonical)

HPC Bridge (Node client)
  └─ Outbound WS to Hub  (Slurm job submission, fs/log/artifact access; sim mode if no Slurm)
```

### Swift — LabOSCore

- **`AppStore.swift`**: Single `@MainActor` `ObservableObject` that holds all app state. Views read `@Published` properties; mutations flow through `AppStore` methods. `AppStore` owns both `BackendClient` (HTTP) and `GatewayClient` (WebSocket). Demo data is seeded when the gateway is not configured; the gateway connection is auto-started when it is.
- **`GatewayClient.swift`**: WebSocket connection with HMAC `connect.challenge` auth, reconnect logic, and a typed `GatewayEvent` enum for all inbound events.
- **`Models.swift`**: Core value types (`Project`, `Session`, `Artifact`, `RunRecord`, `ChatMessage`, etc.) — all `Sendable`, `Codable`, `Hashable`.
- **`APIContract.swift`**: Static URL path helpers for all REST endpoints.
- **`BackendClient.swift`**: Protocol + `MockBackendClient` implementation used in unit tests.
- **`DeepLink.swift`**: `app://project/<id>/artifact`, `.../run/<id>`, `.../session/<id>` URL codec.
- **`Generated/`**: Swift models generated from the TypeBox protocol schema via `pnpm -w protocol:gen:swift`. Do not edit by hand.

### Swift — LabOSApp (SwiftUI)

`RootContainerView` drives navigation via `store.context` (`.home` / `.project(id)` / `.session(projectID, sessionID)`). The left panel is a slide-over drawer. The Results panel is a `fullScreenCover`.

Key view hierarchy:
- **`HomeView`** — project list, resource status
- **`ProjectPageView`** — session list, artifact browser for a project
- **`SessionChatView`** — streaming chat with inline composer, plan approval sheet, live agent events
- **`ResultsPageView`** — full-screen artifacts/runs browser
- **`Drawers/`** — `ProjectsDrawerView`, `SessionsDrawerView`
- **`Shared/`** — `InlineComposerView`, `StreamingMarkdownView`, `NotebookPreviewView`, `HighlightedCodeWebView`, etc.

### Hub (Node, `packages/hub`)

- **`server.ts`**: Fastify server + WebSocket server. Handles both `operator` (iPhone) and `node` (HPC Bridge) roles. Exposes all REST routes and WebSocket framing (`req`/`res`/`event`).
- **`agent/runtime.ts`**: Wraps `pi-agent-core` `Agent` to execute an AI turn, emit plan-updated / tool-event / assistant-delta events, and handle approval gating.
- **`db/db.ts`**: SQLite pool adapter (rewrites Postgres-style `$1` params to `?`), migration runner (reads `.sql` files from `packages/hub/migrations/` in sorted order).
- **`storage/layout.ts`**: File path helpers for `~/.labos/projects/<id>/sessions/`, uploads, cache, generated dirs.
- **`indexing/`**: File context streaming and upload indexing (PDF text extraction, summaries).
- **`transport/frames.ts`**: `sendEvent`, `sendResOk`, `sendResError`, `broadcastEvent` helpers.

### Protocol (`packages/protocol`)

TypeBox schema (`src/schema.ts`) defines all wire types shared between Hub and HPC Bridge. `dist/schema.json` is consumed by `tools/codegen-swift` to generate `Sources/LabOSCore/Generated/`.

### Hub state directory layout

```
~/.labos/
  config.json
  labos.sqlite
  hub.log
  projects/
    <projectId>/
      sessions/<sessionId>.jsonl   ← canonical transcript
      uploads/
      cache/generated/
      bootstrap/
```

## Key conventions

- Swift code targets iOS 17+ and uses Swift 6 (`SWIFT_VERSION = 6.0`). All public types are `Sendable`.
- UUID IDs are transmitted as **lowercase** strings over the wire (matches SQLite `uuidv4()` output).
- `AppStore` is the only place that mutates state; views never directly mutate model data.
- Unit tests (`LabOSCoreTests`) use `AppStore(bootstrapDemo: false)` with `MockBackendClient` — no real network needed.
- E2E tests (`LabOSE2ETests`) use `XCUIApplication` and require a running simulator.
- `project.yml` (XcodeGen) is the source of truth for the Xcode project; never edit `LabOS.xcodeproj` by hand.
- JS packages use ESM (`"type": "module"`), built with `tsup`.
