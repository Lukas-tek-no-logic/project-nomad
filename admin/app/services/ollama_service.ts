import { inject } from '@adonisjs/core'
import type { ChatRequest } from 'ollama'
import { NomadOllamaModel } from '../../types/ollama.js'
import type { LLMBackendType } from '../../types/llm.js'
import { FALLBACK_RECOMMENDED_OLLAMA_MODELS } from '../../constants/ollama.js'
import fs from 'node:fs/promises'
import path from 'node:path'
import logger from '@adonisjs/core/services/logger'
import axios from 'axios'
import { DownloadModelJob } from '#jobs/download_model_job'
import { SERVICE_NAMES } from '../../constants/service_names.js'
import transmit from '@adonisjs/transmit/services/main'
import Fuse, { IFuseOptions } from 'fuse.js'
import { BROADCAST_CHANNELS } from '../../constants/broadcast.js'
import env from '#start/env'
import { NOMAD_API_DEFAULT_BASE_URL } from '../../constants/misc.js'
import { LLMProvider } from './llm/llm_provider.js'
import { OllamaProvider } from './llm/ollama_provider.js'
import { LlamaCppProvider } from './llm/llamacpp_provider.js'

const NOMAD_MODELS_API_PATH = '/api/v1/ollama/models'
const MODELS_CACHE_FILE = path.join(process.cwd(), 'storage', 'ollama-models-cache.json')
const CACHE_MAX_AGE_MS = 24 * 60 * 60 * 1000 // 24 hours

@inject()
export class OllamaService {
  private provider: LLMProvider | null = null
  private providerInitPromise: Promise<void> | null = null

  constructor() {}

  /**
   * Determines which LLM backend to use and its URL.
   *
   * Resolution order:
   *   1. LLM_BACKEND_TYPE + LLM_REMOTE_URL env vars  (explicit remote config)
   *   2. OLLAMA_REMOTE_URL env var                    (shorthand for remote Ollama)
   *   3. Docker service discovery                     (default — local container)
   */
  private async _initializeProvider() {
    if (!this.providerInitPromise) {
      this.providerInitPromise = (async () => {
        const backendType = (process.env.LLM_BACKEND_TYPE as LLMBackendType) || 'ollama'
        const remoteUrl = process.env.LLM_REMOTE_URL || process.env.OLLAMA_REMOTE_URL

        if (remoteUrl) {
          logger.info(`[OllamaService] Using remote ${backendType} backend at ${remoteUrl}`)
          this.provider = this._createProvider(backendType, remoteUrl)
          return
        }

        // Fall back to Docker service discovery (original behavior)
        const dockerService = new (await import('./docker_service.js')).DockerService()
        const serviceUrl = await dockerService.getServiceURL(SERVICE_NAMES.OLLAMA)
        if (!serviceUrl) {
          throw new Error('LLM service is not installed or running. Set LLM_REMOTE_URL to use a remote server.')
        }
        logger.info(`[OllamaService] Using Docker-managed ${backendType} backend at ${serviceUrl}`)
        this.provider = this._createProvider(backendType, serviceUrl)
      })()
    }
    return this.providerInitPromise
  }

  private _createProvider(type: LLMBackendType, url: string): LLMProvider {
    switch (type) {
      case 'llamacpp':
        return new LlamaCppProvider(url)
      case 'ollama':
      default:
        return new OllamaProvider(url)
    }
  }

  private async _ensureDependencies() {
    if (!this.provider) {
      await this._initializeProvider()
    }
  }

  /** Returns the current backend type */
  public getBackendType(): LLMBackendType {
    return (process.env.LLM_BACKEND_TYPE as LLMBackendType) || 'ollama'
  }

  /** Returns true if using a remote (non-Docker) backend */
  public isRemoteBackend(): boolean {
    return !!(process.env.LLM_REMOTE_URL || process.env.OLLAMA_REMOTE_URL)
  }

