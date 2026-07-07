import { describe, it, expect } from "vitest";
import {
  dataRequestWorkflow,
  modifyPayloadActivity,
  delayActivity,
  fetchPostgresDataActivity,
} from "../data-request-workflow";

// Generator-level unit tests for dataRequestWorkflow. We drive the async
// generator by hand with a fake WorkflowContext whose callActivity records the
// (activity, input) it was asked to run and lets the test feed back the result
// the Dapr runtime would normally supply. This exercises the workflow's OWN
// control flow (delay gate, result-key mapping, skip-Postgres branch) without a
// live sidecar — the branches the API/integration path cannot reach directly.

type FakeCall = { name: string; input: unknown };
type ResultFor = unknown | ((input: unknown) => unknown);

// Run the workflow to completion, feeding each callActivity the canned result
// keyed by the activity function's name. Returns the final output + call log.
async function runWorkflow(
  input: Record<string, unknown>,
  resultsByName: Record<string, ResultFor>,
): Promise<{ output: Record<string, unknown>; calls: FakeCall[] }> {
  const calls: FakeCall[] = [];
  const ctx = {
    callActivity: (fn: { name: string }, arg: unknown) => {
      calls.push({ name: fn.name, input: arg });
      // The yielded value is discarded by the driver — the real result is fed
      // back via gen.next(result), mirroring the Dapr replay model.
      return { __activity: fn.name };
    },
  };

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const gen = dataRequestWorkflow(ctx as any, input);
  let res = await gen.next();
  while (!res.done) {
    const lastCall = calls[calls.length - 1];
    const r = resultsByName[lastCall.name];
    const value = typeof r === "function" ? r(lastCall.input) : r;
    res = await gen.next(value);
  }
  return { output: res.value as Record<string, unknown>, calls };
}

// A stand-in for modifyPayloadActivity: returns a fresh enriched object each
// call (the workflow then mutates it by adding the result key).
const enrich = (arg: unknown) => ({
  ...(arg as Record<string, unknown>),
  processed: true,
  modified: true,
});

describe("dataRequestWorkflow generator", () => {
  it("maps the DB result under a custom resultKey (not dbData)", async () => {
    const dbRows = { rows: [{ id: 1 }] };
    const { output } = await runWorkflow(
      {
        payload: { name: "x" },
        query: "select * from users",
        storeName: "postgres-db",
        resultKey: "customKey",
        delayMs: 0,
      },
      {
        [modifyPayloadActivity.name]: enrich,
        [fetchPostgresDataActivity.name]: dbRows,
      },
    );
    expect(output.customKey).toEqual(dbRows);
    expect(output.dbData).toBeUndefined();
    expect(output.processed).toBe(true);
  });

  it("defaults the result key to dbData when resultKey is omitted", async () => {
    const dbRows = { rows: [] };
    const { output } = await runWorkflow(
      {
        payload: { name: "x" },
        query: "select * from users",
        storeName: "postgres-db",
      },
      {
        [modifyPayloadActivity.name]: enrich,
        [fetchPostgresDataActivity.name]: dbRows,
      },
    );
    expect(output.dbData).toEqual(dbRows);
  });

  it("passes queryParams through to the Postgres fetch activity", async () => {
    const { calls } = await runWorkflow(
      {
        payload: { name: "x" },
        query: "select * from users where id = $1",
        queryParams: [42],
        storeName: "postgres-db",
      },
      {
        [modifyPayloadActivity.name]: enrich,
        [fetchPostgresDataActivity.name]: { rows: [] },
      },
    );
    const fetchCall = calls.find(
      (c) => c.name === fetchPostgresDataActivity.name,
    );
    expect(fetchCall).toBeDefined();
    const params = (fetchCall?.input as { queryParams?: unknown[] } | undefined)
      ?.queryParams;
    expect(params).toEqual([42]);
  });

  it("skips the Postgres fetch when query/storeName are absent", async () => {
    const { output, calls } = await runWorkflow(
      { payload: { name: "no-db" } },
      { [modifyPayloadActivity.name]: enrich },
    );
    expect(calls.map((c) => c.name)).not.toContain(
      fetchPostgresDataActivity.name,
    );
    expect(output.dbData).toBeUndefined();
    expect(output.processed).toBe(true);
  });

  it("invokes delayActivity only when delayMs > 0", async () => {
    const withDelay = await runWorkflow(
      { payload: {}, delayMs: 5 },
      {
        [delayActivity.name]: undefined,
        [modifyPayloadActivity.name]: enrich,
      },
    );
    const delayCall = withDelay.calls.find(
      (c) => c.name === delayActivity.name,
    );
    expect(delayCall).toBeDefined();
    expect(delayCall?.input).toBe(5);

    const noDelay = await runWorkflow(
      { payload: {}, delayMs: 0 },
      { [modifyPayloadActivity.name]: enrich },
    );
    expect(noDelay.calls.map((c) => c.name)).not.toContain(delayActivity.name);
  });
});
