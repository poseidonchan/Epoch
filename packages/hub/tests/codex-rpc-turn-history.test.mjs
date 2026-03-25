import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";

import { handleTurnStart } from "../dist/index.js";

const originalWorkspaceRoot = process.env.EPOCH_HPC_WORKSPACE_ROOT;
test.before(() => {
  process.env.EPOCH_HPC_WORKSPACE_ROOT = "/tmp/epoch";
});
test.after(() => {
  if (originalWorkspaceRoot == null) {
    delete process.env.EPOCH_HPC_WORKSPACE_ROOT;
  } else {
    process.env.EPOCH_HPC_WORKSPACE_ROOT = originalWorkspaceRoot;
  }
});

function withStateDirectory(repository, stateDir = "/tmp/epoch-turn-history-state") {
  return {
    stateDirectory() {
      return stateDir;
    },
    ...repository,
  };
}

test("handleTurnStart forwards plan mode as collaborationMode=plan", async () => {
  const threadId = "123e4567-e89b-12d3-a456-426614174111";
  const thread = {
    id: threadId,
    preview: "",
    modelProvider: "openai",
    createdAt: 1,
    updatedAt: 1,
    path: null,
    cwd: "/tmp/project",
    cliVersion: "epoch/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [],
  };

  let capturedStartArgs = null;

  const repository = withStateDirectory({
    async query() {
      return [];
    },
    async getThreadRecord(id) {
      assert.equal(id, threadId);
      return {
        id: threadId,
        projectId: "proj_1",
        cwd: "/tmp/project",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "",
        createdAt: 1,
        updatedAt: 1,
        archived: false,
        statusJson: JSON.stringify({
          modelProvider: "openai",
          model: "gpt-5.3-codex",
          cwd: "/tmp/project",
          approvalPolicy: "on-request",
          sandbox: { mode: "workspace-write" },
          reasoningEffort: null,
        }),
        engine: "codex-app-server",
      };
    },
    async readThread(id) {
      assert.equal(id, threadId);
      return JSON.parse(JSON.stringify(thread));
    },
    async updateThread() {},
    async createTurn() {},
    async upsertItem() {},
  });

  const engines = {
    async getEngine(name) {
      assert.equal(name, "codex-app-server");
      return {
        async startTurn(args) {
          capturedStartArgs = args;
          return {
            turn: {
              id: args.turnId,
              items: [],
              status: "inProgress",
              error: null,
            },
            events: emptyEvents(),
          };
        },
      };
    },
  };

  await handleTurnStart(
    {
      repository,
      engines,
    },
    {
      threadId,
      input: [{ type: "text", text: "plan this change" }],
      planMode: true,
    }
  );

  assert.ok(capturedStartArgs);
  assert.equal(capturedStartArgs.collaborationMode.mode, "plan");
  assert.equal(capturedStartArgs.collaborationMode.settings.model, "gpt-5.3-codex");
  assert.match(
    capturedStartArgs.collaborationMode.settings.developer_instructions,
    /plan mode is active/i
  );
  assert.match(
    capturedStartArgs.collaborationMode.settings.developer_instructions,
    /one question at a time/i
  );
  assert.match(
    capturedStartArgs.collaborationMode.settings.developer_instructions,
    /stop.*cancel/i
  );
});

test("handleTurnStart falls back to the default direct-connect workspace root", async () => {
  const threadId = "123e4567-e89b-12d3-a456-426614174120";
  const projectId = "proj_missing_root";
  const stateDir = "/tmp/epoch-turn-default-state";
  const expectedCwd = `${stateDir}/workspace/projects/${projectId}`;
  const thread = {
    id: threadId,
    preview: "",
    modelProvider: "openai",
    createdAt: 1,
    updatedAt: 1,
    path: null,
    cwd: `projects/${projectId}`,
    cliVersion: "epoch/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [],
  };

  let capturedStartArgs = null;
  let updatedThread = null;
  const originalWorkspaceRoot = process.env.EPOCH_WORKSPACE_ROOT;
  const originalLegacyRoot = process.env.EPOCH_HPC_WORKSPACE_ROOT;
  delete process.env.EPOCH_WORKSPACE_ROOT;
  delete process.env.EPOCH_HPC_WORKSPACE_ROOT;

  try {
    const repository = withStateDirectory({
      stateDirectory() {
        return stateDir;
      },
      async query(sql, args = []) {
        const normalized = String(sql);
        if (normalized.includes("FROM projects") && normalized.includes("hpc_workspace_path")) {
          assert.equal(args[0], projectId);
          return [];
        }
        return [];
      },
      async getThreadRecord(id) {
        assert.equal(id, threadId);
        return {
          id: threadId,
          projectId,
          cwd: `projects/${projectId}`,
          modelProvider: "openai",
          modelId: "gpt-5.3-codex",
          preview: "",
          createdAt: 1,
          updatedAt: 1,
          archived: false,
          statusJson: JSON.stringify({
            modelProvider: "openai",
            model: "gpt-5.3-codex",
            cwd: `projects/${projectId}`,
            approvalPolicy: "on-request",
            sandbox: { mode: "workspace-write" },
            reasoningEffort: null,
          }),
          engine: "codex-app-server",
        };
      },
      async readThread(id) {
        assert.equal(id, threadId);
        return JSON.parse(JSON.stringify(thread));
      },
      async updateThread(args) {
        updatedThread = args;
      },
      async createTurn() {},
      async upsertItem() {},
    });

    const engines = {
      async getEngine(name) {
        assert.equal(name, "codex-app-server");
        return {
          async startTurn(args) {
            capturedStartArgs = args;
            return {
              turn: {
                id: args.turnId,
                items: [],
                status: "inProgress",
                error: null,
              },
              events: emptyEvents(),
            };
          },
        };
      },
    };

    await handleTurnStart(
      {
        repository,
        engines,
      },
      {
        threadId,
        input: [{ type: "text", text: "plan this change" }],
        planMode: true,
      }
    );

    assert.ok(updatedThread);
    assert.equal(updatedThread.cwd, expectedCwd);
    assert.ok(capturedStartArgs);
    assert.equal(capturedStartArgs.cwd, expectedCwd);
  } finally {
    if (originalWorkspaceRoot == null) {
      delete process.env.EPOCH_WORKSPACE_ROOT;
    } else {
      process.env.EPOCH_WORKSPACE_ROOT = originalWorkspaceRoot;
    }
    if (originalLegacyRoot == null) {
      delete process.env.EPOCH_HPC_WORKSPACE_ROOT;
    } else {
      process.env.EPOCH_HPC_WORKSPACE_ROOT = originalLegacyRoot;
    }
  }
});

