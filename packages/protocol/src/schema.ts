import { Type, type Static } from "@sinclair/typebox";

export const UUID = Type.String({ format: "uuid" });
export const ISODateTime = Type.String({ format: "date-time" });

export const Role = Type.Union([Type.Literal("operator"), Type.Literal("node")]);
export type Role = Static<typeof Role>;

export const SessionLifecycle = Type.Union([Type.Literal("active"), Type.Literal("archived")]);
export type SessionLifecycle = Static<typeof SessionLifecycle>;

export const ArtifactKind = Type.Union([
  Type.Literal("notebook"),
  Type.Literal("python"),
  Type.Literal("image"),
  Type.Literal("text"),
  Type.Literal("json"),
  Type.Literal("log"),
  Type.Literal("unknown"),
]);
export type ArtifactKind = Static<typeof ArtifactKind>;

export const ArtifactOrigin = Type.Union([Type.Literal("user_upload"), Type.Literal("generated")]);
export type ArtifactOrigin = Static<typeof ArtifactOrigin>;

export const ArtifactIndexStatus = Type.Union([
  Type.Literal("processing"),
  Type.Literal("indexed"),
  Type.Literal("failed"),
]);
export type ArtifactIndexStatus = Static<typeof ArtifactIndexStatus>;

export const RunStatus = Type.Union([
  Type.Literal("queued"),
  Type.Literal("running"),
  Type.Literal("succeeded"),
  Type.Literal("failed"),
  Type.Literal("canceled"),
]);
export type RunStatus = Static<typeof RunStatus>;

export const ThinkingLevel = Type.Union([
  Type.Literal("minimal"),
  Type.Literal("low"),
  Type.Literal("medium"),
  Type.Literal("high"),
  Type.Literal("xhigh"),
]);
export type ThinkingLevel = Static<typeof ThinkingLevel>;

export const ToolRuntime = Type.Union([
  Type.Literal("Python"),
  Type.Literal("Shell"),
  Type.Literal("Download"),
  Type.Literal("HPC Job"),
  Type.Literal("Notebook"),
]);
export type ToolRuntime = Static<typeof ToolRuntime>;

export const PlanRiskFlag = Type.Union([
  Type.Literal("Network access"),
  Type.Literal("Large download"),
  Type.Literal("Overwrite existing files"),
]);
export type PlanRiskFlag = Static<typeof PlanRiskFlag>;

export const Project = Type.Object({
  id: UUID,
  name: Type.String(),
  createdAt: ISODateTime,
  updatedAt: ISODateTime,
});
export type Project = Static<typeof Project>;

export const Session = Type.Object({
  id: UUID,
  projectID: UUID,
  title: Type.String(),
  lifecycle: SessionLifecycle,
  createdAt: ISODateTime,
  updatedAt: ISODateTime,
});
export type Session = Static<typeof Session>;

export const ChatArtifactReference = Type.Object({
  displayText: Type.String(),
  projectID: UUID,
  path: Type.String(),
  artifactID: Type.Optional(UUID),
});
export type ChatArtifactReference = Static<typeof ChatArtifactReference>;

export const PlanStep = Type.Object({
  id: UUID,
  title: Type.String(),
  runtime: ToolRuntime,
  inputs: Type.Array(Type.String()),
  outputs: Type.Array(Type.String()),
  riskFlags: Type.Array(PlanRiskFlag),
});
export type PlanStep = Static<typeof PlanStep>;

export const ExecutionPlan = Type.Object({
  id: UUID,
  projectID: UUID,
  sessionID: UUID,
  createdAt: ISODateTime,
  steps: Type.Array(PlanStep),
});
export type ExecutionPlan = Static<typeof ExecutionPlan>;

export const JudgmentOption = Type.Object({
  label: Type.String(),
  description: Type.String(),
});
export type JudgmentOption = Static<typeof JudgmentOption>;

export const JudgmentQuestion = Type.Object({
  id: Type.String(),
  header: Type.String(),
  question: Type.String(),
  options: Type.Array(JudgmentOption),
  allowFreeform: Type.Boolean(),
});
export type JudgmentQuestion = Static<typeof JudgmentQuestion>;

export const JudgmentPrompt = Type.Object({
  questions: Type.Array(JudgmentQuestion),
});
export type JudgmentPrompt = Static<typeof JudgmentPrompt>;

export const JudgmentResponses = Type.Object({
  answers: Type.Optional(Type.Record(Type.String(), Type.String())),
  freeform: Type.Optional(Type.Record(Type.String(), Type.String())),
});
export type JudgmentResponses = Static<typeof JudgmentResponses>;

