import { createCipheriv, createDecipheriv, randomBytes, scrypt as scryptCallback } from "node:crypto";
import { chmod, mkdir, readFile, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";

import type { HubConfig } from "./config.js";

const scrypt = promisify(scryptCallback);

type EncryptedPushKeyFile = {
  version: 1;
  algorithm: "aes-256-gcm";
  kdf: "scrypt";
  salt: string;
  iv: string;
  tag: string;
  ciphertext: string;
  createdAt: string;
};

export type PushKeyStatus = {
  encryptedKeyPath: string | null;
  exists: boolean;
  fileMode: number | null;
  privatePermissions: boolean;
};

export function pushSecretsDir(stateDir: string): string {
  return path.join(stateDir, "secrets");
}

export function defaultEncryptedPushKeyPath(stateDir: string): string {
  return path.join(pushSecretsDir(stateDir), "apns-key.enc");
}

export async function importEncryptedApnsKey(args: {
  stateDir: string;
  sourcePath: string;
  passphrase: string;
  destinationPath?: string | null;
}) {
  const sourcePath = normalizeRequired(args.sourcePath, "APNs key path");
  const passphrase = normalizeRequired(args.passphrase, "unlock passphrase");
  const privateKeyPem = normalizeRequired(await readFile(sourcePath, "utf8"), "APNs private key");
  const encryptedKeyPath = args.destinationPath?.trim() || defaultEncryptedPushKeyPath(args.stateDir);

  await ensureSecretsDir(args.stateDir);
  const encrypted = await encryptApnsPrivateKey(privateKeyPem, passphrase);
  await writeFile(encryptedKeyPath, JSON.stringify(encrypted, null, 2) + "\n", {
    encoding: "utf8",
    mode: 0o600,
  });
  await chmod(encryptedKeyPath, 0o600).catch(() => {
    // best effort
  });

  return {
    encryptedKeyPath,
  };
}

export async function decryptEncryptedApnsKey(args: {
  encryptedKeyPath: string;
  passphrase: string;
}): Promise<string> {
  const encryptedKeyPath = normalizeRequired(args.encryptedKeyPath, "encrypted APNs key path");
  const passphrase = normalizeRequired(args.passphrase, "unlock passphrase");
  const raw = JSON.parse(await readFile(encryptedKeyPath, "utf8")) as Partial<EncryptedPushKeyFile>;

  if (raw.version !== 1 || raw.algorithm !== "aes-256-gcm" || raw.kdf !== "scrypt") {
    throw new Error("Unsupported encrypted APNs key format");
  }

  const salt = decodeBase64Required(raw.salt, "salt");
  const iv = decodeBase64Required(raw.iv, "iv");
  const tag = decodeBase64Required(raw.tag, "tag");
  const ciphertext = decodeBase64Required(raw.ciphertext, "ciphertext");
  const key = await deriveEncryptionKey(passphrase, salt);
  const decipher = createDecipheriv("aes-256-gcm", key, iv);
  decipher.setAuthTag(tag);
  const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString("utf8").trim();
  return normalizeRequired(plaintext, "decrypted APNs private key");
}

export async function readPushKeyStatus(args: {
  stateDir: string;
  config?: HubConfig | null;
}): Promise<PushKeyStatus> {
  const encryptedKeyPath = resolveEncryptedPushKeyPath(args);
  if (!encryptedKeyPath) {
    return {
      encryptedKeyPath: null,
      exists: false,
      fileMode: null,
      privatePermissions: false,
    };
  }

  try {
    const fileStat = await stat(encryptedKeyPath);
    const mode = fileStat.mode & 0o777;
    return {
      encryptedKeyPath,
      exists: true,
      fileMode: mode,
      privatePermissions: mode === 0o600,
    };
  } catch (error) {
    const code = (error as NodeJS.ErrnoException | null)?.code;
    if (code === "ENOENT") {
      return {
        encryptedKeyPath,
        exists: false,
        fileMode: null,
        privatePermissions: false,
      };
    }
    throw error;
  }
}

export async function ensureSecretsDir(stateDir: string) {
  const dir = pushSecretsDir(stateDir);
  await mkdir(dir, { recursive: true, mode: 0o700 });
  await chmod(dir, 0o700).catch(() => {
    // best effort
  });
}

export function resolveEncryptedPushKeyPath(args: {
  stateDir: string;
  config?: HubConfig | null;
}): string | null {
  return normalizeOptionalString(args.config?.push?.encryptedKeyPath) ?? null;
}

async function encryptApnsPrivateKey(privateKeyPem: string, passphrase: string): Promise<EncryptedPushKeyFile> {
  const salt = randomBytes(16);
  const iv = randomBytes(12);
  const key = await deriveEncryptionKey(passphrase, salt);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const ciphertext = Buffer.concat([cipher.update(privateKeyPem, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return {
    version: 1,
    algorithm: "aes-256-gcm",
    kdf: "scrypt",
    salt: salt.toString("base64"),
    iv: iv.toString("base64"),
    tag: tag.toString("base64"),
    ciphertext: ciphertext.toString("base64"),
    createdAt: new Date().toISOString(),
  };
}

async function deriveEncryptionKey(passphrase: string, salt: Buffer): Promise<Buffer> {
  const derived = await scrypt(passphrase, salt, 32);
  return Buffer.isBuffer(derived) ? derived : Buffer.from(derived);
}

function decodeBase64Required(raw: unknown, field: string): Buffer {
  const value = normalizeRequired(raw, field);
  return Buffer.from(value, "base64");
}

function normalizeOptionalString(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function normalizeRequired(raw: unknown, field: string): string {
  const value = normalizeOptionalString(raw);
  if (!value) {
    throw new Error(`Missing ${field}`);
  }
  return value;
}
