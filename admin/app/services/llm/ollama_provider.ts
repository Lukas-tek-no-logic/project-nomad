import { Ollama } from 'ollama'
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
 * Ollama backend provider.
 * Wraps the official `ollama` npm package.
 */
export class OllamaProvider extends LLMProvider {
  private client: Ollama

  constructor(host: string) {
    super(host)
    this.client = new Ollama({ host })
    logger.info(`[OllamaProvider] Initialized with host: ${host}`)
  }

  async chat(request: LLMChatRequest): Promise<LLMChatResponse> {
    const think = request.think as boolean | 'high' | 'medium' | 'low' | undefined
    const response = await this.client.chat({
      model: request.model,
      messages: request.messages,
      stream: false as const,
      ...(think !== undefined && { think }),
    })
    return {
      model: response.model,
      message: {
        role: response.message.role,
        content: response.message.content,
      },
      done: true,
    }
  }

  async chatStream(request: LLMChatRequest): Promise<AsyncIterable<LLMStreamChunk>> {
    const think = request.think as boolean | 'high' | 'medium' | 'low' | undefined
    const stream = await this.client.chat({
      model: request.model,
      messages: request.messages,
      stream: true as const,
      ...(think !== undefined && { think }),
    })

    // The ollama library returns an AbortableAsyncIterator which is already AsyncIterable
    return stream as AsyncIterable<LLMStreamChunk>
  }

  async listModels(): Promise<LLMModelInfo[]> {
    const response = await this.client.list()
    return response.models.map((m) => ({
      name: m.name,
      model: m.model,
      size: m.size,
      digest: m.digest,
      modified_at: m.modified_at?.toString(),
      details: m.details as Record<string, any>,
    }))
  }

  async showModel(name: string): Promise<LLMModelDetails> {
    const info = await this.client.show({ model: name })
    return {
      ...info,
      capabilities: info.capabilities || [],
    }
  }

  async pullModel(name: string): Promise<AsyncIterable<LLMDownloadProgress>> {
    const stream = await this.client.pull({ model: name, stream: true })
    return stream as AsyncIterable<LLMDownloadProgress>
  }

  async deleteModel(name: string): Promise<void> {
    await this.client.delete({ model: name })
  }

  async embed(model: string, input: string | string[]): Promise<LLMEmbedResponse> {
    const inputArray = Array.isArray(input) ? input : [input]
    const response = await this.client.embed({ model, input: inputArray })
    return { embeddings: response.embeddings }
  }

  async healthCheck(): Promise<boolean> {
    try {
      await this.client.list()
      return true
    } catch {
      return false
    }
  }

  /** Expose the raw Ollama client for any edge cases that need direct access */
  getRawClient(): Ollama {
    return this.client
  }
}
