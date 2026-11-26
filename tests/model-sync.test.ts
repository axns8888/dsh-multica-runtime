import { afterEach, describe, expect, it } from 'vitest'
import { mkdtemp, writeFile, readFile, mkdir, rename, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { ModelSync, canonical, fingerprint, reconcileGroups, type SyncAdapter, type Provider, type Providers, type SourceGroup } from '../src/model-sync.js'
import { validatePolicy } from '../src/model-sync-dsh.js'

const provider = (ids = ['model-a'], extra = {}) => ({ api: 'openai-completions', apiKeyEnv: 'TEST_REF', models: ids.map(id => ({ id, name: id })), ...extra })
const source = (id: string, config: Provider = provider(), extra = {}): SourceGroup => ({ provider: id, config, enabled: true, active: true, ...extra })
const roots: string[] = []
afterEach(async () => { for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }) })

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'multica-sync-test-')); roots.push(root)
  await mkdir(join(root, '.model-sync'))
  const target = join(root, 'cordis.patch.yml'), input = join(root, 'source.json')
  await writeFile(target, JSON.stringify({}))
  await writeFile(input, JSON.stringify([source('route')]))
  let live: Providers = {}, reject = false, failObserve = false, mutate = false
  let activateCount = 0
  const adapter: SyncAdapter = {
    async observe() {
      if (failObserve) throw new Error('private endpoint https://secret.invalid key=DO_NOT_LOG')
      const files = { [input]: await fingerprint(input), [target]: await fingerprint(target) }
      const sources = JSON.parse(await readFile(input, 'utf8')) as SourceGroup[]
      const current = JSON.parse(await readFile(target, 'utf8')) as Providers
      if (mutate) { mutate = false; await writeFile(input, JSON.stringify([source('newer')])) }
      return { sources, target: current, files, render: canonical }
    },
    async validate() { if (reject) throw new Error('schema invalid DO_NOT_LOG') },
    async activate(next) { live = structuredClone(next); activateCount++ },
  }
  const logs: unknown[] = []
  const sync = new ModelSync(root, adapter, s => logs.push(s), 60_000, 15)
  await sync.control(true)
  return { root, target, input, sync, logs, adapter, live: () => live, activations: () => activateCount,
    reject: (value = true) => { reject = value }, failObserve: () => { failObserve = true }, mutate: () => { mutate = true } }
}

