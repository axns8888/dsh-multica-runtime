# 转发清单：另一台 Windows 电脑加入同一 Multica workspace

请在目标电脑本人登录的 Windows 用户下执行，完整命令见随附 `MULTI-MACHINE.zh-CN.md`。
本清单是手工步骤，目前不默认使用 GitHub Release；没有其他电脑已安装的承诺。

- [ ] 确认 PowerShell7.4+、Node24.21.0、DSH0.2.2-rc.5、Git/tar；已有版本不符先停，不盲目重装。
- [ ] 找到该机 Multica Desktop 实际 CLI 绝对路径，明确配置 profile，确认0.13.0；不要调用PATH旧CLI。普通shell可能没有MULTICA_CLI_PATH。
- [ ] 在该机独立登录同一workspace，避免重复启动Desktop管理的daemon。不复制别机daemon_id/token/用户目录。
- [ ] 确认daemon用户与DSH_HOME，在该机官方设置→模型保存自己的凭据，或本地编辑version:1/refs格式的.credentials.yaml；保留已有内容。不发送密钥。
- [ ] 在该机新目录clone私有仓库，固定7e90bdb574bf0da459892413f69454327da7f775；旧目录存在就停。需要T-7增量时审阅附件补丁后应用提交，或使用后续明确推送的SHA。
- [ ] `prepare-pnpm.ps1`提供12.5.1入口 → `build-release.ps1 -PnpmEntry ...`输出唯一tgz、SHA256SUMS和build-info；确认sourceSha/审计通过。
- [ ] 无profile使用者时，明确`-DshHome`和`-DshCommand`调用`install-runtime.ps1 -Package ... -Checksums ...`；保存该机backupId。
- [ ] `verify-runtime.ps1`：probe v1/插件0.2.0-axns.1、非空model catalog、stdioHandshake均passed；空目录先处理凭据，不能跳过验证。
- [ ] 以精确CLI路径运行同profile的daemon status/runtime list，核对本机device/daemon_id、独立DSH runtime ID及online。自动发现成功无需restart。
- [ ] 未发现先查DSH入口/home/环境；仅在三种任务计数全0且无新任务时按指南由用户重启正确daemon；不另起竞争daemon。
- [ ] 回退：使用同home运行`install-runtime.ps1 -Rollback <该机backupId>`；连续安装从最新逐层回退。recovery_required按人工恢复说明处理。
- [ ] 回传设备/OS、版本、CLI路径与profile、workspace、DSH_HOME、modelCount/握手状态、daemon_id/runtime ID/online，以及期望Agent/项目来源；不传凭据、session或备份。

先完成逐机online再决定Agent绑定。新增机器不会自动改变现有Agent或实现自动故障切换。
真实推理/取消/恢复/工具回传待用户确认目标runtime后分别验收。无需共享源码工作区；
当前维护机D盘路径不适用于所有电脑，跨机优先Git或显式每机目录。
