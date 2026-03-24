import { describe, it, expect } from "vitest";

const API_URL = process.env.API_URL || "http://localhost:3000";

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
    const res = await fetch(`${API_URL}/process-payload`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name: "integration-test", data: { key: "value" } }),
    });
    expect(res.status).toBe(202);
    const body = (await res.json()) as { message: string; id: string };
    expect(body.id).toBeDefined();
    expect(typeof body.id).toBe("string");
    expect(body.message).toContain("scheduled");
  });

  it("GET /workflow/:id/status returns state for a scheduled workflow", async () => {
    // Schedule a workflow first
    const scheduleRes = await fetch(`${API_URL}/process-payload`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name: "status-check" }),
    });
    const { id } = (await scheduleRes.json()) as { id: string };

    // Give the workflow a moment to register
    await new Promise((resolve) => setTimeout(resolve, 2000));

    // Poll status — workflow is still running (30s delay) but state should exist
    const statusRes = await fetch(`${API_URL}/workflow/${id}/status`);
    expect(statusRes.status).toBe(200);
    const status = (await statusRes.json()) as { id: string; status: string };
    expect(status.id).toBe(id);
    expect(status.status).toBeDefined();
  });
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
