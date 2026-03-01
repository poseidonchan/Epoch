import test from "node:test";
import assert from "node:assert/strict";

import { createWizardPrompter } from "@labos/cli-utils";

test("non-interactive prompter rejects required values", async () => {
  const prompter = createWizardPrompter({ interactive: false });

  await assert.rejects(() => prompter.input({ message: "Hub WS URL" }), /non-interactive mode/);
  await assert.rejects(() => prompter.secret({ message: "Shared token", allowEmpty: false }), /non-interactive mode/);

  prompter.close();
});

test("non-interactive prompter keeps optional/default behavior", async () => {
  const prompter = createWizardPrompter({ interactive: false });

  assert.equal(await prompter.input({ message: "Workspace root", defaultValue: "/tmp/labos" }), "/tmp/labos");
  assert.equal(await prompter.input({ message: "Optional partition", allowEmpty: true }), "");
  assert.equal(await prompter.secret({ message: "Optional secret", allowEmpty: true }), "");
  assert.equal(await prompter.confirm({ message: "Confirm", defaultYes: true }), true);
  assert.equal(await prompter.confirm({ message: "Confirm", defaultYes: false }), false);

  prompter.close();
});
