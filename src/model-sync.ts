import { createHash, randomUUID } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { watch, type FSWatcher } from 'node:fs'
import { mkdir, readFile, writeFile, rename, unlink, open, lstat } from 'node:fs/promises'
import { dirname, join, resolve, parse } from 'node:path'

export type Provider = Record<string, unknown> & { models?: Array<Record<string, unknown> & { id: string }> }
export type Providers = Record<string, Provider>
export interface SourceGroup { provider: string; config: Provider; enabled: boolean; active: boolean }
export interface Observation {
  sources: SourceGroup[]
  target: Providers
  /** Hashes stay local; never include these in a public diagnostic. */
  files: Record<string, string | null>
  render(providers: Providers): string
}
export interface SyncAdapter {
  observe(): Promise<Observation>
  /** Offline schema and exact directory/selection configuration check, no inference. */
  validate(providers: Providers, document: string): Promise<void>
  /** Update the existing LLM plugin, never a separate adapter or runner. */
  activate(providers: Providers): Promise<void>
}
export interface SyncState {
  schema: 1
  revision: string
  managed: Providers
  disabled: string[]
  updatedAt: string
}
export interface SyncStatus {
  enabled: boolean
  revision?: string
  lastSuccess?: string
  nextCheck?: string
  changed: number
  conflicts: number
  drift: number
  stale: number
  failures: number
  deletionPreview: number
  inactive: number
  removed: number
  pinned: boolean
  localCatalogGeneration?: string
  platformRefresh: 'unsupported'
  code?: string
}
export interface MergeResult {
  providers: Providers; managed: Providers; disabled: string[]
  changed: number; conflicts: number; drift: number; deletionPreview: number; inactive: number; removed: number
}

export function canonical(value: unknown): string {
  if (Array.isArray(value)) return JSON.stringify(value.map(item => JSON.parse(canonical(item))))
  if (value !== null && typeof value === 'object') {
    return JSON.stringify(Object.fromEntries(Object.entries(value).filter(([, v]) => v !== undefined)
      .sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => [k, JSON.parse(canonical(v))])))
  }
  return JSON.stringify(value) ?? 'null'
}
export function digest(value: string): string { return createHash('sha256').update(value).digest('hex') }
function same(a: unknown, b: unknown): boolean { return canonical(a) === canonical(b) }
function normalized(p: Provider): Provider {
  const result = structuredClone(p)
  if (result.models) {
    const seen = new Map<string, unknown>()
    for (const model of result.models) {
      if (seen.has(model.id) && !same(seen.get(model.id), model)) throw new Error('MODEL_CONFLICT')
      seen.set(model.id, model)
    }
    result.models = [...seen.values()] as Provider['models']
    result.models!.sort((a, b) => a.id.localeCompare(b.id))
  }
  if (result.headers && typeof result.headers === 'object') {
    const headers: Record<string, unknown> = {}
    for (const [name, value] of Object.entries(result.headers)) {
      const key = name.toLowerCase()
      if (Object.hasOwn(headers, key) && !same(headers[key], value)) throw new Error('HEADER_CONFLICT')
      headers[key] = value
    }
    result.headers = headers
  }
  return result
}

