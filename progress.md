# AXNS-6 Progress

2026-11-26: 完成任务/评论读取、基线与权限核验、checkout 路径修正、项目资源定位。尚未运行测试或安装。

已完成脚本/工作流与文档初稿；22 单测通过；18 工具故障用例通过。真实隔离无凭据返回空目录，已拒装并恢复；配置离线目录夹具后，真实 DSH 安装/重装/两层回退通过。独立只读复核仍在前台收集结果。

独立复核完成，修复回退恢复状态、重复tar、stdio握手和Release可信来源/job权限。真实profile probe/2模型/stdio握手通过，27项工具用例通过。即将重新固定源码，构建两份校验可重复性，安装最终产物并确认daemon未重启。

2026-11-26 最终复核实现：22单测及27工具用例通过；两次独立输出目录tgz一致（7f3ea262...）。交付前最后仅更新留痕，不修改包内容；将重新生成与最终HEAD一致的build-info，并从真实profile恢复原件后安装最终包。无后台复核遗留，无push/PR/tag/Release，未重启daemon。

## T-7 当前进度

2026-11-26：基线/讨论/原生CLI及官方安装包凭据合同已核对，实施多机文档与最小报错改进。所有真实profile与daemon保持原状。尚未执行本轮构建测试。

T-7修正文档编辑时的PowerShell引号语法错误（解析前拒绝，未发生部分写入）；改用无转义的字面here-string后写入成功。新增Phase6沿用唯一计划。

T-7：16段PowerShell命令语法/Markdown相对链接检查通过；7项文档护栏检查（实际前置、错Node/DSH、缺依赖、空CLI路径、已存在clone保全）通过。固定pnpm准备首次因沙箱npm-cache EPERM失败，按权限流程沙箱外重试成功，只安装仓库.local/t7/pnpm-12.5.1。只读查询CI45755289376，7e90bdb的Windows/Ubuntu两job均success，未触发workflow。

T-7当前验证：ccbde02完整构建/22单测成功、31工具用例成功。实际DSH无凭据拒装恢复、受管version1合成凭据+离线目录+stdio、回退恢复absence均通过，真实profile未改。环境清理测试曾将DEEPSEEK_BASE_URL置为空字符串导致Invalid URL；验证.NET删除在Windows保留空值后，改用Remove-Item Env:后通过，仅影响测试进程。
沙箱初次build的Vitest spawn EPERM、真实隔离ACL拒绝、夹具缺Release分支被ACL提前阻断，均按权限流程沙箱外重试成功；不把沙箱失败记为产品功能失败。另有临时runner嵌套here-string语法错误，在写入前解析拒绝，改为字符串数组后通过。
只读核验Release列表为空。末次daemon PID22332未变，running/active=2，不满足重启条件。6个现有Agent仍均绑定GX703HR Codex，DSH runtime online但不自动迁移。
官方launcher源码链接从猜测的dsh修正为其package.json声明的apps/cli；新增审查包与旧安装器白名单配套说明。需重新构建固定此文档修正的包；不重跑无关真实推理。

T-7最终构建：32ae4e8源SHA，22单测和归档审计通过；tgz SHA256=0acd821920c6d99212d353dfa2d83f38ac74ba2e49b130a5dc6becaf79226121。与受31项工具/真实隔离安装验证的ccbde02包逐条比较，所有非docs条目完全相同。详见docs/MULTI-MACHINE-VALIDATION.zh-CN.md及issue证据附件。后续提交仅交付记录，不改分发内容；无需重跑无关检查。
