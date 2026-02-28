import type { CodexEngineRegistry } from "../engine_registry.js";

export type ModelHandlerContext = {
  engines: CodexEngineRegistry;
};

export async function handleModelList(
  ctx: ModelHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
  const params = (rawParams ?? {}) as Record<string, unknown>;
  const engine = await ctx.engines.getEngine(null);
  if (!engine.modelList) {
    throw new Error(`Engine ${engine.name} does not support model/list`);
  }
  return await engine.modelList(params);
}