test("handleTurnStart prefers a persisted project workspace path when available", async () => {
  const threadId = "123e4567-e89b-12d3-a456-426614174122";
  const projectId = "proj_from_nodes";
  const chosenWorkspacePath = "/srv/hpc/custom-thread-project";
  const legacyCwd = `projects/${projectId}`;
  const thread = {
    id: threadId,
    preview: "",
    modelProvider: "openai",
    createdAt: 1,
    updatedAt: 1,
    path: null,
    cwd: legacyCwd,
    cliVersion: "epoch/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [],
  };

  let capturedStartArgs = null;
  let updatedThread = null;
  const originalWorkspaceRoot = process.env.EPOCH_WORKSPACE_ROOT;
  const originalLegacyRoot = process.env.EPOCH_HPC_WORKSPACE_ROOT;
  delete process.env.EPOCH_WORKSPACE_ROOT;
  delete process.env.EPOCH_HPC_WORKSPACE_ROOT;

  try {
    const repository = withStateDirectory({
      stateDirectory() {
        return "/tmp/epoch-turn-state";
      },
      async query(sql, args = []) {
        const normalized = String(sql);
        if (normalized.includes("FROM projects") && normalized.includes("hpc_workspace_path")) {
          assert.equal(args[0], projectId);
          return [{ hpc_workspace_path: chosenWorkspacePath }];
        }
        return [];
      },
      async getThreadRecord(id) {
        assert.equal(id, threadId);
        return {
          id: threadId,
          projectId,
          cwd: legacyCwd,
          modelProvider: "openai",
          modelId: "gpt-5.3-codex",
          preview: "",
          createdAt: 1,
          updatedAt: 1,
          archived: false,
          statusJson: JSON.stringify({
            modelProvider: "openai",
            model: "gpt-5.3-codex",
            cwd: legacyCwd,
            approvalPolicy: "on-request",
            sandbox: { mode: "workspace-write" },
            reasoningEffort: null,
          }),
          engine: "codex-app-server",
        };
      },
      async readThread(id) {
        assert.equal(id, threadId);
        return JSON.parse(JSON.stringify(thread));
      },
      async updateThread(args) {
        updatedThread = args;
      },
      async createTurn() {},
      async upsertItem() {},
    });

    const engines = {
      async getEngine(name) {
        assert.equal(name, "codex-app-server");
        return {
          async startTurn(args) {
            capturedStartArgs = args;
            return {
              turn: {
                id: args.turnId,
                items: [],
                status: "inProgress",
                error: null,
              },
              events: emptyEvents(),
            };
          },
        };
      },
    };

    await handleTurnStart(
      {
        repository,
        engines,
      },
      {
        threadId,
        input: [{ type: "text", text: "hello from nodes root" }],
      }
    );

    assert.ok(updatedThread);
    assert.equal(updatedThread.cwd, chosenWorkspacePath);
    assert.ok(capturedStartArgs);
    assert.equal(capturedStartArgs.cwd, chosenWorkspacePath);
  } finally {
    if (originalWorkspaceRoot == null) {
      delete process.env.EPOCH_WORKSPACE_ROOT;
    } else {
      process.env.EPOCH_WORKSPACE_ROOT = originalWorkspaceRoot;
    }
    if (originalLegacyRoot == null) {
      delete process.env.EPOCH_HPC_WORKSPACE_ROOT;
    } else {
      process.env.EPOCH_HPC_WORKSPACE_ROOT = originalLegacyRoot;
    }
  }
});

