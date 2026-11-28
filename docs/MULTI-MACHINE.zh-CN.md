# Windows 多机部署原生 DSH runtime

适用于同一 Multica workspace 的每台独立 Windows 电脑。路线为
`Multica daemon → dsh --profile multica → JSONL v1 stdio`。
本文是分步手工部署入口；构建、安装、发现和真实任务各有独立验收。
不使用 dsh-as-mcp、Orca 或新增 runner/controller。

截至 2026-11-26：已验证修复源码为 `7e90bdb574bf0da459892413f69454327da7f775`。
旧 tag `v0.2.0-axns.1` 指向 `55d93eb3258a8b2eaba24692e75f4d5568f5f1eb`，
缺少 pnpm 修复；当前没有已确认可用的 Release 作为新机默认来源。
本指南的新改动尚需审阅/推送，使用附件补丁或审阅后的准确提交取得；
仅克隆旧 main 不会自动得到本指南。不要默认下载旧 tag 或使用 latest。
所有带profile的Multica命令在目标电脑的普通用户shell执行；daemon任务上下文会拒绝部分本机配置操作。

## 1. 每台机器的准备清单

| 项目 | 本路线要求 | 不符时处理 |
| --- | --- | --- |
| OS | Windows x64，本机实测 | Ubuntu CI 构建/夹具通过不等于 Linux daemon 实装；macOS 未验 |
| PowerShell | 7.4+，使用 `pwsh -NoProfile` | Windows PowerShell 5.1 不适用 |
| Node | 精确 24.21.0（发布构建工具链） | 先查现有路径/版本，由用户调整，不覆盖已有 Node |
| DSH | 精确 0.2.2-rc.5（逐机复现目标） | 已有安装先检查；声明范围 `>=0.2.1-rc.2 <0.3.0` 不代表逐版实测 |
| Git / tar | 可执行且可用 | 缺少即停，不默默下载安装 |
| pnpm | 12.5.1，由 `prepare-pnpm.ps1` 固定提供 | 不依赖 PATH 的旧 pnpm，不盲目全局升级 |
| Multica | 建议 Desktop 与其 CLI 均为已验证的 0.13.0 | 0.12.1 等老版本先核对原生 DSH 发现能力，不承诺兼容 |
| 网络/权限 | 可读取私有 GitHub 仓库、npm 包；可访问 workspace 和模型服务 | GitHub 的读取权限与模型凭据分别准备 |
| 账户 | daemon 运行的 Windows 用户 | 在同一用户、同一 DSH_HOME 配置模型凭据 |

先手工核对，不执行任何重装命令：

```powershell
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.4') { throw '请使用 PowerShell 7.4+' }
Get-Command node, npm, git, tar, dsh -ErrorAction Stop | Select-Object Name, Source
if ((node --version) -cne 'v24.21.0' -or $LASTEXITCODE -ne 0) { throw '请选择 Node 24.21.0 后再继续' }
$DshCommand = (Get-Command dsh -ErrorAction Stop).Source
if ([IO.Path]::GetExtension($DshCommand) -notin @('.ps1','.exe')) { throw '请选择DSH的.ps1或.exe入口；本安装工具不运行.cmd/.bat' }
if ((& $DshCommand --version) -cne '0.2.2-rc.5' -or $LASTEXITCODE -ne 0) { throw '先核对已有 DSH，目标为 0.2.2-rc.5' }
git --version
if ($LASTEXITCODE -ne 0) { throw 'Git 不可用' }
tar --version
if ($LASTEXITCODE -ne 0) { throw 'tar 不可用' }
```

缺少 DSH 时，由该机用户依官方安装说明选择 Node 下的
`@deepseek-ai/dsh@0.2.2-rc.5`，安装后重新核对真实入口；本指南不代装或更新已有 DSH。
不使用兼容性豁免，不为错版本放宽检查。

## 2. 找到该机 Desktop 实际使用的 CLI，独立登录

`MULTICA_CLI_PATH` 是 daemon 注入任务的变量，普通 shell 经常没有。
为空时先在 Multica Desktop 的本机运行上下文查看它；也可以只读查看本机运行进程：

