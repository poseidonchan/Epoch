import { v4 as uuidv4 } from "uuid";

import { Agent, type AgentTool, type ThinkingLevel } from "@mariozechner/pi-agent-core";
import { Type, type ImageContent, type Model as PiModel } from "@mariozechner/pi-ai";

const ALLOWED_THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh"] as const;
const ALLOWED_TOOL_RUNTIMES = ["Python", "Shell", "Download", "HPC Job", "Notebook"] as const;
const ALLOWED_RISK_FLAGS = ["Network access", "Large download", "Overwrite existing files"] as const;

export type LabosJudgmentPrompt = {
  questions: Array<{
    id: string;
    header: string;
    question: string;
    options: Array<{ label: string; description: string }>;
    allowFreeform: boolean;
  }>;
};

export type LabosJudgmentResponses = {
  answers?: Record<string, string>;
  freeform?: Record<string, string>;
};

export type LabosToolEventPayload = {
  agentRunId: string;
  projectId: string;
  sessionId: string;
  runId: string | null;
  toolCallId: string;
  tool: string;
  phase: "start" | "update" | "end" | "error";
  summary: string;
  detail: Record<string, unknown>;
  ts: string;
};

export type LabosPlanUpdatedPayload = {
  agentRunId: string;
  projectId: string;
  sessionId: string;
  explanation?: string;
  plan: Array<{ step: string; status: "pending" | "in_progress" | "completed" }>;
};

export type LabosExecutionPlan = {
  id: string;
  projectID: string;
  sessionID: string;
  createdAt: string;
  steps: Array<{
    id: string;
    title: string;
    runtime: string;
    inputs: string[];
    outputs: string[];
    riskFlags: string[];
  }>;
};

type ExecutionContext = {
  plan: LabosExecutionPlan | null;
  runId: string | null;
};

// OpenAI tool names must match ^[a-zA-Z0-9_-]+$ (no dots).
const TOOL_PLAN_PROPOSE = "labos_plan_propose";
const TOOL_PLAN_UPDATE = "labos_plan_update";
const TOOL_RUN_EXECUTE = "labos_run_execute";

export type LabosAgentHost = {
  nowIso: () => string;
  broadcastEvent: (event: string, payload: any) => void;
  getApiKey: (provider: string) => Promise<string | undefined>;

  persistAssistantMessage: (msg: {
    projectId: string;
    sessionId: string;
    id: string;
    text: string;
    proposedPlan: any | null;
    artifactRefs: any[];
    usage?: { input: number; output: number; totalTokens: number } | null;
    modelId?: string;
    contextWindowTokens?: number;
    runId?: string;
  }) => Promise<void>;
  persistToolMessage: (msg: { projectId: string; sessionId: string; text: string; runId?: string }) => Promise<void>;

  insertPlan: (plan: LabosExecutionPlan, agentRunId: string) => Promise<void>;
  waitForApproval: (planId: string) => Promise<{ decision: "approve" | "reject"; judgmentResponses?: LabosJudgmentResponses }>;

  createRunRecord: (opts: { id: string; projectId: string; sessionId: string; stepTitles: string[] }) => Promise<any>;
  executePlan: (opts: { projectId: string; sessionId: string; agentRunId: string; plan: any; runId: string }) => Promise<void>;
  updateRunCurrentStep: (opts: { projectId: string; runId: string; currentStep: number; logSnippet: string }) => Promise<void>;
};

