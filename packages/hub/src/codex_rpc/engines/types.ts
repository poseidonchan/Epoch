import type { ThreadItem, Turn, UserInput } from "../types.js";

export type EngineStartTurnArgs = {
  threadId: string;
  turnId: string;
  input: UserInput[];
  historyTurns?: Turn[];
  cwd: string;
  model: string | null;
  modelProvider: string;
  approvalPolicy: string;
};

export type EngineStreamNotification = {
  type: "notification";
  method: string;
  params: Record<string, unknown>;
};

export type EngineStreamServerRequest = {
  type: "serverRequest";
  id?: string | number;
  method: string;
  params: Record<string, unknown>;
  respond?: (response: { result?: unknown; error?: { code: number; message: string; data?: unknown } }) => Promise<void>;
};

export type EngineStreamEvent = EngineStreamNotification | EngineStreamServerRequest;

export type EngineStartTurnResult = {
  turn: Turn;
  events: AsyncIterable<EngineStreamEvent>;
};

export interface CodexEngineSession {
  readonly name: string;

  threadStart?(params: Record<string, unknown>): Promise<Record<string, unknown>>;
  threadResume?(params: Record<string, unknown>): Promise<Record<string, unknown>>;
  threadRead?(params: Record<string, unknown>): Promise<Record<string, unknown>>;
  threadList?(params: Record<string, unknown>): Promise<Record<string, unknown>>;
  threadRollback?(params: Record<string, unknown>): Promise<Record<string, unknown>>;
  modelList?(params: Record<string, unknown>): Promise<Record<string, unknown>>;

  startTurn(args: EngineStartTurnArgs): Promise<EngineStartTurnResult>;
  interruptTurn(args: { threadId: string; turnId: string }): Promise<void>;
  handleClientResponse?(payload: { id: string | number; result?: unknown; error?: { code: number; message: string; data?: unknown } }): Promise<boolean>;
  close(): Promise<void>;
}

export class AsyncPushQueue<T> implements AsyncIterable<T> {
  private items: T[] = [];
  private waitingResolvers: Array<(value: IteratorResult<T>) => void> = [];
  private done = false;

  push(item: T) {
    if (this.done) return;
    const waiter = this.waitingResolvers.shift();
    if (waiter) {
      waiter({ done: false, value: item });
      return;
    }
    this.items.push(item);
  }

  finish() {
    if (this.done) return;
    this.done = true;
    while (this.waitingResolvers.length > 0) {
      const waiter = this.waitingResolvers.shift();
      if (waiter) waiter({ done: true, value: undefined as never });
    }
  }

  [Symbol.asyncIterator](): AsyncIterator<T> {
    return {
      next: async () => {
        if (this.items.length > 0) {
          const value = this.items.shift() as T;
          return { done: false, value };
        }
        if (this.done) {
          return { done: true, value: undefined as never };
        }
        return await new Promise<IteratorResult<T>>((resolve) => {
          this.waitingResolvers.push(resolve);
        });
      },
    };
  }
}

export function flattenUserInputToText(input: UserInput[]): string {
  return input
    .map((part) => {
      if (part.type === "text") return part.text;
      if (part.type === "image") return `[image:${part.url}]`;
      if (part.type === "localImage") return `[localImage:${part.path}]`;
      if (part.type === "skill") return `[skill:${part.name}]`;
      if (part.type === "mention") return `[mention:${part.name}]`;
      return "";
    })
    .filter(Boolean)
    .join("\n")
    .trim();
}

export function cloneThreadItem<T extends ThreadItem>(item: T): T {
  return JSON.parse(JSON.stringify(item)) as T;
}
