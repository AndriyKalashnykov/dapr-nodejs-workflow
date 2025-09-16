
import { TWorkflow, WorkflowContext, WorkflowActivityContext, DaprClient, CommunicationProtocolEnum } from "@dapr/dapr";
import axios from 'axios';

// Activity to modify the payload
export const modifyPayloadActivity = async (
    _: WorkflowActivityContext,
    payload: Record<string, any>
): Promise<Record<string, any>> => {
    console.log(`Activity modifying payload: ${JSON.stringify(payload)}`);
    // Add a timestamp and processed flag to the payload
    const result = {
        ...payload,
        processed: true,
        processedAt: new Date().toISOString(),
        modified: true
    };
    console.log(`Activity returning modified payload: ${JSON.stringify(result)}`);
    return result;
};

// Activity to introduce a delay
export const delayActivity = async (
    _: WorkflowActivityContext,
    milliseconds: number
): Promise<void> => {
    console.log(`Delaying for ${milliseconds}ms`);
    await new Promise(resolve => setTimeout(resolve, milliseconds));
    console.log(`Delay of ${milliseconds}ms completed`);
};

// Activity to fetch data from Postgres using Dapr HTTP API directly
export const fetchPostgresDataActivity = async (
    _: WorkflowActivityContext,
    params: {
        query: string;
        queryParams?: any[];
        storeName: string;
    }
): Promise<any> => {
    try {
        console.log(`Fetching data from Postgres with query: ${params.query}`);

        // Get the Dapr HTTP port from environment variable or use default
        const daprHttpPort = process.env.DAPR_HTTP_PORT || "3500";

        // Use direct HTTP call to Dapr sidecar for binding invocation with configurable port
        const response = await axios.post(
            `http://localhost:${daprHttpPort}/v1.0/bindings/${params.storeName}`,
            {
                operation: "query",
                metadata: {
                    sql: params.query,
                    params: JSON.stringify(params.queryParams || [])
                }
            }
        );

        console.log(`Successfully fetched data from Postgres: ${JSON.stringify(response.data || {})}`);
        return response.data || {};
    } catch (error) {
        console.error(`Error fetching data from Postgres: ${error instanceof Error ? error.message : String(error)}`);

        // Add detailed diagnostic information
        if (error instanceof Error && 'isAxiosError' in error && (error as any).isAxiosError) {
            const axiosError = error as any;
            console.error(`Request failed with status ${axiosError.response?.status}`);
            console.error(`Error details: ${JSON.stringify(axiosError.response?.data || {})}`);

            // Return a structured error response rather than throwing
            return {
                error: true,
                message: axiosError.response?.data?.message || axiosError.message,
                status: axiosError.response?.status,
                timestamp: new Date().toISOString()
            };
        }

        // Return a structured error for non-axios errors
        return {
            error: true,
            message: error instanceof Error ? error.message : String(error),
            timestamp: new Date().toISOString()
        };
    }
};



// Activity to get data from state store using direct HTTP API
export const getFromStateStoreActivity = async (
    _: WorkflowActivityContext,
    params: {
        key: string;
        storeName: string;
    }
): Promise<any> => {
    try {
        console.log(`Getting data from state store: ${params.storeName} with key: ${params.key}`);

        // Use direct HTTP call to Dapr sidecar for state store
        const response = await axios.get(
            `http://localhost:3500/v1.0/state/${params.storeName}/${params.key}`
        );

        console.log(`Successfully retrieved data from state store: ${JSON.stringify(response.data || {})}`);
        return response.data;
    } catch (error) {
        console.error(`Error getting data from state store: ${error instanceof Error ? error.message : String(error)}`);
        throw error;
    }
};

// Workflow that processes the payload and fetches data from Postgres
export const dataRequestWorkflow: TWorkflow = async function* (
    ctx: WorkflowContext,
    input: {
        payload?: Record<string, any>;
        query?: string ;
        queryParams?: any[];
        storeName?: string ;
        resultKey?: string;
        stateKey?: string; // Optional key for state store access
        delayMs?: number;
    }
): AsyncGenerator<any, Record<string, any>, any> {
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
        const modifiedPayload = yield ctx.callActivity(modifyPayloadActivity, payload);

        // If stateKey is provided, try to get data from state store
        if (input.stateKey && input.storeName) {
            try {
                console.log(`Attempting to get data from state store using key: ${input.stateKey}`);
                const stateData = yield ctx.callActivity(getFromStateStoreActivity, {
                    key: input.stateKey,
                    storeName: input.storeName
                });

                if (stateData) {
                    modifiedPayload.stateData = stateData;
                    console.log(`Added state store data to payload`);
                }
            } catch (stateError) {
                console.error(`Error getting data from state store: ${stateError instanceof Error ? stateError.message : String(stateError)}`);
                // Add error info but continue with the workflow
                modifiedPayload.stateError = {
                    message: stateError instanceof Error ? stateError.message : String(stateError),
                    timestamp: new Date().toISOString()
                };
            }
        }

        // If query and storeName are provided, fetch data from Postgres
        if (input.query && input.storeName) {
            console.log(`Fetching data from Postgres: ${input.query}`);
            try {
                // Call the postgres fetch activity
                const dbResult = yield ctx.callActivity(fetchPostgresDataActivity, {
                    query: input.query,
                    queryParams: input.queryParams,
                    storeName: input.storeName
                });

                // Add the database results to the payload
                modifiedPayload[resultKey] = dbResult;

                console.log(`Added database results to payload under key: ${resultKey}`);
            } catch (dbError) {
                console.error(`Error fetching data from Postgres: ${dbError instanceof Error ? dbError.message : String(dbError)}`);
                // Add error info to the payload instead of failing the workflow
                modifiedPayload.dbError = {
                    message: dbError instanceof Error ? dbError.message : String(dbError),
                    timestamp: new Date().toISOString()
                };
            }
        } else {
            console.log(`Not fetching data from Postgres`);
        }

        console.log(`Workflow completed with final payload: ${JSON.stringify(modifiedPayload)}`);
        return modifiedPayload;
    } catch (error) {
        console.error(`Error in workflow: ${error instanceof Error ? error.message : String(error)}`);
        throw error;
    }
};