export async function runLabosAgentTurn(opts: {
  host: LabosAgentHost;
  agentRunId: string;
  projectId: string;
  sessionId: string;
  userText: string;
  promptImages: ImageContent[];
  wantsPlan: boolean;
  planMode: boolean;
  model: PiModel<any>;
  thinkingLevel: string | null;
  systemPrompt: string;
  messages: any[];
}) {
  const { host } = opts;
  const exec: ExecutionContext = { plan: null, runId: null };

  let currentAssistantMessageId: string | null = null;
  let currentAssistantText = "";

  const thinking = normalizeThinkingLevel(opts.thinkingLevel, opts.model);

  const executionToolsEnabled = opts.planMode || opts.wantsPlan;
  const tools: AgentTool<any>[] = executionToolsEnabled
    ? [
        makePlanProposeTool({
          host,
          agentRunId: opts.agentRunId,
          projectId: opts.projectId,
          sessionId: opts.sessionId,
          planMode: opts.planMode,
          exec,
        }),
        makePlanUpdateTool({
          host,
          agentRunId: opts.agentRunId,
          projectId: opts.projectId,
          sessionId: opts.sessionId,
          exec,
        }),
        makeRunExecuteTool({
          host,
          agentRunId: opts.agentRunId,
          projectId: opts.projectId,
          sessionId: opts.sessionId,
          exec,
        }),
      ]
    : [];

  const agent = new Agent({
    getApiKey: async (provider) => {
      return await host.getApiKey(provider);
    },
    initialState: {
      systemPrompt: opts.systemPrompt,
      model: opts.model as any,
      thinkingLevel: thinking,
      tools,
      messages: opts.messages as any,
    },
  });

  agent.subscribe((event) => {
    if (event.type === "message_start") {
      const m: any = (event as any).message;
      if (m?.role === "assistant") {
        currentAssistantMessageId = uuidv4();
        currentAssistantText = "";
      }
      return;
    }

    if (event.type === "message_update") {
      const m: any = (event as any).message;
      const assistantMessageEvent: any = (event as any).assistantMessageEvent;
      if (m?.role !== "assistant") return;
      if (!currentAssistantMessageId) currentAssistantMessageId = uuidv4();
      if (assistantMessageEvent?.type === "text_delta") {
        const delta = String(assistantMessageEvent.delta ?? "");
        if (!delta) return;
        currentAssistantText += delta;
        host.broadcastEvent("agent.stream.assistant_delta", {
          agentRunId: opts.agentRunId,
          projectId: opts.projectId,
          sessionId: opts.sessionId,
          messageId: currentAssistantMessageId,
          delta,
        });
      }
      return;
    }

    if (event.type === "message_end") {
      const m: any = (event as any).message;
      if (m?.role !== "assistant") return;
      const id = currentAssistantMessageId ?? uuidv4();
      const text = currentAssistantText.trim() ? currentAssistantText : assistantTextFromMessage(m);
      if (!String(text ?? "").trim()) {
        // eslint-disable-next-line no-console
        console.warn("empty assistant message", {
          keys: m && typeof m === "object" ? Object.keys(m) : [],
          errorMessage: typeof m?.errorMessage === "string" ? m.errorMessage.slice(0, 200) : null,
          contentType: typeof m?.content,
          contentPreview:
            typeof m?.content === "string"
              ? m.content.slice(0, 200)
              : Array.isArray(m?.content)
                ? JSON.stringify(m.content).slice(0, 500)
                : null,
        });
      }
      const usage = (() => {
        const u = m?.usage;
        const input = typeof u?.input === "number" ? u.input : null;
        const output = typeof u?.output === "number" ? u.output : null;
        const totalTokens = typeof u?.totalTokens === "number" ? u.totalTokens : null;
        if (input == null || output == null) return null;
        return { input, output, totalTokens: totalTokens ?? input + output };
      })();
      void host.persistAssistantMessage({
        projectId: opts.projectId,
        sessionId: opts.sessionId,
        id,
        text,
        proposedPlan: null,
        artifactRefs: [],
        ...(usage ? { usage } : {}),
        ...(typeof m?.model === "string" && m.model.trim() ? { modelId: String(m.model) } : { modelId: opts.model.id }),
        ...(typeof opts.model?.contextWindow === "number" ? { contextWindowTokens: opts.model.contextWindow } : {}),
        ...(exec.runId ? { runId: exec.runId } : {}),
      });
      currentAssistantMessageId = null;
      currentAssistantText = "";
      return;
    }

    if (event.type === "tool_execution_start") {
      const e: any = event;
      const payload: LabosToolEventPayload = {
        agentRunId: opts.agentRunId,
        projectId: opts.projectId,
        sessionId: opts.sessionId,
        runId: exec.runId,
        toolCallId: String(e.toolCallId),
        tool: String(e.toolName),
        phase: "start",
        summary: `Starting ${String(e.toolName)}`,
        detail: { args: e.args ?? {} },
        ts: host.nowIso(),
      };
      host.broadcastEvent("agent.stream.tool_event", payload);
      void host.persistToolMessage({
        projectId: opts.projectId,
        sessionId: opts.sessionId,
        text: `Tool call: ${payload.tool}\n${payload.summary}`,
        ...(exec.runId ? { runId: exec.runId } : {}),
      });
      return;
    }

    if (event.type === "tool_execution_update") {
      const e: any = event;
      const payload: LabosToolEventPayload = {
        agentRunId: opts.agentRunId,
        projectId: opts.projectId,
        sessionId: opts.sessionId,
        runId: exec.runId,
        toolCallId: String(e.toolCallId),
        tool: String(e.toolName),
        phase: "update",
        summary: `Running ${String(e.toolName)}`,
        detail: { partialResult: e.partialResult ?? {} },
        ts: host.nowIso(),
      };
      host.broadcastEvent("agent.stream.tool_event", payload);
      return;
    }

    if (event.type === "tool_execution_end") {
      const e: any = event;
      const payload: LabosToolEventPayload = {
        agentRunId: opts.agentRunId,
        projectId: opts.projectId,
        sessionId: opts.sessionId,
        runId: exec.runId,
        toolCallId: String(e.toolCallId),
        tool: String(e.toolName),
        phase: e.isError ? "error" : "end",
        summary: e.isError ? `Failed ${String(e.toolName)}` : `Completed ${String(e.toolName)}`,
        detail: { result: e.result ?? {} },
        ts: host.nowIso(),
      };
      host.broadcastEvent("agent.stream.tool_event", payload);
      void host.persistToolMessage({
        projectId: opts.projectId,
        sessionId: opts.sessionId,
        text: `Tool call: ${payload.tool}\n${payload.summary}`,
        ...(exec.runId ? { runId: exec.runId } : {}),
      });
      return;
    }
  });

  await agent.prompt(opts.userText, opts.promptImages);
}

