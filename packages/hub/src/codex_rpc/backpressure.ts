export class BoundedWorkQueue {
  private readonly maxDepth: number;
  private queue: Array<() => Promise<void>> = [];
  private draining = false;

  constructor(maxDepth: number) {
    this.maxDepth = Math.max(1, Math.floor(maxDepth));
  }

  enqueue(task: () => Promise<void>): boolean {
    if (this.queue.length >= this.maxDepth) {
      return false;
    }
    this.queue.push(task);
    if (!this.draining) {
      void this.drain();
    }
    return true;
  }

  depth(): number {
    return this.queue.length;
  }

  private async drain() {
    this.draining = true;
    while (this.queue.length > 0) {
      const task = this.queue.shift();
      if (!task) continue;
      try {
        await task();
      } catch {
        // Ignore task-level failures so the queue keeps draining.
      }
    }
    this.draining = false;
  }
}
