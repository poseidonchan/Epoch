#!/usr/bin/env node
import process from "node:process";

import { initCommand } from "./commands/init.js";
import { startCommand } from "./commands/start.js";
import { doctorCommand } from "./commands/doctor.js";
import { configCommand } from "./commands/config.js";
import { restartCommand } from "./commands/restart.js";

const args = process.argv.slice(2);
const cmd = args[0];

async function main() {
  try {
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
      case "doctor":
        await doctorCommand(args.slice(1));
        return;
      case "config":
        await configCommand(args.slice(1));
        return;
      case "-h":
      case "--help":
      case undefined:
        console.log("Usage: labos-hub <init|config|start|restart|doctor>");
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