describe('semantic group reconciliation', () => {
  it('adds, renames, updates capabilities while preserving namespace', () => {
    const original = provider()
    const next = provider(['model-a', 'model-b'], { displayName: 'Renamed', defaultInput: ['text', 'image'] })
    const merged = reconcileGroups([source('sp-gpt-dsh', next)], { 'sp-gpt-dsh': original }, { 'sp-gpt-dsh': original })
    expect(merged.providers['sp-gpt-dsh']).toEqual(next)
    expect(Object.keys(merged.providers)).toEqual(['sp-gpt-dsh'])
  })
  it('deduplicates reordered models/headers but isolates protocol/credential/capability/endpoint conflicts', () => {
    const a = provider(['a', 'b'], { headers: { Authorization: 'fixture' } })
    const b = provider(['b', 'a'], { headers: { authorization: 'fixture' } })
    expect(reconcileGroups([source('r', a), source('r', b)], {}, {}).conflicts).toBe(0)
    for (const field of ['api','apiKeyEnv','baseURL','headers','defaultInput']) {
      const result = reconcileGroups([source('r', a), source('r', { ...a, [field]: 'different' }), source('other')], { r: a }, { r: a })
      expect(result.conflicts).toBe(1)
      expect(result.providers.r).toEqual(a)
      expect(result.providers.other).toBeDefined()
    }
  })
  it('does not merge equal display names across provider keys', () => {
    expect(Object.keys(reconcileGroups([source('a'), source('b')], {}, {}).providers)).toEqual(['a','b'])
  })
  it('deletes managed models only on a successful authoritative source read, previews unknown target-only data', () => {
    const old = provider(['a','b'])
    const result = reconcileGroups([source('r', provider(['a']))], { r: old, manual: provider(['c']) }, { r: old })
    expect(result.deletionPreview).toBe(1)
    expect(result.removed).toBe(1)
    expect(result.providers.r!.models).toHaveLength(1)
    expect(result.providers.manual).toBeDefined()
  })
  it('blocks explicitly disabled managed routes while retaining historical reference outside active map', () => {
    const old = provider()
    const result = reconcileGroups([source('r', old, { enabled: false })], { r: old }, { r: old })
    expect(result.providers.r).toBeUndefined()
    expect(result.disabled).toEqual(['r'])
    expect(reconcileGroups([], {}, {}, ['r']).disabled).toEqual(['r'])
  })
  it('protects unknown manual changes with three-way conflict detection', () => {
    const old = provider(), manual = provider(['manual']), fresh = provider(['new'])
    const result = reconcileGroups([source('r', fresh), source('other')], { r: manual }, { r: old })
    expect(result.providers.r).toEqual(manual)
    expect(result.drift).toBe(1)
    expect(result.providers.other).toBeDefined()
  })
  it('regression: historical/unselected/missing-credential yuz routes do not become active sources', () => {
    const result = reconcileGroups([source('sp-gpt-dsh'), source('yuz-codex', provider(), { active: false }),
      source('yuz-deekseek', provider(), { active: false })], {}, {})
    expect(Object.keys(result.providers)).toEqual(['sp-gpt-dsh'])
    expect(result.inactive).toBe(2)
  })
  it('rejects duplicate model IDs with different semantics without stopping other groups', () => {
    const bad = { models: [{id:'a',name:'one'},{id:'a',name:'two'}] }
    const result = reconcileGroups([source('bad', bad), source('good')], {}, {})
    expect(result.conflicts).toBe(1)
    expect(result.providers.bad).toBeUndefined()
    expect(result.providers.good).toBeDefined()
  })
  it('removes owned legacy asd/yuz groups, keeps current source provider IDs and never resurrects backup data', () => {
    const old = { asd: provider(), 'yuz-codex': provider(['legacy']), 'yuz-deekseek': provider(['legacy-ds']) }
    const result = reconcileGroups([source('sp-gpt-dsh'), source('sp-ds-dsh')], old, old)
    expect(Object.keys(result.providers).sort()).toEqual(['sp-ds-dsh', 'sp-gpt-dsh'])
    expect(result.providers.asd).toBeUndefined()
    expect(result.removed).toBe(3)
    expect(result.disabled).toContain('asd')
  })
  it('preserves manual target deletion and never adopts an unknown identical route', () => {
    const old = provider()
    const deleted = reconcileGroups([source('r')], {}, { r: old })
    expect(deleted.providers.r).toBeUndefined()
    expect(deleted.drift).toBe(1)
    const unknown = reconcileGroups([source('r')], { r: old }, {})
    expect(unknown.managed).toEqual({})
    expect(reconcileGroups([], unknown.providers, unknown.managed).providers.r).toEqual(old)
  })
  it('isolates malformed target model groups while updating valid groups', () => {
    const bad = provider(['same','same']); bad.models[1]!.name = 'different'
    const result = reconcileGroups([source('bad'), source('good')], {bad}, {bad})
    expect(result.conflicts).toBe(1)
    expect(result.providers.good).toBeDefined()
    expect(result.providers.bad).toEqual(bad)
  })
  it('requires explicit source activation and rejects legacy aliases', () => {
    expect(() => validatePolicy({schema:1,sources:[]})).toThrow()
    expect(() => validatePolicy({schema:1,sources:[{profile:'../escape',enabled:true}]})).toThrow()
    expect(() => validatePolicy({schema:1,sources:[{profile:'desktop',enabled:true}],aliases:{'desktop/sp-gpt-dsh':'asd'}})).toThrow()
  })
})

