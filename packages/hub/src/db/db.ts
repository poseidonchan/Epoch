import path from "node:path";
import { mkdir } from "node:fs/promises";

import Database from "better-sqlite3";

export type DbQueryResult<T> = {
  rows: T[];
  rowCount: number;
};

export type DbPool = {
  query<T = any>(sql: string, params?: any[]): Promise<DbQueryResult<T>>;
  exec: (sql: string) => Promise<void>;
  end: () => Promise<void>;
};

function normalizeSqlForSqlite(sql: string, params: any[]): { sql: string; params: any[] } {
  // The Hub code uses Postgres-style positional params ($1, $2, ...). SQLite
  // doesn't understand that syntax, so we rewrite it to "?" placeholders.
  //
  // Important: Postgres allows reusing the same index multiple times (e.g. $1
  // appears twice). With bare "?" placeholders, SQLite requires a value for
  // each occurrence, so we expand the params array accordingly.
  const expanded: any[] = [];
  const normalized = sql.replace(/\$(\d+)/g, (_m, rawIndex) => {
    const index = Number(rawIndex);
    if (!Number.isFinite(index) || index < 1) {
      throw new Error(`Invalid SQL parameter index: $${rawIndex}`);
    }
    const valueIndex = index - 1;
    if (valueIndex >= params.length) {
      throw new Error("Too few parameter values were provided");
    }
    expanded.push(params[valueIndex]);
    return "?";
  });
  return { sql: normalized, params: expanded };
}

function normalizeSql(sql: string): string {
  // Best-effort normalization for statements executed without bound parameters.
  return sql.replace(/\$\d+/g, "?");
}

export async function connectDb(dbPath: string): Promise<DbPool> {
  await mkdir(path.dirname(dbPath), { recursive: true });

  const db = new Database(dbPath);
  db.pragma("foreign_keys = ON");
  db.pragma("journal_mode = WAL");
  db.pragma("synchronous = NORMAL");
  db.prepare("SELECT 1").get();

  return {
    query: async (sql: string, params: any[] = []) => {
      const normalized = normalizeSqlForSqlite(sql, params);
      try {
        const stmt = db.prepare(normalized.sql);
        if (stmt.reader) {
          const rows = stmt.all(normalized.params) as any[];
          return { rows, rowCount: rows.length };
        }
        const info = stmt.run(normalized.params);
        return { rows: [], rowCount: info.changes };
      } catch (err: any) {
        const message = String(err?.message ?? "");
        if (message.includes("more than one statement")) {
          // Multi-statement SQL shouldn't use bound params in this codebase;
          // normalize positional markers best-effort and execute.
          db.exec(normalizeSql(sql));
          return { rows: [], rowCount: 0 };
        }
        throw err;
      }
    },
    exec: async (sql: string) => {
      db.exec(sql);
    },
    end: async () => {
      db.close();
    },
  };
}

export async function runMigrations(pool: DbPool, opts: { migrationsDir: URL }) {
  const { readdir, readFile } = await import("node:fs/promises");
  const { fileURLToPath } = await import("node:url");

  await pool.exec(`
    CREATE TABLE IF NOT EXISTS labos_schema_migrations (
      id TEXT PRIMARY KEY,
      applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );
  `);

  const applied = await pool.query<{ id: string }>("SELECT id FROM labos_schema_migrations");
  const appliedSet = new Set(applied.rows.map((r: { id: string }) => r.id));

  const dirPath = fileURLToPath(opts.migrationsDir);
  const files = (await readdir(dirPath)).filter((f: string) => f.endsWith(".sql")).sort();

  for (const file of files) {
    if (appliedSet.has(file)) continue;

    const sql = await readFile(path.join(dirPath, file), "utf8");
    await pool.exec("BEGIN");
    try {
      await pool.exec(sql);
      await pool.query("INSERT INTO labos_schema_migrations (id) VALUES ($1)", [file]);
      await pool.exec("COMMIT");
    } catch (err) {
      await pool.exec("ROLLBACK");
      throw err;
    }
  }
}
