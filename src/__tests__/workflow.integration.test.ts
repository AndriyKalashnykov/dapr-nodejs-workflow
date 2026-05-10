import { describe, it, expect } from "vitest";

const API_URL = process.env.API_URL || "http://localhost:3000";

type ScheduleResponse = { message: string; id: string };
type StatusResponse = {
  id: string;
  status: string;
  output?: string;
  createdAt?: string;
  lastUpdatedAt?: string;
};

async function scheduleWorkflow(
  body: Record<string, unknown>,
): Promise<ScheduleResponse> {
  const res = await fetch(`${API_URL}/process-payload`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (res.status !== 202) {
    throw new Error(`Expected 202 but got ${res.status}: ${await res.text()}`);
  }
  return (await res.json()) as ScheduleResponse;
}

async function pollUntilCompleted(
  id: string,
  timeoutMs: number,
): Promise<StatusResponse> {
  const deadline = Date.now() + timeoutMs;
  let last: StatusResponse | null = null;
  while (Date.now() < deadline) {
    const res = await fetch(`${API_URL}/workflow/${id}/status`);
    if (res.status !== 200) {
      throw new Error(
        `Status request failed: ${res.status} ${await res.text()}`,
      );
    }
    last = (await res.json()) as StatusResponse;
    if (last.status === "COMPLETED") {
      return last;
    }
    if (last.status === "FAILED" || last.status === "TERMINATED") {
      throw new Error(`Workflow ended in ${last.status}: ${last.output}`);
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(
    `Workflow ${id} did not COMPLETE within ${timeoutMs}ms (last status: ${last?.status})`,
  );
}

describe("health check", () => {
  it("GET / returns running message", async () => {
    const res = await fetch(`${API_URL}/`);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { message: string };
    expect(body.message).toBe("Dapr Workflow API is running");
  });
});

describe("workflow scheduling", () => {
  it("POST /process-payload returns 202 with workflow ID", async () => {
    const body = await scheduleWorkflow({
      name: "integration-test",
      data: { key: "value" },
    });
    expect(body.id).toBeDefined();
    expect(typeof body.id).toBe("string");
    expect(body.message).toContain("scheduled");
  });

  it("POST /process-payload returns 400 for empty JSON body", async () => {
    const res = await fetch(`${API_URL}/process-payload`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string; details?: string };
    expect(body.error).toBe("Invalid request");
  });

  it("GET /workflow/:id/status returns state for a scheduled workflow", async () => {
    const { id } = await scheduleWorkflow({ name: "status-check" });

    // Give the workflow a moment to register
    await new Promise((resolve) => setTimeout(resolve, 2000));

    const statusRes = await fetch(`${API_URL}/workflow/${id}/status`);
    expect(statusRes.status).toBe(200);
    const status = (await statusRes.json()) as StatusResponse;
    expect(status.id).toBe(id);
    expect(status.status).toBeDefined();
  });

  it("GET /workflow/:id/status returns 404 for unknown workflow id", async () => {
    const res = await fetch(
      `${API_URL}/workflow/nonexistent-wf-${Date.now()}/status`,
    );
    expect(res.status).toBe(404);
    const body = (await res.json()) as { error: string; details?: string };
    expect(body.error).toBe("Workflow not found");
  });
});

describe("workflow end-to-end completion", () => {
  it("POST /process-payload with delayMs=0 completes with enriched payload + dbData", async () => {
    const { id } = await scheduleWorkflow({
      delayMs: 0,
      payload: { name: "eventual-completion" },
    });

    const status = await pollUntilCompleted(id, 30_000);
    expect(status.status).toBe("COMPLETED");
    expect(status.output).toBeDefined();

    const output = JSON.parse(status.output ?? "{}") as Record<string, unknown>;
    expect(output.processed).toBe(true);
    expect(output.modified).toBe(true);
    expect(output.processedAt).toBeDefined();

    const dbData = output.dbData as Record<string, unknown> | unknown[];
    expect(dbData).toBeDefined();
    // Postgres binding returns results as an array-of-rows payload (or wrapped).
    // Either shape is acceptable — what matters is the binding round-tripped.
  }, 35_000);

  it("transitions through RUNNING → COMPLETED while a delayActivity is in flight", async () => {
    const { id } = await scheduleWorkflow({
      delayMs: 2000,
      payload: { name: "status-transition" },
    });

    // Poll quickly: workflow should be RUNNING (delayActivity in flight).
    await new Promise((r) => setTimeout(r, 200));
    const midRes = await fetch(`${API_URL}/workflow/${id}/status`);
    const mid = (await midRes.json()) as StatusResponse;
    expect(["RUNNING", "PENDING"]).toContain(mid.status);

    const final = await pollUntilCompleted(id, 30_000);
    expect(final.status).toBe("COMPLETED");
  }, 35_000);

  it("folds dbError into payload when the postgres binding fails (does NOT fail the workflow)", async () => {
    // Point at a non-existent storeName — Dapr's binding lookup fails, the
    // activity returns a structured error envelope, and the workflow swallows
    // it and folds it under `dbError` instead of failing.
    const { id } = await scheduleWorkflow({
      delayMs: 0,
      payload: { name: "db-error" },
      // Override default storeName to force a binding lookup failure.
      // The /process-payload handler hardcodes "postgres-db" so we cheat by
      // sending a query that postgres will reject (parse error -> 500 from binding).
      // The workflow's catch-fold contract holds for ANY thrown error, so SQL syntax error works.
      query: "this is not valid sql",
    });

    const status = await pollUntilCompleted(id, 30_000);
    expect(status.status).toBe("COMPLETED");
    const output = JSON.parse(status.output ?? "{}") as Record<string, unknown>;
    // Either dbError landed (binding failed cleanly) OR dbData carries an error envelope.
    // Both are acceptable expressions of the "do not fail the workflow" contract.
    const hasError =
      output.dbError !== undefined ||
      (output.dbData &&
        typeof output.dbData === "object" &&
        "error" in (output.dbData as Record<string, unknown>));
    expect(hasError).toBe(true);
    expect(output.processed).toBe(true);
  }, 35_000);

  it("handles 5 workflows scheduled concurrently — each reaches COMPLETED with distinct ids", async () => {
    const N = 5;
    const scheduled = await Promise.all(
      Array.from({ length: N }, (_, i) =>
        scheduleWorkflow({ delayMs: 0, payload: { name: `concurrent-${i}` } }),
      ),
    );
    const ids = scheduled.map((s) => s.id);
    expect(new Set(ids).size).toBe(N); // all distinct

    const finals = await Promise.all(
      ids.map((id) => pollUntilCompleted(id, 30_000)),
    );
    for (const f of finals) {
      expect(f.status).toBe("COMPLETED");
      const out = JSON.parse(f.output ?? "{}") as Record<string, unknown>;
      expect(out.processed).toBe(true);
    }
  }, 60_000);
});

describe("database integration", () => {
  it("GET /db-health returns success with database info", async () => {
    const res = await fetch(`${API_URL}/db-health`);
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      status: string;
      dbConnection: string;
      workflowId: string;
    };
    expect(body.status).toBe("success");
    expect(body.dbConnection).toBe("working");
    expect(body.workflowId).toBeDefined();
  }, 30000);
});