describe('transaction and lifecycle', () => {
  it('uses one snapshot for directory and execution, persists revision, then freezes active execution', async () => {
    const f = await fixture()
    const initial = await f.sync.reconcile()
    expect(initial.code).toBeUndefined()
    expect(f.live()).toEqual(JSON.parse(await readFile(f.target, 'utf8')))
    await f.sync.pin()
    await writeFile(f.input, JSON.stringify([source('route',provider(['new']))]))
    const updated = await f.sync.reconcile()
    expect(updated.revision).not.toBe(initial.revision)
    expect(f.live().route!.models![0]!.id).toBe('model-a')
    expect(JSON.parse(await readFile(f.target,'utf8')).route.models.map((m: {id:string})=>m.id)).toContain('new')
    await f.sync.dispose()
  })
  it('does not activate or overwrite on malformed, half-written, missing input or discovery failure; logs no secrets', async () => {
    const f = await fixture(); await f.sync.reconcile()
    const old = await readFile(f.target, 'utf8'), count = f.activations()
    await writeFile(f.input, '{')
    expect((await f.sync.reconcile()).code).toBeDefined()
    expect(f.activations()).toBe(count)
    await rm(f.input)
    expect((await f.sync.reconcile()).code).toBeDefined()
    f.failObserve(); await f.sync.reconcile()
    expect(await readFile(f.target,'utf8')).toBe(old)
    expect(JSON.stringify(f.logs)).not.toMatch(/secret.invalid|DO_NOT_LOG|TEST_REF/)
    await f.sync.dispose()
  })
  it('rejects schema/probe failure before target or live activation', async () => {
    const f = await fixture(); f.reject()
    const result = await f.sync.reconcile()
    expect(result.code).toBeDefined()
    expect(await readFile(f.target,'utf8')).toBe('{}')
    expect(f.live()).toEqual({})
    await f.sync.dispose()
  })
  it('checks source revisions again and refuses stale candidates', async () => {
    const f = await fixture(); f.mutate()
    const status = await f.sync.reconcile()
    expect(status.code).toBe('REVISION_CHANGED')
    expect(await readFile(f.target,'utf8')).toBe('{}')
    await f.sync.dispose()
  })
  it('isolates concurrent writers and serializes repeated reconciles', async () => {
    const f = await fixture()
    await writeFile(join(f.root,'.model-sync','writer.lock'),JSON.stringify({pid:process.pid,nonce:'other'}))
    expect((await f.sync.reconcile()).code).toBe('LOCK_BUSY')
    expect(await readFile(f.target,'utf8')).toBe('{}')
    await rm(join(f.root,'.model-sync','writer.lock'))
    const results = await Promise.all([f.sync.reconcile(),f.sync.reconcile(),f.sync.reconcile()])
    expect(results.every(r=>r.code===undefined)).toBe(true)
    expect(new Set(results.map(r=>r.revision)).size).toBe(1)
    await f.sync.dispose()
  })
  it('recovers restart state and rollback disables synchronization and invalidates local catalog', async () => {
    const f = await fixture(); const initial = await f.sync.reconcile(); await f.sync.dispose()
    const restarted = new ModelSync(f.root,f.adapter)
    expect((await restarted.loadStatus()).revision).toBe(initial.revision)
    await restarted.reconcile()
    const result = await restarted.rollback(initial.revision!)
    expect(result.enabled).toBe(false)
    expect(await readFile(f.target,'utf8')).toBe('{}')
    expect((await restarted.reconcile()).enabled).toBe(false)
    expect(await readFile(join(f.root,'.model-sync','catalog-generation.json'),'utf8')).toContain(result.localCatalogGeneration)
    await restarted.dispose()
  })
  it('refuses rollback after a manual target edit', async () => {
    const f = await fixture(); const status = await f.sync.reconcile()
    await writeFile(f.target, '{"manual":{}}')
    await expect(f.sync.rollback(status.revision!)).rejects.toThrow('ROLLBACK_DRIFT')
    expect(await readFile(f.target,'utf8')).toBe('{"manual":{}}')
    await f.sync.dispose()
  })
  it('recovers a committed journal after crash without reverting an unrelated edit', async () => {
    const f = await fixture(); const status = await f.sync.reconcile()
    const record = await readFile(join(f.root,'.model-sync','history',`${status.revision}.json`),'utf8')
    await writeFile(join(f.root,'.model-sync','journal.json'),record)
    expect((await f.sync.reconcile()).code).toBeUndefined()
    expect(JSON.parse(await readFile(join(f.root,'.model-sync','catalog-generation.json'),'utf8')).revision).toBe(status.revision)
    await writeFile(join(f.root,'.model-sync','journal.json'),record)
    await writeFile(f.target,'{"manual":{}}')
    expect((await f.sync.reconcile()).code).toBe('RECOVERY_DRIFT')
    expect(await readFile(f.target,'utf8')).toBe('{"manual":{}}')
    await f.sync.dispose()
  })
  it('watches atomic replacement and stops on disable', async () => {
    const f = await fixture(); await f.sync.start()
    await writeFile(`${f.input}.new`,JSON.stringify([source('route',provider(['atomic']))]))
    await rename(`${f.input}.new`,f.input)
    await expect.poll(async()=>await readFile(f.target,'utf8'),{timeout:4000}).toContain('atomic')
    await writeFile(f.input,JSON.stringify([source('route',provider(['fallback']))]))
    await expect.poll(async()=>await readFile(f.target,'utf8'),{timeout:4000}).toContain('fallback')
    await f.sync.control(false)
    const old = await readFile(f.target,'utf8')
    await writeFile(f.input,JSON.stringify([source('route',provider(['disabled']))]))
    await new Promise(resolve=>setTimeout(resolve,150))
    expect(await readFile(f.target,'utf8')).toBe(old)
    await f.sync.dispose()
  })
  it('reconciles via timer even when all directory events are lost', async () => {
    const f = await fixture()
    await f.sync.dispose()
    const timerOnly = new ModelSync(f.root, f.adapter, () => {}, 60, 15, () => { throw new Error('events unavailable') })
    await timerOnly.start()
    await writeFile(f.input, JSON.stringify([source('route', provider(['timer-only']))]))
    await expect.poll(async () => await readFile(f.target, 'utf8'), { timeout: 4000 }).toContain('timer-only')
    expect(timerOnly.status().stale).toBeGreaterThan(0)
    await timerOnly.dispose()
  })

})

