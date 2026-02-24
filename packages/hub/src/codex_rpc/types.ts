export type JsonRpcId = string | number;

export type JsonRpcRequest = {
  id: JsonRpcId;
  method: string;
  params?: unknown;
};

export type JsonRpcNotification = {
  method: string;
  params?: unknown;
};

export type JsonRpcResponse = {
  id: JsonRpcId;
  result?: unknown;
  error?: {
    code: number;
    message: string;
    data?: unknown;
  };
};

export type JsonRpcMessage = JsonRpcRequest | JsonRpcNotification | JsonRpcResponse;

export type TurnStatus = "inProgress" | "completed" | "interrupted" | "failed";

export type ThreadSource = "cli" | "vscode" | "exec" | "appServer" | "unknown";

export type TurnError = {
  message: string;
  codexErrorInfo: unknown | null;
  additionalDetails: string | null;
};

export type Turn = {
  id: string;
  items: Array<ThreadItem>;
  status: TurnStatus;
  error: TurnError | null;
};

export type Thread = {
  id: string;
  preview: string;
  modelProvider: string;
  createdAt: number;
  updatedAt: number;
  path: string | null;
  cwd: string;
  cliVersion: string;
  source: ThreadSource;
  gitInfo: { sha: string | null; branch: string | null; originUrl: string | null } | null;
  turns: Turn[];
};

export type UserInput =
  | { type: "text"; text: string; text_elements: Array<Record<string, unknown>> }
  | { type: "image"; url: string }
  | { type: "localImage"; path: string }
  | { type: "skill"; name: string; path: string }
  | { type: "mention"; name: string; path: string };

export type ThreadItem =
  | { type: "userMessage"; id: string; content: UserInput[] }
  | { type: "agentMessage"; id: string; text: string }
  | { type: "plan"; id: string; text: string }
  | {
      type: "commandExecution";
      id: string;
      command: string;
      cwd: string;
      processId: string | null;
      status: "inProgress" | "completed" | "failed" | "interrupted";
      commandActions: Array<Record<string, unknown>>;
      aggregatedOutput: string | null;
      exitCode: number | null;
      durationMs: number | null;
    }
  | {
      type: "fileChange";
      id: string;
      changes: Array<{ path: string; kind: string; diff: string }>;
      status: "pending" | "applied" | "rejected" | "failed";
    }
  | { type: "mcpToolCall"; id: string; server: string; tool: string; status: string; arguments: unknown; result: unknown; error: unknown; durationMs: number | null }
  | { type: string; id: string; [key: string]: unknown };

export type TurnPlanStep = {
  step: string;
  status: "pending" | "inProgress" | "completed";
};

export type CodexNotificationEnvelope = {
  method: string;
  params: Record<string, unknown>;
};

export function isJsonRpcRequest(message: unknown): message is JsonRpcRequest {
  if (!message || typeof message !== "object") return false;
  const obj = message as Record<string, unknown>;
  return (typeof obj.id === "string" || typeof obj.id === "number") && typeof obj.method === "string";
}

export function isJsonRpcNotification(message: unknown): message is JsonRpcNotification {
  if (!message || typeof message !== "object") return false;
  const obj = message as Record<string, unknown>;
  return typeof obj.method === "string" && obj.id == null;
}

export function isJsonRpcResponse(message: unknown): message is JsonRpcResponse {
  if (!message || typeof message !== "object") return false;
  const obj = message as Record<string, unknown>;
  return (typeof obj.id === "string" || typeof obj.id === "number") && typeof obj.method !== "string";
}

export function nowUnixSeconds(): number {
  return Math.floor(Date.now() / 1000);
}

export function previewFromText(text: string): string {
  const compact = text.replace(/\s+/g, " ").trim();
  if (compact.length <= 140) return compact;
  return `${compact.slice(0, 137)}...`;
}
