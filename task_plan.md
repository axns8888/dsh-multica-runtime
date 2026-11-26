# Task Plan: AXNS-6 自有 DSH 原生 runtime

## Goal
在指定维护仓库交付可审查的构建、分发、安装、校验与回退工具及实测证据，不推送、不重启 daemon。

## Next Step
收集独立复核结论并固定干净源码提交，构建最终分发产物。

## Current Phase
Phase 4

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
- [ ] 构建、隔离安装/失败/回退、真实 profile、独立复核。
- **Status:** in_progress

### Phase 5: Delivery
- [ ] 固定源码、产物哈希、实测边界及 issue 最终交付。
- **Status:** pending

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
