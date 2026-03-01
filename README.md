# LabOS

LabOS 是一个 iPhone 优先的 AI 编程工作台，核心由三部分组成：

- `LabOSApp`（SwiftUI iOS 客户端）
- `@labos/hub`（Node.js Hub 守护进程，Fastify + WebSocket + SQLite）
- `@labos/hpc-bridge`（可选，连接 HPC/Slurm 与远端工作区）

当前主执行链路是 **Codex RPC over `/codex`**；同时保留 legacy `/ws` 网关能力用于兼容与桥接。

## 架构总览

```text
iOS App (LabOSApp)
  ├─ UI + AppStore 状态管理
  ├─ GatewayClient (legacy /ws)
  └─ CodexRPCClient (/codex, JSON-RPC)
            │
            ▼
LabOS Hub (@labos/hub)
  ├─ HTTP API + WS endpoints (/ws, /codex)
  ├─ Codex RPC router/handlers (thread/turn/labos/model/skills)
  ├─ AI model/provider resolution
  ├─ Project file indexing (extract/chunk/embed/summarize)
  ├─ SQLite (migrations in packages/hub/migrations)
  └─ JSONL transcripts + project storage (~/.labos/projects/...)
            │
            ▼
HPC Bridge (@labos/hpc-bridge, optional)
  ├─ outbound WS to Hub
  ├─ Slurm/fs/runtime tools
  └─ command/runtime safety policy (default/full)
```

## 仓库结构

- `Sources/LabOSApp`: iOS SwiftUI 应用与页面
- `Sources/LabOSCore`: 应用核心状态、模型、网关/RPC 客户端、服务层
- `Tests/LabOSCoreTests`, `Tests/LabOSAppTests`: Swift 单元测试
- `packages/hub`: Hub 守护进程与 Codex RPC 实现
- `packages/hpc-bridge`: HPC Bridge 守护进程
- `packages/protocol`: 网关协议（TypeBox + schema 导出）
- `packages/codex-spec`: codex app-server 协议 schema 产物与校验
- `tools/codegen-swift`: 从协议 schema 生成 Swift 模型
- `tools/ios/rebuild_reinstall_labos.sh`: 本地 iOS 重装/校验脚本
- `project.yml`: XcodeGen 项目源（`LabOS.xcodeproj` 由其生成）

## 运行要求

- macOS + Xcode（iOS 17+ 目标）
- Node.js >= 22
- pnpm（推荐 `corepack enable`）
- SQLite（Hub 内嵌，无需单独服务）

## 快速开始

### 1) 安装依赖

```bash
corepack enable
pnpm -w install
```

### 2) 启动 Hub

```bash
pnpm build:hub
node packages/hub/dist/cli.js init
node packages/hub/dist/cli.js start
node packages/hub/dist/cli.js status
node packages/hub/dist/cli.js stop
```

说明：

- `labos-hub <init|config|start|restart|stop|status|doctor>`
- `init/config` 在 TTY 下会进入向导式配置；非 TTY 模式保持脚本友好（不阻塞交互）。
- `status` 用于查看 Hub 配置与守护进程状态；`doctor` 用于更深入诊断；`stop` 会安全停止后台 Hub 进程。
- `init` 会创建 `~/.labos/config.json`，执行 migration，并打印共享 token/QR pairing 信息。
- `config` 会配置 Codex backend 默认值与 OpenAI key（用于文件索引/embedding/OCR 等能力）。
- 默认监听：
  - HTTP: `http://0.0.0.0:8787`
  - WS legacy: `ws://0.0.0.0:8787/ws`
  - WS codex: `ws://0.0.0.0:8787/codex`

常用环境变量：

- `LABOS_HOST`, `LABOS_PORT`, `LABOS_STATE_DIR`, `LABOS_DB_PATH`
- `LABOS_REPAIR_ON_START=0` 可关闭 JSONL→SQLite 启动修复
- `LABOS_PDF_OCR_MODEL` 可指定 PDF OCR 模型（默认 `gpt-5.2`）

### 3) （可选）启动 HPC Bridge

```bash
pnpm build:hpc-bridge
node packages/hpc-bridge/dist/cli.js init
node packages/hpc-bridge/dist/cli.js config --hub ws://127.0.0.1:8787/ws --token <TOKEN> --workspace-root /tmp/labos
node packages/hpc-bridge/dist/cli.js doctor
node packages/hpc-bridge/dist/cli.js start
node packages/hpc-bridge/dist/cli.js status
node packages/hpc-bridge/dist/cli.js restart
node packages/hpc-bridge/dist/cli.js stop
```

说明：

- `labos-hpc-bridge <init|config|pair|start|restart|stop|status|doctor>`
- `pair` 保留为兼容别名；`pair --hub ... --token ... --workspace-root ...` 旧脚本仍可直接使用。
- `start` 默认后台守护进程模式，`start --foreground` 可用于调试。
- `init/config` 在 TTY 下会进入向导式配置；非 TTY 模式可通过 flags 批处理。
- `runtime policy` 默认是 **open**：仅当请求里提供 `policy` override 时才会启用并发/资源上限。
- 配置写入 `~/.labos-hpc-bridge/config.json`，PID/log 位于同目录下 `bridge.pid` / `bridge.log`。
- 若宿主机缺少 `sbatch/squeue/sacct/scancel`，相关能力会降级/受限，但服务可启动。

### 4) 运行 iOS App

1. 打开 `LabOS.xcodeproj`
2. 选择 scheme `LabOSApp`
3. 选择模拟器并运行（`Cmd+R`）
4. 在 App 中进入 `Settings -> Gateway` 配置 WS URL 与 token

建议：

- 模拟器：`ws://127.0.0.1:8787/ws`
- 真机：`ws://<你的局域网IP>:8787/ws`

## 主要能力（当前实现）

- 项目/会话管理（创建、重命名、归档、删除）
- Codex 线程与回合（start/read/resume/rollback/steer/interrupt）
- 实时事件与流式展示（思考、工具调用、命令输出、文件变更）
- 审批流（plan/exec approval + judgment 问答）
- 会话级/项目级权限策略同步（default/full）
- 项目文件上传与索引（文本/PDF；支持 OCR fallback）
- 语音转写（OpenAI 音频转写模型）与图片/文件附件
- 结果浏览（artifact 预览、diff、notebook、代码高亮）
- 本地通知（任务完成、待用户输入）

## 数据与存储

Hub 状态目录默认在 `~/.labos`，典型结构：

```text
~/.labos/
  config.json
  labos.sqlite
  hub.log
  projects/
    <projectId>/
      sessions/<sessionId>.jsonl
      uploads/
      cache/
      generated/
      bootstrap/
```

其中 `sessions/*.jsonl` 是会话 canonical transcript，SQLite 用于索引与查询加速。

## 开发命令

### JS/TS

```bash
pnpm -w build
pnpm build:hub
pnpm build:hpc-bridge
pnpm -w typecheck
pnpm -w test
```

### Swift

```bash
swift test
```

### 协议与代码生成

```bash
pnpm -w protocol:build
pnpm -w protocol:gen:swift
pnpm -w codex-spec:refresh
pnpm -w codex-spec:check
```

### Xcode 项目再生成

```bash
xcodegen generate
```

## 深链（内部）

- `app://project/<projectId>/artifact?path=<urlencodedPath>`
- `app://project/<projectId>/run/<runId>`
- `app://project/<projectId>/session/<sessionId>`
