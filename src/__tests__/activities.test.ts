import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { WorkflowActivityContext } from "@dapr/dapr";
import {
  modifyPayloadActivity,
  delayActivity,
  fetchPostgresDataActivity,
} from "../data-request-workflow";

const stubCtx = {} as WorkflowActivityContext;

describe("modifyPayloadActivity", () => {
  it("enriches payload with processed flag and timestamp", async () => {
    const input = { name: "test" };
    const result = await modifyPayloadActivity(stubCtx, input);

    expect(result).toMatchObject({
      name: "test",
      processed: true,
      modified: true,
    });
    expect(result.processedAt).toBeDefined();
    expect(typeof result.processedAt).toBe("string");
  });

  it("preserves all original fields", async () => {
    const input = { a: 1, b: "two", c: [3] };
    const result = await modifyPayloadActivity(stubCtx, input);

    expect(result.a).toBe(1);
    expect(result.b).toBe("two");
    expect(result.c).toEqual([3]);
  });

  it("handles empty payload", async () => {
    const result = await modifyPayloadActivity(stubCtx, {});

    expect(result.processed).toBe(true);
    expect(result.modified).toBe(true);
    expect(result.processedAt).toBeDefined();
  });

  it("does not mutate the original payload", async () => {
    const input = { name: "original" };
    const frozen = { ...input };
    await modifyPayloadActivity(stubCtx, input);

    expect(input).toEqual(frozen);
  });
});

describe("delayActivity", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("resolves after the specified delay", async () => {
    const promise = delayActivity(stubCtx, 5000);

    vi.advanceTimersByTime(5000);

    await expect(promise).resolves.toBeUndefined();
  });

  it("accepts zero milliseconds", async () => {
    const promise = delayActivity(stubCtx, 0);

    vi.advanceTimersByTime(0);

    await expect(promise).resolves.toBeUndefined();
  });
});

describe("fetchPostgresDataActivity", () => {
  const originalPort = process.env.DAPR_HTTP_PORT;

  afterEach(() => {
    if (originalPort === undefined) {
      delete process.env.DAPR_HTTP_PORT;
    } else {
      process.env.DAPR_HTTP_PORT = originalPort;
    }
  });

  it("returns a structured error envelope when Dapr is unreachable", async () => {
    // Point the activity at a closed port; 19999 is not expected to be listening
    process.env.DAPR_HTTP_PORT = "19999";

    const result = await fetchPostgresDataActivity(stubCtx, {
      query: "select 1",
      storeName: "postgres-db",
    });

    expect(result.error).toBe(true);
    expect(result.message).toBeDefined();
    expect(typeof result.message).toBe("string");
    expect(result.timestamp).toBeDefined();
  });
});
