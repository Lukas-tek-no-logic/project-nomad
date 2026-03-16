import type {
  LLMChatRequest,
  LLMChatResponse,
  LLMStreamChunk,
  LLMModelInfo,
  LLMModelDetails,
  LLMEmbedResponse,
  LLMDownloadProgress,
} from '../../../types/llm.js'

/**
 * Abstract LLM provider interface.
 * All backends (Ollama, llama.cpp) implement this contract.
 */
export abstract class LLMProvider {
  constructor(protected host: string) {}

  /** Send a chat completion request (non-streaming) */
  abstract chat(request: LLMChatRequest): Promise<LLMChatResponse>

  /** Send a streaming chat completion request */
  abstract chatStream(request: LLMChatRequest): Promise<AsyncIterable<LLMStreamChunk>>

  /** List installed/loaded models */
  abstract listModels(): Promise<LLMModelInfo[]>

  /** Get model details (capabilities, etc.) */
  abstract showModel(name: string): Promise<LLMModelDetails>

  /** Download/pull a model. Returns async iterable of progress events. */
  abstract pullModel(name: string): Promise<AsyncIterable<LLMDownloadProgress>>

  /** Delete a model */
  abstract deleteModel(name: string): Promise<void>

  /** Generate embeddings */
  abstract embed(model: string, input: string | string[]): Promise<LLMEmbedResponse>

  /** Check if the backend is reachable */
  abstract healthCheck(): Promise<boolean>
}