```powershell
Get-CimInstance Win32_Process -Filter "Name='multica.exe'" |
    Select-Object ProcessId, ExecutablePath
```

将已核实属于当前 Desktop 安装的 `ExecutablePath` 作为 CLI 路径。
没有运行进程时，从该机实际 Desktop 安装/快捷方式目标定位随安装交付的 CLI，
或先启动 Desktop 后重查；权限导致路径不可见时也需在该机确认。
不要套用其他电脑用户名/安装目录，不用 `Get-Command multica` 回退到 PATH 旧 CLI。

```powershell
# 若变量为空，下一行由该机用户填入刚刚确认的绝对路径。
$Cli = $env:MULTICA_CLI_PATH
# $Cli = '<该机实际 Desktop CLI 的绝对路径>'
if ([string]::IsNullOrWhiteSpace($Cli) -or -not [IO.Path]::IsPathFullyQualified($Cli) -or
    -not (Test-Path -LiteralPath $Cli -PathType Leaf)) { throw '先确认该机实际 Desktop CLI 路径；非交互执行必须预先提供' }
$env:MULTICA_CLI_PATH = (Resolve-Path -LiteralPath $Cli).Path
& "$env:MULTICA_CLI_PATH" --version
if ($LASTEXITCODE -ne 0) { throw 'CLI 不可执行' }
# 当前Desktop使用的配置profile也必须从该机上下文确认，不能凭别机目录猜测。
$MulticaProfile = '<该机 Desktop 当前配置 profile 名称>'
if ($MulticaProfile -like '<*') { throw '请先确认 Desktop 配置 profile' }
& "$env:MULTICA_CLI_PATH" --profile $MulticaProfile auth status
```

版本输出应为 0.13.0；不符时先按该机帮助/发现合同评估，再由用户决定调整。
profile 是 Multica 配置隔离名，与 DSH 的 `multica` profile 是两回事。
可在该机Desktop启动的任务上下文只读运行daemon status取得其profile字段；不要在任务里登录或启停daemon。
用 Desktop 在该机独立登录同一账号并选择同一 workspace。
若该配置尚未登录，也可由用户执行以下浏览器登录命令；它会自动发现并监视 workspace，
具有 daemon 启动副作用，执行前确认同配置没有 Desktop 管理的 daemon：

```powershell
& "$env:MULTICA_CLI_PATH" --profile $MulticaProfile login
& "$env:MULTICA_CLI_PATH" --profile $MulticaProfile --workspace-id 'dc886509-5031-48ac-8461-37dd9387b3a0' workspace list --output json
```

确认当前 workspace 为项目所在的 workspace。示例 UUID 属于本项目；转给其他 workspace 时替换。
不得从另一台电脑复制 daemon_id、登录 token、用户配置目录或 DSH 凭据文件。
不在命令行传明文 token。任务内 `mat_` token 也不是新机登录凭证。

## 3. 先配置模型凭据，再进行 profile 安装

DSH `0.2.2-rc.5` 官方安装包说明：默认本地凭据服务的优先级是
`$DSH_HOME/.credentials.yaml > 启动环境 > 项目 .env > $DSH_HOME/.env`。
README 的 `DEEPSEEK_API_KEY` 不仅指进程环境变量，也可指凭据存储中的同名引用。
默认 DeepSeek 路由缺凭据时会隐藏，导致目录为空；目录非空仍不证明密钥有效或推理成功。

先确认 daemon 用户及其 DSH_HOME。通常为该用户的 `.dsh`，也可能显式覆盖；
不要把“本终端的 HOME”当作其他用户/服务进程的 HOME：

```powershell
$DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dsh' }
$DshHome = [IO.Path]::GetFullPath($DshHome)
$DshHome  # 仅输出路径，不输出凭据内容
```

推荐在该机已有的官方 DSH 设置界面进入 **设置 → 模型 → DeepSeek API 密钥 → 保存**，
确认该界面确实使用相同的 DSH_HOME；DSH Desktop 与 Node CLI 可能不是同一个 home。
本任务不启动 Web/插件服务。不在本维护仓库放 `.env`。

