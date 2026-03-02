import type { CodexConnectionState } from "../connection_state.js";

export function handleInitialize(
  connection: CodexConnectionState,
  params: Record<string, unknown> | undefined
): { userAgent: string } {
  const capabilitiesRaw =
    params && typeof params.capabilities === "object" && params.capabilities ? (params.capabilities as Record<string, unknown>) : null;

  const experimentalApi = Boolean(capabilitiesRaw?.experimentalApi ?? false);

  const optOutRaw = capabilitiesRaw?.optOutNotificationMethods;
  const optOutMethods = new Set<string>();
  if (Array.isArray(optOutRaw)) {
    for (const entry of optOutRaw) {
      if (typeof entry === "string" && entry.trim()) {
        optOutMethods.add(entry.trim());
      }
    }
  }

  connection.capabilities = {
    experimentalApi,
    optOutNotificationMethods: optOutMethods,
  };
  connection.initializedRequestReceived = true;

  return {
    userAgent: "@epoch/hub/0.1.0",
  };
}
