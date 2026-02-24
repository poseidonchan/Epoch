#!/usr/bin/env node
import process from "node:process";

import { pairCommand } from "./commands/pair.js";
import { startCommand } from "./commands/start.js";
import { statusCommand } from "./commands/status.js";
import { doctorCommand } from "./commands/doctor.js";

const args = process.argv.slice(2);
const cmd = args[0];

async function main() {
  try {
    switch (cmd) {
      case "pair":
        await pairCommand(args.slice(1));
        return;
      case "start":
        await startCommand(args.slice(1));
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
        console.log("Usage: labos-hpc-bridge <pair|start|status|doctor>");
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

