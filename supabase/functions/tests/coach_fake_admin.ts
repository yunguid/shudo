/// In-memory service-role client for the coach brain tests: PostgREST-style
/// filters (including `payload->>key` paths), insert/update/upsert, range,
/// scripted RPCs, and signed URLs. Only what the coach modules use.

export type Row = Record<string, unknown>;
export type RpcCall = { name: string; args: Record<string, unknown> };
type RpcHandler = (args: Record<string, unknown>) => unknown;

function resolve(row: Row, column: string): unknown {
  const path = /^(\w+)->>(\w+)$/u.exec(column);
  if (path) {
    const value = (row[path[1]] as Row | null | undefined)?.[path[2]];
    return value === undefined || value === null ? null : String(value);
  }
  return row[column];
}

function compare(left: unknown, right: unknown): number {
  if (typeof left === "number" && typeof right === "number") {
    return left - right;
  }
  return String(left).localeCompare(String(right));
}

export function coachFakeAdmin(
  options: {
    tables?: Record<string, Row[]>;
    rpc?: Record<string, RpcHandler>;
  } = {},
) {
  const tables: Record<string, Row[]> = {};
  for (const [name, rows] of Object.entries(options.tables ?? {})) {
    tables[name] = rows.map((row) => structuredClone(row));
  }
  const rpcCalls: RpcCall[] = [];
  const rpc: Record<string, RpcHandler> = { ...options.rpc };

  class Query implements PromiseLike<{ data: unknown; error: unknown }> {
    #filters: Array<(row: Row) => boolean> = [];
    #operation: "select" | "insert" | "update" | "upsert" | "delete" = "select";
    #values: Row | Row[] | null = null;
    #conflict: string[] = [];
    #order: Array<{ column: string; ascending: boolean }> = [];
    #limit: number | null = null;
    #offset = 0;
    #single = false;

    constructor(readonly table: string) {}

    select(_columns?: string, _options?: unknown) {
      return this;
    }
    insert(values: Row | Row[]) {
      this.#operation = "insert";
      this.#values = values;
      return this;
    }
    update(values: Row) {
      this.#operation = "update";
      this.#values = values;
      return this;
    }
    upsert(values: Row | Row[], upsertOptions: { onConflict?: string } = {}) {
      this.#operation = "upsert";
      this.#values = values;
      this.#conflict = (upsertOptions.onConflict ?? "id").split(",").map((
        part,
      ) => part.trim());
      return this;
    }
    delete() {
      this.#operation = "delete";
      return this;
    }
    eq(column: string, value: unknown) {
      this.#filters.push((row) => resolve(row, column) === value);
      return this;
    }
    neq(column: string, value: unknown) {
      this.#filters.push((row) => resolve(row, column) !== value);
      return this;
    }
    lt(column: string, value: unknown) {
      this.#filters.push((row) =>
        resolve(row, column) != null && compare(resolve(row, column), value) < 0
      );
      return this;
    }
    lte(column: string, value: unknown) {
      this.#filters.push((row) =>
        resolve(row, column) != null &&
        compare(resolve(row, column), value) <= 0
      );
      return this;
    }
    gt(column: string, value: unknown) {
      this.#filters.push((row) =>
        resolve(row, column) != null && compare(resolve(row, column), value) > 0
      );
      return this;
    }
    gte(column: string, value: unknown) {
      this.#filters.push((row) =>
        resolve(row, column) != null &&
        compare(resolve(row, column), value) >= 0
      );
      return this;
    }
    in(column: string, values: unknown[]) {
      this.#filters.push((row) => values.includes(resolve(row, column)));
      return this;
    }
    is(column: string, value: unknown) {
      this.#filters.push((row) => (resolve(row, column) ?? null) === value);
      return this;
    }
    order(column: string, orderOptions: { ascending?: boolean } = {}) {
      this.#order.push({ column, ascending: orderOptions.ascending ?? true });
      return this;
    }
    limit(count: number) {
      this.#limit = count;
      return this;
    }
    range(from: number, to: number) {
      this.#offset = from;
      this.#limit = to - from + 1;
      return this;
    }
    maybeSingle() {
      this.#single = true;
      return this;
    }
    single() {
      this.#single = true;
      return this;
    }

    #matching(): Row[] {
      return (tables[this.table] ?? []).filter((row) =>
        this.#filters.every((filter) => filter(row))
      );
    }

    #result(rows: Row[]): { data: unknown; error: unknown } {
      let result = [...rows];
      for (const { column, ascending } of [...this.#order].reverse()) {
        result.sort((left, right) =>
          compare(left[column], right[column]) * (ascending ? 1 : -1)
        );
      }
      result = result.slice(
        this.#offset,
        this.#limit === null ? undefined : this.#offset + this.#limit,
      );
      const copies = result.map((row) => structuredClone(row));
      return { data: this.#single ? copies[0] ?? null : copies, error: null };
    }

    #execute(): { data: unknown; error: unknown } {
      const now = new Date().toISOString();
      tables[this.table] ??= [];
      const values = Array.isArray(this.#values)
        ? this.#values
        : this.#values
        ? [this.#values]
        : [];
      switch (this.#operation) {
        case "select":
          return this.#result(this.#matching());
        case "insert": {
          const inserted = values.map((value) => ({
            id: crypto.randomUUID(),
            created_at: now,
            updated_at: now,
            ...structuredClone(value),
          }));
          tables[this.table].push(...inserted);
          return this.#result(inserted);
        }
        case "upsert": {
          const touched: Row[] = [];
          for (const value of values) {
            const existing = tables[this.table].find((row) =>
              this.#conflict.every((column) => row[column] === value[column])
            );
            if (existing) {
              Object.assign(existing, structuredClone(value), {
                updated_at: now,
              });
              touched.push(existing);
            } else {
              const row = {
                id: crypto.randomUUID(),
                created_at: now,
                updated_at: now,
                ...structuredClone(value),
              };
              tables[this.table].push(row);
              touched.push(row);
            }
          }
          return this.#result(touched);
        }
        case "update": {
          const matched = this.#matching();
          for (const row of matched) {
            Object.assign(row, structuredClone(values[0] ?? {}), {
              updated_at: now,
            });
          }
          return this.#result(matched);
        }
        case "delete": {
          const matched = this.#matching();
          tables[this.table] = tables[this.table].filter((row) =>
            !matched.includes(row)
          );
          return this.#result(matched);
        }
      }
    }

    then<TResult1 = { data: unknown; error: unknown }, TResult2 = never>(
      onfulfilled?:
        | ((
          value: { data: unknown; error: unknown },
        ) => TResult1 | PromiseLike<TResult1>)
        | null,
      onrejected?:
        | ((reason: unknown) => TResult2 | PromiseLike<TResult2>)
        | null,
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
    rpc(name: string, args: Record<string, unknown> = {}) {
      rpcCalls.push({ name, args: structuredClone(args) });
      const handler = rpc[name];
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
          error: {
            message: error instanceof Error ? error.message : String(error),
          },
        });
      }
    },
    storage: {
      from(bucket: string) {
        return {
          createSignedUrl(path: string, _seconds: number) {
            return Promise.resolve({
              data: {
                signedUrl: `https://storage.test/${bucket}/${path}?token=t`,
              },
              error: null,
            });
          },
        };
      },
    },
  };

  return { admin, tables, rpc, rpcCalls };
}

