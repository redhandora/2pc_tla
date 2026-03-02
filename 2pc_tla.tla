----------------------------- MODULE 2pc_tla -----------------------------
EXTENDS Naturals, Sequences, FiniteSets, TLC

(*
    Tree-structured Two-Phase Commit Protocol

    Each node acts as Participant for its parent and Coordinator for its children.
    Supports: normal commit/abort flow, circular topology (duplicate messages),
    and dynamic participant addition via transfer.
*)

CONSTANTS
    Node,         \* Set of all participant nodes
    Root,         \* Root node (top-level Coordinator)
    InitChildren  \* Function: Node -> SUBSET Node (initial children mapping)

VARIABLES
    rmState,               \* Node state: RUNNING | PREPARE | COMMIT | ABORT | TOMBSTONE
    children,              \* Active children in current phase
    intermediate_children, \* Pending children from transfers (merged at next phase transition)
    msgs,                  \* Network message set (unordered, reliable delivery)
    votes,                 \* Prepare votes received from children: "unknown" | "ok" | "no"
    acks,                  \* Ack received from children in commit/abort phase: TRUE | FALSE
    parent                 \* Recorded parent node ("none" until first PrepareReq received)

Vars == <<rmState, children, intermediate_children, msgs, votes, acks, parent>>

----

(***************************************************************************)
(* Auxiliary Definitions                                                   *)
(***************************************************************************)

States == {"RUNNING", "PREPARE", "COMMIT", "ABORT", "TOMBSTONE"}

\* ── Message Constructors ──

MsgPrepareReq(src, dst)         == [type |-> "PrepareReq",  src |-> src, dst |-> dst]
MsgPrepareResp(src, dst, status) == [type |-> "PrepareResp", src |-> src, dst |-> dst, status |-> status]
MsgCommit(src, dst)              == [type |-> "Commit",      src |-> src, dst |-> dst]
MsgAbort(src, dst)               == [type |-> "Abort",       src |-> src, dst |-> dst]
MsgAck(src, dst)                 == [type |-> "Ack",         src |-> src, dst |-> dst]

IsRoot(n) == n = Root

\* ── Reusable Helpers ──

\* Children to use at a phase transition: merge pending transfers into active set
MergedChildren(n) == children[n] \cup intermediate_children[n]

\* Apply the merge: promote intermediate_children into children, clear pending set
ApplyMerge(n, mc) ==
    /\ children' = [children EXCEPT ![n] = mc]
    /\ intermediate_children' = [intermediate_children EXCEPT ![n] = {}]

\* Record parent from message source, preserving existing parent if already set
RecordParent(n, src) == [parent EXCEPT ![n] = IF @ = "none" THEN src ELSE @]

\* ── Vote & Ack Predicates ──

AllVotesOk(n) == \A c \in children[n] : votes[n][c] = "ok"
AnyVoteNo(n)  == \E c \in children[n] : votes[n][c] = "no"
AllAcked(n)   == \A c \in children[n] : acks[n][c] = TRUE

----

(***************************************************************************)
(* Initial State                                                           *)
(***************************************************************************)

Init ==
    /\ rmState = [n \in Node |-> "RUNNING"]
    /\ children = InitChildren
    /\ intermediate_children = [n \in Node |-> {}]
    /\ msgs = {}
    /\ votes = [n \in Node |-> [c \in children[n] |-> "unknown"]]
    /\ acks = [n \in Node |-> [c \in children[n] |-> FALSE]]
    /\ parent = [n \in Node |-> "none"]

----

(***************************************************************************)
(* Phase 1: Prepare                                                        *)
(***************************************************************************)