function normalizeThinkingLevel(raw: string | null, model: PiModel<any>): ThinkingLevel {
  if (!model.reasoning) return "off";
  const normalized = raw ? String(raw).trim().toLowerCase() : "off";
  return (ALLOWED_THINKING_LEVELS as readonly string[]).includes(normalized)
    ? (normalized as ThinkingLevel)
    : "off";
}

function assistantTextFromMessage(m: any): string {
  if (!m) return "";

  // pi-agent-core / pi-ai have used a few shapes over time:
  // - content: string
  // - content: [{ type: "text", text: "..." }, ...]
  // - text: string
  if (typeof (m as any).content === "string") return String((m as any).content);
  if (typeof (m as any).text === "string") return String((m as any).text);

  const blocks: any[] = Array.isArray((m as any).content) ? (m as any).content : [];
  const fromBlocks = blocks
    .map((b: any) => {
      if (!b) return "";
      if (typeof b.text === "string") return b.text;
      if (typeof b.content === "string") return b.content;
      if (b.type === "text" && typeof b.value === "string") return b.value;
      return "";
    })
    .join("");

  if (fromBlocks.trim()) return fromBlocks;

  // Some provider errors surface as an assistant message with no content blocks.
  if (typeof (m as any).errorMessage === "string" && (m as any).errorMessage.trim()) {
    return String((m as any).errorMessage);
  }

  return "";
}

function normalizeRuntime(value: unknown): string {
  const v = typeof value === "string" ? value : "";
  return (ALLOWED_TOOL_RUNTIMES as readonly string[]).includes(v) ? v : "HPC Job";
}

function normalizeRiskFlags(value: unknown): string[] {
  const arr = Array.isArray(value) ? value : [];
  return arr
    .map((v) => (typeof v === "string" ? v : ""))
    .filter((v) => (ALLOWED_RISK_FLAGS as readonly string[]).includes(v));
}

