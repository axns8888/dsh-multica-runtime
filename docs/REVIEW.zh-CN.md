# AXNS-6 独立复核与修复

2026-11-26 使用临时 Codex CLI 独立上下文、read-only sandbox 审查脚本、
工作流、许可和兼容声明。不创建永久 Agent，不使用 Orca，不更改平台配置。
审查者未执行测试，测试由主执行上下文完成。原始审查文本作为 issue 附件保留。
审查期间有并发修复，报告部分发现对应此前读取的快照；以下按最终源码逐项落实。

| 发现 | 处理 | 验证 |
| --- | --- | --- |
| 回退双重恢复失败缺少状态（高） | 回退交换单独恢复事务；候选恢复成功则保持 installed；双重失败/receipt写入失败标 recovery_required，保留 original/retired 路径，提供人工命令 | 正常两层回退、缺失 original 导致回退失败后候选仍活动；外部双重锁的真实故障未注入 |
| tar 重复路径（中） | 所有条目使用不区分大小写 HashSet 去重；重复立即拒绝 | 特制同名普通文件 tar，检查专门 Duplicate 错误 |
| stdio 未纳入验收（中） | 增加带超时的 --stdio ready/能力握手；关闭stdin后严格检查预期EOF退出，不发送 execute；报告明确限定 startup 范围 | 真实 profile 握手，以及空/错ready/非预期退出夹具 |
| tag 来源和写权限覆盖构建（中） | tag必须与版本一致并已进入 origin/main；只读build与write发布job分离，发布job不checkout/执行仓库代码；显式tag、draft | YAML解析和静态检查；未触发远端CI/Release |
| 备份目录权限及安装失败恢复（审查中间反馈） | Windows 当前用户/SYSTEM ACL，Unix0700；原子目录移动拒覆盖；失败恢复有 recovery_required | 本机ACL重复设置、现有目标拒移动、安装失败恢复和原生profile回退 |
| 验证文档引用缺失 | 补齐 VALIDATION 与本记录，并加入实际包白名单 | 归档条目审计 |

剩余边界：没有宣称第二轮独立审查全部通过；本记录是对独立发现的修复与自检。
没有修改 GitHub 权限、分支/tag保护、环境审批或签名策略。main祖先校验与job权限
分离已在代码实现；仓库治理和发布者真实性仍由仓库所有者控制，checksum不是签名。
真实推理、Multica发现、取消、恢复和工具回传依旧需要无活动任务后的端到端验收。
