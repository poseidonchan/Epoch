#!/usr/bin/env node
import process from "node:process";

import { initCommand } from "./commands/init.js";
import { configCommand } from "./commands/config.js";
import { pairCommand } from "./commands/pair.js";
import { startCommand } from "./commands/start.js";
import { restartCommand } from "./commands/restart.js";
import { stopCommand } from "./commands/stop.js";
import { statusCommand } from "./commands/status.js";
import { doctorCommand } from "./commands/doctor.js";

const args = process.argv.slice(2);
const cmd = args[0];

async function main() {
  try {
    if (cmd && cmd !== "-h" && cmd !== "--help") {
      console.warn("epoch-bridge is deprecated. Use `epoch <init|config|start|restart|stop|status|doctor>` for direct-connect deployments.");
    }
    switch (cmd) {
      case "init":
        await initCommand(args.slice(1));
        return;
      case "config":
        await configCommand(args.slice(1));
        return;
      case "pair":
        await pairCommand(args.slice(1));
        return;
      case "start":
        await startCommand(args.slice(1));
        return;
      case "restart":
        await restartCommand(args.slice(1));
        return;
      case "stop":
        await stopCommand(args.slice(1));
        return;
      case "status":
        await statusCommand(args.slice(1));
        return;
      case "doctor":
        await doctorCommand(args.slice(1));
        return;
      case "-h":
      case "--help":
      case undefined:
        console.log("Usage: epoch-bridge <init|config|pair|start|restart|stop|status|doctor>");
        console.log("Deprecated: use `epoch <init|config|start|restart|stop|status|doctor>` on the HPC host.");
        return;
      default:
        console.error(`Unknown command: ${cmd}`);
        process.exitCode = 1;
        return;
    }
  } catch (err) {
    console.error(err);
    process.exitCode = 1;
  }
}

await main();
