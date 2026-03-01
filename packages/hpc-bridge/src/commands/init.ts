import { configCommand } from "./config.js";

export async function initCommand(argv: string[]) {
  await configCommand(argv, { mode: "init" });
}
