import { mkdirSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { validateOrigin } from "./auth";
import { cliError } from "./errors";

const require = createRequire(import.meta.url);

type SqlValue = string | number | null | Buffer;

interface SqliteRunResult {
  changes: number;
  lastInsertRowid: number | bigint;
}

interface SqliteStatement {
  run: (...params: SqlValue[]) => SqliteRunResult;
  get: (...params: SqlValue[]) => Record<string, unknown> | undefined;
  all: (...params: SqlValue[]) => Array<Record<string, unknown>>;
}

interface SqliteDatabase {
  exec: (source: string) => void;
  prepare: (source: string) => SqliteStatement;
  pragma: (source: string) => unknown;
  close: () => void;
}

type SqliteConstructor = new (filename: string, options?: { readonly?: boolean }) => SqliteDatabase;

const Database = require("better-sqlite3") as SqliteConstructor;

export const CLI_STORE_SCHEMA_VERSION = 2;

export interface AccountPartition {
  backendOrigin: string;
  userId: string;
}

export interface AccountStampInput {
  backendOrigin?: string | null;
  userId?: string | null;
}

export interface ManifestAccountStampInput {
  accountBackendOrigin?: string | null;
  accountUserId?: string | null;
}

export type LocalArtifactKind = "recording_session" | "download" | "live_caption_draft";

export interface LocalArtifact {
  id: number;
  kind: LocalArtifactKind;
  account: AccountPartition | null;
  localPath: string;
  remoteId?: string;
  metadata?: unknown;
  createdAt: number;
  updatedAt: number;
  lastOpenedAt?: number;
}

export interface OpenCliStoreOptions {
  dbPath?: string;
  homeDir?: string;
  env?: NodeJS.ProcessEnv;
  readonly?: boolean;
  now?: () => number;
}

export interface AddLocalArtifactInput {
  kind: LocalArtifactKind;
  account?: AccountPartition | null;
  localPath: string;
  remoteId?: string | null;
  metadata?: unknown;
  lastOpenedAt?: number | null;
}

export interface ListLocalArtifactsOptions {
  kind?: LocalArtifactKind;
  remoteId?: string;
}

export function defaultStorePath(
  homeDir = os.homedir(),
  env: NodeJS.ProcessEnv = process.env,
): string {
  const explicit = env.RECAPPI_CLI_STORE_PATH?.trim();
  if (explicit) return explicit;
  const dataHome = env.XDG_DATA_HOME?.trim() || path.join(homeDir, ".local", "share");
  return path.join(dataHome, "recappi", "cli-state.sqlite");
}

export function normalizeAccountStamp(
  input: AccountStampInput | null | undefined,
): AccountPartition | null {
  return parseAccountPartition(input, "lenient");
}

export function normalizeManifestAccountStamp(
  input: ManifestAccountStampInput | null | undefined,
): AccountPartition | null {
  return normalizeAccountStamp({
    backendOrigin: input?.accountBackendOrigin,
    userId: input?.accountUserId,
  });
}

export function requireAccountPartition(input: AccountStampInput): AccountPartition {
  const account = parseAccountPartition(input, "strict");
  if (!account) {
    throw cliError(
      "usage.invalid_argument",
      "Account partition requires a backend origin and user id.",
      {
        hint: "Resolve Recappi auth first, then use the normalized origin and authenticated user id.",
      },
    );
  }
  return account;
}

export function openCliStore(opts: OpenCliStoreOptions = {}): CliLocalStore {
  return new CliLocalStore(opts);
}

export class CliLocalStore {
  private readonly db: SqliteDatabase;
  private readonly now: () => number;

  constructor(opts: OpenCliStoreOptions = {}) {
    const dbPath = opts.dbPath ?? defaultStorePath(opts.homeDir, opts.env);
    if (!opts.readonly && dbPath !== ":memory:") {
      mkdirSync(path.dirname(dbPath), { recursive: true, mode: 0o700 });
    }
    this.db = new Database(dbPath, opts.readonly === true ? { readonly: true } : undefined);
    this.now = opts.now ?? Date.now;
    if (!opts.readonly) this.migrate();
  }

  close(): void {
    this.db.close();
  }

  recordAccountSeen(account: AccountPartition, email?: string | null): void {
    const now = this.now();
    this.db
      .prepare(
        `
        INSERT INTO account_scopes (backend_origin, user_id, email, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT (backend_origin, user_id) DO UPDATE SET
          email = excluded.email,
          updated_at = excluded.updated_at
      `,
      )
      .run(account.backendOrigin, account.userId, email?.trim() || null, now, now);
  }

  addLocalArtifact(input: AddLocalArtifactInput): LocalArtifact {
    const account = input.account ? requireAccountPartition(input.account) : null;
    const localPath = input.localPath.trim();
    if (!localPath) {
      throw cliError("usage.invalid_argument", "Local artifact path is required.");
    }
    if (account) this.recordAccountSeen(account);
    const now = this.now();
    const result = this.db
      .prepare(
        `
        INSERT INTO local_artifacts (
          kind,
          backend_origin,
          user_id,
          remote_id,
          local_path,
          metadata_json,
          created_at,
          updated_at,
          last_opened_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      `,
      )
      .run(
        input.kind,
        account?.backendOrigin ?? null,
        account?.userId ?? null,
        input.remoteId?.trim() || null,
        localPath,
        input.metadata === undefined ? null : JSON.stringify(input.metadata),
        now,
        now,
        input.lastOpenedAt ?? null,
      );
    return this.getLocalArtifact(Number(result.lastInsertRowid));
  }

  upsertLocalArtifact(input: AddLocalArtifactInput): LocalArtifact {
    const remoteId = input.remoteId?.trim();
    if (!remoteId) return this.addLocalArtifact(input);
    const account = input.account ? requireAccountPartition(input.account) : null;
    if (account) this.recordAccountSeen(account);
    const existing = this.findLocalArtifact({
      account,
      kind: input.kind,
      remoteId,
    });
    if (!existing) return this.addLocalArtifact({ ...input, remoteId });

    const localPath = input.localPath.trim();
    if (!localPath) {
      throw cliError("usage.invalid_argument", "Local artifact path is required.");
    }
    const now = this.now();
    this.db
      .prepare(
        `
        UPDATE local_artifacts
        SET local_path = ?,
            metadata_json = ?,
            updated_at = ?,
            last_opened_at = COALESCE(?, last_opened_at)
        WHERE id = ?
      `,
      )
      .run(
        localPath,
        input.metadata === undefined ? null : JSON.stringify(input.metadata),
        now,
        input.lastOpenedAt ?? null,
        existing.id,
      );
    return this.getLocalArtifact(existing.id);
  }

  getLocalArtifact(id: number): LocalArtifact {
    const row = this.db.prepare("SELECT * FROM local_artifacts WHERE id = ?").get(id);
    if (!row) {
      throw cliError("usage.invalid_argument", `Local artifact ${id} does not exist.`);
    }
    return mapArtifactRow(row);
  }

  listLocalArtifactsForAccount(
    accountInput: AccountStampInput,
    opts: ListLocalArtifactsOptions = {},
  ): LocalArtifact[] {
    const account = requireAccountPartition(accountInput);
    const params: SqlValue[] = [account.backendOrigin, account.userId];
    let source = `
      SELECT * FROM local_artifacts
      WHERE backend_origin = ? AND user_id = ?
    `;
    if (opts.kind) {
      source += " AND kind = ?";
      params.push(opts.kind);
    }
    if (opts.remoteId) {
      source += " AND remote_id = ?";
      params.push(opts.remoteId);
    }
    source += " ORDER BY updated_at DESC, id DESC";
    return this.db
      .prepare(source)
      .all(...params)
      .map(mapArtifactRow);
  }

  listUnattributedLocalArtifacts(opts: ListLocalArtifactsOptions = {}): LocalArtifact[] {
    const params: SqlValue[] = [];
    let source = `
      SELECT * FROM local_artifacts
      WHERE backend_origin IS NULL AND user_id IS NULL
    `;
    if (opts.kind) {
      source += " AND kind = ?";
      params.push(opts.kind);
    }
    if (opts.remoteId) {
      source += " AND remote_id = ?";
      params.push(opts.remoteId);
    }
    source += " ORDER BY updated_at DESC, id DESC";
    return this.db
      .prepare(source)
      .all(...params)
      .map(mapArtifactRow);
  }

  findLocalArtifactForAccount(
    accountInput: AccountStampInput,
    opts: { kind: LocalArtifactKind; remoteId: string },
  ): LocalArtifact | null {
    const account = requireAccountPartition(accountInput);
    return this.findLocalArtifact({ account, kind: opts.kind, remoteId: opts.remoteId });
  }

  listDownloadedRecordingIdsForAccount(accountInput: AccountStampInput): Set<string> {
    return new Set(
      this.listLocalArtifactsForAccount(accountInput, { kind: "download" })
        .map((artifact) => artifact.remoteId)
        .filter((remoteId): remoteId is string => Boolean(remoteId)),
    );
  }

  markLocalArtifactOpened(id: number): LocalArtifact {
    const now = this.now();
    const result = this.db
      .prepare(
        `
        UPDATE local_artifacts
        SET last_opened_at = ?, updated_at = ?
        WHERE id = ?
      `,
      )
      .run(now, now, id);
    if (result.changes !== 1) {
      throw cliError("usage.invalid_argument", `Local artifact ${id} does not exist.`);
    }
    return this.getLocalArtifact(id);
  }

  claimUnattributedLocalArtifact(id: number, accountInput: AccountStampInput): boolean {
    const account = requireAccountPartition(accountInput);
    this.recordAccountSeen(account);
    const result = this.db
      .prepare(
        `
        UPDATE local_artifacts
        SET backend_origin = ?, user_id = ?, updated_at = ?
        WHERE id = ? AND backend_origin IS NULL AND user_id IS NULL
      `,
      )
      .run(account.backendOrigin, account.userId, this.now(), id);
    return result.changes === 1;
  }

  private migrate(): void {
    this.db.pragma("journal_mode = WAL");
    this.db.pragma("foreign_keys = ON");
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS schema_meta (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
      );

      INSERT INTO schema_meta (key, value)
      VALUES ('schema_version', '${CLI_STORE_SCHEMA_VERSION}')
      ON CONFLICT (key) DO UPDATE SET value = excluded.value;

      CREATE TABLE IF NOT EXISTS account_scopes (
        backend_origin TEXT NOT NULL,
        user_id TEXT NOT NULL,
        email TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (backend_origin, user_id)
      );

      CREATE TABLE IF NOT EXISTS local_artifacts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        backend_origin TEXT,
        user_id TEXT,
        remote_id TEXT,
        local_path TEXT NOT NULL,
        metadata_json TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        last_opened_at INTEGER,
        CHECK (
          (backend_origin IS NULL AND user_id IS NULL)
          OR (backend_origin IS NOT NULL AND user_id IS NOT NULL)
        )
      );

      CREATE INDEX IF NOT EXISTS local_artifacts_account_kind_idx
        ON local_artifacts (backend_origin, user_id, kind, updated_at DESC);

      CREATE INDEX IF NOT EXISTS local_artifacts_remote_idx
        ON local_artifacts (backend_origin, user_id, kind, remote_id);
    `);
    if (!hasColumn(this.db, "local_artifacts", "last_opened_at")) {
      this.db.exec("ALTER TABLE local_artifacts ADD COLUMN last_opened_at INTEGER");
    }
  }

  private findLocalArtifact({
    account,
    kind,
    remoteId,
  }: {
    account: AccountPartition | null;
    kind: LocalArtifactKind;
    remoteId: string;
  }): LocalArtifact | null {
    const row = account
      ? this.db
          .prepare(
            `
            SELECT * FROM local_artifacts
            WHERE backend_origin = ? AND user_id = ? AND kind = ? AND remote_id = ?
            ORDER BY updated_at DESC, id DESC
            LIMIT 1
          `,
          )
          .get(account.backendOrigin, account.userId, kind, remoteId)
      : this.db
          .prepare(
            `
            SELECT * FROM local_artifacts
            WHERE backend_origin IS NULL AND user_id IS NULL AND kind = ? AND remote_id = ?
            ORDER BY updated_at DESC, id DESC
            LIMIT 1
          `,
          )
          .get(kind, remoteId);
    return row ? mapArtifactRow(row) : null;
  }
}

function parseAccountPartition(
  input: AccountStampInput | null | undefined,
  mode: "strict" | "lenient",
): AccountPartition | null {
  const rawOrigin = cleanString(input?.backendOrigin);
  const rawUserId = cleanString(input?.userId);
  if (!rawOrigin && !rawUserId) return null;
  if (!rawOrigin || !rawUserId) {
    if (mode === "strict") {
      throw cliError(
        "usage.invalid_argument",
        "Account stamp must include both backend origin and user id.",
        {
          hint: "Partial account stamps are treated as unattributed when reading legacy local state.",
        },
      );
    }
    return null;
  }
  try {
    return { backendOrigin: validateOrigin(rawOrigin), userId: rawUserId };
  } catch (error) {
    if (mode === "strict") throw error;
    return null;
  }
}

function cleanString(value: string | null | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}

function mapArtifactRow(row: Record<string, unknown>): LocalArtifact {
  const backendOrigin = stringOrNull(row.backend_origin);
  const userId = stringOrNull(row.user_id);
  const lastOpenedAt = numberOrNull(row.last_opened_at);
  return {
    id: numberValue(row.id),
    kind: localArtifactKind(row.kind),
    account: backendOrigin && userId ? { backendOrigin, userId } : null,
    localPath: stringValue(row.local_path),
    ...(stringOrNull(row.remote_id) ? { remoteId: stringOrNull(row.remote_id) ?? undefined } : {}),
    ...(typeof row.metadata_json === "string" ? { metadata: JSON.parse(row.metadata_json) } : {}),
    createdAt: numberValue(row.created_at),
    updatedAt: numberValue(row.updated_at),
    ...(lastOpenedAt ? { lastOpenedAt } : {}),
  };
}

function hasColumn(db: SqliteDatabase, table: string, column: string): boolean {
  return db
    .prepare(`PRAGMA table_info(${table})`)
    .all()
    .some((row) => row.name === column);
}

function localArtifactKind(value: unknown): LocalArtifactKind {
  if (value === "recording_session" || value === "download" || value === "live_caption_draft") {
    return value;
  }
  throw cliError("cloud.invalid_response", "CLI store contains an unknown artifact kind.");
}

function stringValue(value: unknown): string {
  if (typeof value === "string") return value;
  throw cliError("cloud.invalid_response", "CLI store row contained an invalid string value.");
}

function stringOrNull(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function numberValue(value: unknown): number {
  if (typeof value === "number") return value;
  if (typeof value === "bigint") return Number(value);
  throw cliError("cloud.invalid_response", "CLI store row contained an invalid number value.");
}

function numberOrNull(value: unknown): number | null {
  if (typeof value === "number") return value;
  if (typeof value === "bigint") return Number(value);
  return null;
}
