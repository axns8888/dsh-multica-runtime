# 自有原生 DSH runtime 安装、发布和回退

所有脚本在仓库根目录、PowerShell7.4+执行。身份保持 private/UNLICENSED。
新机从 [Windows多机部署入口](MULTI-MACHINE.zh-CN.md) 开始，转发可用
[逐机清单](DEPLOY-CHECKLIST.zh-CN.md)。文档中的安装命令由每台机器用户手工执行。

## 本地构建（不改profile）

先确认已选 Node24.21.0；pnpm由固定准备脚本提供12.5.1，不通过PATH猜测旧版本。
源码及文档须已提交；不覆盖已有输出目录。完整来源/工具链检查见多机指南。

```powershell
$PnpmEntry = & ./scripts/prepare-pnpm.ps1 -ToolDirectory (Join-Path $PWD '.local/pnpm-12.5.1')
$Output = Join-Path $PWD ('artifacts/manual-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
./scripts/build-release.ps1 -PnpmEntry $PnpmEntry -OutputDirectory $Output
```

输出tgz、SHA256SUMS.txt、build-info.json；构建检查冻结依赖、类型/测试/编译、
归档白名单、身份/许可/版本，记录实际sourceSha/锁文件hash。构建不发布，不安装profile。

## 凭据前置：先配置，再安装

首次安装前按 [凭据步骤](MULTI-MACHINE.zh-CN.md#3-先配置模型凭据再进行-profile-安装)
在daemon使用的Windows用户和DSH_HOME中准备模型凭据。官方DSH0.2.2-rc.5支持
模型设置界面或本地受管 `.credentials.yaml`（version:1、refs中的DEEPSEEK_API_KEY）。
存储优先于启动环境；普通shell临时环境不保证已运行Desktop/daemon能读到。
凭据不进入源码、命令行历史、构建信息或issue。空模型目录仍严格拒绝安装。

## 明确home后安装及回退

`-DshHome`省略时沿用DSH_HOME，再缺省为当前用户`.dsh`。逐机部署建议显式指定，
确保与daemon一致。以下在无profile使用者及无其他插件包管理操作时执行。
先前步骤已定义 `$Output`、`$DshHome`、`$DshCommand`：

```powershell
$Archives = @(Get-ChildItem -LiteralPath $Output -Filter '*.tgz')
if ($Archives.Count -ne 1) { throw '需要唯一tgz' }
$pkg = $Archives[0].FullName
$sums = Join-Path $Output 'SHA256SUMS.txt'
$result = & ./scripts/install-runtime.ps1 -Package $pkg -Checksums $sums -DshHome $DshHome -DshCommand $DshCommand
$result | Format-List
$BackupId = $result.backupId
./scripts/verify-runtime.ps1 -DshHome $DshHome -DshCommand $DshCommand -ExpectedVersion '0.2.0'
# 仅当需要撤销本次安装时运行：
./scripts/install-runtime.ps1 -Rollback $BackupId -DshHome $DshHome -DshCommand $DshCommand
```

隔离验证可将DshHome指向全新`.local`目录；它不会继承真实home的存储凭据或模型设置。
因此无凭据的新home预期在catalog阶段失败，不能为了隔离通过而复制真实凭据。
测试用离线路由只证明安装机制，不是用户部署配置。

安装器重验hash/包身份，完整移动旧profile至同home的
`.axns-runtime/<backupId>/original`，包括node_modules及本地设置。
新profile保留既有配置，安装依赖时禁用生命周期脚本。失败自动恢复安装前状态，
首次安装失败恢复为profile不存在。候选保留在failed供本机排查，勿上传整个备份。
状态目录使用用户私有权限（Windows用户/SYSTEM ACL；Unix0700）。
外部锁造成恢复失败时明确报recovery_required，按下文手工恢复。
回退仅允许当前安装编号，连续安装需由最新一次逐层回退；home级凭据不随profile回退。

## Release入口（当前不作为新机默认来源）

截至2026-11-26，旧tag `v0.2.0-axns.1`不含pnpm修复，且没有确认可用的Release。
默认从已验证修复源码 `7e90bdb574bf0da459892413f69454327da7f775` 构建。
将来用户确认受信任Release及其显式tag后，才使用以下可选入口；不要原样运行占位符：

```powershell
$ReleaseTag = '<已确认存在且可信的vX.Y.Z>'
if ($ReleaseTag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') { throw '先选择真实正式版Release' }
./scripts/install-runtime.ps1 -ReleaseTag $ReleaseTag -DshHome $DshHome -DshCommand $DshCommand
```

要求gh登录且可读仓库，资产恰好一个tgz及SHA256SUMS。缺Release/资产会失败，
不静默回退latest/旧tag。hash证明相对于可信校验和的完整性，同源下载不是独立签名。

## daemon发现、官方切换和发布边界

安装脚本不启停daemon。[多机指南第7节](MULTI-MACHINE.zh-CN.md#7-daemon-发现与逐机-online-验收)
给出精确CLI路径、同配置profile的status/runtime list，以及仅无daemon时start、
确有必要且三项任务计数均0时restart的手工命令。普通shell不一定有MULTICA_CLI_PATH，
应从本机真实Desktop安装/运行上下文确认，不能回退PATH旧CLI。
probe/非空目录/stdio握手、daemon发现/online、真实推理/取消/恢复/工具回传分别验收。

切回官方先按保存的backupId恢复旧profile；原先没有官方bundle时，需取得明确来源、
适配当前DSH的官方包，核验SHA256并备份后按官方说明安装，不臆造公共npm版本。

正式版采用 `v0.2.0` 标签，发布前固定源码并重新构建、审计；核验发行资产后再供新机使用。
旧 tag 保持原位。普通 push 不发布、不升级本机。

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
