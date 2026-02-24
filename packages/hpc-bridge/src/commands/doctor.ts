import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export async function doctorCommand(_argv: string[]) {
  const cmds = ["sbatch", "squeue", "sacct", "scancel"];
  for (const cmd of cmds) {
    const ok = await which(cmd);
    console.log(`${cmd}: ${ok ? "ok" : "missing"}`);
  }
}

async function which(bin: string) {
  try {
    await execFileAsync("which", [bin]);
    return true;
  } catch {
    return false;
  }
}