function normalizePlan(raw: any, projectId: string, sessionId: string, nowIso: string): LabosExecutionPlan {
  const stepsRaw = Array.isArray(raw?.steps) ? raw.steps : [];
  const steps = stepsRaw.map((s: any, idx: number) => ({
    id: uuidv4(),
    title: String(s?.title ?? `Step ${idx + 1}`),
    runtime: normalizeRuntime(s?.runtime),
    inputs: Array.isArray(s?.inputs) ? s.inputs.map((v: any) => String(v)) : [],
    outputs: Array.isArray(s?.outputs) ? s.outputs.map((v: any) => String(v)) : [],
    riskFlags: normalizeRiskFlags(s?.riskFlags),
  }));
  return {
    id: uuidv4(),
    projectID: projectId,
    sessionID: sessionId,
    createdAt: nowIso,
    steps,
  };
}

function normalizeJudgment(raw: any): LabosJudgmentPrompt | null {
  const qRaw = Array.isArray(raw?.questions) ? raw.questions : [];
  const questions = qRaw
    .map((q: any) => {
      const id = typeof q?.id === "string" ? q.id : "";
      const header = typeof q?.header === "string" ? q.header : "";
      const question = typeof q?.question === "string" ? q.question : "";
      const allowFreeform = Boolean(q?.allowFreeform);
      const optionsRaw = Array.isArray(q?.options) ? q.options : [];
      const options = optionsRaw
        .map((o: any) => ({
          label: typeof o?.label === "string" ? o.label : "",
          description: typeof o?.description === "string" ? o.description : "",
        }))
        .filter((o: any) => o.label && o.description);
      if (!id || !header || !question || options.length === 0) return null;
      return { id, header, question, options, allowFreeform };
    })
    .filter(Boolean) as LabosJudgmentPrompt["questions"];

  if (questions.length === 0) return null;
  return { questions };
}

function defaultJudgmentPrompt(): LabosJudgmentPrompt {
  return {
    questions: [
      {
        id: "operator_note",
        header: "Note",
        question: "Any constraints or notes before execution?",
        options: [
          { label: "No additional notes", description: "Proceed as planned." },
          { label: "Add a note", description: "Provide constraints or preferences for the run." },
        ],
        allowFreeform: true,
      },
    ],
  };
}

function makePlanProposeTool(opts: {
  host: LabosAgentHost;
  agentRunId: string;
  projectId: string;
  sessionId: string;
  planMode: boolean;
  exec: ExecutionContext;
}): AgentTool<any> {
  return {
    name: TOOL_PLAN_PROPOSE,
    label: "Propose Plan",
    description: "Propose an execution plan and request operator approval.",
    parameters: Type.Object({
      plan: Type.Any(),
      judgment: Type.Optional(Type.Any()),
    }),
    execute: async (toolCallId, params) => {
      const now = opts.host.nowIso();
      const plan = normalizePlan((params as any)?.plan, opts.projectId, opts.sessionId, now);
      const judgment = normalizeJudgment((params as any)?.judgment) ?? (opts.planMode ? defaultJudgmentPrompt() : null);
      opts.exec.plan = plan;

      await opts.host.insertPlan(plan, opts.agentRunId);
      await opts.host.persistAssistantMessage({
        projectId: opts.projectId,
        sessionId: opts.sessionId,
        id: uuidv4(),
        text: "Proposed plan ready for approval.",
        proposedPlan: plan,
        artifactRefs: [],
      });

      opts.host.broadcastEvent("exec.approval.requested", {
        planId: plan.id,
        agentRunId: opts.agentRunId,
        projectId: opts.projectId,
        sessionId: opts.sessionId,
        plan,
        required: true,
        ...(judgment ? { judgment } : {}),
      });

      const approval = await opts.host.waitForApproval(plan.id);
      if (approval.decision === "reject") {
        await opts.host.persistAssistantMessage({
          projectId: opts.projectId,
          sessionId: opts.sessionId,
          id: uuidv4(),
          text: `Plan rejected. No run was created for project ${opts.projectId.slice(0, 8)}.`,
          proposedPlan: null,
          artifactRefs: [],
        });
        return {
          content: [{ type: "text", text: JSON.stringify({ decision: "reject", judgmentResponses: approval.judgmentResponses ?? null }) }],
          details: { decision: "reject", judgmentResponses: approval.judgmentResponses ?? null },
        };
      }

      const runId = uuidv4();
      opts.exec.runId = runId;
      const runRecord = await opts.host.createRunRecord({
        id: runId,
        projectId: opts.projectId,
        sessionId: opts.sessionId,
        stepTitles: plan.steps.map((s) => s.title),
      });

      opts.host.broadcastEvent("runs.updated", { projectId: opts.projectId, run: runRecord, change: "created" });

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({ decision: "approve", runId, judgmentResponses: approval.judgmentResponses ?? null }),
          },
        ],
        details: { decision: "approve", runId, judgmentResponses: approval.judgmentResponses ?? null },
      };
    },
  };
}

