# AXNS-6 本机验证记录

日期：2026-11-26。以下区分原生 DSH 的实际执行与测试夹具，不宣称远端 CI 或真实推理已通过。

| 项目 | 状态 | 实测范围 |
| --- | --- | --- |
| Git 来源 | 通过 | 自有 origin/官方 upstream main 实时 SHA 相同；非浅克隆完整历史 |
| 工具链 | 通过 | Node 24.21.0、pnpm 12.5.1、DSH 0.2.2-rc.5、Multica 0.13.0 |
| 类型/单测/编译 | 通过 | pnpm check；3 文件共 22 单测 |
| 冻结依赖 | 通过 | --frozen-lockfile --ignore-scripts，维护版锁固定 pnpm 自身完整性；上游依赖未升级 |
| 工具安全用例 | 通过 | JSONL 错误/空输出/空目录/版本不符、hash失败、失败恢复、逐层回退、互斥、路径与超时 |
| 真实 DSH 无凭据隔离安装 | 失败且正确恢复 | probe 成功，目录为空；验收拒绝，profile 恢复为安装前不存在 |
| 真实 DSH 离线目录夹具 | 通过 | 使用真实 DSH 0.2.2-rc.5，临时 home 中仅 localhost:9 的夹具路由；1 模型，未请求推理 |
| 真实 DSH 重复安装/回退 | 通过 | 保留 pnpm node_modules 链接的原件回退，再回退至初始不存在 |
| 真实 multica profile | 通过 | 本机现有凭据/设置下 probe 维护版与非空目录（2 模型）；完整备份，未输出凭据 |
| 可重复打包 | 见交付 build-info 与校验和 | 使用固定提交构建两份并对比 tgz hash；产物不入 Git |
| daemon 上线 | 未验证 | 当前 daemon 承载本任务；不重启，初次状态未发现 runtime |
| 真实推理 | 未验证 | 未发起模型任务，不把目录可见认作凭据/推理成功 |
| 取消/恢复/工具回传 | 未验证 | 现有单测通过，但没有 Multica+DSH 真实任务端到端证据 |
| GitHub CI/Release | 未执行 | 工作流 YAML 本地解析，action SHA 经官方 GitHub API 核对；未 push/tag/发布 |
| Linux 安装工具 | 未验证 | CI 配置 Ubuntu，当前只有 Windows 实测 |

构建入口：scripts/build-release.ps1；工具用例入口：scripts/test-release-tools.ps1。
最终产物、源 SHA、SHA256 及命令结果在随 issue 交付的 build-info.json /
SHA256SUMS.txt，独立复核及修复说明见 docs/REVIEW.zh-CN.md。

沙箱内 Vitest 的 spawn EPERM 没有运行任何测试；获准沙箱外执行后 22 测试通过。
备份 ACL 采用 .NET AccessControl API，避免 PowerShell Set-Acl 对新 ACL 对象
要求额外 SeSecurityPrivilege；私有目录设定与重复设置都已在本机核实。
初次依赖安装使用了主机既有父级缓存；随后改为显式仓库内 .local store/state，
未删除或改动相邻项目和已有缓存。