/** A group is the conflict boundary: never combine credentials from one route with another model set. */
export function reconcileGroups(sources: SourceGroup[], target: Providers, baseline: Providers, previouslyDisabled: string[] = []): MergeResult {
  const providers = structuredClone(target)
  const managed = structuredClone(baseline)
  const grouped = new Map<string, SourceGroup[]>()
  let inactive = 0
  for (const source of sources) {
    if (!source.active) { inactive++; continue }
    grouped.set(source.provider, [...grouped.get(source.provider) ?? [], source])
  }
  let changed = 0, conflicts = 0, drift = 0, deletionPreview = 0, removed = 0
  const disabled = previouslyDisabled.filter(key => !grouped.has(key))
  for (const [key, group] of grouped) {
    let first: Provider
    try { first = normalized(group[0]!.config) } catch { conflicts++; continue }
    if (group.some(item => {
      try { return item.enabled !== group[0]!.enabled || !same(normalized(item.config), first) } catch { return true }
    })) { conflicts++; continue }
    let current: Provider | undefined, prior: Provider | undefined
    try {
      current = target[key] === undefined ? undefined : normalized(target[key]!)
      prior = baseline[key] === undefined ? undefined : normalized(baseline[key]!)
    } catch { conflicts++; drift++; continue }
    // A manual deletion is target drift as well. Do not recreate it behind the editor's back.
    if (prior !== undefined && current === undefined) { conflicts++; drift++; continue }
    if (!group[0]!.enabled) {
      disabled.push(key)
      if (current !== undefined && prior !== undefined && same(current, prior)) {
        delete providers[key]; delete managed[key]; changed++; removed += current.models?.length ?? 1
      } else if (current !== undefined) { drift++; conflicts++ }
      continue
    }
    // Successful reads of a selected current source are authoritative only for our owned fields.
    // Unknown target edits remain conflicts; a read failure never reaches this merge.
    if (same(current, first)) {
      // An identical existing route is not proof of ownership. Only prior managed data may be deleted later.
      if (prior !== undefined) managed[key] = first
      else deletionPreview += current?.models?.length ?? 1
      continue
    }
    if (current !== undefined && (prior === undefined || !same(current, prior))) {
      drift++; conflicts++; continue
    }
    if (current?.models && first.models) {
      const ids = new Set(first.models.map(model => model.id))
      removed += current.models.filter(model => !ids.has(model.id)).length
    }
    providers[key] = first; managed[key] = first; changed++
  }
  const observed = new Set(sources.map(source => source.provider))
  for (const [key, value] of Object.entries(target)) {
    if (grouped.has(key)) continue
    const prior = baseline[key]
    if (prior && !observed.has(key)) {
      let unchanged = false
      try { unchanged = same(normalized(value), normalized(prior)) } catch { /* isolate malformed target group */ }
      if (unchanged) {
        delete providers[key]; delete managed[key]; disabled.push(key)
        changed++; removed += value.models?.length ?? 1
      } else { drift++; conflicts++ }
    } else deletionPreview += value.models?.length ?? 1
  }
  return { providers, managed, disabled, changed, conflicts, drift, deletionPreview, inactive, removed }

}

async function text(path: string): Promise<string | undefined> {
  try { return await readFile(path, 'utf8') } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined
    throw new Error('READ_FAILED')
  }
}
export async function fingerprint(path: string): Promise<string | null> {
  const value = await text(path)
  return value === undefined ? null : digest(value)
}
export async function assertUnlinked(path: string): Promise<void> {
  let current = resolve(path)
  while (current !== parse(current).root) {
    try { if ((await lstat(current)).isSymbolicLink()) throw new Error('LINKED_PATH') }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw new Error('UNSAFE_PATH') }
    current = dirname(current)
  }
}
/** Nothing sensitive is written until the newly created directory's inheritance is removed. */
async function privateDirectory(path: string): Promise<void> {
  await assertUnlinked(path)
  await mkdir(path, { recursive: true, mode: 0o700 })
  if (process.platform === 'win32') {
    const identity = execFileSync('whoami.exe', ['/user', '/fo', 'csv', '/nh'], { encoding: 'utf8', windowsHide: true })
    const sid = identity.match(/S-1-(?:\d+-)+\d+/)?.[0]
    if (!sid) throw new Error('ACL_UNAVAILABLE')
    execFileSync('icacls.exe', [path, '/inheritance:r', '/grant:r', `*${sid}:(OI)(CI)F`],
      { stdio: 'pipe', windowsHide: true })
  }
}
async function atomic(path: string, value: string, stagingDirectory = dirname(path)): Promise<void> {
  await assertUnlinked(path)
  const temporary = join(stagingDirectory, `.model-sync-${randomUUID()}.tmp`)
  const handle = await open(temporary, 'wx', 0o600)
  try { await handle.writeFile(value, 'utf8'); await handle.sync() } finally { await handle.close() }
  try { await rename(temporary, path) } finally { await unlink(temporary).catch(() => {}) }
}
interface Transaction {
  schema: 1; revision: string; before: string; after: string
  previous: SyncState | null; next: SyncState | null
}

