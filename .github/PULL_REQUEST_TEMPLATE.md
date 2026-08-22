<!--
Kelivo / KelivoMeow Skills 子系统 PR 模板。
核心原则：基础实现以 Kelivo 上源为准，仅在 skill 子系统内改动；任何 skill 相关改动不得拖垮 Kelivo 核心。
-->

## 改动摘要

<!-- 一句话说明这次 PR 做了什么。 -->

## 类型

- [ ] 新功能（skills 子系统内）
- [ ] 修复（性能 / 安全 / 优雅降级）
- [ ] 重构（仅 skill 子系统，未触碰 Kelivo 核心架构）
- [ ] 文档 / 测试
- [ ] CI / 工程化

## 范围自检（必填）

- [ ] 仅改动 `lib/core/{models,providers,services/skills}`、skills UI 及测试
- [ ] 未改动 Kelivo 核心聊天 / provider / UI 架构
- [ ] 注入面仍只有 `home_view_model.dart` 一处（被动 system prompt 注入）
- [ ] 未引入 skill 执行引擎（skills 仍仅为参考文本）

## 优雅降级检查（skills 相关改动必填，依据 code review 标准 G1–G6）

- [ ] G1 构造不抛异常
- [ ] G2 `initialize()` / 存储故障时回退空集合且 provider 仍可用
- [ ] G3 注入构建为纯函数（无副作用、可单测）
- [ ] G4 注入错误被 catch 并记录日志，不影响对话
- [ ] G5 `system` 角色 skill 消息在 UI 过滤
- [ ] G6 设置页技能入口在 skill 不可用时仍安全

## 安全自查

- [ ] 导入内容经转义（S1，防注入逃逸）
- [ ] 单条/总 token 有上限（P4）
- [ ] zip / 外部文件导入有体积与递归深度预算（S2，防 zip bomb）
- [ ] 不含明文密钥入库风险，或已在文档/日志标注（S4）

## 测试

- [ ] `dart analyze --fatal-infos lib test` 零 issue
- [ ] 新增/更新 `test/features/skills/` 下测试并跑绿
- [ ] 已覆盖至少一种故障路径（坏数据 / 坏存储不崩溃）

## 关联

<!-- 关联的 issue、审查报告或需求文档链接。 -->
