# Task Plan: AXNS-6 自有 DSH 原生 runtime

## Goal
在指定维护仓库交付可审查的构建、分发、安装、校验与回退工具及实测证据，不推送、不重启 daemon。

## Next Step
向T-7指定线程交付runtime基础helpers/文档与证据并设in_review；面向用户入口由独立技能任务01a21631-921c-7b98-8ca5-247f1b4170e7完成。

## Current Phase
Phase 5

## Phases

### Phase 1: Requirements & Discovery
- [x] 读取 issue、评论、版本、Git 权限和目录。
- **Status:** complete

### Phase 2: Planning & Structure
- [x] 保留完整历史；精确目录和项目资源已落实。
- [x] 记录工具链、上游及安装行为。
- **Status:** complete

### Phase 3: Implementation
- [x] 脚本、CI、Release、中文文档及安全测试。
- **Status:** complete

### Phase 4: Testing & Verification
- [x] 构建、隔离安装/失败/回退、真实 profile、独立复核。
- **Status:** complete

### Phase 5: Delivery
- [x] 整理源码、产物哈希、实测边界与issue交付材料。
- **Status:** complete

## Decisions Made
| Decision | Rationale |
|---|---|
| 使用现有 0.2.0-private.1 上的 0.2.0-axns.1 | 上游版本已实时核实，不沿用过期副本结论 |
| 当前上下文实施，不使用 Orca | 用户明确要求 |
| 仅当前仓库留痕 | 不修改 skill-repo、全局 Git 或父入口 |

## Errors Encountered
| Error | Attempt | Resolution |
|---|---|---|
| PowerShell profile oh-my-posh 写入受限 | 1 | 后续使用 login=false |
| Git HTTPS schannel SEC_E_NO_CREDENTIALS | 1 | 提权只读核验成功 |
| checkout 自动添加仓库 basename | 1 | 校验父目录仅含新建 checkout 后原生 PowerShell 移动到目标 |
| 新 packageManager 导致 frozen lock 过期 | 1 | 显式刷新 package-manager 锁后 frozen 成功 |
| Vitest 沙箱内 spawn EPERM | 1 | 沙箱外 check 22 用例通过 |
| Python 默认 GBK 读取中文留痕失败 | 1 | 显式 UTF-8，补记发现 |
| PowerShell 新 ACL 对象 Set-Acl 要求 SeSecurityPrivilege | 2 | 改 .NET FileSystemAclExtensions，仅设访问 ACL；两次设置通过 |
| 无凭据隔离 home 模型目录为空 | 1 | 正确拒装并恢复；另用离线目录夹具验证原生路径 |

## Notes
不推送/PR/tag/Release，不重启 daemon。许可保持 private/UNLICENSED。

## Final preparation evidence
固定实现提交785f9fa完成两份发布构建，tgz SHA256一致：7f3ea2628eaf60dbdce9e0b20af0329fc8e2aaf51a13ca828f734ea1c0fe442a。27项工具安全用例通过。最终分发的源码SHA以build-info.json为准，技术交付等待用户验收，不等于真实推理闭环验收。

# T-7 多机部署（2026-11-26，当前任务）

沿用本文件唯一计划，保留上方 AXNS-6 历史。分支 agent/mika/54a3c223e412，起始 HEAD 7e90bdb574bf0da459892413f69454327da7f775；起始仅未跟踪 .multica/，不修改或暂存它。适用 AGENTS 与项目资源已读；无 _plan/prompts/project.md，无扩展配置。

- [x] 读取 T-7、T-6 描述及相关两条完整评论线程，核对实际 CLI/DSH 与官方安装包凭据文档。
- [x] 补齐中文多机指南/转发清单，修正旧 Release、pnpm、首次凭据与 daemon 命令。
- [x] 必要隔离验证、打包审计与回退，不改真实 profile/凭据，不启停 daemon。
- [x] 本地实现提交及验证证据已备妥；本轮最后上传附件/评论并设in_review。禁止push/PR/tag/Release。

实施选择：复用现有四个脚本作为分步入口，不增加会修改机器的包装安装器；文档提供逐步失败检查。上下文剩余容量未知，当前只在本窗口实施本短工单，不派生 agent。真实多机 online、推理/取消/恢复/工具回传均留给逐机验收。

### Phase 6: T-7 多机部署指南与验证
- [x] 文档、报错与打包白名单；隔离验证及本地提交，交付文件已备妥。
- **Status:** complete

最新收口范围：用户选择axns-config-dsh-multica-runtime技能，runtime任务只交接已验证基础helpers，不写skill-repo，不维护第二套安装逻辑；具体接口见docs/MULTI-MACHINE-VALIDATION.zh-CN.md。