export class ModelSync {
  readonly directory: string
  readonly target: string
  private state?: SyncState
  private pinned = false
  private disposed = false
  private watchers: FSWatcher[] = []
  private observedFiles: string[] = []
  private debounce?: NodeJS.Timeout
  private timer?: NodeJS.Timeout
  private tail: Promise<unknown> = Promise.resolve()
  private statusValue: SyncStatus = {
    enabled: false, changed: 0, conflicts: 0, drift: 0, stale: 0, failures: 0,
    deletionPreview: 0, inactive: 0, removed: 0, pinned: false, platformRefresh: 'unsupported',
  }
  constructor(readonly profileDirectory: string, readonly adapter: SyncAdapter,
    readonly notify: (status: SyncStatus) => void = () => {}, readonly periodMs = 60_000, readonly debounceMs = 2_000, readonly directoryWatch: typeof watch = watch) {
    this.directory = join(profileDirectory, '.model-sync')
    this.target = join(profileDirectory, 'cordis.patch.yml')
  }
  status(): SyncStatus { return structuredClone(this.statusValue) }
  /** Exactly one execute per process: freeze the entire task at its boot revision. */
  async pin(): Promise<void> { this.pinned = true; this.statusValue.pinned = true; await this.tail }
  private async enabled(): Promise<boolean> {
    try { return JSON.parse(await text(join(this.directory, 'control.json')) ?? '{}').enabled === true }
    catch { throw new Error('CONTROL_INVALID') }
  }
  async control(enabled: boolean): Promise<void> {
    if (!enabled) this.stopWatching()
    const result = this.tail.then(async () => {
      await privateDirectory(this.directory)
      await this.exclusive(async () => {
        await atomic(join(this.directory, 'control.json'), JSON.stringify({ enabled }))
        this.statusValue.enabled = enabled
      })
    })
    this.tail = result.catch(() => {})
    await result
  }
  async loadStatus(): Promise<SyncStatus> {
    this.statusValue.enabled = await this.enabled()
    const stored = await text(join(this.directory, 'state.json'))
    if (stored !== undefined) {
      const state = this.parseState(stored)
      this.statusValue.revision = state.revision
      this.statusValue.lastSuccess = state.updatedAt
    }
    return this.status()
  }
  async disabledProviders(): Promise<Set<string>> {
    const stored = await text(join(this.directory, 'state.json'))
    return new Set(stored === undefined ? [] : this.parseState(stored).disabled)
  }
  private parseState(raw: string): SyncState {
    const state = JSON.parse(raw) as SyncState
    if (state.schema !== 1 || !/^[\da-f-]{36}$/.test(state.revision) || !state.managed || !Array.isArray(state.disabled)) {
      throw new Error('STATE_INVALID')
    }
    return state
  }
  private async exclusive<T>(operation: () => Promise<T>): Promise<T> {
    const lockPath = join(this.directory, 'writer.lock')
    await assertUnlinked(lockPath)
    const nonce = randomUUID()
    let lock
    try { lock = await open(lockPath, 'wx', 0o600) } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
      const guardPath = join(this.directory, 'recovery.lock')
      let guard
      try { guard = await open(guardPath, 'wx', 0o600) } catch { throw new Error('LOCK_BUSY') }
      try {
        const old = await text(lockPath)
        let owner: { pid: number }
        try { owner = JSON.parse(old ?? '') as { pid: number } } catch { throw new Error('LOCK_BUSY') }
        if (!Number.isInteger(owner.pid) || owner.pid <= 0) throw new Error('LOCK_BUSY')
        try { process.kill(owner.pid, 0); throw new Error('LOCK_BUSY') } catch (probe) {
          if ((probe as NodeJS.ErrnoException).code !== 'ESRCH') throw new Error('LOCK_BUSY')
        }
        if (await text(lockPath) !== old) throw new Error('LOCK_BUSY')
        await unlink(lockPath)
        lock = await open(lockPath, 'wx', 0o600)
      } finally { await guard.close(); await unlink(guardPath) }

    }
    try {
      await lock.writeFile(JSON.stringify({ pid: process.pid, nonce }))
      await this.recover()
      return await operation()
    } finally {
      await lock.close()
      const current = await text(lockPath)
      if (current && JSON.parse(current).nonce === nonce) await unlink(lockPath)
    }
  }
  private async recover(): Promise<void> {
    const journal = await text(join(this.directory, 'journal.json'))
    if (!journal) return
    const transaction = JSON.parse(journal) as Transaction
    if (transaction.schema !== 1 || !/^[\da-f-]{36}$/.test(transaction.revision)) throw new Error('JOURNAL_INVALID')
    const current = await text(this.target)
    if (current === transaction.after) {
      if (transaction.next) await atomic(join(this.directory, 'state.json'), JSON.stringify(transaction.next))
      else await unlink(join(this.directory, 'state.json')).catch(error => {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
      })
      await atomic(join(this.directory, 'catalog-generation.json'), JSON.stringify({ revision: transaction.revision }))
    } else if (current !== transaction.before) throw new Error('RECOVERY_DRIFT')
    await unlink(join(this.directory, 'journal.json'))
  }
  private async assertFiles(files: Record<string, string | null>): Promise<void> {
    const checks = await Promise.all(Object.entries(files).map(async ([path, hash]) => (await fingerprint(path)) === hash))
    if (checks.includes(false)) throw new Error('REVISION_CHANGED')
  }
  async reconcile(): Promise<SyncStatus> {
    const result = this.tail.then(() => this.perform())
    this.tail = result.catch(() => {})
    return result
  }
  private async perform(): Promise<SyncStatus> {
    let rollbackLive: Providers | undefined
    if (this.disposed) return this.status()
    try {
      this.statusValue.enabled = await this.enabled()
      if (!this.statusValue.enabled) { this.stopWatching(); return this.status() }
      await privateDirectory(this.directory)
      await this.exclusive(async () => {
        const before = await text(this.target)
        if (before === undefined) throw new Error('TARGET_MISSING')
        const controlHash = await fingerprint(join(this.directory, 'control.json'))
        const stored = await text(join(this.directory, 'state.json'))
        this.state = stored === undefined ? undefined : this.parseState(stored)
        const observation = await this.adapter.observe()
        await this.assertFiles(observation.files)
        if (observation.files[this.target] !== digest(before)) throw new Error('REVISION_CHANGED')
        this.observedFiles = Object.keys(observation.files)
        rollbackLive = observation.target
        const merge = reconcileGroups(observation.sources, observation.target, this.state?.managed ?? {}, this.state?.disabled ?? [])
        const document = observation.render(merge.providers)
        await this.adapter.validate(merge.providers, document)
        // Before committing files, prove the live catalog and execution registry accept the same snapshot.
        if (!this.pinned) await this.adapter.activate(merge.providers)
        // CAS includes source bundles/manifests, home layer, target and enable/disable control.
        await this.assertFiles({ ...observation.files, [join(this.directory, 'control.json')]: controlHash })
        const next: SyncState = {
          schema: 1, revision: this.state?.revision ?? randomUUID(), managed: merge.managed,
          disabled: merge.disabled, updatedAt: new Date().toISOString(),
        }
        if (document !== before || !same(this.state?.managed, merge.managed) || !same(this.state?.disabled, merge.disabled)) {
          next.revision = randomUUID()
          const transaction: Transaction = { schema: 1, revision: next.revision, before, after: document,
            previous: this.state ?? null, next }
          await privateDirectory(join(this.directory, 'history'))
          await atomic(join(this.directory, 'history', `${next.revision}.json`), JSON.stringify(transaction))
          await atomic(join(this.directory, 'journal.json'), JSON.stringify(transaction))
          // There is no filesystem CAS against arbitrary editors: recheck immediately before same-volume rename.
          await this.assertFiles({ ...observation.files, [join(this.directory, 'control.json')]: controlHash })
          if (document !== before) await atomic(this.target, document, this.directory)
          await atomic(join(this.directory, 'state.json'), JSON.stringify(next))
          await unlink(join(this.directory, 'journal.json'))
          await atomic(join(this.directory, 'catalog-generation.json'), JSON.stringify({ revision: next.revision }))
        }
        this.state = next
        this.statusValue = {
          ...this.statusValue, enabled: true, revision: next.revision, lastSuccess: next.updatedAt,
          changed: merge.changed, conflicts: merge.conflicts, drift: merge.drift,
          deletionPreview: merge.deletionPreview, inactive: merge.inactive, removed: merge.removed,
          localCatalogGeneration: next.revision, code: undefined,
        }
        if (this.watchers.length) this.armWatchers(Object.keys(observation.files))
      })
    } catch (error) {
      if (rollbackLive && !this.pinned) await this.adapter.activate(rollbackLive).catch(() => {})
      const known = new Set(['CONTROL_INVALID','STATE_INVALID','TARGET_MISSING','LOCK_BUSY','REVISION_CHANGED',
        'SOURCE_MISSING','SOURCE_INVALID','SCHEMA_INVALID','ACTIVE_SOURCE_REQUIRED','RECOVERY_DRIFT','UNSAFE_PATH'])
      const code = error instanceof Error && known.has(error.message) ? error.message : 'RECONCILE_FAILED'
      this.statusValue.failures++
      if (code === 'REVISION_CHANGED') this.statusValue.stale++
      this.statusValue.code = code
    }
    this.notify(this.status())
    return this.status()
  }
  /** Directory watches survive atomic file replacement; periodic reconciliation covers dropped events and new bundles. */
  private armWatchers(files: string[]): void {
    for (const watcher of this.watchers) watcher.close()
    this.watchers = []
    const directories = new Set([...files.map(dirname), this.directory])
    for (const directory of directories) {
      try {
        const watcher = this.directoryWatch(directory, { persistent: false }, (_event, filename) => {
          if (!filename || files.some(file => dirname(file) === directory && file.endsWith(String(filename)))
            || String(filename) === 'control.json') this.schedule()
        })
        watcher.on('error', () => { this.statusValue.stale++; watcher.close() })
        this.watchers.push(watcher)
      } catch { this.statusValue.stale++ }
    }
  }
  private schedule(): void {
    if (this.disposed) return
    clearTimeout(this.debounce)
    this.debounce = setTimeout(() => { void this.reconcile() }, this.debounceMs)
    this.debounce.unref()
  }
  async start(): Promise<SyncStatus> {
    const status = await this.reconcile()
    if (status.enabled) {
      // Includes the profile roots even if the first parse failed; timer repairs missing directories.
      this.armWatchers(this.observedFiles.length ? this.observedFiles : [this.target])
      this.timer = setInterval(() => {
        this.statusValue.nextCheck = new Date(Date.now() + this.periodMs).toISOString()
        void this.reconcile()
      }, this.periodMs)
      this.timer.unref()
      this.statusValue.nextCheck = new Date(Date.now() + this.periodMs).toISOString()
    }
    return this.status()
  }
  private stopWatching(): void {
    clearTimeout(this.debounce); clearInterval(this.timer)
    for (const watcher of this.watchers) watcher.close()
    this.watchers = []; this.statusValue.nextCheck = undefined
  }
  async dispose(): Promise<void> { this.disposed = true; this.stopWatching(); await this.tail }
  /** Rollback disables future reconciliation first, and refuses to overwrite any post-transaction manual edit. */
  async rollback(revision: string): Promise<SyncStatus> {
    if (!/^[\da-f-]{36}$/.test(revision)) throw new Error('REVISION_INVALID')
    await this.control(false)
    await this.exclusive(async () => {
      const raw = await text(join(this.directory, 'history', `${revision}.json`))
      if (!raw) throw new Error('REVISION_MISSING')
      const transaction = JSON.parse(raw) as Transaction
      if (transaction.schema !== 1 || transaction.revision !== revision) throw new Error('JOURNAL_INVALID')
      if (await text(this.target) !== transaction.after) throw new Error('ROLLBACK_DRIFT')
      const generation = randomUUID()
      // Journal rollback too: recovery can finish state/generation after the target rename.
      const reversal: Transaction = { schema: 1, revision: generation,
        before: transaction.after, after: transaction.before,
        previous: transaction.next, next: transaction.previous }
      await atomic(join(this.directory, 'journal.json'), JSON.stringify(reversal))
      await atomic(this.target, transaction.before, this.directory)
      if (transaction.previous) await atomic(join(this.directory, 'state.json'), JSON.stringify(transaction.previous))
      else await unlink(join(this.directory, 'state.json')).catch(() => {})
      await atomic(join(this.directory, 'catalog-generation.json'), JSON.stringify({ revision: generation }))
      await unlink(join(this.directory, 'journal.json'))
      this.statusValue.localCatalogGeneration = generation
      // Current process runs remain pinned. The next native process boots from the restored profile.
      this.statusValue.revision = transaction.previous?.revision
      this.statusValue.enabled = false
    })
    this.notify(this.status())
    return this.status()
  }
}
