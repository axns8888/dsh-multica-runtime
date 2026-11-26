import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { readFile } from 'node:fs/promises'
import { join, basename, dirname } from 'node:path'
import type { Context } from '@deepseek-ai/cordis'
import { ModelSync, canonical, fingerprint, type Providers, type Observation, type SourceGroup, type SyncAdapter } from './model-sync.js'

interface EntryOptions {
  id?: string; name?: string; disabled?: boolean; group?: boolean; config?: Record<string, unknown> | EntryOptions[]
}
interface Profile {
  dir: string; patchPath: string; patches: unknown[]
  layers: Array<{ patchPaths: string[]; packageDir: string; patches: unknown[] }>
  skippedBundles: unknown[]
}
interface Boot {
  loadProfile(name: string, profile: string, anchor: string, home: string): Profile
  createRuntimeResolution(options: { installAnchor: string; profile: Profile; home: string }): Promise<{
    entries: Array<{ name: string; packageDir: string; version?: string }>
  }>
  loadOptionalPatches(name: string, path: string): unknown[] | undefined
  composeEntries(layers: unknown[][]): EntryOptions[]
}
export interface SyncPolicy {
  schema: 1
  sources: Array<{ profile: string; enabled: boolean; providers?: string[] }>
}
interface LoaderEntry {
  options: EntryOptions
  disabled?: boolean
  update(options: { config: unknown }): Promise<void>
  fiber?: { resolveConfig(config: unknown): unknown }
}
interface Host {
  profileContext: { dir: string; name: string; installAnchor: string; home: string }
  loader: { await(): Promise<void>; entries(): Iterable<LoaderEntry> }
  get(name: 'credentials'): { resolve(ref: string): Promise<{ value?: string } | undefined> } | undefined
  llm: { listProviders(): Array<{ id: string }>; resolveModelInfo(provider: string, model: string): Promise<unknown> }
}
const PI_AI = '@deepseek-ai/dsh-llm-pi-ai'
const MARKER = ' multica-model-sync:v1 (managed providers only)'
const safeName = (value: string): boolean => /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,99}$/.test(value)

export function validatePolicy(value: unknown): SyncPolicy {
  const p = value as SyncPolicy
  if (!p || p.schema !== 1 || !Array.isArray(p.sources) || p.sources.length === 0 || p.sources.length > 16
    || p.sources.some(s => !safeName(s.profile) || typeof s.enabled !== 'boolean'
      || (s.providers !== undefined && (!Array.isArray(s.providers) || s.providers.some(id => !safeName(id)))))
    || new Set(p.sources.map(s => s.profile)).size !== p.sources.length
    || Object.hasOwn(p, 'aliases')) {
    throw new Error('ACTIVE_SOURCE_REQUIRED')
  }
  return p
}
function flatten(entries: EntryOptions[], inheritedDisabled = false): EntryOptions[] {
  return entries.flatMap(entry => entry.group && Array.isArray(entry.config)
    ? flatten(entry.config, inheritedDisabled || entry.disabled === true)
    : [{ ...entry, disabled: inheritedDisabled || entry.disabled === true }])
}
function providerMap(entry: EntryOptions): Providers {
  const config = entry.config as { providers?: Providers } | undefined
  return structuredClone(config?.providers ?? {})
}

