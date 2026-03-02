---- MODULE MC ----
EXTENDS 2pc_tla, TLC

CONSTANTS n1, n2, n3

const_Node == {n1, n2, n3}
const_Root == n1

const_InitChildren_fanout == (n1 :> {n2, n3} @@ n2 :> {} @@ n3 :> {})
const_InitChildren_chain == (n1 :> {n2} @@ n2 :> {n3} @@ n3 :> {})

=============================================================================