没有配置界面时，官方支持该机用户用本地编辑器直接编辑上述 home 下的
`.credentials.yaml`。首次新建的文件格式如下；将占位文字仅在该机编辑器里换成自己的密钥：

```yaml
version: 1
refs:
  DEEPSEEK_API_KEY: '在本机编辑器中填入自己的密钥'
```

若文件已存在，保留 `version`、其他 `refs` 与 `records`，只编辑目标项；
不要用整文件覆盖脚本，不打印文件，不把密钥贴到聊天、issue、截图或终端历史。
在本地文件属性中限制为 daemon 用户所需的读取权限。Windows 版本不等同于 POSIX
严格权限检查，不能把自动创建文件当作与同用户 agent 隔离密钥的边界。
不要复制别机文件。不要创建 `DEEPSEEK_BASE_URL` 或伪造模型条目绕过验收。

临时 `$env:DEEPSEEK_API_KEY` 仅对该 shell 和它新启动的子进程有效；已运行的
Multica Desktop/daemon 不会因此收到变量。持久用户环境也不能更新已经启动的进程。
优先使用同一 home 的受管凭据；若组织只允许环境注入，必须由该机用户通过实际
daemon 启动方式提供，并在所有任务空闲时重新启动对应的宿主/daemon，之后重验。
`daemon restart` 也可能继承旧 Desktop 环境，不能假定它修复了继承问题。
不采集、显示或搬运任何真实密钥。

## 4. 取得源码：新目录，固定已验证提交

每台电脑选择自己的目录。当前维护机的 `D:\Coding\Axns8888\multica\...`
不是其他电脑的通用路径。下面在该机用户目录新建专用 clone；目录已存在就停止，
由用户查看其改动、分支和远端后另选新目录，绝不覆盖或强制 checkout：

```powershell
$Source = Join-Path $HOME 'src/dsh-multica-runtime-deploy'
if (Test-Path -LiteralPath $Source) { throw '目标已存在；先检查或另选新目录' }
New-Item -ItemType Directory -Path (Split-Path $Source -Parent) -Force | Out-Null
git clone https://github.com/axns8888/dsh-multica-runtime.git $Source
if ($LASTEXITCODE -ne 0) { throw '克隆失败；检查该机私有仓库读取权限，不要继续安装' }
Set-Location -LiteralPath $Source
$Revision = 'v0.2.0'
git switch --detach $Revision
if ($LASTEXITCODE -ne 0) { throw '固定源码失败；确认正式标签已推送，不强制切换' }
if ((git rev-parse HEAD) -cne (git rev-parse "$Revision^{commit}")) { throw '源码SHA不符' }
git status --short
```

确认正式标签存在并核对其提交及发布记录；若标签尚不可用则停止，勿回退到旧源码。

## 5. 只构建和审计：不改真实 profile

以下入口无需 Multica 登录或模型凭据。仓库源码/文档须已提交，未跟踪 `.multica/`
运行元数据除外；不自动提交用户改动。pnpm 只装在指定工具目录：

```powershell
$PnpmEntry = & ./scripts/prepare-pnpm.ps1 -ToolDirectory (Join-Path $PWD '.local/pnpm-12.5.1')
# 输出目录必须全新/为空；不覆盖已有发布证据。
$Output = Join-Path $PWD ('artifacts/manual-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
./scripts/build-release.ps1 -PnpmEntry $PnpmEntry -OutputDirectory $Output
$Archives = @(Get-ChildItem -LiteralPath $Output -Filter '*.tgz')
if ($Archives.Count -ne 1) { throw '需要唯一tgz' }
$pkg = $Archives[0].FullName
$sums = Join-Path $Output 'SHA256SUMS.txt'
. ./scripts/package-audit.ps1
$null = Test-RuntimePackage $pkg
Get-FileHash -LiteralPath $pkg -Algorithm SHA256
Get-Content -LiteralPath (Join-Path $Output 'build-info.json') -Raw
```