test("handleTurnStart normalizes stale project cwd before engine start", async () => {
  const originalRoot = process.env.EPOCH_HPC_WORKSPACE_ROOT;
  process.env.EPOCH_HPC_WORKSPACE_ROOT = "/tmp/epoch";

  const threadId = "123e4567-e89b-12d3-a456-426614174121";
  const projectId = "proj_normalize";
  const staleCwd = `/Users/example/projects/${projectId}/runs/run_42`;
  const expectedCwd = `/tmp/epoch/projects/${projectId}/runs/run_42`;
  const thread = {
    id: threadId,
    preview: "",
    modelProvider: "openai",
    createdAt: 1,
    updatedAt: 1,
    path: null,
    cwd: staleCwd,
    cliVersion: "epoch/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [],
  };

  let capturedStartArgs = null;
  let capturedUpdateThread = null;

  try {
    const repository = withStateDirectory({
      async query() {
        return [];
      },
      async getThreadRecord(id) {
        assert.equal(id, threadId);
        return {
          id: threadId,
          projectId,
          cwd: staleCwd,
          modelProvider: "openai",
          modelId: "gpt-5.3-codex",
          preview: "",
          createdAt: 1,
          updatedAt: 1,
          archived: false,
          statusJson: JSON.stringify({
            modelProvider: "openai",
            model: "gpt-5.3-codex",
            cwd: staleCwd,
            approvalPolicy: "on-request",
            sandbox: { mode: "workspace-write" },
            reasoningEffort: null,
          }),
          engine: "codex-app-server",
        };
      },
      async readThread(id) {
        assert.equal(id, threadId);
        return JSON.parse(JSON.stringify(thread));
      },
      async updateThread(args) {
        capturedUpdateThread = args;
      },
      async createTurn() {},
      async upsertItem() {},
    });

    const engines = {
      async getEngine(name) {
        assert.equal(name, "codex-app-server");
        return {
          async startTurn(args) {
            capturedStartArgs = args;
            return {
              turn: {
                id: args.turnId,
                items: [],
                status: "inProgress",
                error: null,
              },
              events: emptyEvents(),
            };
          },
        };
      },
    };

    await handleTurnStart(
      {
        repository,
        engines,
      },
      {
        threadId,
        input: [{ type: "text", text: "normalize cwd" }],
      }
    );

    assert.ok(capturedUpdateThread);
    assert.equal(capturedUpdateThread.cwd, expectedCwd);
    assert.ok(capturedStartArgs);
    assert.equal(capturedStartArgs.cwd, expectedCwd);
  } finally {
    if (originalRoot == null) {
      delete process.env.EPOCH_HPC_WORKSPACE_ROOT;
    } else {
      process.env.EPOCH_HPC_WORKSPACE_ROOT = originalRoot;
    }
  }
});

test("handleTurnStart repairs legacy embedded-tilde persisted project roots before engine start", async () => {
  const threadId = "123e4567-e89b-12d3-a456-426614174124";
  const projectId = "proj_embedded_tilde";
  const thread = {
    id: threadId,
    preview: "",
    modelProvider: "openai",
    createdAt: 1,
    updatedAt: 1,
    path: null,
    cwd: `projects/${projectId}`,
    cliVersion: "epoch/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [],
  };

  let capturedStartArgs = null;
  let updatedThread = null;

  const repository = withStateDirectory({
    async query(sql, args = []) {
      const normalized = String(sql);
      if (normalized.includes("FROM projects") && normalized.includes("hpc_workspace_path")) {
        assert.equal(args[0], projectId);
        return [{ hpc_workspace_path: `${process.cwd()}/~` }];
      }
      return [];
    },
    async getThreadRecord(id) {
      assert.equal(id, threadId);
      return {
        id: threadId,
        projectId,
        cwd: `projects/${projectId}`,
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "",
        createdAt: 1,
        updatedAt: 1,
        archived: false,
        statusJson: JSON.stringify({
          modelProvider: "openai",
          model: "gpt-5.3-codex",
          cwd: `projects/${projectId}`,
          approvalPolicy: "on-request",
          sandbox: { mode: "workspace-write" },
          reasoningEffort: null,
        }),
        engine: "codex-app-server",
      };
    },
    async readThread(id) {
      assert.equal(id, threadId);
      return JSON.parse(JSON.stringify(thread));
    },
    async updateThread(args) {
      updatedThread = args;
    },
    async createTurn() {},
    async upsertItem() {},
  });

  const engines = {
    async getEngine(name) {
      assert.equal(name, "codex-app-server");
      return {
        async startTurn(args) {
          capturedStartArgs = args;
          return {
            turn: {
              id: args.turnId,
              items: [],
              status: "inProgress",
              error: null,
            },
            events: emptyEvents(),
          };
        },
      };
    },
  };

  await handleTurnStart(
    {
      repository,
      engines,
    },
    {
      threadId,
      input: [{ type: "text", text: "repair legacy tilde path" }],
    }
  );

  assert.ok(updatedThread);
  assert.equal(updatedThread.cwd, os.homedir());
  assert.ok(capturedStartArgs);
  assert.equal(capturedStartArgs.cwd, os.homedir());
});

