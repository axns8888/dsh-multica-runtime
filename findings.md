# AXNS-6 Findings
- 2026-11-26: 自有及官方 main 实时 ls-remote 均为 571d7c036d15f58ee88c89fd80afb0a6c7f0023c。Git 非 shallow，原始工作区 clean，无项目内部 AGENTS。
- 目录 D:/Coding/Axns8888/multica/dsh-multica-runtime，分支 agent/mika/54a3c223e412。用户 Git 身份保留。
- 工具链 Node 24.21.0, pnpm 12.5.1, DSH 0.2.2-rc.5, Multica 0.13.0 (35b54a374)。上游 devDependencies 锁定 DSH 0.2.1-rc.2，peer 范围 >=0.2.1-rc.2 <0.3.0。
- 许可 private=true / UNLICENSED。包名 @multica-ai/dsh-runtime、profile multica、protocol v1 不变。
- 项目 local_directory 已改到精确目录，in_place。

- pnpm12 packageManagerDependencies lock refreshed explicitly, then frozen install passed. Initial install used host parent store; release passes explicit local store/state.
- Sandboxed Vitest spawn EPERM meant no tests; escalated pnpm check ran all 22 tests and build successfully.
- 18 release tool fixture tests passed. Real isolated DSH installation reached probe but list-models empty: strict verifier rejected and installer restored original absence. No false success recorded. DSH official installed docs state missing credentials hide model route.
- No DEEPSEEK_API_KEY/OPENAI_API_KEY/ANTHROPIC_API_KEY launch env present (values never printed). Existing real multica profile contains only base bundle, no runtime dependency.

- 真实 profile 安装与 probe/list-models 通过（2 模型），备份 ID 3f576c6e1d97460e82dfd754d29453b1；候选包 hash 42765e7c...，后续替换为最终构建，不重启daemon。未执行真实推理。
- 独立复核中提出外部锁导致恢复链中断和备份目录权限，已补 recovery_required 明确信号、原子拒覆盖目录移动、私有状态目录及追加安全用例。

- 独立只读审查完成（原文 .local/independent-review.txt），4项正式发现和中间反馈逐条修复于 docs/REVIEW.zh-CN.md；部分报告基于并发修复前快照，未宣称第二次独立全量通过。
- 真实 profile stdio握手通过；最终27个工具用例全部通过；新增回退失败保留活动候选与重复tar明确拒绝。
- 第一版干净提交1d87009完整发布构建通过，22单测；后续审查修复需重新固定源码并重建。

- 最终实现两次tgz hash一致：7f3ea2628eaf60dbdce9e0b20af0329fc8e2aaf51a13ca828f734ea1c0fe442a；包manifest没有gitHead，留痕提交不改变tgz内容，build-info将重新生成以匹配最终HEAD。

## T-7 发现（2026-11-26）

- 当前实际 CLI 0.13.0/35b54a374，DSH 0.2.2-rc.5；daemon GX703HR PID22332、launched_by=desktop、running/active=1；未启停。本机 dsh runtime 4b505eed-28ab-4a49-8320-925888445829 online；DESKTOP-V32DROC 仅旧0.12.1的Codex/Claude/Pi offline，无 DSH 登记。
- 官方已安装 @deepseek-ai/dsh-credentials-local 0.2.2-rc.5 README.zh.md：支持 .credentials.yaml version:1 + refs；优先级存储>启动环境>项目.env>home.env；启动环境是快照。官方 providers.zh.md 支持 设置→模型 保存 DeepSeek API key。没有 dsh login/config set 命令可假定。
- 官方已安装 DSH launcher README：dsh plugin 初始化 base profile；不使用 --from-default-profile 重置既有 profile。
- 原 INSTALL 文档仍使用 PATH pnpm、假定已有 axns.1 Release、仅使用任务变量 MULTICA_CLI_PATH；需要修正。旧 tag 55d93eb，不含7e90bdb修复，不是新机来源。
- 本轮 web 工具对官方 GitHub/raw 查询没有返回正文；凭据合同以本机官方 npm 包中随版本交付的源码/文档为依据，不声称在线页面已核验。

- T-7补查：CI45755289376在7e90bdb的Windows-2025/Ubuntu24.04两job均completed/success。只读查询，不将它归为本轮新提交CI。
- 本轮不新增自动安装包装器；新指南和清单纳入tgz白名单，verify仅补空目录错误的配置指引。新增空目录失败报告/指引及缺Release保全测试。
