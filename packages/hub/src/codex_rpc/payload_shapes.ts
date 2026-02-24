import type { JsonRpcId } from "./types.js";

export function makeTurnStartedNotification(args: { threadId: string; turnId: string }) {
  return {
    method: "turn/started",
    params: {
      threadId: args.threadId,
      turn: {
        id: args.turnId,
        items: [],
        status: "inProgress",
        error: null,
      },
    },
  };
}

export function makeTurnCompletedNotification(args: {
  threadId: string;
  turnId: string;
  status?: "completed" | "interrupted" | "failed";
  error?: {
    message: string;
    codexErrorInfo: unknown | null;
    additionalDetails: string | null;
  } | null;
}) {
  return {
    method: "turn/completed",
    params: {
      threadId: args.threadId,
      turn: {
        id: args.turnId,
        items: [],
        status: args.status ?? "completed",
        error: args.error ?? null,
      },
    },
  };
}

export function makeAgentMessageStartedNotification(args: { threadId: string; turnId: string; itemId: string }) {
  return {
    method: "item/started",
    params: {
      threadId: args.threadId,
      turnId: args.turnId,
      item: {
        type: "agentMessage",
        id: args.itemId,
        text: "",
      },
    },
  };
}

export function makeAgentMessageDeltaNotification(args: { threadId: string; turnId: string; itemId: string; delta: string }) {
  return {
    method: "item/agentMessage/delta",
    params: {
      threadId: args.threadId,
      turnId: args.turnId,
      itemId: args.itemId,
      delta: args.delta,
    },
  };
}

export function makeAgentMessageCompletedNotification(args: { threadId: string; turnId: string; itemId: string; text: string }) {
  return {
    method: "item/completed",
    params: {
      threadId: args.threadId,
      turnId: args.turnId,
      item: {
        type: "agentMessage",
        id: args.itemId,
        text: args.text,
      },
    },
  };
}

export function makeCommandExecutionApprovalRequest(args: {
  id: JsonRpcId;
  threadId: string;
  turnId: string;
  itemId: string;
  reason?: string;
  command?: string;
  cwd?: string;
  commandActions?: Array<Record<string, unknown>>;
  proposedExecpolicyAmendment?: string[];
}) {
  return {
    method: "item/commandExecution/requestApproval",
    id: args.id,
    params: {
      threadId: args.threadId,
      turnId: args.turnId,
      itemId: args.itemId,
      ...(args.reason ? { reason: args.reason } : {}),
      ...(args.command ? { command: args.command } : {}),
      ...(args.cwd ? { cwd: args.cwd } : {}),
      ...(Array.isArray(args.commandActions) ? { commandActions: args.commandActions } : {}),
      ...(Array.isArray(args.proposedExecpolicyAmendment)
        ? { proposedExecpolicyAmendment: args.proposedExecpolicyAmendment }
        : {}),
    },
  };
}

export function makeCommandExecutionApprovalResponse(args: {
  id: JsonRpcId;
  decision:
    | "accept"
    | "acceptForSession"
    | "decline"
    | "cancel"
    | { acceptWithExecpolicyAmendment: { execpolicy_amendment: string[] } };
}) {
  return {
    id: args.id,
    result: {
      decision: args.decision,
    },
  };
}

export function makeFileChangeApprovalRequest(args: {
  id: JsonRpcId;
  threadId: string;
  turnId: string;
  itemId: string;
  reason?: string;
  grantRoot?: string;
}) {
  return {
    method: "item/fileChange/requestApproval",
    id: args.id,
    params: {
      threadId: args.threadId,
      turnId: args.turnId,
      itemId: args.itemId,
      ...(args.reason ? { reason: args.reason } : {}),
      ...(args.grantRoot ? { grantRoot: args.grantRoot } : {}),
    },
  };
}

export function makeFileChangeApprovalResponse(args: {
  id: JsonRpcId;
  decision: "accept" | "acceptForSession" | "decline" | "cancel";
}) {
  return {
    id: args.id,
    result: {
      decision: args.decision,
    },
  };
}
