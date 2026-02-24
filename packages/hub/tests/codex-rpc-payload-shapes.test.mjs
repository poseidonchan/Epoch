import test from "node:test";
import assert from "node:assert/strict";

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

test("turn lifecycle payload shapes", () => {
  const started = makeTurnStartedNotification({ threadId: "thr_123", turnId: "turn_456" });
  assert.deepEqual(started, {
    method: "turn/started",
    params: {
      threadId: "thr_123",
      turn: {
        id: "turn_456",
        items: [],
        status: "inProgress",
        error: null,
      },
    },
  });

  const completed = makeTurnCompletedNotification({ threadId: "thr_123", turnId: "turn_456" });
  assert.deepEqual(completed, {
    method: "turn/completed",
    params: {
      threadId: "thr_123",
      turn: {
        id: "turn_456",
        items: [],
        status: "completed",
        error: null,
      },
    },
  });
});

test("agent message streaming payload shapes", () => {
  assert.deepEqual(makeAgentMessageStartedNotification({ threadId: "thr_123", turnId: "turn_456", itemId: "item_msg_1" }), {
    method: "item/started",
    params: {
      threadId: "thr_123",
      turnId: "turn_456",
      item: {
        type: "agentMessage",
        id: "item_msg_1",
        text: "",
      },
    },
  });

  assert.deepEqual(makeAgentMessageDeltaNotification({ threadId: "thr_123", turnId: "turn_456", itemId: "item_msg_1", delta: "Hello" }), {
    method: "item/agentMessage/delta",
    params: {
      threadId: "thr_123",
      turnId: "turn_456",
      itemId: "item_msg_1",
      delta: "Hello",
    },
  });

  assert.deepEqual(makeAgentMessageCompletedNotification({ threadId: "thr_123", turnId: "turn_456", itemId: "item_msg_1", text: "Hello world" }), {
    method: "item/completed",
    params: {
      threadId: "thr_123",
      turnId: "turn_456",
      item: {
        type: "agentMessage",
        id: "item_msg_1",
        text: "Hello world",
      },
    },
  });
});

test("command and file approval request/response payload shapes", () => {
  assert.deepEqual(
    makeCommandExecutionApprovalRequest({
      id: 91,
      threadId: "thr_123",
      turnId: "turn_456",
      itemId: "item_cmd_1",
      reason: "Needs network access",
      command: "pnpm test",
      cwd: "/Users/chan/Documents/GitHub/LabOS",
      commandActions: [{ type: "unknown", command: "pnpm test" }],
      proposedExecpolicyAmendment: ["allow command pnpm test in /Users/chan/Documents/GitHub/LabOS"],
    }),
    {
      method: "item/commandExecution/requestApproval",
      id: 91,
      params: {
        threadId: "thr_123",
        turnId: "turn_456",
        itemId: "item_cmd_1",
        reason: "Needs network access",
        command: "pnpm test",
        cwd: "/Users/chan/Documents/GitHub/LabOS",
        commandActions: [{ type: "unknown", command: "pnpm test" }],
        proposedExecpolicyAmendment: ["allow command pnpm test in /Users/chan/Documents/GitHub/LabOS"],
      },
    }
  );

  assert.deepEqual(makeCommandExecutionApprovalResponse({ id: 91, decision: "acceptForSession" }), {
    id: 91,
    result: {
      decision: "acceptForSession",
    },
  });

  assert.deepEqual(
    makeFileChangeApprovalRequest({
      id: 92,
      threadId: "thr_123",
      turnId: "turn_456",
      itemId: "item_patch_1",
      reason: "Apply patch to tracked files",
      grantRoot: "/Users/chan/Documents/GitHub/LabOS",
    }),
    {
      method: "item/fileChange/requestApproval",
      id: 92,
      params: {
        threadId: "thr_123",
        turnId: "turn_456",
        itemId: "item_patch_1",
        reason: "Apply patch to tracked files",
        grantRoot: "/Users/chan/Documents/GitHub/LabOS",
      },
    }
  );

  assert.deepEqual(makeFileChangeApprovalResponse({ id: 92, decision: "accept" }), {
    id: 92,
    result: {
      decision: "accept",
    },
  });
});