export const MessageRole = Type.Union([
  Type.Literal("user"),
  Type.Literal("assistant"),
  Type.Literal("tool"),
  Type.Literal("system"),
]);
export type MessageRole = Static<typeof MessageRole>;

export const ChatMessage = Type.Object({
  id: UUID,
  sessionID: UUID,
  role: MessageRole,
  text: Type.String(),
  createdAt: ISODateTime,
  artifactRefs: Type.Array(ChatArtifactReference),
  proposedPlan: Type.Optional(ExecutionPlan),
  runID: Type.Optional(UUID),
  parentID: Type.Optional(UUID),
});
export type ChatMessage = Static<typeof ChatMessage>;

export const Artifact = Type.Object({
  id: UUID,
  projectID: UUID,
  path: Type.String(),
  kind: ArtifactKind,
  origin: ArtifactOrigin,
  modifiedAt: ISODateTime,
  sizeBytes: Type.Optional(Type.Integer({ minimum: 0 })),
  createdBySessionID: Type.Optional(UUID),
  createdByRunID: Type.Optional(UUID),
  indexStatus: Type.Optional(ArtifactIndexStatus),
  indexSummary: Type.Optional(Type.String()),
  indexedAt: Type.Optional(ISODateTime),
});
export type Artifact = Static<typeof Artifact>;

export const RunRecord = Type.Object({
  id: UUID,
  projectID: UUID,
  sessionID: Type.Optional(UUID),
  status: RunStatus,
  initiatedAt: ISODateTime,
  completedAt: Type.Optional(ISODateTime),
  currentStep: Type.Integer({ minimum: 0 }),
  totalSteps: Type.Integer({ minimum: 0 }),
  logSnippet: Type.String(),
  stepTitles: Type.Array(Type.String()),
  producedArtifactPaths: Type.Array(Type.String()),
  hpcJobId: Type.Optional(Type.String()),
});
export type RunRecord = Static<typeof RunRecord>;

export const ModelInfo = Type.Object({
  id: Type.String(),
  name: Type.String(),
  reasoning: Type.Boolean(),
});
export type ModelInfo = Static<typeof ModelInfo>;

export const ModelsCurrentResponse = Type.Object({
  provider: Type.String(),
  defaultModelId: Type.String(),
  models: Type.Array(ModelInfo),
  thinkingLevels: Type.Array(ThinkingLevel),
});
export type ModelsCurrentResponse = Static<typeof ModelsCurrentResponse>;

export const ToolEventPhase = Type.Union([
  Type.Literal("start"),
  Type.Literal("update"),
  Type.Literal("end"),
  Type.Literal("error"),
]);
export type ToolEventPhase = Static<typeof ToolEventPhase>;

export const ToolEventPayload = Type.Object({
  agentRunId: UUID,
  projectId: UUID,
  sessionId: UUID,
  runId: Type.Union([UUID, Type.Null()]),
  toolCallId: Type.String(),
  tool: Type.String(),
  phase: ToolEventPhase,
  summary: Type.String(),
  detail: Type.Record(Type.String(), Type.Unknown()),
  ts: ISODateTime,
});
export type ToolEventPayload = Static<typeof ToolEventPayload>;

export const PlanItemStatus = Type.Union([Type.Literal("pending"), Type.Literal("in_progress"), Type.Literal("completed")]);
export type PlanItemStatus = Static<typeof PlanItemStatus>;

export const PlanProgressItem = Type.Object({
  step: Type.String(),
  status: PlanItemStatus,
});
export type PlanProgressItem = Static<typeof PlanProgressItem>;

export const AgentPlanUpdatedPayload = Type.Object({
  agentRunId: UUID,
  projectId: UUID,
  sessionId: UUID,
  explanation: Type.Optional(Type.String()),
  plan: Type.Array(PlanProgressItem),
});
export type AgentPlanUpdatedPayload = Static<typeof AgentPlanUpdatedPayload>;

export const HpcTres = Type.Object({
  cpu: Type.Optional(Type.Integer({ minimum: 0 })),
  memMB: Type.Optional(Type.Integer({ minimum: 0 })),
  gpus: Type.Optional(Type.Integer({ minimum: 0 })),
});
export type HpcTres = Static<typeof HpcTres>;

export const HpcStatus = Type.Object({
  partition: Type.Optional(Type.String()),
  account: Type.Optional(Type.String()),
  qos: Type.Optional(Type.String()),
  runningJobs: Type.Integer({ minimum: 0 }),
  pendingJobs: Type.Integer({ minimum: 0 }),
  limit: Type.Optional(HpcTres),
  inUse: Type.Optional(HpcTres),
  available: Type.Optional(HpcTres),
  updatedAt: ISODateTime,
});
export type HpcStatus = Static<typeof HpcStatus>;