  /**
   * Downloads a model from the LLM backend with progress tracking.
   * For llama.cpp this is a no-op since models are loaded at server startup.
   */
  async downloadModel(model: string, progressCallback?: (percent: number) => void): Promise<{ success: boolean; message: string }> {
    try {
      await this._ensureDependencies()
      if (!this.provider) {
        throw new Error('LLM provider is not initialized.')
      }

      // For llama.cpp, model management is external
      if (this.getBackendType() === 'llamacpp') {
        logger.info(`[OllamaService] Model download skipped for llama.cpp backend — models are loaded at server startup.`)
        return { success: true, message: 'llama.cpp models are managed externally. Load models via server startup flags.' }
      }

      // Check if model is already installed
      const installedModels = await this.getModels()
      if (installedModels && installedModels.some((m) => m.name === model)) {
        logger.info(`[OllamaService] Model "${model}" is already installed.`)
        return { success: true, message: 'Model is already installed.' }
      }

      const downloadStream = await this.provider.pullModel(model)

      for await (const chunk of downloadStream) {
        if (chunk.completed && chunk.total) {
          const percent = ((chunk.completed / chunk.total) * 100).toFixed(2)
          const percentNum = parseFloat(percent)

          this.broadcastDownloadProgress(model, percentNum)
          if (progressCallback) {
            progressCallback(percentNum)
          }
        }
      }

      logger.info(`[OllamaService] Model "${model}" downloaded successfully.`)
      return { success: true, message: 'Model downloaded successfully.' }
    } catch (error) {
      logger.error(
        `[OllamaService] Failed to download model "${model}": ${error instanceof Error ? error.message : error}`
      )
      return { success: false, message: 'Failed to download model.' }
    }
  }

  async dispatchModelDownload(modelName: string): Promise<{ success: boolean; message: string }> {
    // For llama.cpp, model management is external
    if (this.getBackendType() === 'llamacpp') {
      return {
        success: true,
        message: 'llama.cpp models are managed externally. Load models via server startup flags (--model / -m).',
      }
    }

    try {
      logger.info(`[OllamaService] Dispatching model download for ${modelName} via job queue`)

      await DownloadModelJob.dispatch({
        modelName,
      })

      return {
        success: true,
        message:
          'Model download has been queued successfully. It will start shortly after Ollama and Open WebUI are ready (if not already).',
      }
    } catch (error) {
      logger.error(
        `[OllamaService] Failed to dispatch model download for ${modelName}: ${error instanceof Error ? error.message : error}`
      )
      return {
        success: false,
        message: 'Failed to queue model download. Please try again.',
      }
    }
  }

  /**
   * Returns the underlying LLM provider.
   * Prefer using the typed methods on OllamaService instead of accessing the provider directly.
   */
  public async getProvider(): Promise<LLMProvider> {
    await this._ensureDependencies()
    return this.provider!
  }

  /**
   * @deprecated Use getProvider() for new code. Kept for backwards compatibility with RAG service.
   * For Ollama backends, returns the raw Ollama client. For llama.cpp, returns a compatibility shim.
   */
  public async getClient(): Promise<any> {
    await this._ensureDependencies()

    if (this.provider instanceof OllamaProvider) {
      return (this.provider as OllamaProvider).getRawClient()
    }

    // For non-Ollama backends, return a compatibility shim that matches the Ollama client API
    // used by RagService (embed method)
    const provider = this.provider!
    return {
      embed: async (params: { model: string; input: string | string[] }) => {
        return provider.embed(params.model, params.input)
      },
    }
  }

  public async chat(chatRequest: ChatRequest & { stream?: boolean; think?: boolean | string }) {
    await this._ensureDependencies()
    if (!this.provider) {
      throw new Error('LLM provider is not initialized.')
    }
    const messages = (chatRequest.messages || []).map((m) => ({
      role: m.role as 'system' | 'user' | 'assistant',
      content: m.content,
    }))
    return await this.provider.chat({
      model: chatRequest.model,
      messages,
      stream: false,
      think: chatRequest.think,
    })
  }

  public async chatStream(chatRequest: ChatRequest & { think?: boolean | string }) {
    await this._ensureDependencies()
    if (!this.provider) {
      throw new Error('LLM provider is not initialized.')
    }
    const messages = (chatRequest.messages || []).map((m) => ({
      role: m.role as 'system' | 'user' | 'assistant',
      content: m.content,
    }))
    return await this.provider.chatStream({
      model: chatRequest.model,
      messages,
      stream: true,
      think: chatRequest.think,
    })
  }

