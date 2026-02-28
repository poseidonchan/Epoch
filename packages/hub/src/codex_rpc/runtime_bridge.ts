import type { NodeMethod } from "@labos/protocol";

export type SessionPermissionLevel = "default" | "full";

export type CodexRuntimeBridge = {
  isNodeConnected: () => boolean;
  listNodeCommands: () => string[];
  callNode: (method: NodeMethod, params: Record<string, unknown>) => Promise<Record<string, unknown>>;
  subscribeNodeEvents: (listener: (event: string, payload: Record<string, unknown>) => void) => () => void;
  getSessionPermissionLevel: (projectId: string, sessionId: string) => Promise<SessionPermissionLevel>;
  reconcileAgentsFile: (projectId: string, source: string) => Promise<void>;
};