function makePlanUpdateTool(opts: {
  host: LabosAgentHost;
  agentRunId: string;
  projectId: string;
  sessionId: string;
  exec: ExecutionContext;
}): AgentTool<any> {
  return {
    name: TOOL_PLAN_UPDATE,
    label: "Update Plan",
    description: "Update plan status and execution progress.",
    parameters: Type.Object({
      explanation: Type.Optional(Type.String()),
      plan: Type.Array(
        Type.Object({
          step: Type.String(),
          status: Type.Union([Type.Literal("pending"), Type.Literal("in_progress"), Type.Literal("completed")]),
        })
      ),
    }),
    execute: async (_toolCallId, params) => {
      const items = Array.isArray((params as any)?.plan) ? (params as any).plan : [];
      const inProgress = items.filter((i: any) => i?.status === "in_progress").length;
      if (inProgress > 1) {
        throw new Error("Invalid plan: more than one step is in_progress");
      }

      const payload: LabosPlanUpdatedPayload = {
        agentRunId: opts.agentRunId,
        projectId: opts.projectId,
        sessionId: opts.sessionId,
        ...(typeof (params as any)?.explanation === "string" ? { explanation: (params as any).explanation } : {}),
        plan: items.map((i: any) => ({ step: String(i.step ?? ""), status: i.status })),
      };
      opts.host.broadcastEvent("agent.plan.updated", payload);

      if (opts.exec.runId) {
        const currentIndex = items.findIndex((i: any) => i?.status === "in_progress");
        const currentStep = currentIndex === -1 ? 0 : currentIndex + 1;
        await opts.host.updateRunCurrentStep({
          projectId: opts.projectId,
          runId: opts.exec.runId,
          currentStep,
          logSnippet: payload.explanation ?? "Running",
        });
      }

      return {
        content: [{ type: "text", text: "Plan updated." }],
        details: { ok: true },
      };
    },
  };
}

function makeRunExecuteTool(opts: {
  host: LabosAgentHost;
  agentRunId: string;
  projectId: string;
  sessionId: string;
  exec: ExecutionContext;
}): AgentTool<any> {
  return {
    name: TOOL_RUN_EXECUTE,
    label: "Execute Run",
    description: "Execute the approved plan steps.",
    parameters: Type.Object({}),
    execute: async (toolCallId, _params, signal, onUpdate) => {
      if (!opts.exec.runId || !opts.exec.plan) {
        throw new Error("APPROVAL_REQUIRED");
      }
      onUpdate?.({ content: [{ type: "text", text: "Starting execution..." }], details: { runId: opts.exec.runId } });
      await opts.host.executePlan({
        projectId: opts.projectId,
        sessionId: opts.sessionId,
        agentRunId: opts.agentRunId,
        plan: opts.exec.plan,
        runId: opts.exec.runId,
      });
      onUpdate?.({ content: [{ type: "text", text: "Execution complete." }], details: { runId: opts.exec.runId } });
      return {
        content: [{ type: "text", text: JSON.stringify({ ok: true, runId: opts.exec.runId }) }],
        details: { ok: true, runId: opts.exec.runId },
      };
    },
  };
}