test("handleTurnStart injects indexed project snippets into turn input", async () => {
  const originalApiKey = process.env.OPENAI_API_KEY;
  delete process.env.OPENAI_API_KEY;

  try {
    const threadId = "123e4567-e89b-12d3-a456-426614174113";
    const thread = {
      id: threadId,
      preview: "",
      modelProvider: "openai",
      createdAt: 1,
      updatedAt: 1,
      path: null,
      cwd: "/tmp/project",
      cliVersion: "epoch/0.1.0",
      source: "appServer",
      gitInfo: null,
      turns: [],
    };

    let capturedStartArgs = null;

    const dbPool = {
      async query(sql) {
        const normalized = String(sql);
        if (normalized.includes("FROM artifacts a")) {
          return {
            rows: [
              {
                path: "uploads/experiment-notes.txt",
                modified_at: "2026-02-24T00:00:00.000Z",
                size_bytes: 120,
                index_status: "indexed",
                index_summary: "Contains marker RED-PLANT-8842.",
                indexed_at: "2026-02-24T00:00:05.000Z",
              },
            ],
          };
        }
        if (normalized.includes("FROM project_file_chunk")) {
          return {
            rows: [
              {
                artifact_path: "uploads/experiment-notes.txt",
                chunk_index: 0,
                content: "Retrieval marker RED-PLANT-8842. The launch code is 8842.",
                embedding_json: null,
              },
            ],
          };
        }
        return { rows: [] };
      },
    };

    const repository = withStateDirectory({
      dbPool() {
        return dbPool;
      },
      async query() {
        return [];
      },
      async getThreadRecord(id) {
        assert.equal(id, threadId);
        return {
          id: threadId,
          projectId: "proj_ctx_1",
          cwd: "/tmp/project",
          modelProvider: "openai",
          modelId: "gpt-5.3-codex",
          preview: "",
          createdAt: 1,
          updatedAt: 1,
          archived: false,
          statusJson: JSON.stringify({
            modelProvider: "openai",
            model: "gpt-5.3-codex",
            cwd: "/tmp/project",
            approvalPolicy: "on-request",
            sandbox: { mode: "workspace-write" },
            reasoningEffort: null,
          }),
          engine: "codex-app-server",
        };
      },
      async readThread(id) {
        assert.equal(id, threadId);
        return JSON.parse(JSON.stringify(thread));
      },
      async updateThread() {},
      async createTurn() {},
      async upsertItem() {},
    });

    const engines = {
      async getEngine(name) {
        assert.equal(name, "codex-app-server");
        return {
          async startTurn(args) {
            capturedStartArgs = args;
            return {
              turn: {
                id: args.turnId,
                items: [],
                status: "inProgress",
                error: null,
              },
              events: emptyEvents(),
            };
          },
        };
      },
    };

    await handleTurnStart(
      {
        repository,
        engines,
      },
      {
        threadId,
        input: [{ type: "text", text: "What is the launch code in the uploaded experiment notes?" }],
      }
    );

    assert.ok(capturedStartArgs);
    assert.equal(capturedStartArgs.input.length, 1);
    const firstText = capturedStartArgs.input.find((part) => part.type === "text")?.text ?? "";
    assert.equal(firstText, "What is the launch code in the uploaded experiment notes?");
    const developerInstructions = capturedStartArgs.collaborationMode?.settings?.developer_instructions ?? "";
    assert.ok(developerInstructions.includes("[EPOCH_PROJECT_CONTEXT]"));
    assert.ok(developerInstructions.includes("uploads/experiment-notes.txt#0"));
    assert.ok(developerInstructions.includes("RED-PLANT-8842"));
    assert.equal(developerInstructions.includes("User request:"), false);
  } finally {
    if (originalApiKey == null) {
      delete process.env.OPENAI_API_KEY;
    } else {
      process.env.OPENAI_API_KEY = originalApiKey;
    }
  }
});

test("handleTurnStart sends history fallback context via developer instructions only", async () => {
  const threadId = "123e4567-e89b-12d3-a456-426614174155";
  const thread = {
    id: threadId,
    preview: "continue",
    modelProvider: "openai",
    createdAt: 1,
    updatedAt: 1,
    path: null,
    cwd: "/tmp/project",
    cliVersion: "epoch/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [
      {
        id: "turn_prev",
        status: "completed",
        error: null,
        items: [
          {
            type: "userMessage",
            id: "item_user_prev",
            content: [{ type: "text", text: "prior request", text_elements: [] }],
          },
          {
            type: "agentMessage",
            id: "item_agent_prev",
            text: "prior answer",
          },
        ],
      },
    ],
  };

  let capturedStartArgs = null;
  const updateThreadCalls = [];

  const repository = withStateDirectory({
    async query() {
      return [];
    },
    async getThreadRecord(id) {
      assert.equal(id, threadId);
      return {
        id: threadId,
        projectId: "proj_1",
        cwd: "/tmp/project",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "continue",
        createdAt: 1,
        updatedAt: 1,
        archived: false,
        statusJson: JSON.stringify({
          modelProvider: "openai",
          model: "gpt-5.3-codex",
          cwd: "/tmp/project",
          approvalPolicy: "on-request",
          sandbox: { mode: "workspace-write" },
          reasoningEffort: null,
          syncState: "needsRemoteHydration",
        }),
        engine: "codex-app-server",
      };
    },
    async readThread(id) {
      assert.equal(id, threadId);
      return JSON.parse(JSON.stringify(thread));
    },
    async updateThread() {},
    async createTurn() {},
    async upsertItem() {},
    async findSessionByThread() {
      return null;
    },
    async assignThreadToSession() {},
  });

  const engines = {
    async getEngine(name) {
      assert.equal(name, "codex-app-server");
      return {
        async threadStart() {
          return { thread };
        },
        async startTurn(args) {
          capturedStartArgs = args;
          return {
            turn: {
              id: args.turnId,
              items: [],
              status: "inProgress",
              error: null,
            },
            events: emptyEvents(),
          };
        },
      };
    },
  };

  await handleTurnStart(
    {
      repository,
      engines,
    },
    {
      threadId,
      input: [{ type: "text", text: "continue" }],
    }
  );

  assert.ok(capturedStartArgs);
  const firstText = capturedStartArgs.input.find((part) => part.type === "text")?.text ?? "";
  assert.equal(firstText, "continue");
  const developerInstructions = capturedStartArgs.collaborationMode?.settings?.developer_instructions ?? "";
  assert.ok(developerInstructions.includes("[EPOCH_SESSION_HISTORY_FALLBACK]"));
  assert.ok(developerInstructions.includes("User: prior request"));
  assert.ok(developerInstructions.includes("Assistant: prior answer"));
  assert.equal(developerInstructions.includes("User request:"), false);
});

