import test from "node:test";
import assert from "node:assert/strict";

import { buildWorkspaceWriteEnv } from "../dist/index.js";

test("workspace-write sandbox env includes expected keys and excludes rust/go overrides", () => {
  const projectRoot = "/tmp/labos-project";
  const env = buildWorkspaceWriteEnv(projectRoot);

  assert.equal(env.HOME, projectRoot);
  assert.equal(env.TMPDIR, `${projectRoot}/tmp`);
  assert.equal(env.XDG_CACHE_HOME, `${projectRoot}/.cache`);
  assert.equal(env.XDG_DATA_HOME, `${projectRoot}/.local/share`);
  assert.equal(env.XDG_CONFIG_HOME, `${projectRoot}/.config`);
  assert.equal(env.PYTHONUSERBASE, `${projectRoot}/.local`);
  assert.equal(env.PIP_USER, "0");
  assert.equal(env.npm_config_prefix, `${projectRoot}/.npm-global`);

  assert.equal(Object.prototype.hasOwnProperty.call(env, "CARGO_HOME"), false);
  assert.equal(Object.prototype.hasOwnProperty.call(env, "GOPATH"), false);
});
