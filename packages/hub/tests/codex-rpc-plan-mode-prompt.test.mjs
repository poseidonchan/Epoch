import test from "node:test";
import assert from "node:assert/strict";

import {
  buildPlanImplementationPromptParams,
  decidePlanImplementationFollowup,
  extractPlanUpdateFromDynamicToolCall,
  turnContainsImplementablePlan,
  turnContainsProposedPlanBlock,
} from "../dist/index.js";

test("turnContainsProposedPlanBlock detects plan fences in assistant messages", () => {
  const turnWithPlan = {
    id: "turn_with_plan",
    status: "completed",
    error: null,
    items: [
      {
        type: "agentMessage",
        id: "item_1",
        text: "<proposed_plan>\n- Step 1\n</proposed_plan>",
      },
    ],
  };
  const turnWithoutPlan = {
    id: "turn_without_plan",
    status: "completed",
    error: null,
    items: [
      {
        type: "agentMessage",
        id: "item_2",
        text: "No fenced plan here.",
      },
    ],
  };

  assert.equal(turnContainsProposedPlanBlock(turnWithPlan), true);
  assert.equal(turnContainsProposedPlanBlock(turnWithoutPlan), false);
});

test("turnContainsImplementablePlan detects plans with proposed_plan fences or step lists", () => {
  const fenced = {
    id: "turn_fenced_plan",
    status: "completed",
    error: null,
    items: [
      {
        type: "agentMessage",
        id: "item_1",
        text: "<proposed_plan>\n1. Step one\n2. Step two\n3. Step three\n</proposed_plan>",
      },
    ],
  };
  const numbered = {
    id: "turn_numbered_plan",
    status: "completed",
    error: null,
    items: [
      {
        type: "agentMessage",
        id: "item_2",
        text: "Here's a 5-step plan:\n1. One\n2. Two\n3. Three\n4. Four\n5. Five",
      },
    ],
  };
  const bullets = {
    id: "turn_bullets_plan",
    status: "completed",
    error: null,
    items: [
      {
        type: "agentMessage",
        id: "item_3",
        text: "Plan:\n- A\n- B\n- C",
      },
    ],
  };
  const notAPlan = {
    id: "turn_not_a_plan",
    status: "completed",
    error: null,
    items: [
      {
        type: "agentMessage",
        id: "item_4",
        text: "Two items:\n1. Not enough\n2. Still not enough",
      },
    ],
  };

  assert.equal(turnContainsImplementablePlan(fenced), true);
  assert.equal(turnContainsImplementablePlan(numbered), true);
  assert.equal(turnContainsImplementablePlan(bullets), true);
  assert.equal(turnContainsImplementablePlan(notAPlan), false);
});

test("buildPlanImplementationPromptParams emits deterministic implementation question", () => {
  const params = buildPlanImplementationPromptParams({
    threadId: "thr_plan_prompt",
    turnId: "turn_plan_prompt",
  });

  assert.equal(params.threadId, "thr_plan_prompt");
  assert.equal(params.turnId, "turn_plan_prompt");
  assert.equal(params.itemId, "labos_plan_implementation_turn_plan_prompt");
  assert.equal(params.prompt, "Implement this plan?");
  assert.equal(Array.isArray(params.questions), true);
  assert.equal(params.questions[0].id, "labos_plan_implementation_decision");
  assert.equal(params.questions[0].isOther, true);
  assert.equal(params.questions[0].options.length, 2);
  assert.equal(params.questions[0].options[0].label, "Yes, implement this plan");
  assert.equal(params.questions[0].options[1].label, "Keep planning");
});

test("decidePlanImplementationFollowup maps implement/plan/other answers", () => {
  const implement = decidePlanImplementationFollowup({
    answers: {
      labos_plan_implementation_decision: {
        answers: ["Yes, implement this plan"],
      },
    },
  });
  assert.deepEqual(implement, {
    planMode: false,
    text: "Implement it",
  });

  const implementFreeform = decidePlanImplementationFollowup({
    answers: {
      labos_plan_implementation_decision: {
        answers: ["Implement it."],
      },
    },
  });
  assert.deepEqual(implementFreeform, {
    planMode: false,
    text: "Implement it",
  });

  const keepPlanning = decidePlanImplementationFollowup({
    answers: {
      labos_plan_implementation_decision: {
        answers: ["Keep planning"],
      },
    },
  });
  assert.deepEqual(keepPlanning, {
    planMode: true,
    text: "Continue planning and refine the plan before implementation.",
  });

  const custom = decidePlanImplementationFollowup({
    answers: {
      labos_plan_implementation_decision: {
        answers: ["Add stronger constraints"],
      },
    },
  });
  assert.equal(custom?.planMode, true);
  assert.match(custom?.text ?? "", /Add stronger constraints/);
});

test("extractPlanUpdateFromDynamicToolCall parses update_plan tool calls", () => {
  const update = extractPlanUpdateFromDynamicToolCall("item/tool/call", {
    threadId: "thr_dynamic_plan",
    turnId: "turn_dynamic_plan",
    callId: "call_dynamic_plan",
    tool: "update_plan",
    arguments: {
      explanation: "Running checklist",
      plan: [
        { step: "Define acceptance criteria", status: "completed" },
        { step: "Implement changes", status: "in_progress" },
        { step: "Run regression tests", status: "pending" },
      ],
    },
  });

  assert.deepEqual(update, {
    turnId: "turn_dynamic_plan",
    explanation: "Running checklist",
    plan: [
      { step: "Define acceptance criteria", status: "completed" },
      { step: "Implement changes", status: "inProgress" },
      { step: "Run regression tests", status: "pending" },
    ],
  });
});

test("extractPlanUpdateFromDynamicToolCall ignores non-plan dynamic tool calls", () => {
  const update = extractPlanUpdateFromDynamicToolCall("item/tool/call", {
    threadId: "thr_dynamic_other",
    turnId: "turn_dynamic_other",
    callId: "call_dynamic_other",
    tool: "open_page",
    arguments: { url: "https://example.com" },
  });
  assert.equal(update, null);
});