test("handleTurnStart still forwards collaborationMode when stored model is missing", async () => {
  const originalModel = process.env.EPOCH_MODEL;
  const originalPrimary = process.env.EPOCH_MODEL_PRIMARY;
  process.env.EPOCH_MODEL = "openai-codex/gpt-5.3-codex";
  process.env.EPOCH_MODEL_PRIMARY = "openai-codex/gpt-5.3-codex";

  try {
    const threadId = "123e4567-e89b-12d3-a456-426614174112";
    const thread = {
      id: threadId,
      preview: "",
      modelProvider: "openai",
      createdAt: 1,
      updatedAt: 1,
      path: null,
      cwd: "/tmp/project",
      cliVersion: "epoch/0.1.0",
      source: "appServer",
      gitInfo: null,
      turns: [],
    };

    let capturedStartArgs = null;

    const repository = withStateDirectory({
      async query() {
        return [];
      },
      async getThreadRecord(id) {
        assert.equal(id, threadId);
        return {
          id: threadId,
          projectId: "proj_1",
          cwd: "/tmp/project",
          modelProvider: "openai",
          modelId: null,
          preview: "",
          createdAt: 1,
          updatedAt: 1,
          archived: false,
          statusJson: JSON.stringify({
            modelProvider: "openai",
            model: null,
            cwd: "/tmp/project",
            approvalPolicy: "on-request",
            sandbox: { mode: "workspace-write" },
            reasoningEffort: null,
          }),
          engine: "codex-app-server",
        };
      },
      async readThread(id) {
        assert.equal(id, threadId);
        return JSON.parse(JSON.stringify(thread));
      },
      async updateThread() {},
      async createTurn() {},
      async upsertItem() {},
    });

    const engines = {
      async getEngine(name) {
        assert.equal(name, "codex-app-server");
        return {
          async startTurn(args) {
            capturedStartArgs = args;
            return {
              turn: {
                id: args.turnId,
                items: [],
                status: "inProgress",
                error: null,
              },
              events: emptyEvents(),
            };
          },
        };
      },
    };

    await handleTurnStart(
      {
        repository,
        engines,
      },
      {
        threadId,
        input: [{ type: "text", text: "plan this change" }],
        planMode: true,
      }
    );

    assert.ok(capturedStartArgs);
    assert.equal(capturedStartArgs.model, "gpt-5.3-codex");
    assert.equal(capturedStartArgs.collaborationMode.mode, "plan");
    assert.equal(capturedStartArgs.collaborationMode.settings.model, "gpt-5.3-codex");
    assert.match(
      capturedStartArgs.collaborationMode.settings.developer_instructions,
      /plan mode is active/i
    );
  } finally {
    if (originalModel == null) {
      delete process.env.EPOCH_MODEL;
    } else {
      process.env.EPOCH_MODEL = originalModel;
    }
    if (originalPrimary == null) {
      delete process.env.EPOCH_MODEL_PRIMARY;
    } else {
      process.env.EPOCH_MODEL_PRIMARY = originalPrimary;
    }
  }
});

test("handleTurnStart normalizes legacy pi threads and starts with codex engine", async () => {
  const legacyThreadId = "123e4567-e89b-12d3-a456-426614174099";
  const priorTurn = {
    id: "turn_prev",
    status: "completed",
    error: null,
    items: [
      {
        type: "userMessage",
        id: "item_user_prev",
        content: [{ type: "text", text: "previous question", text_elements: [] }],
      },
      {
        type: "agentMessage",
        id: "item_agent_prev",
        text: "previous answer",
      },
    ],
  };

  const thread = {
    id: legacyThreadId,
    preview: "previous question",
    modelProvider: "openai",
    createdAt: 1,
    updatedAt: 2,
    path: null,
    cwd: "/tmp/project",
    cliVersion: "epoch/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [priorTurn],
  };

  let capturedStartArgs = null;
  const updateThreadCalls = [];

  const repository = withStateDirectory({
    async query() {
      return [];
    },
    async getThreadRecord(threadId) {
      assert.equal(threadId, legacyThreadId);
      return {
        id: legacyThreadId,
        projectId: "proj_1",
        cwd: "/tmp/project",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "previous question",
        createdAt: 1,
        updatedAt: 2,
        archived: false,
        statusJson: JSON.stringify({
          modelProvider: "openai",
          model: "gpt-5.3-codex",
          cwd: "/tmp/project",
          approvalPolicy: "on-request",
          sandbox: { mode: "workspace-write" },
          reasoningEffort: null,
        }),
        engine: "pi",
      };
    },
    async readThread(threadId) {
      assert.equal(threadId, legacyThreadId);
      return JSON.parse(JSON.stringify(thread));
    },
    async updateThread(args) {
      assert.equal(args.id, legacyThreadId);
      updateThreadCalls.push(args);
    },
    async createTurn() {},
    async upsertItem() {},
  });

  const engines = {
    async getEngine(name) {
      assert.equal(name, "codex-app-server");
      return {
        async startTurn(args) {
          capturedStartArgs = args;
          return {
            turn: {
              id: args.turnId,
              items: [],
              status: "inProgress",
              error: null,
            },
            events: emptyEvents(),
          };
        },
      };
    },
  };

  const prepared = await handleTurnStart(
    {
      repository,
      engines,
    },
    {
      threadId: legacyThreadId,
      input: [{ type: "text", text: "new question" }],
    }
  );

  assert.equal(prepared.threadId, legacyThreadId);
  assert.ok(capturedStartArgs);
  assert.equal(capturedStartArgs.threadId, legacyThreadId);
  assert.equal(capturedStartArgs.input.length, 1);
  assert.equal(capturedStartArgs.historyTurns.length, 1);
  assert.equal(capturedStartArgs.historyTurns[0].id, "turn_prev");
  assert.ok(updateThreadCalls.some((entry) => entry.engine === "codex-app-server"));
});