(*
    RootStartToCommit: Root initiates the 2PC protocol
    (triggered by scheduler's txn commit request).
    Merges pending intermediate children before broadcasting PrepareReq.
*)
RootStartToCommit ==
    /\ rmState[Root] = "RUNNING"
    /\ LET mc == MergedChildren(Root) IN
       /\ rmState' = [rmState EXCEPT ![Root] = "PREPARE"]
       /\ ApplyMerge(Root, mc)
       /\ votes' = [votes EXCEPT ![Root] = [c \in mc |-> "unknown"]]
       /\ msgs' = msgs \cup {MsgPrepareReq(Root, c) : c \in mc}
       /\ UNCHANGED <<acks, parent>>

(*
    Handle2pcPrepareRequest: Node receives PrepareReq from parent.
    Records parent, transitions to PREPARE, forwards PrepareReq to own children.
*)
Handle2pcPrepareRequest(n) ==
    /\ rmState[n] = "RUNNING"
    /\ \E m \in msgs :
        /\ m.type = "PrepareReq" /\ m.dst = n
        /\ LET mc == MergedChildren(n) IN
           /\ parent' = [parent EXCEPT ![n] = m.src]
           /\ rmState' = [rmState EXCEPT ![n] = "PREPARE"]
           /\ ApplyMerge(n, mc)
           /\ votes' = [votes EXCEPT ![n] = [c \in mc |-> "unknown"]]
           /\ msgs' = msgs \cup {MsgPrepareReq(n, c) : c \in mc}
           /\ UNCHANGED <<acks>>

(*
    Handle2pcDuplicatePrepareRequest: Already-PREPARE node receives PrepareReq
    from a different sender (circular topology). Responds "ok" immediately
    without re-executing the prepare flow.
*)
Handle2pcDuplicatePrepareRequest(n) ==
    /\ rmState[n] = "PREPARE"
    /\ \E m \in msgs :
        /\ m.type = "PrepareReq" /\ m.dst = n
        /\ m.src # parent[n]
        /\ msgs' = msgs \cup {MsgPrepareResp(n, m.src, "ok")}
        /\ UNCHANGED <<rmState, children, intermediate_children, votes, acks, parent>>

(*
    HandleOrphan2pcPrepareRequest: Node already in ABORT/TOMBSTONE receives
    PrepareReq (e.g., InternalAbort happened before parent's PrepareReq arrived).
    Responds "no" and records parent if not yet known.
*)
HandleOrphan2pcPrepareRequest(n) ==
    /\ rmState[n] \in {"ABORT", "TOMBSTONE"}
    /\ \E m \in msgs :
        /\ m.type = "PrepareReq" /\ m.dst = n
        /\ parent' = RecordParent(n, m.src)
        /\ msgs' = msgs \cup {MsgPrepareResp(n, m.src, "no")}
        /\ UNCHANGED <<rmState, children, intermediate_children, votes, acks>>

(***************************************************************************)
(* Phase 2: Vote Collection                                                *)
(***************************************************************************)

(*
    Handle2pcPrepareResponse: Collect a prepare vote from a child.
    Only records the vote; decision logic is in Handle2pcCommit/AbortDecided.
*)
Handle2pcPrepareResponse(n) ==
    /\ rmState[n] = "PREPARE"
    /\ \E m \in msgs :
        /\ m.type = "PrepareResp"
        /\ m.dst = n
        /\ m.src \in children[n]
        /\ votes[n][m.src] = "unknown"
        /\ votes' = [votes EXCEPT ![n][m.src] = m.status]
        /\ UNCHANGED <<rmState, children, intermediate_children, msgs, acks, parent>>

(***************************************************************************)
(* Phase 3: Commit / Abort Decision                                        *)
(***************************************************************************)

(*
    Handle2pcCommitDecided: All children voted "ok"; node decides commit.
    Root: transitions to COMMIT and broadcasts MsgCommit to children.
    Non-root: forwards "ok" vote to parent (awaits commit request from root).
*)
Handle2pcCommitDecided(n) ==
    /\ rmState[n] = "PREPARE"
    /\ AllVotesOk(n)
    /\ IF IsRoot(n)
       THEN LET mc == MergedChildren(n) IN
            /\ rmState' = [rmState EXCEPT ![n] = "COMMIT"]
            /\ ApplyMerge(n, mc)
            /\ acks' = [acks EXCEPT ![n] = [c \in mc |-> FALSE]]
            /\ msgs' = msgs \cup {MsgCommit(n, c) : c \in mc}
            /\ UNCHANGED <<votes, parent>>
       ELSE /\ msgs' = msgs \cup {MsgPrepareResp(n, parent[n], "ok")}
            /\ UNCHANGED <<rmState, children, intermediate_children, votes, acks, parent>>

(*
    Handle2pcAbortDecided: A child voted "no"; node decides abort.
    Root: transitions to ABORT and broadcasts MsgAbort to children.
    Non-root: forwards "no" vote to parent (awaits abort request from root).
*)
Handle2pcAbortDecided(n) ==
    /\ \/ rmState[n] = "PREPARE"
       \/ (IsRoot(n) /\ rmState[n] = "RUNNING")
    /\ AnyVoteNo(n)
    /\ IF IsRoot(n)
       THEN LET mc == MergedChildren(n) IN
            /\ rmState' = [rmState EXCEPT ![n] = "ABORT"]
            /\ ApplyMerge(n, mc)
            /\ acks' = [acks EXCEPT ![n] = [c \in mc |-> FALSE]]
            /\ msgs' = msgs \cup {MsgAbort(n, c) : c \in mc}
            /\ UNCHANGED <<votes, parent>>
       ELSE /\ msgs' = msgs \cup {MsgPrepareResp(n, parent[n], "no")}
            /\ UNCHANGED <<rmState, children, intermediate_children, votes, acks, parent>>

(***************************************************************************)
(* Phase 4: Decision Propagation                                           *)
(***************************************************************************)

(*
    Handle2pcCommitRequest: Non-root receives Commit from parent.
    Merges intermediate children, forwards commit to all children,
    and sends Ack to parent immediately.
*)
Handle2pcCommitRequest(n) ==
    /\ ~IsRoot(n)
    /\ rmState[n] \in {"RUNNING", "PREPARE"}
    /\ \E m \in msgs :
        /\ m.type = "Commit" /\ m.dst = n
        /\ LET mc == MergedChildren(n) IN
           /\ parent' = RecordParent(n, m.src)
           /\ rmState' = [rmState EXCEPT ![n] = "COMMIT"]
           /\ ApplyMerge(n, mc)
           /\ acks' = [acks EXCEPT ![n] = [c \in mc |-> FALSE]]
           /\ msgs' = msgs \cup {MsgCommit(n, c) : c \in mc} \cup {MsgAck(n, m.src)}
           /\ UNCHANGED <<votes>>

(*
    Handle2pcAbortRequest: Non-root receives Abort from parent.
    Merges intermediate children, forwards abort to all children,
    and sends Ack to parent immediately.
*)
Handle2pcAbortRequest(n) ==
    /\ ~IsRoot(n)
    /\ rmState[n] \in {"RUNNING", "PREPARE"}
    /\ \E m \in msgs :
        /\ m.type = "Abort" /\ m.dst = n
        /\ LET mc == MergedChildren(n) IN
           /\ parent' = RecordParent(n, m.src)
           /\ rmState' = [rmState EXCEPT ![n] = "ABORT"]
           /\ ApplyMerge(n, mc)
           /\ acks' = [acks EXCEPT ![n] = [c \in mc |-> FALSE]]
           /\ msgs' = msgs \cup {MsgAbort(n, c) : c \in mc} \cup {MsgAck(n, m.src)}
           /\ UNCHANGED <<votes>>

(*
    HandleOrphan2pcCommitRequest: Node already committed or tombstoned
    receives a duplicate Commit (circular topology). Responds with Ack.
*)
HandleOrphan2pcCommitRequest(n) ==
    /\ ~IsRoot(n)
    /\ rmState[n] \in {"COMMIT", "TOMBSTONE"}
    /\ \E m \in msgs :
        /\ m.type = "Commit" /\ m.dst = n
        /\ msgs' = msgs \cup {MsgAck(n, m.src)}
        /\ UNCHANGED <<rmState, children, intermediate_children, votes, acks, parent>>

(*
    HandleOrphan2pcAbortRequest: Node already aborted or tombstoned
    receives a duplicate Abort (circular topology). Responds with Ack.
*)
HandleOrphan2pcAbortRequest(n) ==
    /\ ~IsRoot(n)
    /\ rmState[n] \in {"ABORT", "TOMBSTONE"}
    /\ \E m \in msgs :
        /\ m.type = "Abort" /\ m.dst = n
        /\ msgs' = msgs \cup {MsgAck(n, m.src)}
        /\ UNCHANGED <<rmState, children, intermediate_children, votes, acks, parent>>

(***************************************************************************)
(* Abnormal Flow                                                           *)
(***************************************************************************)

(*
    InternalAbort: Node aborts due to execution error or timeout (RUNNING only).
    Notifies parent with "no" vote if parent is known.
*)
InternalAbort(n) ==
    /\ rmState[n] = "RUNNING"
    /\ LET mc == MergedChildren(n)
           parentNotify == IF parent[n] # "none"
                           THEN {MsgPrepareResp(n, parent[n], "no")}
                           ELSE {}
       IN
       /\ rmState' = [rmState EXCEPT ![n] = "ABORT"]
       /\ ApplyMerge(n, mc)
       /\ acks' = [acks EXCEPT ![n] = [c \in mc |-> FALSE]]
       /\ msgs' = msgs \cup {MsgAbort(n, c) : c \in mc} \cup parentNotify
    /\ UNCHANGED <<votes, parent>>

(***************************************************************************)
(* Phase 5: Completion & Cleanup                                           *)
(***************************************************************************)

(*
    Handle2pcAckResponse: Collect an ack from a child in the commit/abort phase.
*)
Handle2pcAckResponse(n) ==
    /\ rmState[n] \in {"COMMIT", "ABORT"}
    /\ \E m \in msgs :
        /\ m.type = "Ack"
        /\ m.dst = n
        /\ m.src \in children[n]
        /\ acks[n][m.src] = FALSE
        /\ acks' = [acks EXCEPT ![n][m.src] = TRUE]
        /\ UNCHANGED <<rmState, children, intermediate_children, msgs, votes, parent>>

(*
    ForgetCtx: All children have acked; transition to TOMBSTONE.
    Safe because no other node's state machine progress depends on this node.
*)
ForgetCtx(n) ==
    /\ rmState[n] \in {"COMMIT", "ABORT"}
    /\ AllAcked(n)
    /\ rmState' = [rmState EXCEPT ![n] = "TOMBSTONE"]
    /\ UNCHANGED <<children, intermediate_children, msgs, votes, acks, parent>>

(***************************************************************************)
(* Dynamic Membership                                                      *)
(***************************************************************************)

(*
    AddIntermediateParticipant: Transfer adds a new participant to the context.
    The child goes into intermediate_children (pending); it will be merged into
    the active children set at the next phase transition (write-log point).
*)
AddIntermediateParticipant(n, newChild) ==
    /\ rmState[n] \in {"RUNNING", "PREPARE", "COMMIT", "ABORT"}
    /\ newChild \in Node \ {n}
    /\ newChild \notin children[n]
    /\ newChild \notin intermediate_children[n]
    /\ intermediate_children' = [intermediate_children EXCEPT ![n] = @ \cup {newChild}]
    /\ UNCHANGED <<rmState, children, msgs, votes, acks, parent>>

----

(***************************************************************************)
(* State Machine                                                           *)
(***************************************************************************)

Next ==
    \* ── Prepare ──
    \/ RootStartToCommit
    \/ \E n \in Node : Handle2pcPrepareRequest(n)
    \/ \E n \in Node : Handle2pcDuplicatePrepareRequest(n)
    \/ \E n \in Node : HandleOrphan2pcPrepareRequest(n)
    \* ── Vote Collection & Decision ──
    \/ \E n \in Node : Handle2pcPrepareResponse(n)
    \/ \E n \in Node : Handle2pcCommitDecided(n)
    \/ \E n \in Node : Handle2pcAbortDecided(n)
    \* ── Decision Propagation ──
    \/ \E n \in Node : Handle2pcCommitRequest(n)
    \/ \E n \in Node : Handle2pcAbortRequest(n)
    \/ \E n \in Node : HandleOrphan2pcCommitRequest(n)
    \/ \E n \in Node : HandleOrphan2pcAbortRequest(n)
    \* ── Abnormal Flow ──
    \/ \E n \in Node : InternalAbort(n)
    \* ── Completion ──
    \/ \E n \in Node : Handle2pcAckResponse(n)
    \/ \E n \in Node : ForgetCtx(n)
    \* ── Dynamic Membership ──
    \/ \E n, newChild \in Node : AddIntermediateParticipant(n, newChild)

Spec == Init /\ [][Next]_Vars

----

(***************************************************************************)
(* Safety Invariants                                                       *)
(***************************************************************************)

\* No two nodes may disagree on the final decision:
\* it is never the case that one node is COMMIT while another is ABORT.
Consistency ==
    \A n1, n2 \in Node :
        ~(rmState[n1] = "COMMIT" /\ rmState[n2] = "ABORT")

=============================================================================

