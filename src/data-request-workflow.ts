import {
  TWorkflow,
  WorkflowContext,
  WorkflowActivityContext,
} from "@dapr/dapr";
import axios from "axios";

// Activity to modify the payload
export const modifyPayloadActivity = async (
  _: WorkflowActivityContext,
  payload: Record<string, unknown>,
): Promise<Record<string, unknown>> => {
  console.log(`Activity modifying payload: ${JSON.stringify(payload)}`);
  // Add a timestamp and processed flag to the payload
  const result = {
    ...payload,
    processed: true,
    processedAt: new Date().toISOString(),
    modified: true,
  };
  console.log(`Activity returning modified payload: ${JSON.stringify(result)}`);
  return result;
};

// Activity to introduce a delay
export const delayActivity = async (
  _: WorkflowActivityContext,
  milliseconds: number,
): Promise<void> => {
  console.log(`Delaying for ${milliseconds}ms`);
  await new Promise((resolve) => setTimeout(resolve, milliseconds));
  console.log(`Delay of ${milliseconds}ms completed`);
};

// Activity to fetch data from Postgres using Dapr HTTP API directly
export const fetchPostgresDataActivity = async (
  _: WorkflowActivityContext,
  params: {
    query: string;
    queryParams?: unknown[];
    storeName: string;
  },
): Promise<Record<string, unknown>> => {
  try {
    console.log(`Fetching data from Postgres with query: ${params.query}`);

    // Resolve Dapr sidecar address from env (mirrors app.ts), default to localhost.
    const daprHost = process.env.DAPR_HOST || "localhost";
    const daprHttpPort = process.env.DAPR_HTTP_PORT || "3500";

    // Use direct HTTP call to Dapr sidecar for binding invocation
    const response = await axios.post(
      `http://${daprHost}:${daprHttpPort}/v1.0/bindings/${params.storeName}`,
      {
        operation: "query",
        metadata: {
          sql: params.query,
          params: JSON.stringify(params.queryParams || []),
        },
      },
    );

    console.log(
      `Successfully fetched data from Postgres: ${JSON.stringify(response.data || {})}`,
    );
    return response.data || {};
  } catch (error) {
    console.error(
      `Error fetching data from Postgres: ${error instanceof Error ? error.message : String(error)}`,
    );

    // Add detailed diagnostic information
    if (axios.isAxiosError(error)) {
      const axiosError = error;
      console.error(
        `Request failed with status ${axiosError.response?.status}`,
      );
      console.error(
        `Error details: ${JSON.stringify(axiosError.response?.data || {})}`,
      );

      // Return a structured error response rather than throwing
      return {
        error: true,
        message: axiosError.response?.data?.message || axiosError.message,
        status: axiosError.response?.status,
        timestamp: new Date().toISOString(),
      };
    }

    // Return a structured error for non-axios errors
    return {
      error: true,
      message: error instanceof Error ? error.message : String(error),
      timestamp: new Date().toISOString(),
    };
  }
};

// Workflow that processes the payload and fetches data from Postgres
export const dataRequestWorkflow: TWorkflow = async function* (
  ctx: WorkflowContext,
  input: {
    payload?: Record<string, unknown>;
    query?: string;
    queryParams?: unknown[];
    storeName?: string;
    resultKey?: string;
    delayMs?: number;
  },
): AsyncGenerator<unknown, Record<string, unknown>, unknown> {
  try {
    // Set default values if not provided
    const payload = input.payload || {};
    const resultKey = input.resultKey || "dbData";

    console.log(`Processing payload: ${JSON.stringify(payload)}`);

    if (input.delayMs && input.delayMs > 0) {
      console.log(`Adding a delay of ${input.delayMs}ms to the workflow`);
      yield ctx.callActivity(delayActivity, input.delayMs);
    }

    // First, modify the payload with basic info
    const modifiedPayload = (yield ctx.callActivity(
      modifyPayloadActivity,
      payload,
    )) as Record<string, unknown>;

    // If query and storeName are provided, fetch data from Postgres
    if (input.query && input.storeName) {
      console.log(`Fetching data from Postgres: ${input.query}`);
      try {
        // Call the postgres fetch activity
        const dbResult = yield ctx.callActivity(fetchPostgresDataActivity, {
          query: input.query,
          queryParams: input.queryParams,
          storeName: input.storeName,
        });

        // Add the database results to the payload
        modifiedPayload[resultKey] = dbResult;

        console.log(
          `Added database results to payload under key: ${resultKey}`,
        );
      } catch (dbError) {
        console.error(
          `Error fetching data from Postgres: ${dbError instanceof Error ? dbError.message : String(dbError)}`,
        );
        // Add error info to the payload instead of failing the workflow
        modifiedPayload.dbError = {
          message: dbError instanceof Error ? dbError.message : String(dbError),
          timestamp: new Date().toISOString(),
        };
      }
    } else {
      console.log(`Not fetching data from Postgres`);
    }

    console.log(
      `Workflow completed with final payload: ${JSON.stringify(modifiedPayload)}`,
    );
    return modifiedPayload;
  } catch (error) {
    console.error(
      `Error in workflow: ${error instanceof Error ? error.message : String(error)}`,
    );
    throw error;
  }
};