预期构建返回 `status=passed`；类型检查/22单测/编译/归档审计均通过，
`sourceSha` 为实际 HEAD，Node/pnpm 与固定工具链一致，源码/锁文件未变化。
`SHA256SUMS.txt` 包含 tgz 与 build-info 的 hash。安装器会重新校验 tgz hash、
包身份/白名单/许可及插件版本。hash 的可信度取决于校验和来源，不是独立签名。

只有准备工具脚本会下载 pnpm；build 会下载锁定依赖。它们不安装 DSH/Node、不修改
真实 profile、不重启 daemon、不发布。无网络、错版本、脏工作树、非空输出目录均需处理失败，
不能当作“已装好”。`-ReleaseTag` 仅留给将来已确认存在且受信任的 Release，
不存在时会报错，不会自动改为源码或 latest。

## 6. 安装该机真实 multica profile，并保存回退编号

准备好同用户/同 home 的凭据后，在无任务使用该 DSH profile、无其他插件包管理操作时，
由该机用户执行。活跃 daemon 任务存在时不要替换 profile；先等任务完成。
这一步有真实安装副作用，与第5步只构建分开执行：

```powershell
$result = & ./scripts/install-runtime.ps1 -Package $pkg -Checksums $sums -DshHome $DshHome -DshCommand $DshCommand
$result | Format-List
$BackupId = $result.backupId
./scripts/verify-runtime.ps1 -DshHome $DshHome -DshCommand $DshCommand -ExpectedVersion '0.2.0' -ReportPath (Join-Path $Output 'device-verification.json')
```

预期 `status=installed`，返回 backupId、SHA256；verification 的 probe、modelCatalog、
stdioHandshake 均为 passed。probe 必须为 JSONL v1、runtime=dsh、插件 `0.2.0`；
modelCount>0；stdio ready/能力握手及有界 EOF 退出通过。
`inference/daemonActivation/cancellation/resume/toolResult=not_verified` 是准确边界。

空目录安装会失败且恢复原 profile（首次安装恢复为不存在）；按第3步排查凭据、
home、用户/环境继承后再安装，不要反复盲装。安装器保存旧 profile 完整原件，
不会回退 home 级凭据，失败候选与备份可能含本机配置，只留本机。
保存该机自己的 `$DshHome` 与 `$BackupId`，不要套用其他电脑编号。

```powershell
# 仅需撤销本次安装时执行，使用相同home/入口：
./scripts/install-runtime.ps1 -Rollback $BackupId -DshHome $DshHome -DshCommand $DshCommand
```