export const NodeHeartbeatPayload = Type.Object({
  nodeId: Type.String(),
  ts: ISODateTime,
  queueDepth: Type.Integer({ minimum: 0 }),
  storageUsedPercent: Type.Number({ minimum: 0, maximum: 100 }),
  cpuPercent: Type.Number({ minimum: 0, maximum: 100 }),
  ramPercent: Type.Number({ minimum: 0, maximum: 100 }),
  hpc: Type.Optional(Type.Union([HpcStatus, Type.Null()])),
});
export type NodeHeartbeatPayload = Static<typeof NodeHeartbeatPayload>;

export const RunLogDeltaPayload = Type.Object({
  projectId: UUID,
  runId: UUID,
  stream: Type.String(),
  delta: Type.String(),
});
export type RunLogDeltaPayload = Static<typeof RunLogDeltaPayload>;

export const RuntimePermissionLevel = Type.Union([Type.Literal("default"), Type.Literal("full")]);
export type RuntimePermissionLevel = Static<typeof RuntimePermissionLevel>;

export const RuntimeExecStartedPayload = Type.Object({
  projectId: UUID,
  sessionId: Type.Optional(UUID),
  threadId: Type.String(),
  turnId: Type.String(),
  itemId: Type.String(),
  executionId: Type.String(),
  command: Type.Array(Type.String()),
  cwd: Type.String(),
  permissionLevel: RuntimePermissionLevel,
  ts: ISODateTime,
});
export type RuntimeExecStartedPayload = Static<typeof RuntimeExecStartedPayload>;

export const RuntimeExecOutputDeltaPayload = Type.Object({
  projectId: UUID,
  sessionId: Type.Optional(UUID),
  threadId: Type.String(),
  turnId: Type.String(),
  itemId: Type.String(),
  executionId: Type.String(),
  stream: Type.Union([Type.Literal("stdout"), Type.Literal("stderr"), Type.Literal("system")]),
  delta: Type.String(),
  ts: ISODateTime,
});
export type RuntimeExecOutputDeltaPayload = Static<typeof RuntimeExecOutputDeltaPayload>;

export const RuntimeExecCompletedPayload = Type.Object({
  projectId: UUID,
  sessionId: Type.Optional(UUID),
  threadId: Type.String(),
  turnId: Type.String(),
  itemId: Type.String(),
  executionId: Type.String(),
  ok: Type.Boolean(),
  exitCode: Type.Optional(Type.Integer()),
  durationMs: Type.Optional(Type.Integer({ minimum: 0 })),
  error: Type.Optional(Type.String()),
  ts: ISODateTime,
});
export type RuntimeExecCompletedPayload = Static<typeof RuntimeExecCompletedPayload>;

export const RuntimeFsChangedPayload = Type.Object({
  projectId: UUID,
  sessionId: Type.Optional(UUID),
  threadId: Type.String(),
  turnId: Type.String(),
  itemId: Type.String(),
  changeId: Type.String(),
  path: Type.String(),
  kind: Type.String(),
  diff: Type.Optional(Type.String()),
  ts: ISODateTime,
});
export type RuntimeFsChangedPayload = Static<typeof RuntimeFsChangedPayload>;

export const RuntimeFsPatchCompletedPayload = Type.Object({
  projectId: UUID,
  sessionId: Type.Optional(UUID),
  threadId: Type.String(),
  turnId: Type.String(),
  itemId: Type.String(),
  patchId: Type.String(),
  applied: Type.Boolean(),
  changedPaths: Type.Array(Type.String()),
  diff: Type.Optional(Type.String()),
  error: Type.Optional(Type.String()),
  ts: ISODateTime,
});
export type RuntimeFsPatchCompletedPayload = Static<typeof RuntimeFsPatchCompletedPayload>;

export const ResourceStatus = Type.Object({
  computeConnected: Type.Boolean(),
  queueDepth: Type.Integer({ minimum: 0 }),
  storageUsedPercent: Type.Number({ minimum: 0, maximum: 100 }),
  cpuPercent: Type.Number({ minimum: 0, maximum: 100 }),
  ramPercent: Type.Number({ minimum: 0, maximum: 100 }),
  hpc: Type.Optional(HpcStatus),
});
export type ResourceStatus = Static<typeof ResourceStatus>;

export const ErrorCode = Type.Union([
  Type.Literal("AUTH_FAILED"),
  Type.Literal("FORBIDDEN"),
  Type.Literal("BAD_REQUEST"),
  Type.Literal("NOT_FOUND"),
  Type.Literal("CONFLICT"),
  Type.Literal("RATE_LIMITED"),
  Type.Literal("INTERNAL"),
  Type.Literal("NODE_OFFLINE"),
  Type.Literal("APPROVAL_REQUIRED"),
  Type.Literal("APPROVAL_EXPIRED"),
]);
export type ErrorCode = Static<typeof ErrorCode>;

