# T-7 多机部署准备验证记录

日期：2026-11-26。任务仅准备源码/文档和隔离验证；没有在其他电脑安装。

## 源码与交付关系

起始分支 `agent/mika/54a3c223e412`，起始HEAD
`7e90bdb574bf0da459892413f69454327da7f775`，仅未跟踪 `.multica/`，保留未修改未暂存。
Git身份沿用用户配置。未创建第二套worktree、未操作AXNS-5/skill-repo。

实现提交 `ccbde0254119d9dbe57ed2bc0beb3be24f05d7b0`：多机指南/清单、旧安装说明修正、
打包白名单、空目录报错指引，以及2项新增故障用例。
最终构建源码 `32ae4e8eff408884d80297f1a2b6604e130f4ec6`：只补官方launcher源码链接、
审查包与安装器配套说明、留痕。后续交付记录提交只含本记录及计划/进度，不改分发内容。

当前包仍为 `@multica-ai/dsh-runtime@0.2.0-axns.1` 的本地审查构建，不是已发布的新版本。
归档文件：`multica-ai-dsh-runtime-0.2.0-axns.1.tgz`。
SHA256：`0acd821920c6d99212d353dfa2d83f38ac74ba2e49b130a5dc6becaf79226121`。

新机可从7e90bdb克隆，审阅并应用附件T-7-source.patch、本地提交后，使用配套脚本自行构建。
补丁应放在忽略的.local或仓库外。没有推送本轮提交，不能要求其他电脑直接fetch本地SHA。
新审查包增加两份文档，安装它必须使用本轮配套安装器白名单；旧脚本可能正确拒绝新文档条目。

## 实际验证

| 检查 | 结果与边界 |
| --- | --- |
| 工具版本 | Windows x64 / PowerShell7.4+ / Node24.21.0 / pnpm12.5.1 / DSH0.2.2-rc.5 / Multica CLI0.13.0 |
| pnpm准备 | prepare-pnpm.ps1安装到.local/t7/pnpm-12.5.1，显式入口版本正确 |
| 最终发布构建 | 32ae4e8：冻结安装、类型检查、22单测、编译、tar内容/身份/许可/版本审计通过；锁文件未改 |
| 文档检查 | 16段PowerShell可解析，相对Markdown文件链接存在；7项文档检查通过，覆盖实际前置、错Node/DSH、缺依赖、空CLI与已有clone保全 |
| 安装工具 | ccbde02归档：31项通过；新增空目录指引/failed报告及缺Release不替换profile，其余覆盖hash、JSONL、版本、stdio、失败恢复、逐层回退、互斥、路径、tar与超时 |
| 真实DSH缺凭据 | 全新临时home/干净cwd，移除进程凭据后安装；catalog空被拒绝，receipt=failed_restored，profile恢复为不存在 |
| 真实DSH受管凭据格式 | 全新临时home写version:1/refs的合成AXNS_FIXTURE_KEY，只用于127.0.0.1:9离线路由；安装、1模型、probe v1/插件版本及stdio握手通过 |
| 真实DSH回退 | 上述临时home回退恢复profile不存在，home级合成配置保留；不涉及真实profile或密钥 |
| 最终包与受测包关系 | 逐条比较所有非docs tar条目完全相同；仅文档修正后重新构建审计，没有重复无关真实安装/推理 |
| 基线远端CI | 只读查询45755289376：7e90bdb的Windows-2025/Ubuntu24.04两job均success；本轮新提交未推送/无远端CI |
| 当前Release | 只读gh release list返回空，不假定旧tag存在可用Release |
| 真实推理/取消/恢复/工具回传 | 未验证，没有用目录或online代替端到端证据 |
| 其他机器/Linux/macOS实装 | 未执行；Ubuntu基线CI只是构建/夹具，不是daemon实装 |

隔离真实DSH受测归档hash为
`66d8e487072d692430663de51616abb79a1e4443dfff1bc9eae068ada0933e74`。
验证JSON及临时测试脚本随证据ZIP交付，未附profile/日志/备份/缓存或凭据文件。
临时脚本里的AXNS_FIXTURE_KEY值明确为合成非服务凭据，不包含真实密钥。

沙箱内npm-cache写入、Vitest spawn、私有目录ACL曾被拒绝，按工具权限流程沙箱外重试成功。
未把未运行的测试记为通过。环境清理首次用.NET null留下空DEEPSEEK_BASE_URL，
造成上游Invalid URL；临时脚本改为删除进程Env项后通过。没有修改真实启动环境或产品版本检查。
本轮是当前窗口自检，无新增独立agent复核，不声称第二上下文审查。

## 平台只读快照

GX703HR daemon_id=`01a210f9-fe6b-73ad-8b28-0719eed0c1e1`，PID仍为22332，
CLI0.13.0，launched_by=desktop；末次running/active任务计数为2，不满足重启条件。
DSH runtime=`4b505eed-28ab-4a49-8320-925888445829`，online，设备DSH版本0.2.2-rc.5。
DESKTOP-V32DROC登记的Codex/Claude/Pi仍offline、CLI0.12.1，未见该机DSH runtime。
这些是观察快照，不承诺其他机器的现状或可远程访问。

当前6个Agent（Mika、闪电、软著材料助手、宝塔运维助手、图转Vue助手、技能维护助手）
均绑定GX703HR Codex runtime `1f4524d2-60d3-47ad-a88b-bff4d25eab45`。
没有为此创建或重绑Agent。新机器登记不带来自动负载均衡或故障切换。
如需切换，先提供Agent/当前及目标runtime ID、设备、online、模型/工具、源码目录与任务预览，
用户确认后另执行。

## 每台电脑剩余动作

按MULTI-MACHINE.zh-CN.md及DEPLOY-CHECKLIST.zh-CN.md，在该机确认CLI路径/profile、版本、
独立登录同workspace、本地配置模型凭据、构建/安装/保存backupId、完成probe/catalog/stdio及本机runtime online验收。
回传设备/OS、版本、CLI路径、profile、workspace、DSH_HOME、modelCount/握手状态、daemon_id/runtime ID，
以及期望Agent/项目来源；不回传凭据。

回退使用该机同home的install-runtime.ps1 -Rollback <backupId>，逐层恢复；
recovery_required按INSTALL文档保留original/failed/retired并人工检查，不覆盖。
本机无真实安装因此没有本轮真实profile回退编号。
没有push/PR/tag/Release、远端workflow触发、插件启停、daemon启停或其他机器操作。