test("handleTurnStart seeds history via thread/resume when repairing codex thread ids", async () => {
  const localThread = {
    id: "thr_local",
    preview: "old preview",
    modelProvider: "openai",
    createdAt: 10,
    updatedAt: 11,
    path: null,
    cwd: "/tmp/project",
    cliVersion: "epoch/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [
      {
        id: "turn_local_1",
        status: "completed",
        error: null,
        items: [
          {
            type: "userMessage",
            id: "item_user_1",
            content: [{ type: "text", text: "hello from pi", text_elements: [] }],
          },
          {
            type: "agentMessage",
            id: "item_agent_1",
            text: "hello from agent",
          },
        ],
      },
    ],
  };

  const repairedThread = {
    id: "123e4567-e89b-12d3-a456-426614174000",
    preview: "repaired",
    modelProvider: "openai",
    createdAt: 20,
    updatedAt: 20,
    path: null,
    cwd: "/tmp/project",
    cliVersion: "@openai/codex/1.0.0",
    source: "appServer",
    gitInfo: null,
    turns: [],
  };

  const threadRecords = new Map([
    [
      "thr_local",
      {
        id: "thr_local",
        projectId: "proj_1",
        cwd: "/tmp/project",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "old preview",
        createdAt: 10,
        updatedAt: 11,
        archived: false,
        statusJson: JSON.stringify({
          modelProvider: "openai",
          model: "gpt-5.3-codex",
          cwd: "/tmp/project",
          approvalPolicy: "on-request",
          sandbox: { mode: "workspace-write" },
          reasoningEffort: null,
        }),
        engine: "codex-app-server",
      },
    ],
  ]);

  const threadSnapshots = new Map([["thr_local", JSON.parse(JSON.stringify(localThread))]]);

  let capturedResumeParams = null;
  let capturedStartArgs = null;

  const repository = withStateDirectory({
    async query() {
      return [];
    },
    async getThreadRecord(threadId) {
      return threadRecords.get(threadId) ?? null;
    },
    async readThread(threadId) {
      const snapshot = threadSnapshots.get(threadId);
      return snapshot ? JSON.parse(JSON.stringify(snapshot)) : null;
    },
    async createThread(args) {
      threadRecords.set(args.id, {
        id: args.id,
        projectId: args.projectId ?? null,
        cwd: args.cwd,
        modelProvider: args.modelProvider,
        modelId: args.modelId ?? null,
        preview: args.preview ?? "",
        createdAt: args.createdAt ?? 0,
        updatedAt: args.createdAt ?? 0,
        archived: false,
        statusJson: args.statusJson ?? null,
        engine: args.engine ?? "codex-app-server",
      });
      threadSnapshots.set(args.id, {
        id: args.id,
        preview: args.preview ?? "",
        modelProvider: args.modelProvider,
        createdAt: args.createdAt ?? 0,
        updatedAt: args.createdAt ?? 0,
        path: null,
        cwd: args.cwd,
        cliVersion: "epoch/0.1.0",
        source: "appServer",
        gitInfo: null,
        turns: [],
      });
    },
    async updateThread(args) {
      const existing = threadRecords.get(args.id);
      if (!existing) return;
      threadRecords.set(args.id, {
        ...existing,
        cwd: args.cwd ?? existing.cwd,
        modelProvider: args.modelProvider ?? existing.modelProvider,
        modelId: Object.prototype.hasOwnProperty.call(args, "modelId") ? (args.modelId ?? null) : existing.modelId,
        preview: args.preview ?? existing.preview,
        statusJson: Object.prototype.hasOwnProperty.call(args, "statusJson") ? args.statusJson : existing.statusJson,
        engine: args.engine ?? existing.engine,
        updatedAt: args.updatedAt ?? existing.updatedAt,
      });
    },
    async findSessionByThread() {
      return null;
    },
    async assignThreadToSession() {},
    async createTurn() {},
    async updateTurn() {},
    async upsertItem() {},
    async listTurnRecords() {
      return [];
    },
    async removeTurns() {},
  });

  const engines = {
    async getEngine(name) {
      assert.equal(name, "codex-app-server");
      return {
        async threadStart() {
          return { thread: repairedThread };
        },
        async threadResume(params) {
          capturedResumeParams = params;
          const resumed = {
            ...repairedThread,
            turns: JSON.parse(JSON.stringify(localThread.turns)),
          };
          threadSnapshots.set(repairedThread.id, resumed);
          return { thread: resumed };
        },
        async startTurn(args) {
          capturedStartArgs = args;
          return {
            turn: {
              id: "turn_new",
              items: [],
              status: "inProgress",
              error: null,
            },
            events: emptyEvents(),
          };
        },
      };
    },
  };

  const prepared = await handleTurnStart(
    {
      repository,
      engines,
    },
    {
      threadId: "thr_local",
      input: [{ type: "text", text: "continue" }],
    }
  );

  assert.equal(prepared.threadId, repairedThread.id);
  assert.ok(capturedResumeParams);
  assert.equal(capturedResumeParams.threadId, repairedThread.id);
  assert.equal(Array.isArray(capturedResumeParams.history), true);
  assert.equal(capturedResumeParams.history.length >= 2, true);
  assert.equal(capturedResumeParams.history[0].role, "user");
  assert.equal(capturedResumeParams.history[1].role, "assistant");
  assert.ok(capturedStartArgs);
  assert.equal(capturedStartArgs.threadId, repairedThread.id);
  assert.equal(Array.isArray(capturedStartArgs.historyTurns), true);
});