/** Uses the installation's own resolver and parser. No desktop/web/headless services are started. */
export async function createDshModelSync(context: Context): Promise<ModelSync | undefined> {
  const host = context as unknown as Host
  if (!host.profileContext) return undefined
  const { dir, installAnchor, home } = host.profileContext
  const policyPath = join(dir, '.model-sync', 'policy.json')
  const req = createRequire(installAnchor)
  let observation: Observation | undefined
  let preflight: ((providers: Providers, document: string) => void) | undefined
  let entryId: string | undefined
  const normalize = async (providers: Providers, packageDir: string): Promise<Providers> => {
    const plugin = await import(pathToFileURL(join(packageDir, 'lib', 'index.js')).href) as {
      Config(value: unknown): { providers: { get(): Providers } }
    }
    // Scalar defaults are canonicalized by the installed schema, never guessed from display names.
    return structuredClone(plugin.Config({ providers }).providers.get())
  }
  const adapter: SyncAdapter = {
    async observe() {
      const policyHash = await fingerprint(policyPath)
      let policy: SyncPolicy
      try { policy = validatePolicy(JSON.parse(await readFile(policyPath, 'utf8'))) }
      catch { throw new Error('ACTIVE_SOURCE_REQUIRED') }
      if (policy.sources.some(s => s.profile === basename(dir))) throw new Error('SOURCE_INVALID')
      const boot = await import(pathToFileURL(req.resolve('@deepseek-ai/dsh-app-boot')).href) as Boot
      const yaml = await import(pathToFileURL(req.resolve('yaml')).href)
      const files: Record<string, string | null> = {}
      const capture = async (file: string): Promise<void> => {
        // Capture before parsing, then compare again after the full snapshot. Never mix revisions.
        const hash = await fingerprint(file)
        if (Object.hasOwn(files, file) && files[file] !== hash) throw new Error('REVISION_CHANGED')
        files[file] = hash
      }
      await capture(policyPath)
      if (files[policyPath] !== policyHash) throw new Error('REVISION_CHANGED')
      const homePatch = join(home, 'cordis.patch.yml')
      await capture(homePatch)
      const homeLayers = boot.loadOptionalPatches('dsh', homePatch) ?? []
      const load = async (name: string): Promise<{ profile: Profile; entries: EntryOptions[]; pluginDir: string }> => {
        const profileDir = join(home, 'profiles', name)
        await capture(join(profileDir, 'package.json'))
        await capture(join(profileDir, 'cordis.patch.yml'))
        if (files[join(profileDir, 'package.json')] === null || files[join(profileDir, 'cordis.patch.yml')] === null) {
          throw new Error('SOURCE_MISSING')
        }
        const profile = boot.loadProfile('dsh', name, installAnchor, home)
        if (profile.skippedBundles.length) throw new Error('SOURCE_INVALID')
        for (const layer of profile.layers) {
          await capture(join(layer.packageDir, 'package.json'))
          for (const path of layer.patchPaths) await capture(path)
        }
        const resolution = await boot.createRuntimeResolution({ installAnchor, profile, home })
        const plugin = resolution.entries.find(e => e.name === PI_AI)
        if (!plugin) throw new Error('SOURCE_INVALID')
        await capture(join(plugin.packageDir, 'package.json'))
        const entries = flatten(boot.composeEntries([...profile.layers.map(l => l.patches), profile.patches, homeLayers]))
        return { profile, entries, pluginDir: plugin.packageDir }
      }
      const target = await load(basename(dir))
      const targetRows = target.entries.filter(e => e.name === PI_AI)
      if (targetRows.length !== 1 || targetRows[0]!.disabled) throw new Error('SOURCE_INVALID')
      entryId = targetRows[0]!.id
      if (!entryId) throw new Error('SOURCE_INVALID')
      const targetProviders = await normalize(providerMap(targetRows[0]!), target.pluginDir)
      const sources: SourceGroup[] = []
      for (const source of policy.sources.filter(s => s.enabled)) {
        const parsed = await load(source.profile)
        if (parsed.pluginDir !== target.pluginDir) throw new Error('SOURCE_INVALID')
        for (const row of parsed.entries.filter(e => e.name === PI_AI)) {
          const providers = await normalize(providerMap(row), parsed.pluginDir)
          for (const [id, config] of Object.entries(providers)) {
            const selected = source.providers === undefined || source.providers.includes(id)
            // Presence in an old profile is insufficient: selected source + usable credential seam required.
            // Explicit disabled rows remain authoritative even if credentials were removed.
            const ref = config.apiKeyEnv
            const serviceable = ref === undefined || (typeof ref === 'string'
              && !!(await host.get('credentials')?.resolve(ref))?.value)
            sources.push({ provider: id, config,
              enabled: !row.disabled, active: selected && (!!row.disabled || serviceable) })
          }
        }
      }
      for (const [file, hash] of Object.entries(files)) if (await fingerprint(file) !== hash) throw new Error('REVISION_CHANGED')
      const targetPath = join(dir, 'cordis.patch.yml')
      const raw = await readFile(targetPath, 'utf8')
      if (await fingerprint(targetPath) !== files[targetPath]) throw new Error('REVISION_CHANGED')
      const patch = (providers: Providers) => ({ id: entryId, config: { providers } })
      preflight = (providers, document) => {
        const effective = flatten(boot.composeEntries([
          ...target.profile.layers.map(l => l.patches), yaml.parse(document), homeLayers,
        ])).find(e => e.id === entryId)
        if (!effective || canonical(providerMap(effective)) !== canonical(providers)) throw new Error('SCHEMA_INVALID')
      }
      observation = {
        sources, target: targetProviders, files,
        render(providers) {
          const document = yaml.parseDocument(raw, { keepSourceTokens: true })
          if (document.errors.length || !yaml.isSeq(document.contents)) throw new Error('SCHEMA_INVALID')
          const items = document.contents.items as Array<{ commentBefore?: string }>
          if (items.filter(item => item?.commentBefore === MARKER).length > 1) throw new Error('SCHEMA_INVALID')
          document.contents.items = items.filter(item => item?.commentBefore !== MARKER)
          let replaced = false
          const rewrite = (sequence: { items: unknown[] }): void => {
            for (const item of sequence.items) {
              if (!yaml.isMap(item)) continue
              const row = item as { get(key: string): unknown }
              const insert = row.get('insert')
              if (yaml.isSeq(insert)) rewrite(insert as { items: unknown[] })
              const config = row.get('config') as { has(key: string): boolean; set(key: string, value: unknown): void }
              if (row.get('id') === entryId && yaml.isMap(config) && config.has('providers')) {
                config.set('providers', document.createNode(providers))
                replaced = true
              } else if (yaml.isSeq(config)) rewrite(config as unknown as { items: unknown[] })
            }
          }
          rewrite(document.contents)
          if (!replaced) {
            const node = document.createNode(patch(providers))
            node.commentBefore = MARKER
            document.contents.add(node)
          }
          return document.toString()
        },
      }
      return observation
    },
    async validate(providers, document) {
      preflight?.(providers, document)
      const entry = [...host.loader.entries()].find(e => e.options.id === entryId && e.options.name === PI_AI)
      if (!entry?.fiber?.resolveConfig) throw new Error('SCHEMA_INVALID')
      // The installed plugin's internal/config assertion checks model catalogs, protocols, and capabilities.
      // Resolve only: never mutate the running snapshot here, and never print validation exceptions.
      try { entry.fiber.resolveConfig({ providers }) } catch { throw new Error('SCHEMA_INVALID') }
    },
    async activate(providers) {
      const entry = [...host.loader.entries()].find(e => e.options.id === entryId && e.options.name === PI_AI)
      if (!entry) throw new Error('SCHEMA_INVALID')
      const previous = structuredClone(entry.options.config)
      try {
        await entry.update({ config: { providers } })
        await host.loader.await()
        // Loader volatile-update failures can be logged and swallowed; verify actual registry and descriptors.
        const routes = new Set(host.llm.listProviders().map(p => p.id))
        for (const [provider, config] of Object.entries(providers)) {
          if (!routes.has(provider)) throw new Error('SCHEMA_INVALID')
          for (const model of config.models ?? []) await host.llm.resolveModelInfo(provider, model.id)
        }
      } catch {
        await entry.update({ config: previous })
        throw new Error('SCHEMA_INVALID')
      }
    },
  }
  return new ModelSync(dir, adapter, status => {
    // The only public log is a fixed, bounded allowlist. No raw exception, endpoint, key, header, or secret hash.
    process.stderr.write(`multica-model-sync: ${JSON.stringify(status)}\n`)
  })
}