export const ErrorObject = Type.Object({
  code: ErrorCode,
  message: Type.String(),
  data: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
});
export type ErrorObject = Static<typeof ErrorObject>;

export const RequestFrame = Type.Object({
  type: Type.Literal("req"),
  id: Type.String(),
  method: Type.String(),
  params: Type.Record(Type.String(), Type.Unknown()),
});
export type RequestFrame = Static<typeof RequestFrame>;

export const ResponseFrame = Type.Object({
  type: Type.Literal("res"),
  id: Type.String(),
  ok: Type.Boolean(),
  payload: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
  error: Type.Optional(ErrorObject),
});
export type ResponseFrame = Static<typeof ResponseFrame>;

export const EventFrame = Type.Object({
  type: Type.Literal("event"),
  event: Type.String(),
  payload: Type.Record(Type.String(), Type.Unknown()),
  seq: Type.Integer({ minimum: 0 }),
  ts: ISODateTime,
});
export type EventFrame = Static<typeof EventFrame>;

export const ConnectChallengePayload = Type.Object({
  nonce: Type.String(),
  issuedAt: ISODateTime,
  serverId: UUID,
  protocol: Type.Object({ min: Type.Integer(), max: Type.Integer() }),
  hmac: Type.Object({ alg: Type.Literal("HMAC-SHA256") }),
});
export type ConnectChallengePayload = Static<typeof ConnectChallengePayload>;

export const ConnectRequestParams = Type.Object({
  minProtocol: Type.Integer(),
  maxProtocol: Type.Integer(),
  role: Role,
  auth: Type.Object({
    token: Type.String(),
    signature: Type.String(),
  }),
  device: Type.Object({
    id: UUID,
    name: Type.String(),
    platform: Type.String(),
    osVersion: Type.Optional(Type.String()),
  }),
  client: Type.Object({
    name: Type.String(),
    version: Type.String(),
  }),
  scopes: Type.Optional(Type.Array(Type.String())),
  caps: Type.Optional(Type.Array(Type.String())),
  commands: Type.Optional(Type.Array(Type.String())),
  permissions: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
});
export type ConnectRequestParams = Static<typeof ConnectRequestParams>;

export const ConnectResponsePayload = Type.Object({
  protocol: Type.Integer(),
  connectionId: UUID,
  roleAccepted: Role,
  scopesAccepted: Type.Optional(Type.Array(Type.String())),
  commandsAccepted: Type.Optional(Type.Array(Type.String())),
  server: Type.Object({
    name: Type.String(),
    version: Type.String(),
  }),
});
export type ConnectResponsePayload = Static<typeof ConnectResponsePayload>;

export const JobSpec = Type.Object({
  name: Type.String(),
  command: Type.Array(Type.String()),
  workdir: Type.String(),
  env: Type.Optional(Type.Record(Type.String(), Type.String())),
  resources: Type.Object({
    partition: Type.Optional(Type.String()),
    account: Type.Optional(Type.String()),
    qos: Type.Optional(Type.String()),
    timeLimitMinutes: Type.Integer({ minimum: 1 }),
    cpus: Type.Integer({ minimum: 1 }),
    memMB: Type.Integer({ minimum: 1 }),
    gpus: Type.Optional(Type.Integer({ minimum: 1 })),
  }),
  outputs: Type.Object({
    artifactRoots: Type.Array(Type.String()),
    logDir: Type.String(),
    stdoutFile: Type.String(),
    stderrFile: Type.String(),
  }),
});
export type JobSpec = Static<typeof JobSpec>;

export const ProtocolSchema = Type.Object({
  version: Type.Literal(1),
  types: Type.Object({
    Project,
    Session,
    ChatMessage,
    Artifact,
    RunRecord,
    ExecutionPlan,
    JudgmentPrompt,
    JudgmentResponses,
    ModelsCurrentResponse,
    ToolEventPayload,
    AgentPlanUpdatedPayload,
    HpcTres,
    HpcStatus,
    NodeHeartbeatPayload,
    RunLogDeltaPayload,
    RuntimePermissionLevel,
    RuntimeExecStartedPayload,
    RuntimeExecOutputDeltaPayload,
    RuntimeExecCompletedPayload,
    RuntimeFsChangedPayload,
    RuntimeFsPatchCompletedPayload,
    JobSpec,
    ResourceStatus,
    ErrorObject,
  }),
});
