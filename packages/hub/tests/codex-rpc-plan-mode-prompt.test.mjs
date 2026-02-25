import test from "node:test";
import assert from "node:assert/strict";

import { buildPlanImplementationPromptParams, decidePlanImplementationFollowup, turnContainsProposedPlanBlock } from "../dist/index.js";

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

test("buildPlanImplementationPromptParams emits deterministic implementation question", () => {
  const params = buildPlanImplementationPromptParams({
    threadId: "thr_plan_prompt",
    turnId: "turn_plan_prompt",
  });

  assert.equal(params.threadId, "thr_plan_prompt");
  assert.equal(params.turnId, "turn_plan_prompt");
  assert.equal(params.itemId, "labos_plan_implementation_turn_plan_prompt");
  assert.equal(Array.isArray(params.questions), true);
  assert.equal(params.questions[0].id, "labos_plan_implementation_decision");
});

test("decidePlanImplementationFollowup maps implement/plan/other answers", () => {
  const implement = decidePlanImplementationFollowup({
    answers: {
      labos_plan_implementation_decision: {
        answers: ["Implement now"],
      },
    },
  });
  assert.deepEqual(implement, {
    planMode: false,
    text: "Implement the approved plan now and proceed with execution.",
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
    text: "Continue in plan mode and refine the plan before implementation.",
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
