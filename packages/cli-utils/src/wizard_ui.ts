import process from "node:process";
import { Writable } from "node:stream";
import { createInterface } from "node:readline/promises";

import pc from "picocolors";

export type StepStatus = "info" | "ok" | "warn" | "error";

export type WizardUI = {
  interactive: boolean;
  banner: (title: string, subtitle?: string) => void;
  step: (index: number, total: number, message: string, status?: StepStatus) => void;
  line: (message?: string) => void;
  note: (message: string) => void;
  warn: (message: string) => void;
  error: (message: string) => void;
  success: (message: string) => void;
  keyValue: (key: string, value: string) => void;
  summary: (title: string, rows: Array<{ key: string; before?: string; after: string }>) => void;
};

type PromptInputOptions = {
  message: string;
  defaultValue?: string;
  allowEmpty?: boolean;
};

type PromptSecretOptions = {
  message: string;
  allowEmpty?: boolean;
};

type PromptConfirmOptions = {
  message: string;
  defaultYes?: boolean;
};

export type WizardPrompter = {
  interactive: boolean;
  input: (opts: PromptInputOptions) => Promise<string>;
  secret: (opts: PromptSecretOptions) => Promise<string>;
  confirm: (opts: PromptConfirmOptions) => Promise<boolean>;
  close: () => void;
};

export function createWizardUI(): WizardUI {
  const interactive = Boolean(process.stdout.isTTY);
  const color = interactive
    ? pc
    : {
        ...pc,
        cyan: passthrough,
        green: passthrough,
        yellow: passthrough,
        red: passthrough,
        dim: passthrough,
        bold: passthrough,
      };

  const iconForStatus = (status: StepStatus) => {
    switch (status) {
      case "ok":
        return color.green("OK");
      case "warn":
        return color.yellow("WARN");
      case "error":
        return color.red("ERR");
      default:
        return color.cyan("INFO");
    }
  };

  return {
    interactive: Boolean(process.stdin.isTTY && process.stdout.isTTY),
    banner(title: string, subtitle?: string) {
      const rule = color.dim("=".repeat(Math.max(24, title.length + 8)));
      process.stdout.write(`${rule}\n`);
      process.stdout.write(`${color.bold(title)}\n`);
      if (subtitle) process.stdout.write(`${color.dim(subtitle)}\n`);
      process.stdout.write(`${rule}\n`);
    },
    step(index: number, total: number, message: string, status: StepStatus = "info") {
      process.stdout.write(`${color.dim(`[${index}/${total}]`)} ${iconForStatus(status)} ${message}\n`);
    },
    line(message?: string) {
      process.stdout.write(`${message ?? ""}\n`);
    },
    note(message: string) {
      process.stdout.write(`${color.cyan("•")} ${message}\n`);
    },
    warn(message: string) {
      process.stdout.write(`${color.yellow("!")} ${message}\n`);
    },
    error(message: string) {
      process.stdout.write(`${color.red("x")} ${message}\n`);
    },
    success(message: string) {
      process.stdout.write(`${color.green("✓")} ${message}\n`);
    },
    keyValue(key: string, value: string) {
      process.stdout.write(`${color.dim(`${key}:`)} ${value}\n`);
    },
    summary(title: string, rows: Array<{ key: string; before?: string; after: string }>) {
      process.stdout.write(`${color.bold(title)}\n`);
      for (const row of rows) {
        if (row.before != null && row.before !== row.after) {
          process.stdout.write(`  ${color.dim(`${row.key}:`)} ${color.dim(row.before)} ${color.dim("->")} ${row.after}\n`);
          continue;
        }
        process.stdout.write(`  ${color.dim(`${row.key}:`)} ${row.after}\n`);
      }
    },
  };
}

export function createWizardPrompter(ui: WizardUI): WizardPrompter {
  if (!ui.interactive) {
    return {
      interactive: false,
      async input(opts) {
        if (opts.defaultValue != null) return String(opts.defaultValue);
        if (opts.allowEmpty) return "";
        throw new Error(`Cannot prompt for required value in non-interactive mode: ${opts.message}`);
      },
      async secret(opts) {
        if (opts.allowEmpty) return "";
        throw new Error(`Cannot prompt for required secret in non-interactive mode: ${opts.message}`);
      },
      async confirm(opts) {
        return opts.defaultYes !== false;
      },
      close() {},
    };
  }

  let muted = false;
  const output = new Writable({
    write(chunk, encoding, callback) {
      if (!muted) process.stdout.write(chunk, encoding as BufferEncoding);
      callback();
    },
  });
  const rl = createInterface({ input: process.stdin, output, terminal: true });

  const input = async (opts: PromptInputOptions) => {
    const prompt = opts.defaultValue ? `${opts.message} [${opts.defaultValue}] ` : `${opts.message} `;
    while (true) {
      const raw = (await rl.question(prompt)).trimEnd();
      const value = raw.trim();
      if (value) return value;
      if (opts.defaultValue != null) return String(opts.defaultValue);
      if (opts.allowEmpty) return "";
      process.stdout.write("Value required.\n");
    }
  };

  const secret = async (opts: PromptSecretOptions) => {
    while (true) {
      process.stdout.write(`${opts.message} `);
      muted = true;
      const raw = (await rl.question("")).trimEnd();
      muted = false;
      process.stdout.write("\n");
      const value = raw.trim();
      if (value) return value;
      if (opts.allowEmpty) return "";
      process.stdout.write("Value required.\n");
    }
  };

  const confirm = async (opts: PromptConfirmOptions) => {
    const suffix = opts.defaultYes === false ? "[y/N]" : "[Y/n]";
    const raw = (await rl.question(`${opts.message} ${suffix} `)).trim().toLowerCase();
    if (!raw) return opts.defaultYes !== false;
    return raw === "y" || raw === "yes";
  };

  return {
    interactive: true,
    input,
    secret,
    confirm,
    close() {
      rl.close();
    },
  };
}

function passthrough(value: string) {
  return value;
}