  public async checkModelHasThinking(modelName: string): Promise<boolean> {
    await this._ensureDependencies()
    if (!this.provider) {
      throw new Error('LLM provider is not initialized.')
    }

    try {
      const modelInfo = await this.provider.showModel(modelName)
      return modelInfo.capabilities.includes('thinking')
    } catch {
      // llama.cpp and some setups may not support model introspection
      return false
    }
  }

  public async deleteModel(modelName: string) {
    await this._ensureDependencies()
    if (!this.provider) {
      throw new Error('LLM provider is not initialized.')
    }

    return await this.provider.deleteModel(modelName)
  }

  public async getModels(includeEmbeddings = false) {
    await this._ensureDependencies()
    if (!this.provider) {
      throw new Error('LLM provider is not initialized.')
    }
    const models = await this.provider.listModels()
    if (includeEmbeddings) {
      return models
    }
    // Filter out embedding models
    return models.filter((model) => !model.name.includes('embed'))
  }

  async getAvailableModels(
    { sort, recommendedOnly, query, limit, force }: { sort?: 'pulls' | 'name'; recommendedOnly?: boolean, query: string | null, limit?: number, force?: boolean } = {
      sort: 'pulls',
      recommendedOnly: false,
      query: null,
      limit: 15,
    }
  ): Promise<{ models: NomadOllamaModel[], hasMore: boolean } | null> {
    try {
      const models = await this.retrieveAndRefreshModels(sort, force)
      if (!models) {
        // If we fail to get models from the API, return the fallback recommended models
        logger.warn(
          '[OllamaService] Returning fallback recommended models due to failure in fetching available models'
        )
        return {
          models: FALLBACK_RECOMMENDED_OLLAMA_MODELS,
          hasMore: false
        }
      }

      if (!recommendedOnly) {
        const filteredModels = query ? this.fuseSearchModels(models, query) : models
        return {
          models: filteredModels.slice(0, limit || 15),
          hasMore: filteredModels.length > (limit || 15)
        }
      }

      // If recommendedOnly is true, only return the first three models (if sorted by pulls, these will be the top 3)
      const sortedByPulls = sort === 'pulls' ? models : this.sortModels(models, 'pulls')
      const firstThree = sortedByPulls.slice(0, 3)

      // Only return the first tag of each of these models (should be the most lightweight variant)
      const recommendedModels = firstThree.map((model) => {
        return {
          ...model,
          tags: model.tags && model.tags.length > 0 ? [model.tags[0]] : [],
        }
      })

      if (query) {
        const filteredRecommendedModels = this.fuseSearchModels(recommendedModels, query)
        return {
          models: filteredRecommendedModels,
          hasMore: filteredRecommendedModels.length > (limit || 15)
        }
      }

      return {
        models: recommendedModels,
        hasMore: recommendedModels.length > (limit || 15)
      }
    } catch (error) {
      logger.error(
        `[OllamaService] Failed to get available models: ${error instanceof Error ? error.message : error}`
      )
      return null
    }
  }

  private async retrieveAndRefreshModels(
    sort?: 'pulls' | 'name',
    force?: boolean
  ): Promise<NomadOllamaModel[] | null> {
    try {
      if (!force) {
        const cachedModels = await this.readModelsFromCache()
        if (cachedModels) {
          logger.info('[OllamaService] Using cached available models data')
          return this.sortModels(cachedModels, sort)
        }
      } else {
        logger.info('[OllamaService] Force refresh requested, bypassing cache')
      }

      logger.info('[OllamaService] Fetching fresh available models from API')

      const baseUrl = env.get('NOMAD_API_URL') || NOMAD_API_DEFAULT_BASE_URL
      const fullUrl = new URL(NOMAD_MODELS_API_PATH, baseUrl).toString()

      const response = await axios.get(fullUrl)
      if (!response.data || !Array.isArray(response.data.models)) {
        logger.warn(
          `[OllamaService] Invalid response format when fetching available models: ${JSON.stringify(response.data)}`
        )
        return null
      }

      const rawModels = response.data.models as NomadOllamaModel[]

      // Filter out tags where cloud is truthy, then remove models with no remaining tags
      const noCloud = rawModels
        .map((model) => ({
          ...model,
          tags: model.tags.filter((tag) => !tag.cloud),
        }))
        .filter((model) => model.tags.length > 0)

      await this.writeModelsToCache(noCloud)
      return this.sortModels(noCloud, sort)
    } catch (error) {
      logger.error(
        `[OllamaService] Failed to retrieve models from Nomad API: ${error instanceof Error ? error.message : error
        }`
      )
      return null
    }
  }

