import { mkdir } from "node:fs/promises";
import path from "node:path";

type StateDirHolder = {
  stateDir: string;
};

export function projectDir(state: StateDirHolder, projectId: string) {
  return path.join(state.stateDir, "projects", projectId);
}

export function projectBootstrapDir(state: StateDirHolder, projectId: string) {
  return path.join(projectDir(state, projectId), "bootstrap");
}

export function projectSessionsDir(state: StateDirHolder, projectId: string) {
  return path.join(projectDir(state, projectId), "sessions");
}

export function projectThreadsDir(state: StateDirHolder, projectId: string) {
  return path.join(projectDir(state, projectId), "threads");
}

export function projectUploadsDir(state: StateDirHolder, projectId: string) {
  return path.join(projectDir(state, projectId), "uploads");
}

export function projectCacheDir(state: StateDirHolder, projectId: string) {
  return path.join(projectDir(state, projectId), "cache");
}

export function projectGeneratedDir(state: StateDirHolder, projectId: string) {
  return path.join(projectCacheDir(state, projectId), "generated");
}

export function sessionTranscriptPath(state: StateDirHolder, projectId: string, sessionId: string) {
  return path.join(projectSessionsDir(state, projectId), `${sessionId}.jsonl`);
}

export function codexDir(state: StateDirHolder) {
  return path.join(state.stateDir, "codex");
}

export function codexThreadsDir(state: StateDirHolder) {
  return path.join(codexDir(state), "threads");
}

export function threadTranscriptPath(state: StateDirHolder, args: { threadId: string; projectId?: string | null }) {
  if (args.projectId && args.projectId.trim()) {
    return path.join(projectThreadsDir(state, args.projectId), `${args.threadId}.jsonl`);
  }
  return path.join(codexThreadsDir(state), `${args.threadId}.jsonl`);
}

export async function ensureHubDirs(stateDir: string) {
  await mkdir(stateDir, { recursive: true });
  await mkdir(path.join(stateDir, "projects"), { recursive: true });
  await mkdir(path.join(stateDir, "codex"), { recursive: true });
  await mkdir(path.join(stateDir, "codex", "threads"), { recursive: true });
}

export async function ensureProjectDirs(state: StateDirHolder, projectId: string) {
  await mkdir(projectDir(state, projectId), { recursive: true });
  await mkdir(projectBootstrapDir(state, projectId), { recursive: true });
  await mkdir(projectSessionsDir(state, projectId), { recursive: true });
  await mkdir(projectThreadsDir(state, projectId), { recursive: true });
  await mkdir(projectUploadsDir(state, projectId), { recursive: true });
  await mkdir(projectCacheDir(state, projectId), { recursive: true });
  await mkdir(projectGeneratedDir(state, projectId), { recursive: true });
}
