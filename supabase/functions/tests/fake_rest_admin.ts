/// In-memory stand-in for the service-role Supabase client used by the
/// Train / Body / Nearby modules: a small PostgREST-style query builder over
/// table fixtures, scripted RPC handlers, and a byte-backed Storage fake.
/// Only the operations those modules use are implemented.

export type Row = Record<string, unknown>;
export type RpcCall = { name: string; args: Record<string, unknown> };
export type StorageCall = {
  operation: "upload" | "download" | "remove" | "sign";
  bucket: string;
  path: string;
};
export type MutationCall = {
  table: string;
  operation: "insert" | "update" | "delete";
  values: Row | null;
};

type RpcHandler = (args: Record<string, unknown>) => unknown;
type PostgrestError = { message: string; code?: string };

export type FakeAdminOptions = {
  tables?: Record<string, Row[]>;
  rpc?: Record<string, RpcHandler>;
  /// Column sets that must be unique per table (insert → 23505).
  unique?: Record<string, string[][]>;
  /// Error returned for any insert into the table (e.g. a quota trigger).
  insertErrors?: Record<string, PostgrestError>;
  /// Error returned for any select on the table.
  selectErrors?: Record<string, PostgrestError>;
  storage?: Record<string, Record<string, Uint8Array>>;
};

function compare(left: unknown, right: unknown): number {
  if (typeof left === "number" && typeof right === "number") {
    return left - right;
  }
  return String(left).localeCompare(String(right));
}

