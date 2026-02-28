export const operatorMethods = [
  "projects.list",
  "projects.create",
  "projects.rename",
  "projects.update",
  "projects.delete",
  "sessions.list",
  "sessions.create",
  "sessions.update",
  "sessions.generateTitle",
  "sessions.delete",
  "sessions.permission.set",
  "sessions.context.get",
  "chat.history",
  "runs.list",
  "runs.get",
  "artifacts.list",
  "artifacts.get",
  "artifacts.delete",
  "workspace.bootstrap.get",
  "workspace.bootstrap.update",
  "workspace.list",
  "workspace.content",
  "workspace.raw",
  "settings.openai.get",
  "settings.openai.set",
  "models.current",
  "hpc.prefs.set",
] as const;

export type OperatorMethod = (typeof operatorMethods)[number];

export const nodeMethods = [
  "slurm.submit",
  "slurm.status",
  "slurm.cancel",
  "fs.list",
  "fs.readRange",
  "shell.exec",
  "runtime.exec.start",
  "runtime.exec.cancel",
  "runtime.fs.stat",
  "runtime.fs.read",
  "runtime.fs.write",
  "runtime.fs.list",
  "runtime.fs.diff",
  "runtime.fs.applyPatch",
  "artifact.scan",
  "logs.tail",
  "hpc.prefs.set",
  "workspace.project.ensure",
] as const;

export type NodeMethod = (typeof nodeMethods)[number];

export const gatewayEventNames = [
  "connect.challenge",
  "projects.updated",
  "sessions.updated",
  "sessions.permission.updated",
  "sessions.context.updated",
  "chat.message.created",
  "runs.updated",
  "runs.log.delta",
  "artifacts.updated",
  "node.heartbeat",
  "slurm.job.updated",
  "runtime.exec.started",
  "runtime.exec.outputDelta",
  "runtime.exec.completed",
  "runtime.fs.changed",
  "runtime.fs.patchCompleted",
  "settings.openai.updated",
] as const;

export type GatewayEventName = (typeof gatewayEventNames)[number];

export const gatewayErrorCodes = [
  "AUTH_FAILED",
  "FORBIDDEN",
  "BAD_REQUEST",
  "NOT_FOUND",
  "CONFLICT",
  "RATE_LIMITED",
  "INTERNAL",
  "NODE_OFFLINE",
] as const;

export type GatewayErrorCode = (typeof gatewayErrorCodes)[number];

const operatorMethodsSet = new Set<string>(operatorMethods);
const nodeMethodsSet = new Set<string>(nodeMethods);

export function isOperatorMethod(value: string): value is OperatorMethod {
  return operatorMethodsSet.has(value);
}

export function isNodeMethod(value: string): value is NodeMethod {
  return nodeMethodsSet.has(value);
}
