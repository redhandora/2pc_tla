# OceanBase 单日志流两阶段提交 TLA+ 形式化验证

本目录包含 OceanBase 单日志流(single log stream)树形两阶段提交协议的 TLA+ 形式化规约及自动化模型检验工具。

## 背景

OceanBase 的分布式事务采用树形两阶段提交(Tree-structured 2PC)协议。每个参与节点既是其父节点的 Participant，又是其子节点的 Coordinator。本规约对照 `Oceanbase 单日志流两阶段提交设计文档.md` 进行建模，覆盖正常流程、异常流程、环形事务、以及 transfer 引起的动态参与者变更。

## 文件说明

| 文件 | 说明 |
|---|---|
| `2pc_tla.tla` | 核心 TLA+ 规约，定义协议的状态变量、所有 action 和安全性不变式 |
| `MC.tla` | 模型检验辅助模块，定义具体的节点常量和拓扑配置 |
| `2pc_tla.cfg` | Fan-out 拓扑配置 (n1 -> {n2, n3}) |
| `2pc_tla_chain.cfg` | Chain 拓扑配置 (n1 -> n2 -> n3) |
| `run_tla_test.sh` | 自动化测试脚本，依次运行所有拓扑的模型检验 |
| `TODO.md` | Review 记录：规约与设计文档的对比、发现的问题及修复状态 |

## 协议建模

### 状态机

每个节点有 5 种状态：

```
RUNNING -> PREPARE -> COMMIT -> TOMBSTONE
                  \-> ABORT  -> TOMBSTONE
```

### 状态变量

- `rmState` — 节点状态 (RUNNING / PREPARE / COMMIT / ABORT / TOMBSTONE)
- `children` — 当前阶段的子节点集合
- `intermediate_children` — transfer 过程中新增的待合并子节点
- `msgs` — 网络中的消息集合
- `votes` — 各子节点的 prepare 投票结果
- `acks` — 各子节点的 commit/abort 阶段确认结果
- `parent` — 记录的父节点（来自首次收到的 PrepareReq）

### 消息类型

| 消息 | 方向 | 说明 |
|---|---|---|
| `PrepareReq` | 父 -> 子 | 发起 prepare 投票 |
| `PrepareResp` | 子 -> 父 | 投票结果 (ok / no) |
| `Commit` | 父 -> 子 | 提交决定 |
| `Abort` | 父 -> 子 | 回滚决定 |
| `Ack` | 子 -> 父 | 提交/回滚阶段确认 |

### 辅助定义

| 定义 | 说明 |
|---|---|
| `MergedChildren(n)` | `children[n] ∪ intermediate_children[n]`，阶段转换时的完整子节点集合 |
| `ApplyMerge(n, mc)` | 将 intermediate_children 合并进 children 并清空 pending 集合 |
| `RecordParent(n, src)` | 仅在 parent 尚未设置时记录，保留已有值 |
| `AllVotesOk(n)` | 所有子节点投票为 ok |
| `AnyVoteNo(n)` | 存在子节点投票为 no |
| `AllAcked(n)` | 所有子节点已回复 Ack |

### 建模的 Action（共 15 个）

命名对照 `Oceanbase 单日志流两阶段提交设计文档.md` 中的接口（`handle_2pc_*`）。

**Prepare 阶段：**
- `RootStartToCommit` — Root 发起 2PC，广播 PrepareReq 给所有子节点
- `Handle2pcPrepareRequest` — 子节点处理 PrepareReq，记录 parent 并向下广播
- `Handle2pcDuplicatePrepareRequest` — 已 PREPARE 的节点收到重复 PrepareReq（环形拓扑），直接回 ok
- `HandleOrphan2pcPrepareRequest` — 已 ABORT/TOMBSTONE 的节点收到 PrepareReq，回 no

**投票收集 & 决策：**
- `Handle2pcPrepareResponse` — 收集子节点投票（仅记录，不做决策）
- `Handle2pcCommitDecided` — 所有子节点投 ok；Root 进入 COMMIT 并广播 Commit，非 Root 向父节点回复 ok
- `Handle2pcAbortDecided` — 子节点投了 no；Root 进入 ABORT 并广播 Abort，非 Root 向父节点传递 no

**决策下发：**
- `Handle2pcCommitRequest` — 非 Root 节点处理 Commit 请求，合并 intermediate children 后转发并回 Ack
- `Handle2pcAbortRequest` — 非 Root 节点处理 Abort 请求，合并 intermediate children 后转发并回 Ack
- `HandleOrphan2pcCommitRequest` — 已 COMMIT/TOMBSTONE 的节点收到重复 Commit（环形拓扑），直接回 Ack
- `HandleOrphan2pcAbortRequest` — 已 ABORT/TOMBSTONE 的节点收到重复 Abort（环形拓扑），直接回 Ack

**异常流程：**
- `InternalAbort` — 节点执行错误或超时，从 RUNNING 主动 Abort

**完成 & 清理：**
- `Handle2pcAckResponse` — 收集子节点的 Ack
- `ForgetCtx` — 所有子节点已 Ack，进入 TOMBSTONE

**动态参与者：**
- `AddIntermediateParticipant` — transfer 引起的参与者动态添加（写入 intermediate_children，下次阶段转换时合并）

### 安全性不变式

**Consistency**：任意两个节点不可能同时处于 COMMIT 和 ABORT 状态。

```tla
Consistency == \A n1, n2 \in Node : ~(rmState[n1] = "COMMIT" /\ rmState[n2] = "ABORT")
```

此外，TLC 默认检查 **Deadlock Freedom**（协议不会卡死）。

## 运行模型检验

### 前置条件

- Java 11+
- `tla2tools.jar`（TLA+ Toolbox 或 VS Code TLA+ 插件自带）

### 执行

```bash
# 方式一：使用脚本自动运行所有拓扑
JAVA_HOME=/path/to/jdk bash run_tla_test.sh

# 方式二：手动运行单个配置
java -cp /path/to/tla2tools.jar tlc2.TLC -config 2pc_tla.cfg MC.tla -workers auto
```

### 验证结果（3 节点穷举）

| 拓扑 | 状态数 | 不同状态 | 搜索深度 | 结果 |
|---|---|---|---|---|
| Fan-out (n1->{n2,n3}) | 3,923,063 | 472,761 | 32 | PASS |
| Chain (n1->n2->n3) | 3,063,444 | 365,205 | 32 | PASS |

## 设计参考

- `Oceanbase 单日志流两阶段提交设计文档.md` — 协议设计文档
- `TODO.md` — 规约 review 详细记录

