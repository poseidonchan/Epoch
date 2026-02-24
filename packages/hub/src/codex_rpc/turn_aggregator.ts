import type { ThreadItem, TurnPlanStep } from "./types.js";

export class TurnAggregationState {
  private plan: TurnPlanStep[] = [];
  private explanation: string | null = null;
  private diffByPath = new Map<string, string>();

  updatePlan(args: { explanation?: string | null; plan: TurnPlanStep[] }) {
    this.explanation = args.explanation ?? null;
    this.plan = args.plan.slice();
  }

  planSnapshot(): { explanation: string | null; plan: TurnPlanStep[] } {
    return { explanation: this.explanation, plan: this.plan.slice() };
  }

  ingestCompletedItem(item: ThreadItem): boolean {
    if (item.type !== "fileChange") return false;

    let changed = false;
    const changes = Array.isArray((item as any).changes) ? ((item as any).changes as Array<Record<string, unknown>>) : [];
    for (const change of changes) {
      const path = String(change.path ?? "").trim();
      const diff = String(change.diff ?? "");
      if (!path) continue;
      const prev = this.diffByPath.get(path);
      if (prev !== diff) {
        this.diffByPath.set(path, diff);
        changed = true;
      }
    }
    return changed;
  }

  diffSnapshot(): string {
    const entries = Array.from(this.diffByPath.entries()).sort((a, b) => a[0].localeCompare(b[0]));
    return entries.map(([, diff]) => diff).join("\n");
  }
}
