import express, { Request, Response } from 'express';
import cors from 'cors';
import {
    DaprWorkflowClient,
    WorkflowContext,
    WorkflowRuntime,
    WorkflowState
} from "@dapr/dapr";
import {
    dataRequestWorkflow,
    modifyPayloadActivity,
    delayActivity,
    fetchPostgresDataActivity
} from './data-request-workflow';

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


// Initialize the workflow runtime and client on demand
async function initializeWorkflow(): Promise<void> {
    if (workflowInitialized) {
        return;
    }

    console.log("Initializing workflow runtime and client...");

    const daprHost = "localhost";
    const daprPort = "50001";

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
    return workflowClient!;
}

const app = express();
const port = process.env.PORT ? parseInt(process.env.PORT, 10) : 3000;

// Middleware for JSON parsing and CORS
app.use(express.json());
app.use(cors());

// Define REST API endpoints
app.get('/', (_: Request, res: Response) => {
    res.json({ message: 'Dapr Workflow API is running' });
});


// Enhanced endpoint to process JSON payload and optionally fetch from Postgres
app.post('/process-payload', async (req: Request, res: Response<ScheduleResponse | ErrorResponse>) => {
    try {
        // Validate request body
        if (!req.body) {
            res.status(400).json({
                error: 'Invalid request',
                details: 'Request body must not be empty'
            });
            return;
        }

        // Extract the input parameters
        const input = {
            payload: req.body.payload || req.body, // Support both { payload: {...} } and direct payload
            query: "select * from users",
            queryParams: req.body.queryParams,
            storeName: "postgres-db",
            resultKey: req.body.resultKey,
            delayMs: 30*1000, // 30 seconds delay to emulate long data request
        };

        console.log(`Received input: ${JSON.stringify(input)}`);

        console.log(`Received request to process payload: ${JSON.stringify(input)}`);

        // Get the workflow client (initializing if necessary)
        const client = await getWorkflowClient();

        // Schedule a new workflow instance with the input
        const id = await client.scheduleNewWorkflow(dataRequestWorkflow, input);
        console.log(`Workflow scheduled with ID: ${id}`);

        // Return the workflow ID to the client
        res.status(202).json({
            message: 'Payload processing workflow scheduled successfully',
            id: id
        });
    } catch (error) {
        console.error('Error scheduling payload processing workflow:', error);
        res.status(500).json({
            error: 'Failed to schedule workflow',
            details: error instanceof Error ? error.message : String(error)
        });
    }
});

// Endpoint to get workflow status
app.get('/workflow/:id/status', async (req: Request, res: Response<WorkflowStatusResponse | ErrorResponse>) => {
    try {
        // Get the workflow client (initializing if necessary)
        const client = await getWorkflowClient();

        const id = req.params.id;
        const state: WorkflowState | undefined = await client.getWorkflowState(id, true);

        if (!state) {
            res.status(404).json({
                error: 'Workflow not found',
                details: `No workflow found with ID: ${id}`
            });
            return;
        }

        res.json({
            id: id,
            status: state.runtimeStatus.toString(),
            output: state.serializedOutput,
            createdAt: state.createdAt,
            lastUpdatedAt: state.lastUpdatedAt
        });
    } catch (error) {
        console.error(`Error getting workflow status for ID ${req.params.id}:`, error);
        res.status(500).json({
            error: 'Failed to get workflow status',
            details: error instanceof Error ? error.message : String(error)
        });
    }
});

// Add a database health check endpoint
app.get('/db-health', async (_: Request, res: Response) => {
    try {
        // Extract the input parameters for a simple database health check
        const input = {
            payload: { check: "database-health" },
            query: "SELECT current_timestamp as time, current_database() as database, version() as version",
            storeName: "postgres-db",
            resultKey: "dbStatus"
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
                status: 'success',
                dbConnection: 'working',
                details: output.dbStatus || output,
                workflowId: id
            });
        } else {
            res.status(500).json({
                status: 'error',
                message: 'Database health check timed out or returned no data',
                workflowId: id
            });
        }
    } catch (error) {
        console.error('Database health check failed:', error);
        res.status(500).json({
            status: 'error',
            message: error instanceof Error ? error.message : String(error)
        });
    }
});

// Start the express server
function startServer(): void {
    app.listen(port, () => {
        console.log(`REST API server running at http://localhost:${port}`);
        console.log(`Process payload endpoint: http://localhost:${port}/process-payload`);
    });
}

// Handle graceful shutdown
process.on('SIGINT', async () => {
    console.log('Shutting down gracefully...');
    try {
        if (workflowInitialized) {
            await workflowRuntime!.stop();
            await workflowClient!.stop();
            console.log('Workflow runtime stopped');
        }
        process.exit(0);
    } catch (error) {
        console.error('Error during shutdown:', error);
        process.exit(1);
    }
});

// Start the server
startServer();