import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import Ajv from "ajv";

import {
  makeTurnStartedNotification,
  makeTurnCompletedNotification,
  makeAgentMessageStartedNotification,
  makeAgentMessageDeltaNotification,
  makeAgentMessageCompletedNotification,
  makeCommandExecutionApprovalRequest,
  makeCommandExecutionApprovalResponse,
  makeFileChangeApprovalRequest,
  makeFileChangeApprovalResponse,
} from "../dist/index.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const protocolSchemaPath = path.join(__dirname, "../../codex-spec/schema/json/codex_app_server_protocol.schemas.json");
const protocolSchema = JSON.parse(readFileSync(protocolSchemaPath, "utf8"));
const definitions = protocolSchema.definitions;

function compileDefinition(definitionName) {
  const ajv = new Ajv({ strict: false, allErrors: true });
  return ajv.compile({
    $ref: `#/definitions/${definitionName}`,
    definitions,
  });
}

function assertValid(validator, payload, label) {
  const ok = validator(payload);
  if (!ok) {
    assert.fail(`${label} failed schema validation: ${JSON.stringify(validator.errors, null, 2)}`);
  }
}

test("notifications conform to ServerNotification schema", () => {
  const serverNotification = compileDefinition("ServerNotification");

  assertValid(serverNotification, makeTurnStartedNotification({ threadId: "thr_123", turnId: "turn_456" }), "turn/started");
  assertValid(serverNotification, makeTurnCompletedNotification({ threadId: "thr_123", turnId: "turn_456" }), "turn/completed");
  assertValid(
    serverNotification,
    makeAgentMessageStartedNotification({ threadId: "thr_123", turnId: "turn_456", itemId: "item_msg_1" }),
    "item/started"
  );
  assertValid(
    serverNotification,
    makeAgentMessageDeltaNotification({ threadId: "thr_123", turnId: "turn_456", itemId: "item_msg_1", delta: "Hello" }),
    "item/agentMessage/delta"
  );
  assertValid(
    serverNotification,
    makeAgentMessageCompletedNotification({ threadId: "thr_123", turnId: "turn_456", itemId: "item_msg_1", text: "Hello world" }),
    "item/completed"
  );
});

test("approval requests conform to ServerRequest schema and decisions conform to response schemas", () => {
  const serverRequest = compileDefinition("ServerRequest");
  const cmdApprovalResponse = compileDefinition("CommandExecutionRequestApprovalResponse");
  const fileApprovalResponse = compileDefinition("FileChangeRequestApprovalResponse");

  const cmdRequest = makeCommandExecutionApprovalRequest({
    id: 91,
    threadId: "thr_123",
    turnId: "turn_456",
    itemId: "item_cmd_1",
    reason: "Needs network access",
    command: "pnpm test",
    cwd: "/Users/chan/Documents/GitHub/Epoch",
    commandActions: [{ type: "unknown", command: "pnpm test" }],
    proposedExecpolicyAmendment: ["allow command pnpm test in /Users/chan/Documents/GitHub/Epoch"],
  });
  assertValid(serverRequest, cmdRequest, "item/commandExecution/requestApproval");

  const cmdResponse = makeCommandExecutionApprovalResponse({ id: 91, decision: "acceptForSession" });
  assertValid(cmdApprovalResponse, cmdResponse.result, "command approval result");

  const fileRequest = makeFileChangeApprovalRequest({
    id: 92,
    threadId: "thr_123",
    turnId: "turn_456",
    itemId: "item_patch_1",
    reason: "Apply patch to tracked files",
    grantRoot: "/Users/chan/Documents/GitHub/Epoch",
  });
  assertValid(serverRequest, fileRequest, "item/fileChange/requestApproval");

  const fileResponse = makeFileChangeApprovalResponse({ id: 92, decision: "accept" });
  assertValid(fileApprovalResponse, fileResponse.result, "file approval result");
});
