import axios from 'axios'
import { LLMProvider } from './llm_provider.js'
import type {
  LLMChatRequest,
  LLMChatResponse,
  LLMStreamChunk,
  LLMModelInfo,
  LLMModelDetails,
  LLMEmbedResponse,
  LLMDownloadProgress,
} from '../../../types/llm.js'
import logger from '@adonisjs/core/services/logger'

/**
 * llama.cpp backend provider.
 * Communicates via the OpenAI-compatible API exposed by llama-server.
 *
 * Endpoints used:
 *   POST /v1/chat/completions  — chat (streaming & non-streaming)
 *   GET  /v1/models            — list loaded models
 *   POST /v1/embeddings        — generate embeddings
 *   GET  /health               — health check
 */
export class LlamaCppProvider extends LLMProvider {
  constructor(host: string) {
    super(host)
    logger.info(`[LlamaCppProvider] Initialized with host: ${host}`)
  }

  // ------------------------------------------------------------------ chat --

  async chat(request: LLMChatRequest): Promise<LLMChatResponse> {
    const response = await axios.post(
      `${this.host}/v1/chat/completions`,
      {
        model: request.model,
        messages: request.messages,
        stream: false,
      },
      { timeout: 300_000 }
    )

    const choice = response.data.choices?.[0]
    return {
      model: response.data.model || request.model,
      message: {
        role: choice?.message?.role || 'assistant',
        content: choice?.message?.content || '',
      },
      done: true,
    }
  }

  async chatStream(request: LLMChatRequest): Promise<AsyncIterable<LLMStreamChunk>> {
    const response = await axios.post(
      `${this.host}/v1/chat/completions`,
      {
        model: request.model,
        messages: request.messages,
        stream: true,
      },
      {
        responseType: 'stream',
        timeout: 300_000,
      }
    )

    const model = request.model
    const stream = response.data

    // Parse SSE stream and yield normalized chunks matching Ollama's format
    async function* parseSSE(): AsyncIterable<LLMStreamChunk> {
      let buffer = ''

      for await (const rawChunk of stream) {
        buffer += rawChunk.toString()

        const lines = buffer.split('\n')
        // Keep the last potentially incomplete line in the buffer
        buffer = lines.pop() || ''

        for (const line of lines) {
          const trimmed = line.trim()
          if (!trimmed || !trimmed.startsWith('data: ')) continue

          const data = trimmed.slice(6)
          if (data === '[DONE]') {
            yield { model, done: true }
            return
          }

          try {
            const parsed = JSON.parse(data)
            const delta = parsed.choices?.[0]?.delta
            const finishReason = parsed.choices?.[0]?.finish_reason

            if (delta?.content) {
              yield {
                model: parsed.model || model,
                message: {
                  role: delta.role || 'assistant',
                  content: delta.content,
                },
                done: false,
              }
            }

            if (finishReason === 'stop') {
              yield { model: parsed.model || model, done: true }
              return
            }
          } catch {
            // Skip malformed JSON lines
          }
        }
      }

      // Flush remaining buffer
      if (buffer.trim()) {
        const trimmed = buffer.trim()
        if (trimmed.startsWith('data: ') && trimmed.slice(6) !== '[DONE]') {
          try {
            const parsed = JSON.parse(trimmed.slice(6))
            const delta = parsed.choices?.[0]?.delta
            if (delta?.content) {
              yield {
                model: parsed.model || model,
                message: { role: 'assistant', content: delta.content },
                done: false,
              }
            }
          } catch {
            // Ignore
          }
        }
      }

      // Ensure we always emit a done signal
      yield { model, done: true }
    }

    return parseSSE()
  }

  // -------------------------------------------------------------- models --

  async listModels(): Promise<LLMModelInfo[]> {
    try {
      const response = await axios.get(`${this.host}/v1/models`, { timeout: 10_000 })
      const models = response.data.data || []

      return models.map((m: any) => ({
        name: m.id || m.model || 'default',
        model: m.id || m.model,
        size: 0, // llama.cpp doesn't report model size via API
        details: m,
      }))
    } catch (error) {
      logger.warn(`[LlamaCppProvider] Failed to list models: ${error instanceof Error ? error.message : error}`)
      // llama.cpp loads a single model at startup; if /v1/models fails, return a placeholder
      return [{ name: 'default', size: 0 }]
    }
  }

  async showModel(name: string): Promise<LLMModelDetails> {
    // llama.cpp doesn't have a model-details endpoint.
    // Return empty capabilities — callers should handle gracefully.
    const models = await this.listModels()
    const match = models.find((m) => m.name === name)
    return {
      capabilities: [],
      ...(match?.details || {}),
    }
  }

  // --------------------------------------------------- model management --

  async pullModel(_name: string): Promise<AsyncIterable<LLMDownloadProgress>> {
    // llama.cpp doesn't support pulling models via API.
    // Models are loaded at server startup via CLI args (--model / -m).
    logger.info('[LlamaCppProvider] pullModel is a no-op for llama.cpp — models are loaded at server startup.')

    async function* noop(): AsyncIterable<LLMDownloadProgress> {
      yield { status: 'success', completed: 1, total: 1 }
    }
    return noop()
  }

  async deleteModel(_name: string): Promise<void> {
    logger.info('[LlamaCppProvider] deleteModel is a no-op for llama.cpp — models are managed externally.')
  }

  // -------------------------------------------------------------- embed --

  async embed(model: string, input: string | string[]): Promise<LLMEmbedResponse> {
    const inputArray = Array.isArray(input) ? input : [input]

    const response = await axios.post(
      `${this.host}/v1/embeddings`,
      {
        model,
        input: inputArray,
      },
      { timeout: 120_000 }
    )

    // OpenAI format: { data: [{ embedding: number[] }, ...] }
    const data = response.data.data || []
    const embeddings = data.map((d: any) => d.embedding as number[])

    return { embeddings }
  }

  // -------------------------------------------------------- health check --

  async healthCheck(): Promise<boolean> {
    try {
      const response = await axios.get(`${this.host}/health`, { timeout: 5_000 })
      return response.status === 200
    } catch {
      return false
    }
  }
}
