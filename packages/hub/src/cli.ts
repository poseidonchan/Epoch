#!/usr/bin/env node
import path from "node:path";
import process from "node:process";

import { initCommand } from "./commands/init.js";
import { startCommand } from "./commands/start.js";
import { doctorCommand } from "./commands/doctor.js";
import { statusCommand } from "./commands/status.js";
import { configCommand } from "./commands/config.js";
import { restartCommand } from "./commands/restart.js";
import { stopCommand } from "./commands/stop.js";

const args = process.argv.slice(2);
const cmd = args[0];

async function main() {
  try {
    const invokedAs = path.basename(process.argv[1] ?? "");
    if (invokedAs === "epoch-hub") {
      console.warn("epoch-hub is deprecated. Use `epoch <init|config|start|restart|stop|status|doctor>`.");
    }
    switch (cmd) {
      case "init":
        await initCommand(args.slice(1));
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
      case "doctor":
        await doctorCommand(args.slice(1));
        return;
      case "status":
        await statusCommand(args.slice(1));
        return;
      case "config":
        await configCommand(args.slice(1));
        return;
      case "-h":
      case "--help":
      case undefined:
        console.log("Usage: epoch <init|config|start|restart|stop|status|doctor>");
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
