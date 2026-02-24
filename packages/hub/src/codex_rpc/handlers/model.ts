import { listHubModelsForProvider, resolveHubProvider } from "../../model.js";
import type { CodexEngineRegistry } from "../engine_registry.js";

export type ModelHandlerContext = {
  engines: CodexEngineRegistry;
};

export async function handleModelList(
  _ctx: ModelHandlerContext,
  _rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
  const resolved = resolveHubProvider(null);
  const models = listHubModelsForProvider(resolved.provider);

  const data = models.map((model) => {
    const supportedReasoningEfforts = model.reasoning
      ? [
          { reasoningEffort: "minimal", description: "Light reasoning" },
          { reasoningEffort: "low", description: "Low reasoning" },
          { reasoningEffort: "medium", description: "Balanced reasoning" },
          { reasoningEffort: "high", description: "Thorough reasoning" },
          { reasoningEffort: "xhigh", description: "Maximum reasoning" },
        ]
      : [{ reasoningEffort: "none", description: "No reasoning" }];

    return {
      id: model.id,
      model: model.id,
      upgrade: null,
      displayName: model.name,
      description: `${resolved.provider}/${model.id}`,
      supportedReasoningEfforts,
      defaultReasoningEffort: model.reasoning ? "medium" : "none",
      inputModalities: ["text"],
      supportsPersonality: true,
      isDefault: model.id === resolved.defaultModelId,
    };
  });

  return {
    data,
    nextCursor: null,
  };
}
