export type AiAdapterRequestSchema = "org2:ai-adapter-request:v1";
export type AiAdapterResponseSchema = "org2:ai-adapter-response:v1";

export type AiAdapterPromptRole = "system" | "user" | "assistant";
export type AiAdapterOutputContentType = "text" | "json" | "text+json";

export type AiAdapterPromptMessage = {
  role: AiAdapterPromptRole;
  content: string;
  name?: string;
};

export type AiAdapterSourceRef = {
  file?: string;
  id?: string;
  title?: string;
  line?: number;
  endLine?: number;
  url?: string;
};

export type AiAdapterContextItem = {
  id: string;
  type: "org-headline" | "org-section" | "compiled-corpus" | "query-result" | "raw-transcript" | "artifact" | "text";
  text: string;
  title?: string;
  sourceRefs?: AiAdapterSourceRef[];
  metadata?: Record<string, unknown>;
};

export type AiAdapterTask = {
  type: string;
  template?: string;
  instructions?: string;
};

export type AiAdapterRequest = {
  schema: AiAdapterRequestSchema;
  jobId?: string;
  task: AiAdapterTask;
  prompt: AiAdapterPromptMessage[];
  context: AiAdapterContextItem[];
  output: {
    contentType: AiAdapterOutputContentType;
    schemaHint?: string;
  };
  options?: {
    temperature?: number;
    maxTokens?: number;
    timeoutMs?: number;
  };
  provenance?: {
    requireSourceRefs?: boolean;
    promptTemplateVersion?: string;
  };
};

export type AiAdapterCitation = {
  source: AiAdapterSourceRef;
  note?: string;
};

export type AiAdapterModelMetadata = {
  adapterName: string;
  model: string;
  provider?: string;
  invocationId?: string;
  startedAt?: string;
  completedAt?: string;
  usage?: {
    inputTokens?: number;
    outputTokens?: number;
  };
};

export type AiAdapterResponse = {
  schema: AiAdapterResponseSchema;
  text?: string;
  json?: unknown;
  citations?: AiAdapterCitation[];
  metadata: AiAdapterModelMetadata;
};

export interface AiProviderAdapter {
  readonly name: string;
  generate(request: AiAdapterRequest): Promise<AiAdapterResponse>;
}

export type MockAiAdapterResponder = (request: AiAdapterRequest, callIndex: number) => AiAdapterResponse | Promise<AiAdapterResponse>;

export type MockAiAdapterOptions = {
  name?: string;
  model?: string;
  response?: AiAdapterResponse;
  responder?: MockAiAdapterResponder;
};

function cloneJsonLike<T>(value: T): T {
  if (value === undefined) return value;
  return JSON.parse(JSON.stringify(value)) as T;
}

export function createAiAdapterRequest(input: Omit<AiAdapterRequest, "schema">): AiAdapterRequest {
  return { schema: "org2:ai-adapter-request:v1", ...input };
}

export function normalizeAiAdapterResponse(adapterName: string, model: string, response: Partial<AiAdapterResponse>): AiAdapterResponse {
  return {
    schema: "org2:ai-adapter-response:v1",
    ...response,
    metadata: {
      ...response.metadata,
      adapterName,
      model,
    },
  };
}

export class MockAiAdapter implements AiProviderAdapter {
  readonly name: string;
  readonly model: string;
  private readonly response?: AiAdapterResponse;
  private readonly responder?: MockAiAdapterResponder;
  private readonly recordedRequests: AiAdapterRequest[] = [];

  constructor(options: MockAiAdapterOptions = {}) {
    this.name = options.name || "mock";
    this.model = options.model || "mock-model";
    this.response = options.response;
    this.responder = options.responder;
  }

  get requests(): readonly AiAdapterRequest[] {
    return this.recordedRequests.map((request) => cloneJsonLike(request));
  }

  async generate(request: AiAdapterRequest): Promise<AiAdapterResponse> {
    const callIndex = this.recordedRequests.length;
    this.recordedRequests.push(cloneJsonLike(request));

    if (this.responder) {
      return normalizeAiAdapterResponse(this.name, this.model, await this.responder(cloneJsonLike(request), callIndex));
    }

    if (this.response) {
      return normalizeAiAdapterResponse(this.name, this.model, cloneJsonLike(this.response));
    }

    const text = `Mock AI response for ${request.task.type} using ${request.context.length} context item(s).`;
    const json = request.output.contentType === "json" || request.output.contentType === "text+json"
      ? { taskType: request.task.type, contextCount: request.context.length }
      : undefined;

    return normalizeAiAdapterResponse(this.name, this.model, {
      text,
      json,
      citations: request.context.flatMap((item) => (item.sourceRefs || []).map((source) => ({ source }))),
      metadata: {
        adapterName: this.name,
        model: this.model,
        provider: "mock",
      },
    });
  }
}
