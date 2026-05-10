import { describe, it, expect } from "vitest";
import net from "net";
import request from "supertest";
import { app, checkPort, shutdown } from "../app";

describe("checkPort", () => {
  it("returns true for a listening port", async () => {
    const server = net.createServer();
    await new Promise<void>((resolve) => server.listen(0, resolve));
    const port = (server.address() as net.AddressInfo).port;

    const result = await checkPort("localhost", port);
    expect(result).toBe(true);

    await new Promise<void>((resolve) => server.close(() => resolve()));
  });

  it("returns false for a closed port", async () => {
    const result = await checkPort("localhost", 19999, 500);
    expect(result).toBe(false);
  });

  it("returns false for an unreachable host", async () => {
    // 192.0.2.1 is a TEST-NET-1 address (RFC 5737) — never routable
    const result = await checkPort("192.0.2.1", 80, 500);
    expect(result).toBe(false);
  });
});

describe("GET /", () => {
  it("returns the running message", async () => {
    const res = await request(app).get("/");
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ message: "Dapr Workflow API is running" });
  });
});

describe("shutdown", () => {
  it("returns cleanly when the workflow runtime was never initialized", async () => {
    // No /process-payload call yet → workflowInitialized=false → shutdown is a no-op.
    await expect(shutdown()).resolves.toBeUndefined();
  });
});

describe("POST /process-payload", () => {
  it("returns 400 when the request body is empty", async () => {
    const res = await request(app)
      .post("/process-payload")
      .set("Content-Type", "application/json")
      .send("");

    expect(res.status).toBe(400);
    expect(res.body).toEqual({
      error: "Invalid request",
      details: "Request body must not be empty",
    });
  });

  it("returns 400 when the JSON body is {}", async () => {
    const res = await request(app)
      .post("/process-payload")
      .set("Content-Type", "application/json")
      .send("{}");

    expect(res.status).toBe(400);
    expect(res.body.error).toBe("Invalid request");
  });
});
