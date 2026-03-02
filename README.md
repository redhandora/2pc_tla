# OceanBase Single Log Stream Two-Phase Commit TLA+ Formal Verification

This directory contains a TLA+ formal specification and automated model checking tooling for OceanBase's tree-structured two-phase commit protocol in a single log stream scenario.

## Background

OceanBase distributed transactions use a tree-structured 2PC protocol. Each participant node is both a Participant to its parent and a Coordinator to its children. This specification is modeled against `Oceanbase 单日志流两阶段提交设计文档.md`, and covers normal paths, abnormal paths, cyclic transactions, and dynamic participant changes caused by transfer.

## File Overview

| File | Description |
|---|---|
| `2pc_tla.tla` | Core TLA+ specification, defining protocol state variables, all actions, and safety invariants |
| `MC.tla` | Model checking helper module, defining concrete node constants and topology configurations |
| `2pc_tla.cfg` | Fan-out topology configuration (n1 -> {n2, n3}) |
| `2pc_tla_chain.cfg` | Chain topology configuration (n1 -> n2 -> n3) |
| `run_tla_test.sh` | Automated test script that runs model checking across all topologies |
| `TODO.md` | Review notes: comparison between the spec and design doc, discovered issues, and fix status |

## Protocol Modeling

### State Machine

Each node has 5 possible states:

```
RUNNING -> PREPARE -> COMMIT -> TOMBSTONE
                  \-> ABORT  -> TOMBSTONE
```

### State Variables

- `rmState` - Node state (RUNNING / PREPARE / COMMIT / ABORT / TOMBSTONE)
- `children` - Child node set in the current phase
- `intermediate_children` - Newly added child nodes pending merge during transfer
- `msgs` - In-flight network message set
- `votes` - Prepare voting results from child nodes
- `acks` - Commit/abort phase acknowledgment results from child nodes
- `parent` - Recorded parent node (from the first received PrepareReq)

### Message Types

| Message | Direction | Description |
|---|---|---|
| `PrepareReq` | Parent -> Child | Initiates prepare voting |
| `PrepareResp` | Child -> Parent | Voting result (ok / no) |
| `Commit` | Parent -> Child | Commit decision |
| `Abort` | Parent -> Child | Abort/rollback decision |
| `Ack` | Child -> Parent | Commit/abort phase acknowledgment |

### Helper Definitions

| Definition | Description |
|---|---|
| `MergedChildren(n)` | `children[n] ∪ intermediate_children[n]`, complete child set at phase transition |
| `ApplyMerge(n, mc)` | Merges intermediate_children into children and clears the pending set |
| `RecordParent(n, src)` | Records parent only when unset, preserving any existing value |
| `AllVotesOk(n)` | All child votes are ok |
| `AnyVoteNo(n)` | At least one child vote is no |
| `AllAcked(n)` | All child nodes have replied with Ack |

### Modeled Actions (15 Total)

Naming is aligned with interfaces in `Oceanbase 单日志流两阶段提交设计文档.md` (`handle_2pc_*`).

**Prepare Phase:**
- `RootStartToCommit` - Root initiates 2PC and broadcasts PrepareReq to all children
- `Handle2pcPrepareRequest` - Child handles PrepareReq, records parent, and forwards downward
- `Handle2pcDuplicatePrepareRequest` - PREPARE node receives duplicate PrepareReq (cyclic topology), replies ok directly
- `HandleOrphan2pcPrepareRequest` - ABORT/TOMBSTONE node receives PrepareReq, replies no

**Vote Collection & Decision:**
- `Handle2pcPrepareResponse` - Collects child votes (record only, no decision yet)
- `Handle2pcCommitDecided` - All children vote ok; Root enters COMMIT and broadcasts Commit, non-Root replies ok to parent
- `Handle2pcAbortDecided` - A child votes no; Root enters ABORT and broadcasts Abort, non-Root propagates no to parent

**Decision Propagation:**
- `Handle2pcCommitRequest` - Non-Root handles Commit request, merges intermediate children, forwards, and replies Ack
- `Handle2pcAbortRequest` - Non-Root handles Abort request, merges intermediate children, forwards, and replies Ack
- `HandleOrphan2pcCommitRequest` - COMMIT/TOMBSTONE node receives duplicate Commit (cyclic topology), replies Ack directly
- `HandleOrphan2pcAbortRequest` - ABORT/TOMBSTONE node receives duplicate Abort (cyclic topology), replies Ack directly

**Exceptional Path:**
- `InternalAbort` - Node actively aborts from RUNNING due to execution error or timeout

**Completion & Cleanup:**
- `Handle2pcAckResponse` - Collects child Ack responses
- `ForgetCtx` - Enters TOMBSTONE after all children Ack

**Dynamic Participants:**
- `AddIntermediateParticipant` - Dynamically adds participants due to transfer (written to intermediate_children and merged at next phase transition)

### Safety Invariant

**Consistency**: No two nodes can be in COMMIT and ABORT simultaneously.

```tla
Consistency == \A n1, n2 \in Node : ~(rmState[n1] = "COMMIT" /\ rmState[n2] = "ABORT")
```

In addition, TLC checks **Deadlock Freedom** by default (the protocol does not deadlock).

## Run Model Checking

### Prerequisites

- Java 11+
- `tla2tools.jar` (bundled with TLA+ Toolbox or the VS Code TLA+ extension)

### Execution

```bash
# Option 1: run all topologies via the script
JAVA_HOME=/path/to/jdk bash run_tla_test.sh

# Option 2: run a single configuration manually
java -cp /path/to/tla2tools.jar tlc2.TLC -config 2pc_tla.cfg MC.tla -workers auto
```

### Verification Results (Exhaustive 3-Node Search)

| Topology | States | Distinct States | Search Depth | Result |
|---|---|---|---|---|
| Fan-out (n1->{n2,n3}) | 3,923,063 | 472,761 | 32 | PASS |
| Chain (n1->n2->n3) | 3,063,444 | 365,205 | 32 | PASS |

## Design References

- `Oceanbase 单日志流两阶段提交设计文档.md` - Protocol design document
- `TODO.md` - Detailed spec review notes