test("handleTurnStart repairs codex thread when turn/start reports missing thread", async () => {
  const originalThreadId = "123e4567-e89b-12d3-a456-426614174111";
  const repairedThreadId = "123e4567-e89b-12d3-a456-426614174222";

  const localThread = {
    id: originalThreadId,
    preview: "hello",
    modelProvider: "openai",
    createdAt: 10,
    updatedAt: 11,
    path: null,
    cwd: "/tmp/project",
    cliVersion: "epoch/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [
      {
        id: "turn_local_1",
        status: "completed",
        error: null,
        items: [
          {
            type: "userMessage",
            id: "item_user_1",
            content: [{ type: "text", text: "hello", text_elements: [] }],
          },
          {
            type: "agentMessage",
            id: "item_agent_1",
            text: "world",
          },
        ],
      },
    ],
  };

  const threadRecords = new Map([
    [
      originalThreadId,
      {
        id: originalThreadId,
        projectId: "proj_1",
        cwd: "/tmp/project",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "hello",
        createdAt: 10,
        updatedAt: 11,
        archived: false,
        statusJson: JSON.stringify({
          modelProvider: "openai",
          model: "gpt-5.3-codex",
          cwd: "/tmp/project",
          approvalPolicy: "on-request",
          sandbox: { mode: "workspace-write" },
          reasoningEffort: null,
        }),
        engine: "codex-app-server",
      },
    ],
  ]);

  const threadSnapshots = new Map([[originalThreadId, JSON.parse(JSON.stringify(localThread))]]);
  const startTurnThreadIds = [];
  let resumeCallCount = 0;

  const repository = withStateDirectory({
    async query() {
      return [];
    },
    async getThreadRecord(threadId) {
      return threadRecords.get(threadId) ?? null;
    },
    async readThread(threadId) {
      const snapshot = threadSnapshots.get(threadId);
      return snapshot ? JSON.parse(JSON.stringify(snapshot)) : null;
    },
    async createThread(args) {
      threadRecords.set(args.id, {
        id: args.id,
        projectId: args.projectId ?? null,
        cwd: args.cwd,
        modelProvider: args.modelProvider,
        modelId: args.modelId ?? null,
        preview: args.preview ?? "",
        createdAt: args.createdAt ?? 0,
        updatedAt: args.createdAt ?? 0,
        archived: false,
        statusJson: args.statusJson ?? null,
        engine: args.engine ?? "codex-app-server",
      });
      threadSnapshots.set(args.id, {
        id: args.id,
        preview: args.preview ?? "",
        modelProvider: args.modelProvider,
        createdAt: args.createdAt ?? 0,
        updatedAt: args.createdAt ?? 0,
        path: null,
        cwd: args.cwd,
        cliVersion: "epoch/0.1.0",
        source: "appServer",
        gitInfo: null,
        turns: [],
      });
    },
    async updateThread(args) {
      const existing = threadRecords.get(args.id);
      if (!existing) return;
      threadRecords.set(args.id, {
        ...existing,
        cwd: args.cwd ?? existing.cwd,
        modelProvider: args.modelProvider ?? existing.modelProvider,
        modelId: Object.prototype.hasOwnProperty.call(args, "modelId") ? (args.modelId ?? null) : existing.modelId,
        preview: args.preview ?? existing.preview,
        statusJson: Object.prototype.hasOwnProperty.call(args, "statusJson") ? args.statusJson : existing.statusJson,
        engine: args.engine ?? existing.engine,
        updatedAt: args.updatedAt ?? existing.updatedAt,
      });
    },
    async findSessionByThread() {
      return null;
    },
    async assignThreadToSession() {},
    async createTurn() {},
    async updateTurn() {},
    async upsertItem() {},
    async listTurnRecords() {
      return [];
    },
    async removeTurns() {},
  });

  const engines = {
    async getEngine(name) {
      assert.equal(name, "codex-app-server");
      return {
        async threadStart() {
          return {
            thread: {
              id: repairedThreadId,
              preview: "repaired",
              modelProvider: "openai",
              createdAt: 20,
              updatedAt: 20,
              path: null,
              cwd: "/tmp/project",
              cliVersion: "@openai/codex/1.0.0",
              source: "appServer",
              gitInfo: null,
              turns: [],
            },
          };
        },
        async threadResume(params) {
          resumeCallCount += 1;
          assert.equal(params.threadId, repairedThreadId);
          threadSnapshots.set(repairedThreadId, {
            id: repairedThreadId,
            preview: "repaired",
            modelProvider: "openai",
            createdAt: 20,
            updatedAt: 20,
            path: null,
            cwd: "/tmp/project",
            cliVersion: "@openai/codex/1.0.0",
            source: "appServer",
            gitInfo: null,
            turns: JSON.parse(JSON.stringify(localThread.turns)),
          });
          return {
            thread: threadSnapshots.get(repairedThreadId),
          };
        },
        async startTurn(args) {
          startTurnThreadIds.push(args.threadId);
          if (args.threadId === originalThreadId) {
            throw new Error("thread not found");
          }
          return {
            turn: {
              id: "turn_new",
              items: [],
              status: "inProgress",
              error: null,
            },
            events: emptyEvents(),
          };
        },
      };
    },
  };

  const prepared = await handleTurnStart(
    {
      repository,
      engines,
    },
    {
      threadId: originalThreadId,
      input: [{ type: "text", text: "continue" }],
    }
  );

  assert.equal(prepared.threadId, repairedThreadId);
  assert.equal(startTurnThreadIds.length, 2);
  assert.deepEqual(startTurnThreadIds, [originalThreadId, repairedThreadId]);
  assert.equal(resumeCallCount >= 1, true);
});

