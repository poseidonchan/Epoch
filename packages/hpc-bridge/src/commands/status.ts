import { loadConfig } from "../config.js";

export async function statusCommand(_argv: string[]) {
  const cfg = await loadConfig();
  if (!cfg) {
    console.log("No config found. Run: labos-hpc-bridge pair ...");
    return;
  }
  console.log("LabOS HPC Bridge config:");
  console.log(`- hubUrl: ${cfg.hubUrl}`);
  console.log(`- nodeId: ${cfg.nodeId}`);
  console.log(`- workspaceRoot: ${cfg.workspaceRoot}`);
  console.log(`- defaults: ${JSON.stringify(cfg.defaults)}`);
}

