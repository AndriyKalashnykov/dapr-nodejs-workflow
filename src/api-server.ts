import { app, shutdown } from "./app.js";

const port = process.env.PORT ? parseInt(process.env.PORT, 10) : 3000;
const host = process.env.HOST || "localhost";

function startServer(): void {
  app.listen(port, () => {
    console.log(`REST API server running at http://${host}:${port}`);
    console.log(
      `Process payload endpoint: http://${host}:${port}/process-payload`,
    );
  });
}

process.on("SIGINT", async () => {
  console.log("Shutting down gracefully...");
  try {
    await shutdown();
    process.exit(0);
  } catch (error) {
    console.error("Error during shutdown:", error);
    process.exit(1);
  }
});

startServer();