test("handleTurnStart forwards workspaceWrite sandbox policy and forces network access on", async () => {
  const threadId = "123e4567-e89b-12d3-a456-426614174333";
  const thread = {
    id: threadId,
    preview: "",
    modelProvider: "openai",
    createdAt: 1,
    updatedAt: 1,
    path: null,
    cwd: "/tmp/project",
    cliVersion: "epoch/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [],
  };

  let capturedStartArgs = null;
  const repository = withStateDirectory({
    async query() {
      return [];
    },
    async getThreadRecord(id) {
      assert.equal(id, threadId);
      return {
        id: threadId,
        projectId: null,
        cwd: "/tmp/project",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "",
        createdAt: 1,
        updatedAt: 1,
        archived: false,
        statusJson: JSON.stringify({
          modelProvider: "openai",
          model: "gpt-5.3-codex",
          cwd: "/tmp/project",
          approvalPolicy: "on-request",
          sandbox: { type: "workspaceWrite", networkAccess: false },
          reasoningEffort: null,
        }),
        engine: "codex-app-server",
      };
    },
    async readThread(id) {
      assert.equal(id, threadId);
      return JSON.parse(JSON.stringify(thread));
    },
    async updateThread() {},
    async createTurn() {},
    async upsertItem() {},
  });

  const engines = {
    async getEngine(name) {
      assert.equal(name, "codex-app-server");
      return {
        async startTurn(args) {
          capturedStartArgs = args;
          return {
            turn: {
              id: args.turnId,
              items: [],
              status: "inProgress",
              error: null,
            },
            events: emptyEvents(),
          };
        },
      };
    },
  };

  await handleTurnStart(
    { repository, engines },
    {
      threadId,
      input: [{ type: "text", text: "network please" }],
    }
  );

  assert.deepEqual(capturedStartArgs?.sandboxPolicy, {
    type: "workspaceWrite",
    networkAccess: true,
    writableRoots: ["/tmp/project"],
    excludeTmpdirEnvVar: false,
    excludeSlashTmp: false,
  });
});

test("handleTurnStart forwards persisted danger-full-access sandbox policy as a tagged object", async () => {
  const threadId = "123e4567-e89b-12d3-a456-426614174334";
  const thread = {
    id: threadId,
    preview: "",
    modelProvider: "openai",
    createdAt: 1,
    updatedAt: 1,
    path: null,
    cwd: "/tmp/project",
    cliVersion: "epoch/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [],
  };

  let capturedStartArgs = null;
  const repository = withStateDirectory({
    async query() {
      return [];
    },
    async getThreadRecord(id) {
      assert.equal(id, threadId);
      return {
        id: threadId,
        projectId: null,
        cwd: "/tmp/project",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "",
        createdAt: 1,
        updatedAt: 1,
        archived: false,
        statusJson: JSON.stringify({
          modelProvider: "openai",
          model: "gpt-5.3-codex",
          cwd: "/tmp/project",
          approvalPolicy: "on-request",
          sandbox: { type: "danger-full-access" },
          reasoningEffort: null,
        }),
        engine: "codex-app-server",
      };
    },
    async readThread(id) {
      assert.equal(id, threadId);
      return JSON.parse(JSON.stringify(thread));
    },
    async updateThread() {},
    async createTurn() {},
    async upsertItem() {},
  });

  const engines = {
    async getEngine(name) {
      assert.equal(name, "codex-app-server");
      return {
        async startTurn(args) {
          capturedStartArgs = args;
          return {
            turn: {
              id: args.turnId,
              items: [],
              status: "inProgress",
              error: null,
            },
            events: emptyEvents(),
          };
        },
      };
    },
  };

  await handleTurnStart(
    { repository, engines },
    {
      threadId,
      input: [{ type: "text", text: "go full access" }],
    }
  );

  assert.deepEqual(capturedStartArgs?.sandboxPolicy, { type: "dangerFullAccess" });
});

test("handleTurnStart applies updated sandbox immediately across turns in the same session", async () => {
  const threadId = "123e4567-e89b-12d3-a456-426614174335";
  const thread = {
    id: threadId,
    preview: "",
    modelProvider: "openai",
    createdAt: 1,
    updatedAt: 1,
    path: null,
    cwd: "/tmp/project",
    cliVersion: "epoch/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [],
  };

  let currentSandbox = { type: "workspace-write", networkAccess: false };
  const capturedSandboxPolicies = [];
  const repository = withStateDirectory({
    async query() {
      return [];
    },
    async getThreadRecord(id) {
      assert.equal(id, threadId);
      return {
        id: threadId,
        projectId: null,
        cwd: "/tmp/project",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "",
        createdAt: 1,
        updatedAt: 1,
        archived: false,
        statusJson: JSON.stringify({
          modelProvider: "openai",
          model: "gpt-5.3-codex",
          cwd: "/tmp/project",
          approvalPolicy: "on-request",
          sandbox: currentSandbox,
          reasoningEffort: null,
        }),
        engine: "codex-app-server",
      };
    },
    async readThread(id) {
      assert.equal(id, threadId);
      return JSON.parse(JSON.stringify(thread));
    },
    async updateThread() {},
    async createTurn() {},
    async upsertItem() {},
  });

  const engines = {
    async getEngine(name) {
      assert.equal(name, "codex-app-server");
      return {
        async startTurn(args) {
          capturedSandboxPolicies.push(args.sandboxPolicy);
          return {
            turn: {
              id: args.turnId,
              items: [],
              status: "inProgress",
              error: null,
            },
            events: emptyEvents(),
          };
        },
      };
    },
  };

  await handleTurnStart(
    { repository, engines },
    {
      threadId,
      input: [{ type: "text", text: "first turn default" }],
    }
  );

  currentSandbox = { type: "danger-full-access" };

  await handleTurnStart(
    { repository, engines },
    {
      threadId,
      input: [{ type: "text", text: "second turn full access" }],
    }
  );

  assert.equal(capturedSandboxPolicies.length, 2);
  assert.deepEqual(capturedSandboxPolicies[0], {
    type: "workspaceWrite",
    networkAccess: true,
    writableRoots: ["/tmp/project"],
    excludeTmpdirEnvVar: false,
    excludeSlashTmp: false,
  });
  assert.deepEqual(capturedSandboxPolicies[1], { type: "dangerFullAccess" });
});

async function* emptyEvents() {}