export function fakeAdmin(options: FakeAdminOptions = {}) {
  const tables: Record<string, Row[]> = {};
  for (const [name, rows] of Object.entries(options.tables ?? {})) {
    tables[name] = rows.map((row) => structuredClone(row));
  }
  const storage: Record<string, Record<string, Uint8Array>> = {};
  for (const [bucket, objects] of Object.entries(options.storage ?? {})) {
    storage[bucket] = { ...objects };
  }
  const rpcCalls: RpcCall[] = [];
  const storageCalls: StorageCall[] = [];
  const mutations: MutationCall[] = [];

  class Query implements PromiseLike<{ data: unknown; error: unknown }> {
    #filters: Array<(row: Row) => boolean> = [];
    #operation: "select" | "insert" | "update" | "delete" = "select";
    #values: Row | null = null;
    #order: { column: string; ascending: boolean } | null = null;
    #limit: number | null = null;
    #single: "maybe" | "one" | null = null;

    constructor(readonly table: string) {}

    select(_columns?: string) {
      return this;
    }
    insert(values: Row) {
      this.#operation = "insert";
      this.#values = values;
      return this;
    }
    update(values: Row) {
      this.#operation = "update";
      this.#values = values;
      return this;
    }
    delete() {
      this.#operation = "delete";
      return this;
    }
    eq(column: string, value: unknown) {
      this.#filters.push((row) => row[column] === value);
      return this;
    }
    neq(column: string, value: unknown) {
      this.#filters.push((row) => row[column] !== value);
      return this;
    }
    lt(column: string, value: unknown) {
      this.#filters.push((row) =>
        row[column] != null && compare(row[column], value) < 0
      );
      return this;
    }
    lte(column: string, value: unknown) {
      this.#filters.push((row) =>
        row[column] != null && compare(row[column], value) <= 0
      );
      return this;
    }
    gt(column: string, value: unknown) {
      this.#filters.push((row) =>
        row[column] != null && compare(row[column], value) > 0
      );
      return this;
    }
    gte(column: string, value: unknown) {
      this.#filters.push((row) =>
        row[column] != null && compare(row[column], value) >= 0
      );
      return this;
    }
    in(column: string, values: unknown[]) {
      this.#filters.push((row) => values.includes(row[column]));
      return this;
    }
    is(column: string, value: unknown) {
      this.#filters.push((row) => (row[column] ?? null) === value);
      return this;
    }
    not(column: string, operator: string, value: unknown) {
      if (operator === "is" && value === null) {
        this.#filters.push((row) => row[column] != null);
      } else {
        this.#filters.push((row) => row[column] !== value);
      }
      return this;
    }
    order(column: string, options: { ascending?: boolean } = {}) {
      this.#order = { column, ascending: options.ascending ?? true };
      return this;
    }
    limit(count: number) {
      this.#limit = count;
      return this;
    }
    maybeSingle() {
      this.#single = "maybe";
      return this;
    }
    single() {
      this.#single = "one";
      return this;
    }

    #matching(): Row[] {
      const rows = tables[this.table] ?? [];
      return rows.filter((row) => this.#filters.every((filter) => filter(row)));
    }

    #result(rows: Row[]): { data: unknown; error: unknown } {
      let result = rows;
      if (this.#order) {
        const { column, ascending } = this.#order;
        result = [...result].sort((left, right) =>
          compare(left[column], right[column]) * (ascending ? 1 : -1)
        );
      }
      if (this.#limit !== null) result = result.slice(0, this.#limit);
      const copies = result.map((row) => structuredClone(row));
      if (this.#single) {
        if (copies.length === 0 && this.#single === "one") {
          return { data: null, error: { message: "no rows", code: "PGRST116" } };
        }
        return { data: copies[0] ?? null, error: null };
      }
      return { data: copies, error: null };
    }

    #execute(): { data: unknown; error: unknown } {
      if (this.#operation === "select") {
        const error = options.selectErrors?.[this.table];
        if (error) return { data: null, error };
        return this.#result(this.#matching());
      }
      if (this.#operation === "insert") {
        mutations.push({
          table: this.table,
          operation: "insert",
          values: structuredClone(this.#values),
        });
        const error = options.insertErrors?.[this.table];
        if (error) return { data: null, error };
        const now = new Date().toISOString();
        const row: Row = {
          id: crypto.randomUUID(),
          created_at: now,
          updated_at: now,
          ...structuredClone(this.#values!),
        };
        tables[this.table] ??= [];
        for (const columns of options.unique?.[this.table] ?? []) {
          const clash = tables[this.table].some((existing) =>
            columns.every((column) => existing[column] === row[column])
          );
          if (clash) {
            return {
              data: null,
              error: { message: "duplicate key value", code: "23505" },
            };
          }
        }
        tables[this.table].push(row);
        return this.#result([row]);
      }
      if (this.#operation === "update") {
        mutations.push({
          table: this.table,
          operation: "update",
          values: structuredClone(this.#values),
        });
        const matched = this.#matching();
        for (const row of matched) {
          Object.assign(row, structuredClone(this.#values!), {
            updated_at: new Date().toISOString(),
          });
        }
        return this.#result(matched);
      }
      mutations.push({ table: this.table, operation: "delete", values: null });
      const matched = this.#matching();
      tables[this.table] = (tables[this.table] ?? []).filter((row) =>
        !matched.includes(row)
      );
      return this.#result(matched);
    }

    then<TResult1 = { data: unknown; error: unknown }, TResult2 = never>(
      onfulfilled?:
        | ((value: { data: unknown; error: unknown }) => TResult1 | PromiseLike<TResult1>)
        | null,
      onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
    ): PromiseLike<TResult1 | TResult2> {
      return Promise.resolve().then(() => this.#execute()).then(
        onfulfilled,
        onrejected,
      );
    }
  }

  const admin = {
    from(table: string) {
      return new Query(table);
    },
    rpc(name: string, args: Record<string, unknown>) {
      rpcCalls.push({ name, args: structuredClone(args) });
      const handler = options.rpc?.[name];
      if (!handler) {
        return Promise.resolve({
          data: null,
          error: { message: `Unexpected RPC: ${name}` },
        });
      }
      try {
        return Promise.resolve({ data: handler(args), error: null });
      } catch (error) {
        return Promise.resolve({
          data: null,
          error: { message: error instanceof Error ? error.message : String(error) },
        });
      }
    },
    storage: {
      from(bucket: string) {
        return {
          upload(path: string, body: Uint8Array | Blob) {
            storageCalls.push({ operation: "upload", bucket, path });
            storage[bucket] ??= {};
            storage[bucket][path] = body instanceof Uint8Array ? body : new Uint8Array();
            return Promise.resolve({ data: { path }, error: null });
          },
          download(path: string) {
            storageCalls.push({ operation: "download", bucket, path });
            const bytes = storage[bucket]?.[path];
            return Promise.resolve(
              bytes
                ? { data: new Blob([bytes as BlobPart]), error: null }
                : { data: null, error: { message: "Object not found" } },
            );
          },
          remove(paths: string[]) {
            for (const path of paths) {
              storageCalls.push({ operation: "remove", bucket, path });
              delete storage[bucket]?.[path];
            }
            return Promise.resolve({ data: [], error: null });
          },
          createSignedUrl(path: string, _seconds: number) {
            storageCalls.push({ operation: "sign", bucket, path });
            return Promise.resolve({
              data: { signedUrl: `https://storage.test/${bucket}/${path}?token=t` },
              error: null,
            });
          },
        };
      },
    },
  };

  return { admin, tables, storage, rpcCalls, storageCalls, mutations };
}

/// Scripted coach-run ledger: claim_coach_run / complete_coach_run /
/// fail_coach_run with recorded messages and statuses.
export function fakeLedger(
  options: { claimStatus?: string; completeStatus?: string } = {},
) {
  const runId = crypto.randomUUID();
  const claimToken = crypto.randomUUID();
  const completed: Array<Record<string, unknown>> = [];
  const failed: Array<Record<string, unknown>> = [];
  const claims: Array<Record<string, unknown>> = [];
  return {
    runId,
    claimToken,
    completed,
    failed,
    claims,
    handlers: {
      claim_coach_run(args: Record<string, unknown>) {
        claims.push(args);
        const status = options.claimStatus ?? "claimed";
        return status === "claimed" || status === "reclaimed"
          ? {
            status,
            run_id: runId,
            claim_token: claimToken,
            generation_attempt: 1,
          }
          : { status, run_id: runId };
      },
      complete_coach_run(args: Record<string, unknown>) {
        completed.push(args);
        const messages = Array.isArray(args.p_messages) ? args.p_messages : [];
        return {
          status: options.completeStatus ?? "complete",
          message_ids: messages.map(() => crypto.randomUUID()),
          superseded: 0,
        };
      },
      fail_coach_run(args: Record<string, unknown>) {
        failed.push(args);
        return true;
      },
    } as Record<string, (args: Record<string, unknown>) => unknown>,
  };
}
