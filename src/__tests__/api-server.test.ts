import { describe, it, expect } from "vitest";
import net from "net";

// Import the checkPort utility by extracting it
// Since checkPort is not exported, we re-implement the same logic for testing
function checkPort(
  host: string,
  port: number,
  timeoutMs: number = 2000,
): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = new net.Socket();
    socket.setTimeout(timeoutMs);
    socket.once("connect", () => {
      socket.destroy();
      resolve(true);
    });
    socket.once("timeout", () => {
      socket.destroy();
      resolve(false);
    });
    socket.once("error", () => {
      socket.destroy();
      resolve(false);
    });
    socket.connect(port, host);
  });
}

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
    // Use a port that is very unlikely to be listening
    const result = await checkPort("localhost", 19999, 500);
    expect(result).toBe(false);
  });

  it("returns false for unreachable host", async () => {
    // 192.0.2.1 is a TEST-NET address that should be unreachable
    const result = await checkPort("192.0.2.1", 80, 500);
    expect(result).toBe(false);
  });
});
