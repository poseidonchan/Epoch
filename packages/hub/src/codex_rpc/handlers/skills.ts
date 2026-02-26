import type { CodexEngineRegistry } from "../engine_registry.js";

export type SkillsHandlerContext = {
  engines: CodexEngineRegistry;
};

export async function handleSkillsList(
  ctx: SkillsHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
  const params = (rawParams ?? {}) as Record<string, unknown>;
  const engine = await ctx.engines.getEngine(null);
  if (!engine.skillsList) {
    throw new Error(`Engine ${engine.name} does not support skills/list`);
  }

  return await engine.skillsList(params);
}
