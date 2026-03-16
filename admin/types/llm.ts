/**
 * LLM Backend configuration types.
 * Supports multiple inference backends: Ollama (default) and llama.cpp.
 */

export type LLMBackendType = 'ollama' | 'llamacpp'

export interface LLMBackendConfig {
  /** Backend type: 'ollama' (default) or 'llamacpp' */
  type: LLMBackendType
  /** Remote URL for the LLM server. If set, bypasses Docker service discovery. */
  remoteUrl?: string
}

/** Normalized chat message format used across all backends */
export interface LLMChatMessage {
  role: 'system' | 'user' | 'assistant'
  content: string
}

/** Normalized chat request */
export interface LLMChatRequest {
  model: string
  messages: LLMChatMessage[]
  stream?: boolean
  think?: boolean | string
}

/** Normalized chat response (non-streaming) */
export interface LLMChatResponse {
  model: string
  message: {
    role: string
    content: string
  }
  done: boolean
}

/** Normalized streaming chunk — matches Ollama's format so the frontend doesn't need changes */
export interface LLMStreamChunk {
  model: string
  message?: {
    role: string
    content: string
  }
  done: boolean
}

/** Normalized model info returned by list endpoints */
export interface LLMModelInfo {
  name: string
  model?: string
  size: number
  digest?: string
  modified_at?: string
  details?: Record<string, any>
}

/** Normalized model details */
export interface LLMModelDetails {
  capabilities: string[]
  [key: string]: any
}

/** Normalized embedding response */
export interface LLMEmbedResponse {
  embeddings: number[][]
}

/** Progress info for model downloads */
export interface LLMDownloadProgress {
  status: string
  completed?: number
  total?: number
}
