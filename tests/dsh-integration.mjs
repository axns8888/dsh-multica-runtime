import { mkdir, writeFile, readFile, rename, mkdtemp, rm } from 'node:fs/promises'
import {tmpdir} from 'node:os'
import {fileURLToPath} from 'node:url'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { spawn } from 'node:child_process'
import assert from 'node:assert/strict'
const tempRoot = resolve(tmpdir())
const root = await mkdtemp(join(tempRoot, 'multica-dsh-sync-'))
const binary = process.argv[2]
if (!binary) throw new Error('usage: node tests/dsh-integration.mjs <installed DSH lib/bin.js absolute path>')
const plugin = new URL('../dist/index.js', import.meta.url).href
const env = Object.fromEntries(['Path','PATH','SystemRoot','WINDIR','TEMP','TMP','USERPROFILE','COMSPEC'].flatMap(key => process.env[key] ? [[key,process.env[key]]] : []))
env.DSH_HOME=root; env.TEST_REF='offline-fixture'; env.DSH_TELEMETRY_DISABLED='1'
const route = (model='offline-a')=>({ api:'openai-completions', baseURL:'http://127.0.0.1:9/v1', apiKeyEnv:'TEST_REF', models:[{id:model,name:model,input:['text']}] })
for (const name of ['desktop','headless','web','multica']) {
 const dir=join(root,'profiles',name); await mkdir(dir,{recursive:true})
 await writeFile(join(dir,'package.json'),JSON.stringify({private:true,dsh:{profile:{bundles:['@deepseek-ai/dsh-base']}}}))
 const providers = name==='desktop' ? {'sp-gpt-dsh':route()} : name==='multica' ? {} : {'yuz-codex':{...route('historical'),apiKeyEnv:'UNSET_FIXTURE_REF'}}
 const patches=[{id:'hmr',disabled:true},{id:'session-telemetry-otel',disabled:true},{id:'llm-pi-ai',config:{providers}}]
 if (name==='multica') patches.push({insert:[{id:'headless-runner',name:plugin}]})
 await writeFile(join(dir,'cordis.patch.yml'),JSON.stringify(patches,null,2))
}
const target=join(root,'profiles','multica'); await mkdir(join(target,'.model-sync'),{recursive:true})
await writeFile(join(target,'.model-sync','policy.json'),JSON.stringify({schema:1,sources:[{profile:'desktop',enabled:true},{profile:'headless',enabled:true},{profile:'web',enabled:true}]}))
const children = []
function child(mode,input) {
 const p=spawn(process.execPath,[binary,'--profile','multica',mode],{env,cwd:process.cwd(),windowsHide:true,stdio:['pipe','pipe','pipe']})
 let out='',err=''; p.stdout.on('data',b=>{out+=b});p.stderr.on('data',b=>{err+=b})
 if (input!==undefined)p.stdin.end(input)
 const done=new Promise((resolve,reject)=>{p.on('error',reject);p.on('close',code=>resolve({code,out,err}));const timer=setTimeout(()=>{p.kill();reject(new Error('isolated child timed out'))},30000);p.on('close',()=>clearTimeout(timer))})
 done.catch(()=>{})
 const item = {p,done,getOut:()=>out,getErr:()=>err}
 children.push(item)
 return item
}
function rows(out){return out.split(/\r?\n/).filter(Boolean).map(x=>{try{return JSON.parse(x)}catch{return {invalid:true}}})}
try {
let r=await child('--sync-enable','').done
console.log(JSON.stringify({step:'enable',exit:r.code,status:rows(r.out),stderrLines:r.err.split('\n').length}))
if(r.code!==0){await writeFile(join(root,'isolated-debug.txt'),r.err);throw new Error('enable failed; sanitized fixture details in local debug file')}
r=await child('--list-models','').done
let modelRows=rows(r.out).find(x=>x.type==='models')
console.log(JSON.stringify({step:'catalog',exit:r.code,models:modelRows?.models?.map(m=>m.id)}))
assert(modelRows?.models?.some(m=>m.id==='sp-gpt-dsh/offline-a'));assert(!modelRows.models.some(m=>m.id.includes('yuz')))
const running=child('--stdio')
try { await new Promise((resolve,reject)=>{const timer=setTimeout(()=>{clearInterval(poll);reject(new Error('ready timeout'))},20000);const poll=setInterval(()=>{if(rows(running.getOut()).some(r=>r.type==='ready')){clearTimeout(timer);clearInterval(poll);resolve()}},30)}) } catch(e) { running.p.stdin.end(); const final=await running.done; await writeFile(join(root,'isolated-stdio-debug.txt'),final.out+'\n'+final.err); console.log(JSON.stringify({step:'stdio-failed',exit:final.code,stdout:rows(final.out),stderrSuppressed:true})); throw e }
const patch=join(root,'profiles','desktop','cordis.patch.yml')
const data=JSON.parse(await readFile(patch,'utf8'));data.find(r=>r.id==='llm-pi-ai').config.providers['sp-gpt-dsh']=route('offline-b')
const started=Date.now(); await writeFile(`${patch}.tmp`,JSON.stringify(data));await rename(`${patch}.tmp`,patch)
await new Promise((resolve,reject)=>{const timer=setTimeout(()=>{clearInterval(poll);reject(new Error('watch reconciliation timeout'))},12000);const poll=setInterval(async()=>{if((await readFile(join(target,'cordis.patch.yml'),'utf8')).includes('offline-b')){clearTimeout(timer);clearInterval(poll);resolve()}},40)})
const elapsed=Date.now()-started
running.p.stdin.end();r=await running.done
const statuses=rows(r.err.split('\n').filter(x=>x.startsWith('multica-model-sync: ')).map(x=>x.slice('multica-model-sync: '.length)).join('\n'))
console.log(JSON.stringify({step:'atomic-watch',elapsedMs:elapsed,pinned:statuses.some(s=>s.pinned),childCollected:true}))
r=await child('--list-models','').done;modelRows=rows(r.out).find(x=>x.type==='models')
assert(modelRows.models.some(m=>m.id==='sp-gpt-dsh/offline-b'))
console.log(JSON.stringify({step:'next-process-catalog',models:modelRows.models.map(m=>m.id)}))
// Authoritative deletion removes only the owned route, then rollback restores it with sync disabled.
const deletion = JSON.parse(await readFile(patch,'utf8'))
delete deletion.find(row=>row.id==='llm-pi-ai').config.providers['sp-gpt-dsh']
await writeFile(patch,JSON.stringify(deletion))
r=await child('--sync-reconcile','').done;assert.equal(r.code,0)
const deletionStatus=rows(r.out).find(x=>x.revision)
assert.equal(deletionStatus.removed,1)
r=await child('--list-models','').done;modelRows=rows(r.out).find(x=>x.type==='models')
assert(!modelRows.models.some(m=>m.id.startsWith('sp-gpt-dsh/')))
console.log(JSON.stringify({step:'authoritative-delete',ownedRouteAbsent:true}))
r=await child('--sync-rollback='+deletionStatus.revision,'').done;assert.equal(r.code,0)
assert.equal(rows(r.out).find(x=>typeof x.enabled==='boolean').enabled,false)
r=await child('--list-models','').done;modelRows=rows(r.out).find(x=>x.type==='models')
assert(modelRows.models.some(m=>m.id==='sp-gpt-dsh/offline-b'))
console.log(JSON.stringify({step:'rollback',catalogRestored:true,syncDisabled:true}))
r=await child('--sync-disable','').done;assert.equal(r.code,0)
console.log(JSON.stringify({step:'disable',exit:r.code,allChildrenCollected:true,inference:false,realProfileChanged:false}))

} finally {
 for (const child of children) { if (child.p.exitCode === null && child.p.signalCode === null) child.p.stdin.end() }
 await Promise.allSettled(children.map(child=>child.done))
 if (!root.startsWith(tempRoot + (process.platform === 'win32' ? '\\' : '/'))) throw new Error('unexpected fixture root')
 await rm(root, {recursive:true,force:true})
}
