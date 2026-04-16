import net from "net";
import express, { Request, Response } from "express";
import cors from "cors";
import { DaprWorkflowClient, WorkflowRuntime, WorkflowState } from "@dapr/dapr";
import {
  dataRequestWorkflow,
  modifyPayloadActivity,
  delayActivity,
  fetchPostgresDataActivity,
} from "./data-request-workflow.js";

// Define interfaces for API responses
interface ScheduleResponse {
  message: string;
  id: string;
}

interface ErrorResponse {
  error: string;
  details?: string;
}

interface WorkflowStatusResponse {
  id: string;
  status?: string;
  output?: string;
  createdAt?: Date;
  lastUpdatedAt?: Date;
}

// Lazy-initialized workflow-related variables
let workflowClient: DaprWorkflowClient | null = null;
let workflowRuntime: WorkflowRuntime | null = null;
let workflowInitialized: boolean = false;

// Check if a TCP port is reachable
export function checkPort(
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

// Initialize the workflow runtime and client on demand
async function initializeWorkflow(): Promise<void> {
  if (workflowInitialized) {
    return;
  }

  const daprHost = process.env.DAPR_HOST || "localhost";
  const daprPort = process.env.DAPR_GRPC_PORT || "50001";

  // Pre-check: ensure Dapr sidecar is reachable before attempting gRPC connection
  const daprAvailable = await checkPort(daprHost, parseInt(daprPort));
  if (!daprAvailable) {
    throw new Error(
      `Dapr sidecar is not reachable on ${daprHost}:${daprPort}. ` +
        `Start the application with 'make start' to run with the Dapr sidecar.`,
    );
  }

  console.log("Initializing workflow runtime and client...");

  workflowClient = new DaprWorkflowClient({
    daprHost,
    daprPort,
  });

  workflowRuntime = new WorkflowRuntime({
    daprHost,
    daprPort,
  });

  // Register payload modifier workflow and activities
  console.log("Registering dataRequestWorkflow and related activities");

  // Register all workflows and activities
  workflowRuntime.registerWorkflow(dataRequestWorkflow);
  workflowRuntime.registerActivity(modifyPayloadActivity);
  workflowRuntime.registerActivity(delayActivity);
  workflowRuntime.registerActivity(fetchPostgresDataActivity);

  // Start the workflow runtime
  await workflowRuntime.start();
  console.log("Workflow runtime started successfully");

  workflowInitialized = true;
}

// Get the workflow client, initializing if needed
async function getWorkflowClient(): Promise<DaprWorkflowClient> {
  if (!workflowInitialized) {
    await initializeWorkflow();
  }
  if (!workflowClient) {
    throw new Error("Workflow client failed to initialize");
  }
  return workflowClient;
}

// Stop the workflow runtime and client (invoked by the entrypoint on SIGINT)
export async function shutdown(): Promise<void> {
  if (workflowInitialized && workflowRuntime && workflowClient) {
    await workflowRuntime.stop();
    await workflowClient.stop();
    console.log("Workflow runtime stopped");
  }
}

export const app = express();

// Middleware for JSON parsing and CORS
app.use(express.json());
app.use(cors());

// Define REST API endpoints
app.get("/", (_: Request, res: Response) => {
  res.json({ message: "Dapr Workflow API is running" });
});

// Enhanced endpoint to process JSON payload and optionally fetch from Postgres
app.post(
  "/process-payload",
  async (req: Request, res: Response<ScheduleResponse | ErrorResponse>) => {
    try {
      // Validate request body
      if (!req.body || Object.keys(req.body).length === 0) {
        res.status(400).json({
          error: "Invalid request",
          details: "Request body must not be empty",
        });
        return;
      }

      // Extract the input parameters. Request body may override delayMs (tests use 0).
      const delayMs =
        typeof req.body.delayMs === "number" ? req.body.delayMs : 30 * 1000;
      const input = {
        payload: req.body.payload || req.body, // Support both { payload: {...} } and direct payload
        query: "select * from users",
        queryParams: req.body.queryParams,
        storeName: "postgres-db",
        resultKey: req.body.resultKey,
        delayMs,
      };

      console.log(`Received input: ${JSON.stringify(input)}`);

      console.log(
        `Received request to process payload: ${JSON.stringify(input)}`,
      );

      // Get the workflow client (initializing if necessary)
      const client = await getWorkflowClient();

      // Schedule a new workflow instance with the input
      const id = await client.scheduleNewWorkflow(dataRequestWorkflow, input);
      console.log(`Workflow scheduled with ID: ${id}`);

      // Return the workflow ID to the client
      res.status(202).json({
        message: "Payload processing workflow scheduled successfully",
        id: id,
      });
    } catch (error) {
      console.error("Error scheduling payload processing workflow:", error);
      res.status(500).json({
        error: "Failed to schedule workflow",
        details: error instanceof Error ? error.message : String(error),
      });
    }
  },
);

// Endpoint to get workflow status
app.get(
  "/workflow/:id/status",
  async (
    req: Request,
    res: Response<WorkflowStatusResponse | ErrorResponse>,
  ) => {
    try {
      // Get the workflow client (initializing if necessary)
      const client = await getWorkflowClient();

      const id = req.params.id as string;
      const state: WorkflowState | undefined = await client.getWorkflowState(
        id,
        true,
      );

      if (!state) {
        res.status(404).json({
          error: "Workflow not found",
          details: `No workflow found with ID: ${id}`,
        });
        return;
      }

      res.json({
        id: id,
        status: state.runtimeStatus.toString(),
        output: state.serializedOutput,
        createdAt: state.createdAt,
        lastUpdatedAt: state.lastUpdatedAt,
      });
    } catch (error) {
      console.error(
        `Error getting workflow status for ID ${req.params.id}:`,
        error,
      );
      res.status(500).json({
        error: "Failed to get workflow status",
        details: error instanceof Error ? error.message : String(error),
      });
    }
  },
);

// Add a database health check endpoint
app.get("/db-health", async (_: Request, res: Response) => {
  try {
    // Extract the input parameters for a simple database health check
    const input = {
      payload: { check: "database-health" },
      query:
        "SELECT current_timestamp as time, current_database() as database, version() as version",
      storeName: "postgres-db",
      resultKey: "dbStatus",
    };

    // Get the workflow client (initializing if necessary)
    const client = await getWorkflowClient();

    // Schedule a new workflow instance with the input
    const id = await client.scheduleNewWorkflow(dataRequestWorkflow, input);
    console.log(`Database health check workflow scheduled with ID: ${id}`);

    // Wait for workflow completion with timeout
    const result = await client.waitForWorkflowCompletion(id, undefined, 10);

    if (result && result.serializedOutput) {
      const output = JSON.parse(result.serializedOutput);
      res.json({
        status: "success",
        dbConnection: "working",
        details: output.dbStatus || output,
        workflowId: id,
      });
    } else {
      res.status(500).json({
        status: "error",
        message: "Database health check timed out or returned no data",
        workflowId: id,
      });
    }
  } catch (error) {
    console.error("Database health check failed:", error);
    res.status(500).json({
      status: "error",
      message: error instanceof Error ? error.message : String(error),
    });
  }
});