连续安装从最新 backupId 逐层回退。`recovery_required` 表示未自动恢复；
保留 original 与 failed/retired，按 [安装与人工恢复](INSTALL.zh-CN.md#外部锁导致-recovery_required-的人工恢复)
检查占用和目标目录后处理，不覆盖目录，不上传整个备份。

## 7. daemon 发现与逐机 online 验收

安装器不启停 daemon。先用第2步的相同 CLI/profile/workspace 只读检查：

```powershell
& "$env:MULTICA_CLI_PATH" --profile $MulticaProfile daemon status --output json
& "$env:MULTICA_CLI_PATH" --profile $MulticaProfile --workspace-id 'dc886509-5031-48ac-8461-37dd9387b3a0' runtime list --output json
```

daemon 的 `agents` 包含 `dsh` 只代表已检测候选，仍要检查 `skipped_agents.dsh`。
runtime list 必须找到 `provider=dsh`、`status=online`，且 daemon_id 与本机 status
相等、device_info 是本机设备名，记录其独立 runtime `id`、CLI/DSH版本及 last_seen_at。
只看到别机的 online 不算本机通过；每台独立登录自动产生自己的身份，不手填 `--daemon-id`。

没有 daemon 时，优先从 Desktop 启用本机运行时。仅独立 CLI 场景且确认同一配置没有
Desktop 管理的 daemon，用户才手动执行（名字由该机用户选择，勿冒充别机）：

```powershell
& "$env:MULTICA_CLI_PATH" --profile $MulticaProfile daemon start --device-name $env:COMPUTERNAME
```

现有 daemon 自动发现后无需重启。未发现时先检查 daemon 用户能否找到同一个 dsh、
DSH_HOME 和凭据；非标准 dsh 可在实际 daemon 启动环境设置绝对 `MULTICA_DSH_PATH`，
也要核对该机 daemon 对入口后缀的支持，不能仅在普通 shell 设置就声称生效。
有需要时查看本机 `daemon logs --lines 100`，只本地诊断，不上传敏感内容。

只有配置/凭据/入口已经核对，仍缺 dsh 注册，且同配置
`running_task_count=active_task_count=resource_wait_task_count=0`、期间没有新任务进入，
用户才可在实际 Desktop 管理上下文执行一次重发现所需的重启：

```powershell
& "$env:MULTICA_CLI_PATH" --profile $MulticaProfile daemon restart
```

不要另起新 profile 的 daemon 与 Desktop 争用；未知计数、非零计数或任务将进入时停止。
环境继承问题还需按第3步处理宿主环境。之后重新执行 status/runtime list，未 online 就记未通过。
本任务本机不执行上述登录/启动/重启命令，也未在其他电脑安装。

## 8. Agent 绑定、跨机项目与真实任务另验收

Agent 持有 runtime 绑定；新注册另一台机器不会迁移现有 Agent，也不形成自动负载均衡或
自动故障切换。本指南不自动创建/重绑 Agent。待用户确认时，先展示以下具体预览：
Agent 名称/ID、当前 runtime ID/设备、目标 runtime ID/设备/daemon_id/online状态、
目标机模型与工具访问能力、项目源码来源/工作目录、待运行任务和真实推理费用影响。
用户确认后才做对应绑定/任务验收。

跨机项目优先使用每台都有读取权限的 Git 仓库，让各 daemon 自己获取源码；或显式为每台
设备配置实际存在的目录。项目现有 local_directory 绑定 GX703HR 的 daemon 和本机路径，
不能仅改写为另一台机器的相同字符串就视为可访问。设备无需共享源码工作区。
不分发 workdir、node_modules、缓存、session、token、用户目录或 profile 备份。

真实验收应在目标 runtime 运行一个最小模型任务，确认输出；再单独检查取消、会话恢复、
工具调用及结果回传（含任务归属），记录对应运行证据。上述动作会运行任务/产生模型费用，
须另行授权；本次只准备与验证，不把 probe 或 online 记作真实推理成功。

该机用户只需回传：设备名/OS、版本与精确CLI路径（可脱敏用户名）、Multica profile、
已登录 workspace ID、DSH_HOME路径、四个启动验证状态及modelCount、daemon_id/DSH runtime ID
与online状态、拟使用的Agent/项目来源。凭据只需回答“已在该机配置”，不要提供内容。

## 官方合同依据与后续发布预览

已核对本机官方 npm `@deepseek-ai/dsh@0.2.2-rc.5` 随包文档/配置：
`README.zh.md`、`docs/user/guide/providers.zh.md`、
`node_modules/@deepseek-ai/dsh-credentials-local/README.zh.md`、
`node_modules/@deepseek-ai/dsh-llm-deepseek-api-key/README.zh.md` 和 `dsh-base/cordis.patch.yml`。
对应上游位置：[启动器](https://github.com/deepseek-ai/deepseek-harness/tree/main/apps/cli)、
[凭据服务](https://github.com/deepseek-ai/deepseek-harness/tree/main/packages/credentials/credentials-local)、
[模型设置](https://github.com/deepseek-ai/deepseek-harness/blob/main/docs/user/guide/providers.zh.md)。
链接 main 可能变化，应优先用安装版本随附文档。Multica命令核对当前实际0.13.0 `--help`；
不假定存在 `runtime register`、`dsh login` 或 `dsh config set`。

正式版采用 `0.2.0` 和标签 `v0.2.0`。先固定提交并重跑构建、审计和必要测试，
核验 build-info、hash 与发行资产，再用于新机部署。旧 tag 保持原位。
