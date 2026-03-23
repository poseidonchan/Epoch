declare module "@epoch/hpc-bridge" {
  export function buildWorkspaceWriteEnv(projectRoot: string): Record<string, string>;

  export function collectStorageUsage(
    rootPath: string
  ): Promise<
    | {
        usedPercent: number;
        totalBytes?: number;
        usedBytes?: number;
        availableBytes?: number;
      }
    | null
  >;

  export function computeCpuPercentFromSamples(
    prev: { idle: number; total: number },
    next: { idle: number; total: number }
  ): number;

  export function computeRamPercentFromTotals(totalBytes: number, freeBytes: number): number | null;

  export function parseMemInfoUsagePercent(raw: string): number | null;

  export function parseNvidiaSmiUtilizationPercent(raw: string): number | undefined;

  export function parseProcStatSample(raw: string): { idle: number; total: number } | null;

  export function resolveRuntimeCommandCwd(args: {
    workspaceRoot: string;
    projectRoot: string;
    rawCwd?: string | null;
    fallbackCwd: string;
  }): string;

  export function sampleCpuFromOsCpus(cpus: Array<{ times?: Record<string, unknown> }>): { idle: number; total: number } | null;
}