/// A coach-run ledger that behaves like lane B1's RPCs closely enough for
/// the brain's tests: claims, fenced completion (inserting messages into
/// coach_messages), streaming upserts, failures, memory saves.
export function installCoachLedger(
  fake: ReturnType<typeof coachFakeAdmin>,
  options: { claimStatus?: string; userId?: string; localDay?: string } = {},
) {
  const userId = options.userId ?? "fixture";
  const runId = crypto.randomUUID();
  const claimToken = crypto.randomUUID();
  const state = {
    runId,
    claimToken,
    claims: [] as Array<Record<string, unknown>>,
    completions: [] as Array<Record<string, unknown>>,
    failures: [] as Array<Record<string, unknown>>,
    streams: [] as Array<Record<string, unknown>>,
    memorySaves: [] as Array<Record<string, unknown>>,
    usage: [] as Array<Record<string, unknown>>,
  };
  fake.tables.coach_messages ??= [];
  fake.rpc.claim_coach_run = (args) => {
    state.claims.push(args);
    const status = options.claimStatus ?? "claimed";
    return status === "claimed" || status === "reclaimed"
      ? {
        status,
        run_id: runId,
        claim_token: claimToken,
        generation_attempt: 1,
      }
      : { status, run_id: runId };
  };
  fake.rpc.complete_coach_run = (args) => {
    state.completions.push(args);
    const messages = (args.p_messages ?? []) as Row[];
    const ids: string[] = [];
    for (const message of messages) {
      const id = (message.id as string | undefined) ?? crypto.randomUUID();
      ids.push(id);
      const deliverAt = (message.deliver_at as string | undefined) ??
        new Date().toISOString();
      fake.tables.coach_messages.push({
        id,
        user_id: userId,
        role: "coach",
        kind: message.kind,
        body: message.body,
        payload: message.payload ?? {},
        local_day: message.local_day,
        deliver_at: deliverAt,
        status: Date.parse(deliverAt) > Date.now() ? "scheduled" : "delivered",
        notify: message.notify ?? false,
        slot_key: message.slot_key ?? null,
        entry_id: message.entry_id ?? null,
        activity_id: message.activity_id ?? null,
        run_id: runId,
        created_at: new Date().toISOString(),
      });
    }
    return { status: args.p_status, message_ids: ids, superseded: 0 };
  };
  fake.rpc.fail_coach_run = (args) => {
    state.failures.push(args);
    return true;
  };
  fake.rpc.upsert_streaming_coach_message = (args) => {
    state.streams.push(args);
    const existing = fake.tables.coach_messages.find((row) =>
      row.id === args.p_message_id
    );
    const payload = {
      ...(args.p_payload as Row),
      ...(args.p_done ? {} : { streaming: true }),
    };
    if (existing) {
      Object.assign(existing, { body: args.p_body, payload });
    } else {
      fake.tables.coach_messages.push({
        id: args.p_message_id,
        user_id: userId,
        role: "coach",
        kind: args.p_kind ?? "text",
        body: args.p_body,
        payload,
        local_day: options.localDay ?? "2026-10-05",
        deliver_at: new Date().toISOString(),
        status: "delivered",
        run_id: runId,
        created_at: new Date().toISOString(),
      });
    }
    return { status: "saved", message_id: args.p_message_id };
  };
  fake.rpc.save_coach_memory = (args) => {
    state.memorySaves.push(args);
    return { status: "saved", version: Number(args.p_expected_version) + 1 };
  };
  fake.rpc.record_ai_provider_call = (args) => {
    state.usage.push(args);
    return crypto.randomUUID();
  };
  return state;
}
