# 自有原生 DSH runtime 安装、发布和回退

所有命令在维护仓库根目录使用 PowerShell 7.4+ 执行。本仓库保留 private /
UNLICENSED，发布前自行核实授权与仓库可见范围。包名和原生 stdio 协议不变。

## 本地构建

安装 release-toolchain.json 指定的 Node 24.21.0、pnpm 12.5.1。

```powershell
pnpm install --frozen-lockfile --ignore-scripts
pnpm check
# 所有源码及文档先提交；工作树必须干净。
pwsh -NoProfile -File scripts/build-release.ps1
```

默认产物 artifacts/0.2.0-axns.1/ 下包含 .tgz、SHA256SUMS.txt、
build-info.json。构建不发布 npm/GitHub，不安装 profile，不重启 daemon。
包采用文件白名单并检查 tar 条目、许可、版本及原生命令退出码；源码 SHA
指向实际提交，lockfile SHA 和检查结果在 build-info.json 内。
同版本再次构建请指定新的空输出目录，保留已有证据。

## 隔离验证与本地安装

```powershell
$pkg = (Get-ChildItem artifacts/0.2.0-axns.1/*.tgz).FullName
$sums = (Resolve-Path artifacts/0.2.0-axns.1/SHA256SUMS.txt).Path
$isolated = Join-Path $PWD '.local/dsh-validation'
$result = & ./scripts/install-runtime.ps1 -Package $pkg -Checksums $sums -DshHome $isolated
$result | Format-List
./scripts/verify-runtime.ps1 -DshHome $isolated -ExpectedVersion 0.2.0-axns.1
# 保存 result.backupId；以下恢复安装前状态（包括原先不存在 profile 的情况）
./scripts/install-runtime.ps1 -Rollback $result.backupId -DshHome $isolated
```

明确传入 -DshHome，或沿用 DSH_HOME；均未设置时使用用户主目录下 .dsh。
SHA256 不匹配、包身份/内容不符、安装命令失败、probe 异常或目录为空都会失败。
失败自动恢复原 profile。原 profile（包括 node_modules 及本地设置）完整移动到
同一 DSH_HOME 下 .axns-runtime/<backupId>/original，包管理不会改写备份。
新 profile 复制已有配置与依赖清单，重新安装依赖；默认不执行安装生命周期脚本。
失败候选保留在对应 failed 目录，供本机诊断。不要上传整个备份。
维护状态目录设为当前用户私有（Windows 用户/SYSTEM ACL，Unix 0700）。
若外部进程锁定目录导致恢复也失败，将明确报 recovery_required，原件仍留在
original；关闭占用后手动恢复，不能把该情况视为已恢复。
回退仅允许当前安装对应的编号；连续安装需从最新一次逐层回退。
请勿并行运行其他 dsh plugin 操作；脚本互斥锁只覆盖本维护工具。

隔离安装通过后，去掉 -DshHome 即按实际 DSH_HOME 安装真实 multica profile：

```powershell
$result = & ./scripts/install-runtime.ps1 -Package $pkg -Checksums $sums
./scripts/verify-runtime.ps1 -ExpectedVersion 0.2.0-axns.1
# 若需恢复
./scripts/install-runtime.ps1 -Rollback $result.backupId
```

## 自有 GitHub Release 安装

需 gh 已登录且可读取该仓库。仅支持明确的维护 tag，不跟随 latest。

```powershell
./scripts/install-runtime.ps1 -ReleaseTag v0.2.0-axns.1
```

发布资产要求恰好一个 tgz 和 SHA256SUMS.txt；hash 校验保护完整性，
请从信任的提交/发布者取得校验和，不把同源下载误作独立签名验证。

## 用户自行推送与发布

本任务不执行 push、PR、tag 或 Release。确认本地提交后由用户运行：

```powershell
git push -u origin HEAD
# 审阅后合入目标 main；确保提交和包版本相符，再创建显式 tag。
git tag v0.2.0-axns.1
git push origin v0.2.0-axns.1
```

CI 检查 push/PR，普通 push 不发布。Release workflow 只响应
v*-axns.* tag 或显式 workflow_dispatch（输入已存在 tag），校验精确 tag
与 package.json 版本且 tag 已进入 origin/main 后构建并附加 tgz、hash、构建信息。
构建 job 只读，发布 job 不 checkout/执行仓库代码，写权限只用于生成草稿 Release。
普通 push 不升级本机。
Release 先为 draft，用户检查后自行正式发布。

## daemon 启用和切回官方

安装与验收脚本不会重启 daemon。`--probe` 和非空模型目录通过后仍需区分：
进程协议可用、daemon 已发现 runtime、真实推理、取消、恢复及工具回传。
模型凭据仅由 DSH 在运行时读取，不写入源码或构建信息。

先查看 daemon 状态。以下使用运行环境提供的精确 CLI，不通过 PATH 找旧版本：

```powershell
& "$env:MULTICA_CLI_PATH" daemon status --output json
& "$env:MULTICA_CLI_PATH" daemon --help
```

仅当 running_task_count、active_task_count、resource_wait_task_count 均为 0
且没有新任务进入时，用户再按该版本帮助执行 daemon restart。
当前任务运行期间计数不为 0，必须在任务结束后操作。安装成功本身不代表
现有 daemon 已重新发现 dsh；重启后检查 skipped_agents/agents，再以有凭据的
模型运行单独验收任务，核实 stdio、工具、取消、恢复闭环。

切回官方首先用保存的 backupId 恢复原 profile；若原先没有官方版本，需取得
明确来源、适配当前 DSH 的官方 bundle，核验其 SHA256 并备份后按官方文档安装。
不臆造 npm 公共版本或自动覆盖官方 profile。维护版再次启用也需明确选择产物。

## 外部锁导致 recovery_required 的人工恢复

此状态不表示自动恢复成功。先关闭使用该 profile 的 DSH/插件进程，保留 original
和 retired/failed 两份目录，并确认当前 target 内容。不要终止仍承载任务的 daemon。
以下仅在目标 profile 不存在、original 是所需旧版本且没有活动用户时执行：

```powershell
# 将编号替换为出错信息中的 transaction；仅接受 32 位十六进制编号。
$id = '<transaction-id>'
if ($id -notmatch '^[a-f0-9]{32}$') { throw 'Invalid transaction id' }
$base = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }
$profile = Join-Path $base 'profiles/multica'
$original = Join-Path $base ".axns-runtime/$id/original"
if (Test-Path -LiteralPath $profile) { throw '先检查现有 profile，不能覆盖' }
[IO.Directory]::Move($original, $profile)
```

若旧版已恢复到 target 但仅 receipt 写入失败，检查内容后保留证据，勿再次移动目录。
若希望恢复本次安装候选，出错信息中的 retired 路径仍完整保留；同样仅能在 target
不存在时原子移动。人工恢复后记录选择的版本并重新运行 verify-runtime.ps1。

stdioHandshake 只启动 --stdio、检查 ready 帧与能力、关闭 stdin 并检查退出；
上游在 execute 前 EOF 明确返回 1 并输出 stdin closed before execute，
脚本只在该预期诊断下接受退出 1。不会发送 execute、调用模型或把握手当成推理验收。