  private async readModelsFromCache(): Promise<NomadOllamaModel[] | null> {
    try {
      const stats = await fs.stat(MODELS_CACHE_FILE)
      const cacheAge = Date.now() - stats.mtimeMs

      if (cacheAge > CACHE_MAX_AGE_MS) {
        logger.info('[OllamaService] Cache is stale, will fetch fresh data')
        return null
      }

      const cacheData = await fs.readFile(MODELS_CACHE_FILE, 'utf-8')
      const models = JSON.parse(cacheData) as NomadOllamaModel[]

      if (!Array.isArray(models)) {
        logger.warn('[OllamaService] Invalid cache format, will fetch fresh data')
        return null
      }

      return models
    } catch (error) {
      // Cache doesn't exist or is invalid
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
        logger.warn(
          `[OllamaService] Error reading cache: ${error instanceof Error ? error.message : error}`
        )
      }
      return null
    }
  }

  private async writeModelsToCache(models: NomadOllamaModel[]): Promise<void> {
    try {
      await fs.mkdir(path.dirname(MODELS_CACHE_FILE), { recursive: true })
      await fs.writeFile(MODELS_CACHE_FILE, JSON.stringify(models, null, 2), 'utf-8')
      logger.info('[OllamaService] Successfully cached available models')
    } catch (error) {
      logger.warn(
        `[OllamaService] Failed to write models cache: ${error instanceof Error ? error.message : error}`
      )
    }
  }

  private sortModels(models: NomadOllamaModel[], sort?: 'pulls' | 'name'): NomadOllamaModel[] {
    if (sort === 'pulls') {
      // Sort by estimated pulls (it should be a string like "1.2K", "500", "4M" etc.)
      models.sort((a, b) => {
        const parsePulls = (pulls: string) => {
          const multiplier = pulls.endsWith('K')
            ? 1_000
            : pulls.endsWith('M')
              ? 1_000_000
              : pulls.endsWith('B')
                ? 1_000_000_000
                : 1
          return parseFloat(pulls) * multiplier
        }
        return parsePulls(b.estimated_pulls) - parsePulls(a.estimated_pulls)
      })
    } else if (sort === 'name') {
      models.sort((a, b) => a.name.localeCompare(b.name))
    }

    // Always sort model.tags by the size field in descending order
    // Size is a string like '75GB', '8.5GB', '2GB' etc. Smaller models first
    models.forEach((model) => {
      if (model.tags && Array.isArray(model.tags)) {
        model.tags.sort((a, b) => {
          const parseSize = (size: string) => {
            const multiplier = size.endsWith('KB')
              ? 1 / 1_000
              : size.endsWith('MB')
                ? 1 / 1_000_000
                : size.endsWith('GB')
                  ? 1
                  : size.endsWith('TB')
                    ? 1_000
                    : 0 // Unknown size format
            return parseFloat(size) * multiplier
          }
          return parseSize(a.size) - parseSize(b.size)
        })
      }
    })

    return models
  }

  private broadcastDownloadProgress(model: string, percent: number) {
    transmit.broadcast(BROADCAST_CHANNELS.OLLAMA_MODEL_DOWNLOAD, {
      model,
      percent,
      timestamp: new Date().toISOString(),
    })
    logger.info(`[OllamaService] Download progress for model "${model}": ${percent}%`)
  }

  private fuseSearchModels(models: NomadOllamaModel[], query: string): NomadOllamaModel[] {
    const options: IFuseOptions<NomadOllamaModel> = {
      ignoreDiacritics: true,
      keys: ['name', 'description', 'tags.name'],
      threshold: 0.3, // lower threshold for stricter matching
    }

    const fuse = new Fuse(models, options)

    return fuse.search(query).map(result => result.item)
  }
}
