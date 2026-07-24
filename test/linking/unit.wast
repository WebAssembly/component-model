;; Linking unit tests covering module/component instance multiplicity,
;; multiple memories, resource types, module and component imports, and deep
;; nesting.

;; Isolation of mutable globals between two instances of one module: bumping
;; a counter in one instance must not affect the other.
(component
  (core module $M
    (global $g (mut i32) (i32.const 0))
    (func (export "bump") (result i32)
      (global.set $g (i32.add (global.get $g) (i32.const 1)))
      (global.get $g)))
  (core instance $a (instantiate $M))
  (core instance $b (instantiate $M))
  (func (export "bump-a") (result u32) (canon lift (core func $a "bump")))
  (func (export "bump-b") (result u32) (canon lift (core func $b "bump")))
)

(assert_return (invoke "bump-a") (u32.const 1))
(assert_return (invoke "bump-a") (u32.const 2))
(assert_return (invoke "bump-b") (u32.const 1))
(assert_return (invoke "bump-a") (u32.const 3))

;; Isolation of linear memories between two instances of one module: a store
;; in one instance's memory must not be visible in the other.
(component
  (core module $M
    (memory 1)
    (func (export "poke") (param i32 i32)
      (i32.store8 (local.get 0) (local.get 1)))
    (func (export "peek") (param i32) (result i32)
      (i32.load8_u (local.get 0))))
  (core instance $a (instantiate $M))
  (core instance $b (instantiate $M))
  (func (export "poke-a") (param "addr" u32) (param "val" u32)
    (canon lift (core func $a "poke")))
  (func (export "peek-a") (param "addr" u32) (result u32)
    (canon lift (core func $a "peek")))
  (func (export "peek-b") (param "addr" u32) (result u32)
    (canon lift (core func $b "peek")))
)

(assert_return (invoke "poke-a" (u32.const 10) (u32.const 42)))
(assert_return (invoke "peek-a" (u32.const 10)) (u32.const 42))
(assert_return (invoke "peek-b" (u32.const 10)) (u32.const 0))

;; Isolation of funcref tables between two instances of one module:
;; redirecting a table slot in one instance must not change indirect calls in
;; the other.
(component
  (core module $M
    (type $t (func (result i32)))
    (table 1 funcref)
    (func $ten (result i32) (i32.const 10))
    (func $twenty (result i32) (i32.const 20))
    (elem (i32.const 0) func $ten)
    (elem declare func $twenty)
    (func (export "set-twenty")
      (table.set (i32.const 0) (ref.func $twenty)))
    (func (export "call") (result i32)
      (call_indirect (type $t) (i32.const 0))))
  (core instance $a (instantiate $M))
  (core instance $b (instantiate $M))
  (func (export "set-twenty-a") (canon lift (core func $a "set-twenty")))
  (func (export "call-a") (result u32) (canon lift (core func $a "call")))
  (func (export "call-b") (result u32) (canon lift (core func $b "call")))
)

(assert_return (invoke "call-a") (u32.const 10))
(assert_return (invoke "call-b") (u32.const 10))
(assert_return (invoke "set-twenty-a"))
(assert_return (invoke "call-a") (u32.const 20))
(assert_return (invoke "call-b") (u32.const 10))

;; One core instance shared by two importers: a single counter instance is
;; imported by two client module instances, so both clients bump the same
;; shared counter.
(component
  (core module $Counter
    (global $g (mut i32) (i32.const 0))
    (func (export "bump") (result i32)
      (global.set $g (i32.add (global.get $g) (i32.const 1)))
      (global.get $g)))
  (core module $Client
    (import "env" "bump" (func $bump (result i32)))
    (func (export "go") (result i32) (call $bump)))
  (core instance $counter (instantiate $Counter))
  (core instance $c1 (instantiate $Client (with "env" (instance $counter))))
  (core instance $c2 (instantiate $Client (with "env" (instance $counter))))
  (func (export "go-1") (result u32) (canon lift (core func $c1 "go")))
  (func (export "go-2") (result u32) (canon lift (core func $c2 "go")))
)

(assert_return (invoke "go-1") (u32.const 1))
(assert_return (invoke "go-2") (u32.const 2))
(assert_return (invoke "go-1") (u32.const 3))

;; Parameterizing instantiation with imported globals: the same module is
;; instantiated twice with different globals, and each instance's behavior
;; reflects the global it was given.
(component
  (core module $Cfg10 (global (export "base") i32 (i32.const 10)))
  (core module $Cfg20 (global (export "base") i32 (i32.const 20)))
  (core module $M
    (import "cfg" "base" (global $base i32))
    (func (export "add") (param i32) (result i32)
      (i32.add (global.get $base) (local.get 0))))
  (core instance $cfg10 (instantiate $Cfg10))
  (core instance $cfg20 (instantiate $Cfg20))
  (core instance $a (instantiate $M (with "cfg" (instance $cfg10))))
  (core instance $b (instantiate $M (with "cfg" (instance $cfg20))))
  (func (export "add-10") (param "x" u32) (result u32)
    (canon lift (core func $a "add")))
  (func (export "add-20") (param "x" u32) (result u32)
    (canon lift (core func $b "add")))
)

(assert_return (invoke "add-10" (u32.const 5)) (u32.const 15))
(assert_return (invoke "add-20" (u32.const 5)) (u32.const 25))

;; Synthesizing a core instance by tupling inline exports: the instance is
;; formed directly from preceding definitions, without instantiating a helper
;; module, and a client imports it like any real instance.
(component
  (core module $A
    (func (export "three") (result i32) (i32.const 3)))
  (core instance $a (instantiate $A))
  (core func $three (alias core export $a "three"))
  (core instance $syn (export "f" (func $three)))
  (core module $Client
    (import "env" "f" (func $f (result i32)))
    (func (export "run") (result i32) (i32.add (call $f) (i32.const 1))))
  (core instance $c (instantiate $Client (with "env" (instance $syn))))
  (func (export "run") (result u32) (canon lift (core func $c "run")))
)

(assert_return (invoke "run") (u32.const 4))

;; Renaming an export to satisfy an import: an import named "one" is
;; satisfied by an export actually named "three" using an inline alias in a
;; synthesized with-instance argument.
(component
  (core module $A
    (func (export "three") (result i32) (i32.const 3)))
  (core module $B
    (import "a" "one" (func $one (result i32)))
    (func (export "run") (result i32) (call $one)))
  (core instance $a (instantiate $A))
  (core instance $b (instantiate $B
    (with "a" (instance (export "one" (func $a "three"))))))
  (func (export "run") (result u32) (canon lift (core func $b "run")))
)

(assert_return (invoke "run") (u32.const 3))

;; Combining exports of two instances under one namespace: a synthesized
;; instance mixes exports originating from two different source instances
;; into a single two-level import namespace.
(component
  (core module $A (func (export "f") (result i32) (i32.const 100)))
  (core module $B (func (export "g") (result i32) (i32.const 23)))
  (core instance $a (instantiate $A))
  (core instance $b (instantiate $B))
  (core module $Client
    (import "env" "f" (func $f (result i32)))
    (import "env" "g" (func $g (result i32)))
    (func (export "sum") (result i32) (i32.add (call $f) (call $g))))
  (core instance $c (instantiate $Client
    (with "env" (instance
      (export "f" (func $a "f"))
      (export "g" (func $b "g"))))))
  (func (export "sum") (result u32) (canon lift (core func $c "sum")))
)

(assert_return (invoke "sum") (u32.const 123))

;; Ordering of core start functions across instantiations: start functions
;; run eagerly at each instantiation, in definition order.
(component
  (core module $Log
    (memory 1)
    (global $n (mut i32) (i32.const 0))
    (func (export "append") (param i32)
      (i32.store8 (global.get $n) (local.get 0))
      (global.set $n (i32.add (global.get $n) (i32.const 1))))
    (func (export "get") (param i32) (result i32)
      (i32.load8_u (local.get 0))))
  (core module $M
    (import "log" "append" (func $append (param i32)))
    (import "cfg" "id" (global $id i32))
    (func $start (call $append (global.get $id)))
    (start $start))
  (core module $Id1 (global (export "id") i32 (i32.const 1)))
  (core module $Id2 (global (export "id") i32 (i32.const 2)))
  (core module $Id3 (global (export "id") i32 (i32.const 3)))
  (core instance $log (instantiate $Log))
  (core instance $id1 (instantiate $Id1))
  (core instance $id2 (instantiate $Id2))
  (core instance $id3 (instantiate $Id3))
  (core instance (instantiate $M
    (with "log" (instance $log)) (with "cfg" (instance $id1))))
  (core instance (instantiate $M
    (with "log" (instance $log)) (with "cfg" (instance $id2))))
  (core instance (instantiate $M
    (with "log" (instance $log)) (with "cfg" (instance $id1))))
  (core instance (instantiate $M
    (with "log" (instance $log)) (with "cfg" (instance $id3))))
  (func (export "log-at") (param "i" u32) (result u32)
    (canon lift (core func $log "get")))
)

(assert_return (invoke "log-at" (u32.const 0)) (u32.const 1))
(assert_return (invoke "log-at" (u32.const 1)) (u32.const 2))
(assert_return (invoke "log-at" (u32.const 2)) (u32.const 1))
(assert_return (invoke "log-at" (u32.const 3)) (u32.const 3))

;; Diamond sharing of one base instance at the core level: a single base
;; instance is shared by two mid-level instances which are both imported by
;; one top instance.
(component
  (core module $Base
    (global $g (mut i32) (i32.const 0))
    (func (export "add") (param i32)
      (global.set $g (i32.add (global.get $g) (local.get 0))))
    (func (export "get") (result i32) (global.get $g)))
  (core module $Mid
    (import "base" "add" (func $add (param i32)))
    (import "base" "get" (func $get (result i32)))
    (import "cfg" "inc" (global $inc i32))
    (func (export "bump") (call $add (global.get $inc)))
    (func (export "read") (result i32) (call $get)))
  (core module $Inc1 (global (export "inc") i32 (i32.const 1)))
  (core module $Inc10 (global (export "inc") i32 (i32.const 10)))
  (core module $Top
    (import "m1" "bump" (func $bump1))
    (import "m2" "bump" (func $bump2))
    (import "m1" "read" (func $read1 (result i32)))
    (import "m2" "read" (func $read2 (result i32)))
    (func (export "run") (result i32)
      (call $bump1)
      (call $bump2)
      (i32.add (call $read1) (call $read2))))
  (core instance $base (instantiate $Base))
  (core instance $inc1 (instantiate $Inc1))
  (core instance $inc10 (instantiate $Inc10))
  (core instance $m1 (instantiate $Mid
    (with "base" (instance $base)) (with "cfg" (instance $inc1))))
  (core instance $m2 (instantiate $Mid
    (with "base" (instance $base)) (with "cfg" (instance $inc10))))
  (core instance $top (instantiate $Top
    (with "m1" (instance $m1)) (with "m2" (instance $m2))))
  (func (export "run") (result u32) (canon lift (core func $top "run")))
)

(assert_return (invoke "run") (u32.const 22))
(assert_return (invoke "run") (u32.const 44))

;; Four memories from two component instances of a two-memory module: each
;; component instance gets its own pair of memories, so stores to the same
;; address in all four memories remain independent.
(component
  (component $C
    (core module $M
      (memory $a 1)
      (memory $b 1)
      (func (export "poke-a") (param i32 i32)
        (i32.store8 $a (local.get 0) (local.get 1)))
      (func (export "poke-b") (param i32 i32)
        (i32.store8 $b (local.get 0) (local.get 1)))
      (func (export "peek-a") (param i32) (result i32)
        (i32.load8_u $a (local.get 0)))
      (func (export "peek-b") (param i32) (result i32)
        (i32.load8_u $b (local.get 0))))
    (core instance $m (instantiate $M))
    (func (export "poke-first") (param "addr" u32) (param "val" u32)
      (canon lift (core func $m "poke-a")))
    (func (export "poke-second") (param "addr" u32) (param "val" u32)
      (canon lift (core func $m "poke-b")))
    (func (export "peek-first") (param "addr" u32) (result u32)
      (canon lift (core func $m "peek-a")))
    (func (export "peek-second") (param "addr" u32) (result u32)
      (canon lift (core func $m "peek-b"))))
  (instance $c1 (instantiate $C))
  (instance $c2 (instantiate $C))
  (func (export "poke-first-1") (alias export $c1 "poke-first"))
  (func (export "poke-second-1") (alias export $c1 "poke-second"))
  (func (export "poke-first-2") (alias export $c2 "poke-first"))
  (func (export "poke-second-2") (alias export $c2 "poke-second"))
  (func (export "peek-first-1") (alias export $c1 "peek-first"))
  (func (export "peek-second-1") (alias export $c1 "peek-second"))
  (func (export "peek-first-2") (alias export $c2 "peek-first"))
  (func (export "peek-second-2") (alias export $c2 "peek-second"))
)

(assert_return (invoke "poke-first-1" (u32.const 7) (u32.const 1)))
(assert_return (invoke "poke-second-1" (u32.const 7) (u32.const 2)))
(assert_return (invoke "poke-first-2" (u32.const 7) (u32.const 3)))
(assert_return (invoke "poke-second-2" (u32.const 7) (u32.const 4)))
(assert_return (invoke "peek-first-1" (u32.const 7)) (u32.const 1))
(assert_return (invoke "peek-second-1" (u32.const 7)) (u32.const 2))
(assert_return (invoke "peek-first-2" (u32.const 7)) (u32.const 3))
(assert_return (invoke "peek-second-2" (u32.const 7)) (u32.const 4))

;; Four memories from two component instances with two providers each: every
;; component instance instantiates its own pair of memory providers, so a
;; write through one instance's imported memory changes only that instance's
;; sum.
(component
  (component $C
    (core module $P1
      (memory (export "mem") 1)
      (data (i32.const 0) "\11"))
    (core module $P2
      (memory (export "mem") 1)
      (data (i32.const 0) "\22"))
    (core module $M
      (import "p1" "mem" (memory $a 1))
      (import "p2" "mem" (memory $b 1))
      (func (export "poke1") (param i32)
        (i32.store8 $a (i32.const 0) (local.get 0)))
      (func (export "poke2") (param i32)
        (i32.store8 $b (i32.const 0) (local.get 0)))
      (func (export "sum") (result i32)
        (i32.add
          (i32.load8_u $a (i32.const 0))
          (i32.load8_u $b (i32.const 0)))))
    (core instance $p1 (instantiate $P1))
    (core instance $p2 (instantiate $P2))
    (core instance $m (instantiate $M
      (with "p1" (instance $p1)) (with "p2" (instance $p2))))
    (func (export "poke-first") (param "val" u32)
      (canon lift (core func $m "poke1")))
    (func (export "poke-second") (param "val" u32)
      (canon lift (core func $m "poke2")))
    (func (export "sum") (result u32) (canon lift (core func $m "sum"))))
  (instance $c1 (instantiate $C))
  (instance $c2 (instantiate $C))
  (func (export "poke-first-1") (alias export $c1 "poke-first"))
  (func (export "poke-second-2") (alias export $c2 "poke-second"))
  (func (export "sum-1") (alias export $c1 "sum"))
  (func (export "sum-2") (alias export $c2 "sum"))
)

(assert_return (invoke "sum-1") (u32.const 0x33))
(assert_return (invoke "sum-2") (u32.const 0x33))
(assert_return (invoke "poke-first-1" (u32.const 1)))
(assert_return (invoke "sum-1") (u32.const 0x23))
(assert_return (invoke "sum-2") (u32.const 0x33))
(assert_return (invoke "poke-second-2" (u32.const 2)))
(assert_return (invoke "sum-1") (u32.const 0x23))
(assert_return (invoke "sum-2") (u32.const 0x13))

;; One memory satisfying two imports of one module: a write through one
;; import name must be visible through the other.
(component
  (core module $P
    (memory (export "mem") 1))
  (core module $M
    (import "p1" "mem" (memory $a 1))
    (import "p2" "mem" (memory $b 1))
    (func (export "poke-a") (param i32 i32)
      (i32.store8 $a (local.get 0) (local.get 1)))
    (func (export "peek-b") (param i32) (result i32)
      (i32.load8_u $b (local.get 0))))
  (core instance $p (instantiate $P))
  (core instance $m (instantiate $M
    (with "p1" (instance $p)) (with "p2" (instance $p))))
  (func (export "poke-a") (param "addr" u32) (param "val" u32)
    (canon lift (core func $m "poke-a")))
  (func (export "peek-b") (param "addr" u32) (result u32)
    (canon lift (core func $m "peek-b")))
)

(assert_return (invoke "poke-a" (u32.const 5) (u32.const 77)))
(assert_return (invoke "peek-b" (u32.const 5)) (u32.const 77))

;; One memory shared by two instances of a module: bytes written by one
;; instance are read by the other.
(component
  (core module $P
    (memory (export "mem") 1))
  (core module $M
    (import "p" "mem" (memory 1))
    (func (export "poke") (param i32 i32)
      (i32.store8 (local.get 0) (local.get 1)))
    (func (export "peek") (param i32) (result i32)
      (i32.load8_u (local.get 0))))
  (core instance $p (instantiate $P))
  (core instance $a (instantiate $M (with "p" (instance $p))))
  (core instance $b (instantiate $M (with "p" (instance $p))))
  (func (export "poke-a") (param "addr" u32) (param "val" u32)
    (canon lift (core func $a "poke")))
  (func (export "peek-b") (param "addr" u32) (result u32)
    (canon lift (core func $b "peek")))
)

(assert_return (invoke "poke-a" (u32.const 9) (u32.const 33)))
(assert_return (invoke "peek-b" (u32.const 9)) (u32.const 33))

;; Different (memory ...) canon opts on two lifts in one component: each
;; lifted func returns the string stored in its own memory, proving the opt
;; selects which memory the ABI reads from.
(component
  (core module $A
    (memory (export "mem") 1)
    (data (i32.const 8) "\10\00\00\00\05\00\00\00")
    (data (i32.const 16) "hello")
    (func (export "get") (result i32) (i32.const 8)))
  (core module $B
    (memory (export "mem") 1)
    (data (i32.const 8) "\10\00\00\00\05\00\00\00")
    (data (i32.const 16) "world")
    (func (export "get") (result i32) (i32.const 8)))
  (core instance $a (instantiate $A))
  (core instance $b (instantiate $B))
  (func (export "get-a") (result string)
    (canon lift (core func $a "get") (memory (core memory $a "mem"))))
  (func (export "get-b") (result string)
    (canon lift (core func $b "get") (memory (core memory $b "mem"))))
)

(assert_return (invoke "get-a") (str.const "hello"))
(assert_return (invoke "get-b") (str.const "world"))

;; Lifting using another module instance's memory: use the one passed
;; to canon lift, not the ambient module.
(component
  (core module $P
    (memory (export "mem") 1)
    (data (i32.const 8) "\10\00\00\00\05\00\00\00")
    (data (i32.const 16) "right"))
  (core module $M
    (memory 1)
    (data (i32.const 8) "\10\00\00\00\05\00\00\00")
    (data (i32.const 16) "wrong")
    (func (export "get") (result i32) (i32.const 8)))
  (core instance $p (instantiate $P))
  (core instance $m (instantiate $M))
  (func (export "get") (result string)
    (canon lift (core func $m "get") (memory (core memory $p "mem"))))
)

(assert_return (invoke "get") (str.const "right"))

;; Isolation of state between two instances of one component: bumping one
;; instance's counter must not affect the other.
(component
  (component $C
    (core module $M
      (global $g (mut i32) (i32.const 0))
      (func (export "bump") (result i32)
        (global.set $g (i32.add (global.get $g) (i32.const 1)))
        (global.get $g)))
    (core instance $m (instantiate $M))
    (func (export "bump") (result u32) (canon lift (core func $m "bump"))))
  (instance $a (instantiate $C))
  (instance $b (instantiate $C))
  (func (export "bump-a") (alias export $a "bump"))
  (func (export "bump-b") (alias export $b "bump"))
)

(assert_return (invoke "bump-a") (u32.const 1))
(assert_return (invoke "bump-b") (u32.const 1))
(assert_return (invoke "bump-a") (u32.const 2))

;; One component instance shared by two consumers: a stateful instance is
;; imported by two consumer instances, so both consumers observe the same
;; shared counter.
(component
  (component $Svc
    (core module $M
      (global $g (mut i32) (i32.const 0))
      (func (export "bump") (result i32)
        (global.set $g (i32.add (global.get $g) (i32.const 1)))
        (global.get $g)))
    (core instance $m (instantiate $M))
    (func (export "bump") (result u32) (canon lift (core func $m "bump"))))
  (component $User
    (import "svc" (instance $svc
      (export "bump" (func (result u32)))))
    (core func $bump (canon lower (func $svc "bump")))
    (core module $M
      (import "svc" "bump" (func $bump (result i32)))
      (func (export "go") (result i32) (call $bump)))
    (core instance $m (instantiate $M
      (with "svc" (instance (export "bump" (func $bump))))))
    (func (export "go") (result u32) (canon lift (core func $m "go"))))
  (instance $svc (instantiate $Svc))
  (instance $u1 (instantiate $User (with "svc" (instance $svc))))
  (instance $u2 (instantiate $User (with "svc" (instance $svc))))
  (func (export "go-1") (alias export $u1 "go"))
  (func (export "go-2") (alias export $u2 "go"))
)

(assert_return (invoke "go-1") (u32.const 1))
(assert_return (invoke "go-2") (u32.const 2))
(assert_return (invoke "go-1") (u32.const 3))

;; Instance width subtyping at instantiation: an instance import declaring
;; only one export is satisfied by an instance that exports three.
(component
  (component $Wid
    (core module $M
      (func (export "f") (result i32) (i32.const 1))
      (func (export "g") (result i32) (i32.const 2))
      (func (export "h") (result i32) (i32.const 3)))
    (core instance $m (instantiate $M))
    (func (export "f") (result u32) (canon lift (core func $m "f")))
    (func (export "g") (result u32) (canon lift (core func $m "g")))
    (func (export "h") (result u32) (canon lift (core func $m "h"))))
  (component $User
    (import "api" (instance $api (export "g" (func (result u32)))))
    (core func $g (canon lower (func $api "g")))
    (core module $UM
      (import "api" "g" (func $g (result i32)))
      (func (export "run") (result i32) (call $g)))
    (core instance $um (instantiate $UM
      (with "api" (instance (export "g" (func $g))))))
    (func (export "run") (result u32) (canon lift (core func $um "run"))))
  (instance $wide (instantiate $Wid))
  (instance $u (instantiate $User (with "api" (instance $wide))))
  (func (export "run") (alias export $u "run"))
)

(assert_return (invoke "run") (u32.const 2))

;; Re-exporting an imported instance unchanged: calls through the re-exported
;; path and the direct path must observe the same underlying state.
(component
  (component $Svc
    (core module $M
      (global $g (mut i32) (i32.const 0))
      (func (export "bump") (result i32)
        (global.set $g (i32.add (global.get $g) (i32.const 1)))
        (global.get $g)))
    (core instance $m (instantiate $M))
    (func (export "bump") (result u32) (canon lift (core func $m "bump"))))
  (component $Fwd
    (import "svc" (instance $svc (export "bump" (func (result u32)))))
    (export "svc" (instance $svc)))
  (instance $svc (instantiate $Svc))
  (instance $fwd (instantiate $Fwd (with "svc" (instance $svc))))
  (alias export $fwd "svc" (instance $fsvc))
  (func (export "bump-direct") (alias export $svc "bump"))
  (func (export "bump-forwarded") (alias export $fsvc "bump"))
)

(assert_return (invoke "bump-direct") (u32.const 1))
(assert_return (invoke "bump-forwarded") (u32.const 2))
(assert_return (invoke "bump-direct") (u32.const 3))

;; An instance argument nested inside an instance argument: a consumer
;; imports an instance whose export is itself an instance, and the argument
;; is built by synthesizing two levels of instance nesting around a sibling's
;; func.
(component
  (component $Provider
    (core module $M
      (func (export "get") (result i32) (i32.const 42)))
    (core instance $m (instantiate $M))
    (func (export "get") (result u32) (canon lift (core func $m "get"))))
  (instance $p (instantiate $Provider))
  (alias export $p "get" (func $get))
  (instance $inner_syn (export "get" (func $get)))
  (instance $outer_syn (export "inner" (instance $inner_syn)))
  (component $User
    (import "outer" (instance $outer
      (export "inner" (instance
        (export "get" (func (result u32)))))))
    (alias export $outer "inner" (instance $inner))
    (core func $get (canon lower (func $inner "get")))
    (core module $UM
      (import "api" "get" (func $get (result i32)))
      (func (export "run") (result i32) (call $get)))
    (core instance $um (instantiate $UM
      (with "api" (instance (export "get" (func $get))))))
    (func (export "run") (result u32) (canon lift (core func $um "run"))))
  (instance $u (instantiate $User (with "outer" (instance $outer_syn))))
  (func (export "run") (alias export $u "run"))
)

(assert_return (invoke "run") (u32.const 42))

;; Instantiating one component at two different sites: the same component is
;; instantiated directly by the parent and also inside a sibling wrapper
;; (which receives it as a component import). The two instances have isolated
;; state.
(component
  (component $C
    (core module $M
      (global $g (mut i32) (i32.const 0))
      (func (export "bump") (result i32)
        (global.set $g (i32.add (global.get $g) (i32.const 1)))
        (global.get $g)))
    (core instance $m (instantiate $M))
    (func (export "bump") (result u32) (canon lift (core func $m "bump"))))
  (component $Wrapper
    (import "c" (component $CC
      (export "bump" (func (result u32)))))
    (instance $inner (instantiate $CC))
    (func (export "bump") (alias export $inner "bump")))
  (instance $direct (instantiate $C))
  (instance $wrapped (instantiate $Wrapper (with "c" (component $C))))
  (func (export "bump-direct") (alias export $direct "bump"))
  (func (export "bump-wrapped") (alias export $wrapped "bump"))
)

(assert_return (invoke "bump-direct") (u32.const 1))
(assert_return (invoke "bump-wrapped") (u32.const 1))
(assert_return (invoke "bump-direct") (u32.const 2))
(assert_return (invoke "bump-wrapped") (u32.const 2))

;; Ordering of component instantiation: component instances are created
;; eagerly in definition order. Each child's core start function takes a
;; ticket from a shared service, so the first-defined instance gets rank 1.
(component
  (component $Ticket
    (core module $M
      (global $n (mut i32) (i32.const 0))
      (func (export "next") (result i32)
        (global.set $n (i32.add (global.get $n) (i32.const 1)))
        (global.get $n)))
    (core instance $m (instantiate $M))
    (func (export "next") (result u32) (canon lift (core func $m "next"))))
  (component $Child
    (import "ticket" (instance $t (export "next" (func (result u32)))))
    (core func $next (canon lower (func $t "next")))
    (core module $M
      (import "t" "next" (func $next (result i32)))
      (global $rank (mut i32) (i32.const 0))
      (func $start (global.set $rank (call $next)))
      (start $start)
      (func (export "rank") (result i32) (global.get $rank)))
    (core instance $m (instantiate $M
      (with "t" (instance (export "next" (func $next))))))
    (func (export "rank") (result u32) (canon lift (core func $m "rank"))))
  (instance $ticket (instantiate $Ticket))
  (instance $a (instantiate $Child (with "ticket" (instance $ticket))))
  (instance $b (instantiate $Child (with "ticket" (instance $ticket))))
  (instance $c (instantiate $Child (with "ticket" (instance $ticket))))
  (func (export "rank-a") (alias export $a "rank"))
  (func (export "rank-b") (alias export $b "rank"))
  (func (export "rank-c") (alias export $c "rank"))
)

(assert_return (invoke "rank-a") (u32.const 1))
(assert_return (invoke "rank-b") (u32.const 2))
(assert_return (invoke "rank-c") (u32.const 3))

;; Two resource types with different dtors in one component: dropping handles
;; of each type from a consumer must run the dtor belonging to that type.
;; Two definer instances generate two fresh pairs of resource types, and the
;; dtors accumulate the reps they receive, so every one of the four types'
;; drops is distinguishable.
(component
  (component $Def
    (core module $M
      (global $c1 (mut i32) (i32.const 0))
      (global $c2 (mut i32) (i32.const 0))
      (func (export "dtor1") (param i32)
        (global.set $c1 (i32.add (global.get $c1) (local.get 0))))
      (func (export "dtor2") (param i32)
        (global.set $c2 (i32.add (global.get $c2) (local.get 0))))
      (func (export "count1") (result i32) (global.get $c1))
      (func (export "count2") (result i32) (global.get $c2)))
    (core instance $m (instantiate $M))
    (type $R1 (resource (rep i32) (dtor (core func $m "dtor1"))))
    (type $R2 (resource (rep i32) (dtor (core func $m "dtor2"))))
    (export $R1e "r1" (type $R1))
    (export $R2e "r2" (type $R2))
    (core func $new1 (canon resource.new $R1))
    (core func $new2 (canon resource.new $R2))
    (core module $Maker
      (import "canon" "new1" (func $new1 (param i32) (result i32)))
      (import "canon" "new2" (func $new2 (param i32) (result i32)))
      (func (export "make1") (param i32) (result i32) (call $new1 (local.get 0)))
      (func (export "make2") (param i32) (result i32) (call $new2 (local.get 0))))
    (core instance $maker (instantiate $Maker
      (with "canon" (instance
        (export "new1" (func $new1)) (export "new2" (func $new2))))))
    (func (export "make1") (param "rep" u32) (result (own $R1e))
      (canon lift (core func $maker "make1")))
    (func (export "make2") (param "rep" u32) (result (own $R2e))
      (canon lift (core func $maker "make2")))
    (func (export "count1") (result u32) (canon lift (core func $m "count1")))
    (func (export "count2") (result u32) (canon lift (core func $m "count2"))))
  (component $User
    (import "def" (instance $def
      (export "r1" (type $R1 (sub resource)))
      (export "r2" (type $R2 (sub resource)))
      (export "make1" (func (param "rep" u32) (result (own $R1))))
      (export "make2" (func (param "rep" u32) (result (own $R2))))))
    (alias export $def "r1" (type $R1))
    (alias export $def "r2" (type $R2))
    (core func $make1 (canon lower (func $def "make1")))
    (core func $make2 (canon lower (func $def "make2")))
    (core func $drop1 (canon resource.drop $R1))
    (core func $drop2 (canon resource.drop $R2))
    (core module $M
      (import "e" "make1" (func $make1 (param i32) (result i32)))
      (import "e" "make2" (func $make2 (param i32) (result i32)))
      (import "e" "drop1" (func $drop1 (param i32)))
      (import "e" "drop2" (func $drop2 (param i32)))
      (func (export "run") (param i32)
        (call $drop1 (call $make1 (local.get 0)))
        (call $drop2 (call $make2 (i32.add (local.get 0) (i32.const 1))))
        (call $drop2 (call $make2 (i32.add (local.get 0) (i32.const 2))))))
    (core instance $m (instantiate $M
      (with "e" (instance
        (export "make1" (func $make1)) (export "make2" (func $make2))
        (export "drop1" (func $drop1)) (export "drop2" (func $drop2))))))
    (func (export "run") (param "rep" u32) (canon lift (core func $m "run"))))
  (instance $def1 (instantiate $Def))
  (instance $def2 (instantiate $Def))
  (instance $user1 (instantiate $User (with "def" (instance $def1))))
  (instance $user2 (instantiate $User (with "def" (instance $def2))))
  (func (export "run-1") (alias export $user1 "run"))
  (func (export "run-2") (alias export $user2 "run"))
  (func (export "count1-1") (alias export $def1 "count1"))
  (func (export "count2-1") (alias export $def1 "count2"))
  (func (export "count1-2") (alias export $def2 "count1"))
  (func (export "count2-2") (alias export $def2 "count2"))
)

(assert_return (invoke "run-1" (u32.const 10)))
(assert_return (invoke "run-2" (u32.const 40)))
(assert_return (invoke "count1-1") (u32.const 10))
(assert_return (invoke "count2-1") (u32.const 23))
(assert_return (invoke "count1-2") (u32.const 40))
(assert_return (invoke "count2-2") (u32.const 83))

;; The rep value passed to a dtor: a dtor receives the representation value
;; of the resource being dropped. Each definer instance logs its dtor's rep
;; arguments in its own memory, and each consumer drops two resources in
;; reverse creation order, so the two instances' logs stay independent.
(component
  (component $Def
    (core module $M
      (memory 1)
      (global $n (mut i32) (i32.const 0))
      (func (export "dtor") (param i32)
        (i32.store8 (global.get $n) (local.get 0))
        (global.set $n (i32.add (global.get $n) (i32.const 1))))
      (func (export "log-at") (param i32) (result i32)
        (i32.load8_u (local.get 0))))
    (core instance $m (instantiate $M))
    (type $R (resource (rep i32) (dtor (core func $m "dtor"))))
    (export $Re "r" (type $R))
    (core func $new (canon resource.new $R))
    (core module $Maker
      (import "canon" "new" (func $new (param i32) (result i32)))
      (func (export "make") (param i32) (result i32) (call $new (local.get 0))))
    (core instance $maker (instantiate $Maker
      (with "canon" (instance (export "new" (func $new))))))
    (func (export "make") (param "rep" u32) (result (own $Re))
      (canon lift (core func $maker "make")))
    (func (export "log-at") (param "i" u32) (result u32)
      (canon lift (core func $m "log-at"))))
  (component $User
    (import "def" (instance $def
      (export "r" (type $R (sub resource)))
      (export "make" (func (param "rep" u32) (result (own $R))))))
    (alias export $def "r" (type $R))
    (core func $make (canon lower (func $def "make")))
    (core func $drop (canon resource.drop $R))
    (core module $M
      (import "e" "make" (func $make (param i32) (result i32)))
      (import "e" "drop" (func $drop (param i32)))
      (func (export "run") (param i32) (local $h1 i32) (local $h2 i32)
        (local.set $h1 (call $make (local.get 0)))
        (local.set $h2 (call $make (i32.add (local.get 0) (i32.const 2))))
        (call $drop (local.get $h2))
        (call $drop (local.get $h1))))
    (core instance $m (instantiate $M
      (with "e" (instance
        (export "make" (func $make)) (export "drop" (func $drop))))))
    (func (export "run") (param "rep" u32) (canon lift (core func $m "run"))))
  (instance $def1 (instantiate $Def))
  (instance $def2 (instantiate $Def))
  (instance $user1 (instantiate $User (with "def" (instance $def1))))
  (instance $user2 (instantiate $User (with "def" (instance $def2))))
  (func (export "run-1") (alias export $user1 "run"))
  (func (export "run-2") (alias export $user2 "run"))
  (func (export "log-at-1") (alias export $def1 "log-at"))
  (func (export "log-at-2") (alias export $def2 "log-at"))
)

(assert_return (invoke "run-1" (u32.const 7)))
(assert_return (invoke "run-2" (u32.const 20)))
(assert_return (invoke "log-at-1" (u32.const 0)) (u32.const 9))
(assert_return (invoke "log-at-1" (u32.const 1)) (u32.const 7))
(assert_return (invoke "log-at-2" (u32.const 0)) (u32.const 22))
(assert_return (invoke "log-at-2" (u32.const 1)) (u32.const 20))

;; Transferring an own handle through a middleman: an own handle created by
;; the definer is received by one component and passed on to a second
;; component, which drops it, running the definer's dtor. The whole
;; def/sink/user chain is instantiated twice; each chain's handles carry that
;; chain's fresh resource type and only reach that chain's dtor.
(component
  (component $Def
    (core module $M
      (global $c (mut i32) (i32.const 0))
      (func (export "dtor") (param i32)
        (global.set $c (i32.add (global.get $c) (local.get 0))))
      (func (export "count") (result i32) (global.get $c)))
    (core instance $m (instantiate $M))
    (type $R (resource (rep i32) (dtor (core func $m "dtor"))))
    (export $Re "r" (type $R))
    (core func $new (canon resource.new $R))
    (core module $Maker
      (import "canon" "new" (func $new (param i32) (result i32)))
      (func (export "make") (param i32) (result i32) (call $new (local.get 0))))
    (core instance $maker (instantiate $Maker
      (with "canon" (instance (export "new" (func $new))))))
    (func (export "make") (param "rep" u32) (result (own $Re))
      (canon lift (core func $maker "make")))
    (func (export "count") (result u32) (canon lift (core func $m "count"))))
  (component $Sink
    (import "def" (instance $def
      (export "r" (type (sub resource)))))
    (alias export $def "r" (type $R))
    (core func $drop (canon resource.drop $R))
    (core module $M
      (import "e" "drop" (func $drop (param i32)))
      (func (export "take") (param i32) (call $drop (local.get 0))))
    (core instance $m (instantiate $M
      (with "e" (instance (export "drop" (func $drop))))))
    (func (export "take") (param "h" (own $R))
      (canon lift (core func $m "take"))))
  (component $User
    (import "def" (instance $def
      (export "r" (type $Rd (sub resource)))
      (export "make" (func (param "rep" u32) (result (own $Rd))))))
    (alias export $def "r" (type $R))
    (import "sink" (instance $sink
      (alias outer $User $R (type $Rs))
      (export "take" (func (param "h" (own $Rs))))))
    (core func $make (canon lower (func $def "make")))
    (core func $take (canon lower (func $sink "take")))
    (core module $M
      (import "e" "make" (func $make (param i32) (result i32)))
      (import "e" "take" (func $take (param i32)))
      (func (export "run") (param i32)
        (call $take (call $make (local.get 0)))))
    (core instance $m (instantiate $M
      (with "e" (instance
        (export "make" (func $make)) (export "take" (func $take))))))
    (func (export "run") (param "rep" u32) (canon lift (core func $m "run"))))
  (instance $def1 (instantiate $Def))
  (instance $def2 (instantiate $Def))
  (instance $sink1 (instantiate $Sink (with "def" (instance $def1))))
  (instance $sink2 (instantiate $Sink (with "def" (instance $def2))))
  (instance $user1 (instantiate $User
    (with "def" (instance $def1)) (with "sink" (instance $sink1))))
  (instance $user2 (instantiate $User
    (with "def" (instance $def2)) (with "sink" (instance $sink2))))
  (func (export "run-1") (alias export $user1 "run"))
  (func (export "run-2") (alias export $user2 "run"))
  (func (export "count-1") (alias export $def1 "count"))
  (func (export "count-2") (alias export $def2 "count"))
)

(assert_return (invoke "run-1" (u32.const 41)))
(assert_return (invoke "run-2" (u32.const 58)))
(assert_return (invoke "count-1") (u32.const 41))
(assert_return (invoke "count-2") (u32.const 58))

;; Lending a borrow back to the definer: a consumer lends a borrow of its own
;; handle to the definer, whose method observes the rep directly. Dropping
;; the own handle afterwards still runs the dtor exactly once. Two
;; definer/consumer pairs keep independent dtor counts.
(component
  (component $Def
    (core module $M
      (global $c (mut i32) (i32.const 0))
      (func (export "dtor") (param i32)
        (global.set $c (i32.add (global.get $c) (local.get 0))))
      (func (export "count") (result i32) (global.get $c))
      (func (export "get") (param i32) (result i32)
        (i32.mul (local.get 0) (i32.const 2))))
    (core instance $m (instantiate $M))
    (type $R (resource (rep i32) (dtor (core func $m "dtor"))))
    (export $Re "r" (type $R))
    (core func $new (canon resource.new $R))
    (core module $Maker
      (import "canon" "new" (func $new (param i32) (result i32)))
      (func (export "make") (param i32) (result i32) (call $new (local.get 0))))
    (core instance $maker (instantiate $Maker
      (with "canon" (instance (export "new" (func $new))))))
    (func (export "make") (param "rep" u32) (result (own $Re))
      (canon lift (core func $maker "make")))
    (func (export "get") (param "h" (borrow $Re)) (result u32)
      (canon lift (core func $m "get")))
    (func (export "count") (result u32) (canon lift (core func $m "count"))))
  (component $User
    (import "def" (instance $def
      (export "r" (type $R (sub resource)))
      (export "make" (func (param "rep" u32) (result (own $R))))
      (export "get" (func (param "h" (borrow $R)) (result u32)))))
    (alias export $def "r" (type $R))
    (core func $make (canon lower (func $def "make")))
    (core func $get (canon lower (func $def "get")))
    (core func $drop (canon resource.drop $R))
    (core module $M
      (import "e" "make" (func $make (param i32) (result i32)))
      (import "e" "get" (func $get (param i32) (result i32)))
      (import "e" "drop" (func $drop (param i32)))
      (func (export "run") (param i32) (result i32)
        (local $h i32) (local $v i32)
        (local.set $h (call $make (local.get 0)))
        (local.set $v (call $get (local.get $h)))
        (call $drop (local.get $h))
        (local.get $v)))
    (core instance $m (instantiate $M
      (with "e" (instance
        (export "make" (func $make)) (export "get" (func $get))
        (export "drop" (func $drop))))))
    (func (export "run") (param "rep" u32) (result u32)
      (canon lift (core func $m "run"))))
  (instance $def1 (instantiate $Def))
  (instance $def2 (instantiate $Def))
  (instance $user1 (instantiate $User (with "def" (instance $def1))))
  (instance $user2 (instantiate $User (with "def" (instance $def2))))
  (func (export "run-1") (alias export $user1 "run"))
  (func (export "run-2") (alias export $user2 "run"))
  (func (export "count-1") (alias export $def1 "count"))
  (func (export "count-2") (alias export $def2 "count"))
)

(assert_return (invoke "run-1" (u32.const 13)) (u32.const 26))
(assert_return (invoke "run-2" (u32.const 30)) (u32.const 60))
(assert_return (invoke "count-1") (u32.const 13))
(assert_return (invoke "count-2") (u32.const 30))

;; Generative resource types across component instances: each instance of a
;; resource-defining component generates a fresh resource type with its own
;; dtor state. A single consumer imports both definer instances, keeping the
;; two types distinct, and each drop runs only that type's own dtor.
(component
  (component $Def
    (core module $M
      (global $c (mut i32) (i32.const 0))
      (func (export "dtor") (param i32)
        (global.set $c (i32.add (global.get $c) (local.get 0))))
      (func (export "count") (result i32) (global.get $c)))
    (core instance $m (instantiate $M))
    (type $R (resource (rep i32) (dtor (core func $m "dtor"))))
    (export $Re "r" (type $R))
    (core func $new (canon resource.new $R))
    (core module $Maker
      (import "canon" "new" (func $new (param i32) (result i32)))
      (func (export "make") (param i32) (result i32) (call $new (local.get 0))))
    (core instance $maker (instantiate $Maker
      (with "canon" (instance (export "new" (func $new))))))
    (func (export "make") (param "rep" u32) (result (own $Re))
      (canon lift (core func $maker "make")))
    (func (export "count") (result u32) (canon lift (core func $m "count"))))
  (component $User
    (import "def1" (instance $def1
      (export "r" (type $R1 (sub resource)))
      (export "make" (func (param "rep" u32) (result (own $R1))))))
    (import "def2" (instance $def2
      (export "r" (type $R2 (sub resource)))
      (export "make" (func (param "rep" u32) (result (own $R2))))))
    (alias export $def1 "r" (type $R1))
    (alias export $def2 "r" (type $R2))
    (core func $make1 (canon lower (func $def1 "make")))
    (core func $make2 (canon lower (func $def2 "make")))
    (core func $drop1 (canon resource.drop $R1))
    (core func $drop2 (canon resource.drop $R2))
    (core module $M
      (import "e" "make1" (func $make1 (param i32) (result i32)))
      (import "e" "make2" (func $make2 (param i32) (result i32)))
      (import "e" "drop1" (func $drop1 (param i32)))
      (import "e" "drop2" (func $drop2 (param i32)))
      (func (export "run") (param i32 i32)
        (call $drop1 (call $make1 (local.get 0)))
        (call $drop2 (call $make2 (local.get 1)))))
    (core instance $m (instantiate $M
      (with "e" (instance
        (export "make1" (func $make1)) (export "make2" (func $make2))
        (export "drop1" (func $drop1)) (export "drop2" (func $drop2))))))
    (func (export "run") (param "rep1" u32) (param "rep2" u32)
      (canon lift (core func $m "run"))))
  (instance $def1 (instantiate $Def))
  (instance $def2 (instantiate $Def))
  (instance $user (instantiate $User
    (with "def1" (instance $def1)) (with "def2" (instance $def2))))
  (func (export "run") (alias export $user "run"))
  (func (export "count-1") (alias export $def1 "count"))
  (func (export "count-2") (alias export $def2 "count"))
)

(assert_return (invoke "run" (u32.const 5) (u32.const 100)))
(assert_return (invoke "run" (u32.const 3) (u32.const 200)))
(assert_return (invoke "count-1") (u32.const 8))
(assert_return (invoke "count-2") (u32.const 300))

;; Per-instance handle-index allocation: handle indices come from a per-
;; component-instance table starting at 1, so creating resources in one
;; instance does not shift the indices handed out by another instance.
(component
  (component $C
    (type $R (resource (rep i32)))
    (core func $new (canon resource.new $R))
    (core module $M
      (import "canon" "new" (func $new (param i32) (result i32)))
      (func (export "make") (result i32) (call $new (i32.const 0))))
    (core instance $m (instantiate $M
      (with "canon" (instance (export "new" (func $new))))))
    (func (export "make") (result u32) (canon lift (core func $m "make"))))
  (instance $c1 (instantiate $C))
  (instance $c2 (instantiate $C))
  (func (export "make-1") (alias export $c1 "make"))
  (func (export "make-2") (alias export $c2 "make"))
)

(assert_return (invoke "make-1") (u32.const 1))
(assert_return (invoke "make-1") (u32.const 2))
(assert_return (invoke "make-2") (u32.const 1))
(assert_return (invoke "make-1") (u32.const 3))
(assert_return (invoke "make-2") (u32.const 2))

;; One resource type exported under two names: the second export is eq-bound
;; to the first, so a handle produced via the "r1"-typed func is consumed by
;; the "r2"-typed func. A single consumer imports both definer instances'
;; eq-bound pairs -- four type imports naming two distinct types -- and each
;; handle round-trips only through its own definer's dtor.
(component
  (component $Def
    (core module $M
      (global $c (mut i32) (i32.const 0))
      (func (export "dtor") (param i32)
        (global.set $c (i32.add (global.get $c) (local.get 0))))
      (func (export "count") (result i32) (global.get $c)))
    (core instance $m (instantiate $M))
    (type $R (resource (rep i32) (dtor (core func $m "dtor"))))
    (export $R1e "r1" (type $R))
    (export $R2e "r2" (type $R))
    (core func $new (canon resource.new $R))
    (core func $dropr (canon resource.drop $R))
    (core module $Maker
      (import "canon" "new" (func $new (param i32) (result i32)))
      (import "canon" "drop" (func $drop (param i32)))
      (func (export "make") (param i32) (result i32) (call $new (local.get 0)))
      (func (export "take") (param i32) (call $drop (local.get 0))))
    (core instance $maker (instantiate $Maker
      (with "canon" (instance
        (export "new" (func $new)) (export "drop" (func $dropr))))))
    (func (export "make") (param "rep" u32) (result (own $R1e))
      (canon lift (core func $maker "make")))
    (func (export "take") (param "h" (own $R2e))
      (canon lift (core func $maker "take")))
    (func (export "count") (result u32) (canon lift (core func $m "count"))))
  (component $User
    (import "def1" (instance $def1
      (export "r1" (type $R1a (sub resource)))
      (export "r2" (type $R1b (eq $R1a)))
      (export "make" (func (param "rep" u32) (result (own $R1a))))
      (export "take" (func (param "h" (own $R1b))))))
    (import "def2" (instance $def2
      (export "r1" (type $R2a (sub resource)))
      (export "r2" (type $R2b (eq $R2a)))
      (export "make" (func (param "rep" u32) (result (own $R2a))))
      (export "take" (func (param "h" (own $R2b))))))
    (core func $make1 (canon lower (func $def1 "make")))
    (core func $take1 (canon lower (func $def1 "take")))
    (core func $make2 (canon lower (func $def2 "make")))
    (core func $take2 (canon lower (func $def2 "take")))
    (core module $M
      (import "e" "make1" (func $make1 (param i32) (result i32)))
      (import "e" "take1" (func $take1 (param i32)))
      (import "e" "make2" (func $make2 (param i32) (result i32)))
      (import "e" "take2" (func $take2 (param i32)))
      (func (export "run") (param i32 i32)
        (call $take1 (call $make1 (local.get 0)))
        (call $take2 (call $make2 (local.get 1)))))
    (core instance $m (instantiate $M
      (with "e" (instance
        (export "make1" (func $make1)) (export "take1" (func $take1))
        (export "make2" (func $make2)) (export "take2" (func $take2))))))
    (func (export "run") (param "rep1" u32) (param "rep2" u32)
      (canon lift (core func $m "run"))))
  (instance $def1 (instantiate $Def))
  (instance $def2 (instantiate $Def))
  (instance $user (instantiate $User
    (with "def1" (instance $def1)) (with "def2" (instance $def2))))
  (func (export "run") (alias export $user "run"))
  (func (export "count-1") (alias export $def1 "count"))
  (func (export "count-2") (alias export $def2 "count"))
)

(assert_return (invoke "run" (u32.const 9) (u32.const 12)))
(assert_return (invoke "run" (u32.const 4) (u32.const 30)))
(assert_return (invoke "count-1") (u32.const 13))
(assert_return (invoke "count-2") (u32.const 42))

;; Substituting different resource types into one consumer: the consumer
;; imports a bare abstract resource type plus make/take funcs. Instantiating
;; it twice with two different definers substitutes each definer's fresh
;; type, and each pipeline hits its own definer's dtor.
(component
  (component $Def
    (core module $M
      (global $c (mut i32) (i32.const 0))
      (func (export "dtor") (param i32)
        (global.set $c (i32.add (global.get $c) (local.get 0))))
      (func (export "count") (result i32) (global.get $c)))
    (core instance $m (instantiate $M))
    (type $R (resource (rep i32) (dtor (core func $m "dtor"))))
    (export $Re "r" (type $R))
    (core func $new (canon resource.new $R))
    (core func $dropr (canon resource.drop $R))
    (core module $Maker
      (import "canon" "new" (func $new (param i32) (result i32)))
      (import "canon" "drop" (func $drop (param i32)))
      (func (export "make") (param i32) (result i32) (call $new (local.get 0)))
      (func (export "take") (param i32) (call $drop (local.get 0))))
    (core instance $maker (instantiate $Maker
      (with "canon" (instance
        (export "new" (func $new)) (export "drop" (func $dropr))))))
    (func (export "make") (param "rep" u32) (result (own $Re))
      (canon lift (core func $maker "make")))
    (func (export "take") (param "h" (own $Re))
      (canon lift (core func $maker "take")))
    (func (export "count") (result u32) (canon lift (core func $m "count"))))
  (component $User
    (import "r" (type $R (sub resource)))
    (import "make" (func $make (param "rep" u32) (result (own $R))))
    (import "take" (func $take (param "h" (own $R))))
    (core func $make_l (canon lower (func $make)))
    (core func $take_l (canon lower (func $take)))
    (core module $M
      (import "e" "make" (func $make (param i32) (result i32)))
      (import "e" "take" (func $take (param i32)))
      (func (export "run") (param i32)
        (call $take (call $make (local.get 0)))))
    (core instance $m (instantiate $M
      (with "e" (instance
        (export "make" (func $make_l)) (export "take" (func $take_l))))))
    (func (export "run") (param "rep" u32) (canon lift (core func $m "run"))))
  (instance $def1 (instantiate $Def))
  (instance $def2 (instantiate $Def))
  (alias export $def1 "r" (type $R1))
  (alias export $def2 "r" (type $R2))
  (instance $u1 (instantiate $User
    (with "r" (type $R1))
    (with "make" (func $def1 "make"))
    (with "take" (func $def1 "take"))))
  (instance $u2 (instantiate $User
    (with "r" (type $R2))
    (with "make" (func $def2 "make"))
    (with "take" (func $def2 "take"))))
  (func (export "run-1") (alias export $u1 "run"))
  (func (export "run-2") (alias export $u2 "run"))
  (func (export "count-1") (alias export $def1 "count"))
  (func (export "count-2") (alias export $def2 "count"))
)

(assert_return (invoke "run-1" (u32.const 4)))
(assert_return (invoke "run-2" (u32.const 6)))
(assert_return (invoke "count-1") (u32.const 4))
(assert_return (invoke "count-2") (u32.const 6))
(assert_return (invoke "run-1" (u32.const 10)))
(assert_return (invoke "run-1" (u32.const 20)))
(assert_return (invoke "count-1") (u32.const 34))
(assert_return (invoke "count-2") (u32.const 6))

;; Filling a module import two different ways: a component imports a core
;; module and instantiates it, and filling that import with two different
;; modules yields component instances with different behavior.
(component
  (component $C
    (import "m" (core module $M
      (export "get" (func (result i32)))))
    (core instance $m (instantiate $M))
    (func (export "get") (result u32) (canon lift (core func $m "get"))))
  (core module $M1 (func (export "get") (result i32) (i32.const 111)))
  (core module $M2 (func (export "get") (result i32) (i32.const 222)))
  (instance $c1 (instantiate $C (with "m" (core module $M1))))
  (instance $c2 (instantiate $C (with "m" (core module $M2))))
  (func (export "get-1") (alias export $c1 "get"))
  (func (export "get-2") (alias export $c2 "get"))
)

(assert_return (invoke "get-1") (u32.const 111))
(assert_return (invoke "get-2") (u32.const 222))

;; Filling a component import two different ways: a wrapper imports a
;; component, instantiates it internally, and calls it from a sibling instance.
(component
  (component $Wrap
    (import "c" (component $C
      (export "get" (func (result u32)))))
    (component $Compute
      (import "get" (func $get (result u32)))
      (core func $get_l (canon lower (func $get)))
      (core module $M
        (import "inner" "get" (func $get (result i32)))
        (func (export "get") (result i32)
          (i32.add (i32.mul (call $get) (i32.const 10)) (i32.const 1))))
      (core instance $m (instantiate $M
        (with "inner" (instance (export "get" (func $get_l))))))
      (func (export "get") (result u32) (canon lift (core func $m "get"))))
    (instance $inner (instantiate $C))
    (instance $compute (instantiate $Compute (with "get" (func $inner "get"))))
    (func (export "get") (alias export $compute "get")))
  (component $A
    (core module $M (func (export "get") (result i32) (i32.const 7)))
    (core instance $m (instantiate $M))
    (func (export "get") (result u32) (canon lift (core func $m "get"))))
  (component $B
    (core module $M (func (export "get") (result i32) (i32.const 8)))
    (core instance $m (instantiate $M))
    (func (export "get") (result u32) (canon lift (core func $m "get"))))
  (instance $w1 (instantiate $Wrap (with "c" (component $A))))
  (instance $w2 (instantiate $Wrap (with "c" (component $B))))
  (func (export "get-1") (alias export $w1 "get"))
  (func (export "get-2") (alias export $w2 "get"))
)

(assert_return (invoke "get-1") (u32.const 71))
(assert_return (invoke "get-2") (u32.const 81))

;; Instantiating an imported module twice in one component: the imported
;; module's type declares an import of its own, which the importing component
;; fills with a different step global for each of its two core instances, so
;; the two counters stay separate and advance by different steps.
(component
  (component $C
    (import "m" (core module $M
      (import "cfg" "step" (global i32))
      (export "bump" (func (result i32)))))
    (core module $Step1 (global (export "step") i32 (i32.const 1)))
    (core module $Step10 (global (export "step") i32 (i32.const 10)))
    (core instance $step1 (instantiate $Step1))
    (core instance $step10 (instantiate $Step10))
    (core instance $a (instantiate $M (with "cfg" (instance $step1))))
    (core instance $b (instantiate $M (with "cfg" (instance $step10))))
    (core module $Top
      (import "a" "bump" (func $ba (result i32)))
      (import "b" "bump" (func $bb (result i32)))
      (func (export "run") (result i32)
        (drop (call $ba))
        (drop (call $ba))
        (i32.add (i32.mul (call $ba) (i32.const 100)) (call $bb))))
    (core instance $top (instantiate $Top
      (with "a" (instance $a)) (with "b" (instance $b))))
    (func (export "run") (result u32) (canon lift (core func $top "run"))))
  (core module $Counter
    (import "cfg" "step" (global $step i32))
    (global $g (mut i32) (i32.const 0))
    (func (export "bump") (result i32)
      (global.set $g (i32.add (global.get $g) (global.get $step)))
      (global.get $g)))
  (instance $c (instantiate $C (with "m" (core module $Counter))))
  (func (export "run") (alias export $c "run"))
)

(assert_return (invoke "run") (u32.const 310))

;; Instantiating an imported component twice in one wrapper: the imported
;; component's type declares a func import that the wrapper fills differently
;; for each of its two instances, so the two inner counters stay isolated and
;; advance by different steps.
(component
  (component $Wrap
    (import "c" (component $C
      (import "step" (func (result u32)))
      (export "bump" (func (result u32)))))
    (import "step1" (func $s1 (result u32)))
    (import "step2" (func $s2 (result u32)))
    (instance $i1 (instantiate $C (with "step" (func $s1))))
    (instance $i2 (instantiate $C (with "step" (func $s2))))
    (func (export "bump-1") (alias export $i1 "bump"))
    (func (export "bump-2") (alias export $i2 "bump")))
  (component $Counter
    (import "step" (func $step (result u32)))
    (core func $step_l (canon lower (func $step)))
    (core module $M
      (import "e" "step" (func $step (result i32)))
      (global $g (mut i32) (i32.const 0))
      (func (export "bump") (result i32)
        (global.set $g (i32.add (global.get $g) (call $step)))
        (global.get $g)))
    (core instance $m (instantiate $M
      (with "e" (instance (export "step" (func $step_l))))))
    (func (export "bump") (result u32) (canon lift (core func $m "bump"))))
  (component $Step1
    (core module $M (func (export "get") (result i32) (i32.const 1)))
    (core instance $m (instantiate $M))
    (func (export "get") (result u32) (canon lift (core func $m "get"))))
  (component $Step10
    (core module $M (func (export "get") (result i32) (i32.const 10)))
    (core instance $m (instantiate $M))
    (func (export "get") (result u32) (canon lift (core func $m "get"))))
  (instance $s1 (instantiate $Step1))
  (instance $s10 (instantiate $Step10))
  (instance $w (instantiate $Wrap
    (with "c" (component $Counter))
    (with "step1" (func $s1 "get"))
    (with "step2" (func $s10 "get"))))
  (func (export "bump-1") (alias export $w "bump-1"))
  (func (export "bump-2") (alias export $w "bump-2"))
)

(assert_return (invoke "bump-1") (u32.const 1))
(assert_return (invoke "bump-2") (u32.const 10))
(assert_return (invoke "bump-1") (u32.const 2))
(assert_return (invoke "bump-2") (u32.const 20))

;; Forwarding a module import down two component levels: a core module
;; imported at the top of the nesting is passed down as an instantiation
;; argument and only instantiated at the innermost leaves. Two instances are
;; created at each level -- four leaves totalling eight independent counter
;; instances, all observed through re-exported run funcs.
(component
  (component $L1
    (import "m" (core module $M1 (export "bump" (func (result i32)))))
    (component $L2
      (import "m" (core module $M2 (export "bump" (func (result i32)))))
      (core instance $a (instantiate $M2))
      (core instance $b (instantiate $M2))
      (core module $Sum
        (import "a" "bump" (func $ba (result i32)))
        (import "b" "bump" (func $bb (result i32)))
        (func (export "run") (result i32)
          (i32.add (call $ba) (i32.mul (i32.const 10) (call $bb)))))
      (core instance $sum (instantiate $Sum
        (with "a" (instance $a)) (with "b" (instance $b))))
      (func (export "run") (result u32) (canon lift (core func $sum "run"))))
    (instance $x (instantiate $L2 (with "m" (core module $M1))))
    (instance $y (instantiate $L2 (with "m" (core module $M1))))
    (func (export "run-1") (alias export $x "run"))
    (func (export "run-2") (alias export $y "run")))
  (core module $Impl
    (global $g (mut i32) (i32.const 0))
    (func (export "bump") (result i32)
      (global.set $g (i32.add (global.get $g) (i32.const 1)))
      (global.get $g)))
  (instance $o1 (instantiate $L1 (with "m" (core module $Impl))))
  (instance $o2 (instantiate $L1 (with "m" (core module $Impl))))
  (func (export "run-11") (alias export $o1 "run-1"))
  (func (export "run-12") (alias export $o1 "run-2"))
  (func (export "run-21") (alias export $o2 "run-1"))
  (func (export "run-22") (alias export $o2 "run-2"))
)

(assert_return (invoke "run-11") (u32.const 11))
(assert_return (invoke "run-11") (u32.const 22))
(assert_return (invoke "run-12") (u32.const 11))
(assert_return (invoke "run-21") (u32.const 11))
(assert_return (invoke "run-22") (u32.const 11))
(assert_return (invoke "run-22") (u32.const 22))

;; Forwarding a component import down two levels: a component imported at the
;; top of the nesting is passed down as an instantiation argument and only
;; instantiated at the innermost leaves. Two instances are created at each
;; level -- each of the four leaves instantiates the imported counter twice
;; and sums the pair through a sibling aggregator instance.
(component
  (component $L1
    (import "c" (component $C1 (export "bump" (func (result u32)))))
    (component $L2
      (import "c" (component $C2 (export "bump" (func (result u32)))))
      (component $Agg
        (import "f1" (func $f1 (result u32)))
        (import "f2" (func $f2 (result u32)))
        (core func $f1_l (canon lower (func $f1)))
        (core func $f2_l (canon lower (func $f2)))
        (core module $M
          (import "e" "f1" (func $f1 (result i32)))
          (import "e" "f2" (func $f2 (result i32)))
          (func (export "run") (result i32)
            (i32.add (call $f1) (i32.mul (i32.const 10) (call $f2)))))
        (core instance $m (instantiate $M
          (with "e" (instance
            (export "f1" (func $f1_l)) (export "f2" (func $f2_l))))))
        (func (export "run") (result u32) (canon lift (core func $m "run"))))
      (instance $i1 (instantiate $C2))
      (instance $i2 (instantiate $C2))
      (instance $agg (instantiate $Agg
        (with "f1" (func $i1 "bump")) (with "f2" (func $i2 "bump"))))
      (func (export "run") (alias export $agg "run")))
    (instance $x (instantiate $L2 (with "c" (component $C1))))
    (instance $y (instantiate $L2 (with "c" (component $C1))))
    (func (export "run-1") (alias export $x "run"))
    (func (export "run-2") (alias export $y "run")))
  (component $Impl
    (core module $M
      (global $g (mut i32) (i32.const 0))
      (func (export "bump") (result i32)
        (global.set $g (i32.add (global.get $g) (i32.const 1)))
        (global.get $g)))
    (core instance $m (instantiate $M))
    (func (export "bump") (result u32) (canon lift (core func $m "bump"))))
  (instance $o1 (instantiate $L1 (with "c" (component $Impl))))
  (instance $o2 (instantiate $L1 (with "c" (component $Impl))))
  (func (export "run-11") (alias export $o1 "run-1"))
  (func (export "run-12") (alias export $o1 "run-2"))
  (func (export "run-21") (alias export $o2 "run-1"))
  (func (export "run-22") (alias export $o2 "run-2"))
)

(assert_return (invoke "run-11") (u32.const 11))
(assert_return (invoke "run-11") (u32.const 22))
(assert_return (invoke "run-12") (u32.const 11))
(assert_return (invoke "run-21") (u32.const 11))
(assert_return (invoke "run-22") (u32.const 11))
(assert_return (invoke "run-22") (u32.const 22))

;; Exporting a core module up out of a child: a counter module defined two
;; levels down is aliased up through both levels, with each level
;; instantiating its child twice, so the module surfaces along four export
;; paths. The parent instantiates all four and sums their independent
;; counters.
(component
  (component $C1
    (component $C2
      (core module $M
        (global $g (mut i32) (i32.const 0))
        (func (export "bump") (result i32)
          (global.set $g (i32.add (global.get $g) (i32.const 1)))
          (global.get $g)))
      (export "m" (core module $M)))
    (instance $a (instantiate $C2))
    (instance $b (instantiate $C2))
    (alias export $a "m" (core module $Ma))
    (alias export $b "m" (core module $Mb))
    (export "m1" (core module $Ma))
    (export "m2" (core module $Mb)))
  (instance $c1 (instantiate $C1))
  (instance $c2 (instantiate $C1))
  (alias export $c1 "m1" (core module $M11))
  (alias export $c1 "m2" (core module $M12))
  (alias export $c2 "m1" (core module $M21))
  (alias export $c2 "m2" (core module $M22))
  (core instance $i11 (instantiate $M11))
  (core instance $i12 (instantiate $M12))
  (core instance $i21 (instantiate $M21))
  (core instance $i22 (instantiate $M22))
  (core module $Use
    (import "e" "b11" (func $b11 (result i32)))
    (import "e" "b12" (func $b12 (result i32)))
    (import "e" "b21" (func $b21 (result i32)))
    (import "e" "b22" (func $b22 (result i32)))
    (func (export "run") (result i32)
      (i32.add (i32.add (call $b11) (call $b12))
               (i32.add (call $b21) (call $b22)))))
  (core instance $use (instantiate $Use
    (with "e" (instance
      (export "b11" (func $i11 "bump"))
      (export "b12" (func $i12 "bump"))
      (export "b21" (func $i21 "bump"))
      (export "b22" (func $i22 "bump"))))))
  (func (export "run") (result u32) (canon lift (core func $use "run")))
)

(assert_return (invoke "run") (u32.const 4))
(assert_return (invoke "run") (u32.const 8))

;; Exporting a nested component up out of a child: a counter component
;; defined two levels down is aliased up through both levels, with each level
;; instantiating its child twice, so the component surfaces along four export
;; paths. The parent instantiates all four and a sibling combiner sums their
;; independent counters.
(component
  (component $D1
    (component $D2
      (component $Counter
        (core module $M
          (global $g (mut i32) (i32.const 0))
          (func (export "bump") (result i32)
            (global.set $g (i32.add (global.get $g) (i32.const 1)))
            (global.get $g)))
        (core instance $m (instantiate $M))
        (func (export "bump") (result u32)
          (canon lift (core func $m "bump"))))
      (export "c" (component $Counter)))
    (instance $a (instantiate $D2))
    (instance $b (instantiate $D2))
    (alias export $a "c" (component $Ca))
    (alias export $b "c" (component $Cb))
    (export "c1" (component $Ca))
    (export "c2" (component $Cb)))
  (instance $d1 (instantiate $D1))
  (instance $d2 (instantiate $D1))
  (alias export $d1 "c1" (component $C11))
  (alias export $d1 "c2" (component $C12))
  (alias export $d2 "c1" (component $C21))
  (alias export $d2 "c2" (component $C22))
  (instance $i11 (instantiate $C11))
  (instance $i12 (instantiate $C12))
  (instance $i21 (instantiate $C21))
  (instance $i22 (instantiate $C22))
  (component $Sum
    (import "f11" (func $f11 (result u32)))
    (import "f12" (func $f12 (result u32)))
    (import "f21" (func $f21 (result u32)))
    (import "f22" (func $f22 (result u32)))
    (core func $l11 (canon lower (func $f11)))
    (core func $l12 (canon lower (func $f12)))
    (core func $l21 (canon lower (func $f21)))
    (core func $l22 (canon lower (func $f22)))
    (core module $M
      (import "e" "f11" (func $f11 (result i32)))
      (import "e" "f12" (func $f12 (result i32)))
      (import "e" "f21" (func $f21 (result i32)))
      (import "e" "f22" (func $f22 (result i32)))
      (func (export "run") (result i32)
        (i32.add (i32.add (call $f11) (call $f12))
                 (i32.add (call $f21) (call $f22)))))
    (core instance $m (instantiate $M
      (with "e" (instance
        (export "f11" (func $l11))
        (export "f12" (func $l12))
        (export "f21" (func $l21))
        (export "f22" (func $l22))))))
    (func (export "run") (result u32) (canon lift (core func $m "run"))))
  (instance $sum (instantiate $Sum
    (with "f11" (func $i11 "bump"))
    (with "f12" (func $i12 "bump"))
    (with "f21" (func $i21 "bump"))
    (with "f22" (func $i22 "bump"))))
  (func (export "run") (alias export $sum "run"))
)

(assert_return (invoke "run") (u32.const 4))
(assert_return (invoke "run") (u32.const 8))

;; One module instantiated in two sibling components: the same core module
;; (with a memory) is imported by both siblings, and each component instance
;; gets its own private copy of the memory.
(component
  (core module $Mem
    (memory 1)
    (func (export "poke") (param i32 i32)
      (i32.store8 (local.get 0) (local.get 1)))
    (func (export "peek") (param i32) (result i32)
      (i32.load8_u (local.get 0))))
  (component $C
    (import "m" (core module $M
      (export "poke" (func (param i32 i32)))
      (export "peek" (func (param i32) (result i32)))))
    (core instance $m (instantiate $M))
    (func (export "poke") (param "addr" u32) (param "val" u32)
      (canon lift (core func $m "poke")))
    (func (export "peek") (param "addr" u32) (result u32)
      (canon lift (core func $m "peek"))))
  (instance $c1 (instantiate $C (with "m" (core module $Mem))))
  (instance $c2 (instantiate $C (with "m" (core module $Mem))))
  (func (export "poke-1") (alias export $c1 "poke"))
  (func (export "peek-1") (alias export $c1 "peek"))
  (func (export "poke-2") (alias export $c2 "poke"))
  (func (export "peek-2") (alias export $c2 "peek"))
)

(assert_return (invoke "poke-1" (u32.const 3) (u32.const 66)))
(assert_return (invoke "peek-1" (u32.const 3)) (u32.const 66))
(assert_return (invoke "peek-2" (u32.const 3)) (u32.const 0))
(assert_return (invoke "poke-2" (u32.const 3) (u32.const 99)))
(assert_return (invoke "peek-1" (u32.const 3)) (u32.const 66))
(assert_return (invoke "peek-2" (u32.const 3)) (u32.const 99))

;; Instantiating a module reached by a depth-2 outer alias: a leaf component
;; nested two levels down instantiates a module defined at the top level. Two
;; leaf instances still get isolated module instances.
(component
  (core module $Counter
    (global $g (mut i32) (i32.const 0))
    (func (export "bump") (result i32)
      (global.set $g (i32.add (global.get $g) (i32.const 1)))
      (global.get $g)))
  (component $Mid
    (component $Leaf
      (core instance $m (instantiate $Counter))
      (func (export "bump") (result u32) (canon lift (core func $m "bump"))))
    (instance $l1 (instantiate $Leaf))
    (instance $l2 (instantiate $Leaf))
    (func (export "bump-1") (alias export $l1 "bump"))
    (func (export "bump-2") (alias export $l2 "bump")))
  (instance $mid (instantiate $Mid))
  (func (export "bump-1") (alias export $mid "bump-1"))
  (func (export "bump-2") (alias export $mid "bump-2"))
)

(assert_return (invoke "bump-1") (u32.const 1))
(assert_return (invoke "bump-2") (u32.const 1))
(assert_return (invoke "bump-1") (u32.const 2))

;; A core module delivered inside an instance import: the module is aliased
;; out of the imported instance and then instantiated by the receiving
;; component.
(component
  (component $C
    (import "tools" (instance $tools
      (export "m" (core module (export "get" (func (result i32)))))))
    (alias export $tools "m" (core module $M))
    (core instance $m (instantiate $M))
    (func (export "get") (result u32) (canon lift (core func $m "get"))))
  (core module $Impl (func (export "get") (result i32) (i32.const 123)))
  (instance $tools (export "m" (core module $Impl)))
  (instance $c (instantiate $C (with "tools" (instance $tools))))
  (func (export "get") (alias export $c "get"))
)

(assert_return (invoke "get") (u32.const 123))

;; Re-exporting a func through five levels of nesting: each level
;; instantiates the next and re-exports its func by alias, so the innermost
;; lifted func is reachable from the top.
(component
  (component $L1
    (component $L2
      (component $L3
        (component $L4
          (component $L5
            (core module $M (func (export "get") (result i32) (i32.const 5)))
            (core instance $m (instantiate $M))
            (func (export "get") (result u32) (canon lift (core func $m "get"))))
          (instance $i5 (instantiate $L5))
          (func (export "get") (alias export $i5 "get")))
        (instance $i4 (instantiate $L4))
        (func (export "get") (alias export $i4 "get")))
      (instance $i3 (instantiate $L3))
      (func (export "get") (alias export $i3 "get")))
    (instance $i2 (instantiate $L2))
    (func (export "get") (alias export $i2 "get")))
  (instance $i1 (instantiate $L1))
  (func (export "get") (alias export $i1 "get"))
)

(assert_return (invoke "get") (u32.const 5))

;; An outer alias spanning three component boundaries: the innermost of a
;; three-level nesting explicitly outer-aliases a module defined at the top
;; level and instantiates it.
(component $Top
  (core module $M
    (func (export "get") (result i32) (i32.const 50)))
  (component $L1
    (component $L2
      (component $L3
        (alias outer $Top $M (core module $Mx))
        (core instance $m (instantiate $Mx))
        (func (export "get") (result u32) (canon lift (core func $m "get"))))
      (instance $i (instantiate $L3))
      (func (export "get") (alias export $i "get")))
    (instance $i (instantiate $L2))
    (func (export "get") (alias export $i "get")))
  (instance $i (instantiate $L1))
  (func (export "get") (alias export $i "get"))
)

(assert_return (invoke "get") (u32.const 50))

;; One call crossing five component boundaries: four instances of a wrapper
;; component each lower-then-relift the previous sibling's func, adding at
;; every hop.
(component
  (component $Base
    (core module $M
      (func (export "f") (param i32) (result i32)
        (i32.add (local.get 0) (i32.const 1))))
    (core instance $m (instantiate $M))
    (func (export "f") (param "x" u32) (result u32)
      (canon lift (core func $m "f"))))
  (component $Wrap
    (import "next" (func $next (param "x" u32) (result u32)))
    (core func $next_l (canon lower (func $next)))
    (core module $M
      (import "e" "next" (func $next (param i32) (result i32)))
      (func (export "f") (param i32) (result i32)
        (i32.add (call $next (local.get 0)) (i32.const 10))))
    (core instance $m (instantiate $M
      (with "e" (instance (export "next" (func $next_l))))))
    (func (export "f") (param "x" u32) (result u32)
      (canon lift (core func $m "f"))))
  (instance $c0 (instantiate $Base))
  (instance $c1 (instantiate $Wrap (with "next" (func $c0 "f"))))
  (instance $c2 (instantiate $Wrap (with "next" (func $c1 "f"))))
  (instance $c3 (instantiate $Wrap (with "next" (func $c2 "f"))))
  (instance $c4 (instantiate $Wrap (with "next" (func $c3 "f"))))
  (func (export "f") (alias export $c4 "f"))
)

(assert_return (invoke "f" (u32.const 5)) (u32.const 46))

;; Threading a service instance down three levels of nesting: a service
;; created at the top level is passed down as an instance argument. The leaf
;; calls it, sharing state with the direct path.
(component
  (component $Svc
    (core module $M
      (global $g (mut i32) (i32.const 0))
      (func (export "bump") (result i32)
        (global.set $g (i32.add (global.get $g) (i32.const 1)))
        (global.get $g)))
    (core instance $m (instantiate $M))
    (func (export "bump") (result u32) (canon lift (core func $m "bump"))))
  (component $L1
    (import "svc" (instance $svc (export "bump" (func (result u32)))))
    (component $L2
      (import "svc" (instance $svc (export "bump" (func (result u32)))))
      (component $L3
        (import "svc" (instance $svc (export "bump" (func (result u32)))))
        (core func $bump (canon lower (func $svc "bump")))
        (core module $M
          (import "e" "bump" (func $bump (result i32)))
          (func (export "go") (result i32) (call $bump)))
        (core instance $m (instantiate $M
          (with "e" (instance (export "bump" (func $bump))))))
        (func (export "go") (result u32) (canon lift (core func $m "go"))))
      (instance $l3 (instantiate $L3 (with "svc" (instance $svc))))
      (func (export "go") (alias export $l3 "go")))
    (instance $l2 (instantiate $L2 (with "svc" (instance $svc))))
    (func (export "go") (alias export $l2 "go")))
  (instance $svc (instantiate $Svc))
  (instance $l1 (instantiate $L1 (with "svc" (instance $svc))))
  (func (export "go") (alias export $l1 "go"))
  (func (export "bump-direct") (alias export $svc "bump"))
)

(assert_return (invoke "go") (u32.const 1))
(assert_return (invoke "bump-direct") (u32.const 2))
(assert_return (invoke "go") (u32.const 3))

;; Diamond sharing of one service at the component level: a base counter
;; service is imported by two wrapper instances, and a combiner calls through
;; both wrappers. The counter values observed via the two paths interleave,
;; proving one shared base.
(component
  (component $Base
    (core module $M
      (global $g (mut i32) (i32.const 0))
      (func (export "bump") (result i32)
        (global.set $g (i32.add (global.get $g) (i32.const 1)))
        (global.get $g)))
    (core instance $m (instantiate $M))
    (func (export "bump") (result u32) (canon lift (core func $m "bump"))))
  (component $Wrap
    (import "svc" (instance $svc (export "bump" (func (result u32)))))
    (import "add" (core module $Add (export "amount" (global i32))))
    (core instance $add (instantiate $Add))
    (core func $bump (canon lower (func $svc "bump")))
    (core module $M
      (import "e" "bump" (func $bump (result i32)))
      (import "cfg" "amount" (global $amount i32))
      (func (export "go") (result i32)
        (i32.add (call $bump) (global.get $amount))))
    (core instance $m (instantiate $M
      (with "e" (instance (export "bump" (func $bump))))
      (with "cfg" (instance $add))))
    (func (export "go") (result u32) (canon lift (core func $m "go"))))
  (component $Combine
    (import "a" (instance $a (export "go" (func (result u32)))))
    (import "b" (instance $b (export "go" (func (result u32)))))
    (core func $ga (canon lower (func $a "go")))
    (core func $gb (canon lower (func $b "go")))
    (core module $M
      (import "e" "ga" (func $ga (result i32)))
      (import "e" "gb" (func $gb (result i32)))
      (func (export "run") (result i32) (i32.add (call $ga) (call $gb))))
    (core instance $m (instantiate $M
      (with "e" (instance
        (export "ga" (func $ga)) (export "gb" (func $gb))))))
    (func (export "run") (result u32) (canon lift (core func $m "run"))))
  (core module $Add100 (global (export "amount") i32 (i32.const 100)))
  (core module $Add200 (global (export "amount") i32 (i32.const 200)))
  (instance $base (instantiate $Base))
  (instance $wa (instantiate $Wrap
    (with "svc" (instance $base)) (with "add" (core module $Add100))))
  (instance $wb (instantiate $Wrap
    (with "svc" (instance $base)) (with "add" (core module $Add200))))
  (instance $comb (instantiate $Combine
    (with "a" (instance $wa)) (with "b" (instance $wb))))
  (func (export "run") (alias export $comb "run"))
)

(assert_return (invoke "run") (u32.const 303))
(assert_return (invoke "run") (u32.const 307))

;; Exporting an instance up from three levels down: a service instance
;; created deep in one subtree is exported up through every level, then
;; consumed by a top-level sibling that calls into it.
(component
  (component $L1
    (component $L2
      (component $L3
        (component $Svc
          (core module $M
            (global $g (mut i32) (i32.const 0))
            (func (export "bump") (result i32)
              (global.set $g (i32.add (global.get $g) (i32.const 1)))
              (global.get $g)))
          (core instance $m (instantiate $M))
          (func (export "bump") (result u32) (canon lift (core func $m "bump"))))
        (instance $svc (instantiate $Svc))
        (export "svc" (instance $svc)))
      (instance $l3 (instantiate $L3))
      (alias export $l3 "svc" (instance $svc))
      (export "svc" (instance $svc)))
    (instance $l2 (instantiate $L2))
    (alias export $l2 "svc" (instance $svc))
    (export "svc" (instance $svc)))
  (instance $l1 (instantiate $L1))
  (alias export $l1 "svc" (instance $svc))
  (component $User
    (import "svc" (instance $svc (export "bump" (func (result u32)))))
    (core func $bump (canon lower (func $svc "bump")))
    (core module $M
      (import "e" "bump" (func $bump (result i32)))
      (func (export "go") (result i32) (call $bump)))
    (core instance $m (instantiate $M
      (with "e" (instance (export "bump" (func $bump))))))
    (func (export "go") (result u32) (canon lift (core func $m "go"))))
  (instance $user (instantiate $User (with "svc" (instance $svc))))
  (func (export "go") (alias export $user "go"))
  (func (export "bump-direct") (alias export $svc "bump"))
)

(assert_return (invoke "go") (u32.const 1))
(assert_return (invoke "bump-direct") (u32.const 2))
(assert_return (invoke "go") (u32.const 3))

;; A two-hop inline alias through a nested instance export: a child exports a
;; synthesized instance containing a func, and the parent reaches the func
;; with a single inline alias.
(component
  (component $C
    (core module $M (func (export "f") (result i32) (i32.const 64)))
    (core instance $m (instantiate $M))
    (func $f (result u32) (canon lift (core func $m "f")))
    (instance $i (export "f" (func $f)))
    (export "i" (instance $i)))
  (instance $c (instantiate $C))
  (export "run" (func $c "i" "f"))
)

(assert_return (invoke "run") (u32.const 64))

;; One func exported under many names: a lifted func is exported under two
;; names by the child and re-exported under three names by the parent. All
;; names call the same underlying core func and shared state.
(component
  (component $C
    (core module $M
      (global $g (mut i32) (i32.const 0))
      (func (export "bump") (result i32)
        (global.set $g (i32.add (global.get $g) (i32.const 1)))
        (global.get $g)))
    (core instance $m (instantiate $M))
    (func $bump (result u32) (canon lift (core func $m "bump")))
    (export "first" (func $bump))
    (export "second" (func $bump)))
  (instance $c (instantiate $C))
  (func (export "one") (alias export $c "first"))
  (func (export "two") (alias export $c "second"))
  (func (export "three") (alias export $c "first"))
)

(assert_return (invoke "one") (u32.const 1))
(assert_return (invoke "two") (u32.const 2))
(assert_return (invoke "three") (u32.const 3))

;; Lifting one core func twice: both resulting component funcs call into the
;; same core instance state.
(component
  (core module $M
    (global $g (mut i32) (i32.const 0))
    (func (export "bump") (result i32)
      (global.set $g (i32.add (global.get $g) (i32.const 1)))
      (global.get $g)))
  (core instance $m (instantiate $M))
  (func (export "lift-1") (result u32) (canon lift (core func $m "bump")))
  (func (export "lift-2") (result u32) (canon lift (core func $m "bump")))
)

(assert_return (invoke "lift-1") (u32.const 1))
(assert_return (invoke "lift-2") (u32.const 2))
(assert_return (invoke "lift-1") (u32.const 3))

;; Lowering one component func twice: the same imported func is wired into
;; one module under two names, and both names reach the same callee, observed
;; via one shared counter.
(component
  (component $Svc
    (core module $M
      (global $g (mut i32) (i32.const 0))
      (func (export "bump") (result i32)
        (global.set $g (i32.add (global.get $g) (i32.const 1)))
        (global.get $g)))
    (core instance $m (instantiate $M))
    (func (export "bump") (result u32) (canon lift (core func $m "bump"))))
  (component $User
    (import "svc" (instance $svc (export "bump" (func (result u32)))))
    (core func $b1 (canon lower (func $svc "bump")))
    (core func $b2 (canon lower (func $svc "bump")))
    (core module $M
      (import "e" "b1" (func $b1 (result i32)))
      (import "e" "b2" (func $b2 (result i32)))
      (func (export "run") (result i32)
        (i32.add (i32.mul (call $b1) (i32.const 10)) (call $b2))))
    (core instance $m (instantiate $M
      (with "e" (instance
        (export "b1" (func $b1)) (export "b2" (func $b2))))))
    (func (export "run") (result u32) (canon lift (core func $m "run"))))
  (instance $svc (instantiate $Svc))
  (instance $user (instantiate $User (with "svc" (instance $svc))))
  (func (export "run") (alias export $user "run"))
)

(assert_return (invoke "run") (u32.const 12))
(assert_return (invoke "run") (u32.const 34))

;; Re-export by alias vs by lower-then-lift: a middle component re-exports an
;; imported func both directly by alias and wrapped through its own core
;; module. Both exports reach the same underlying state.
(component
  (component $A
    (core module $M
      (global $g (mut i32) (i32.const 0))
      (func (export "bump") (result i32)
        (global.set $g (i32.add (global.get $g) (i32.const 1)))
        (global.get $g)))
    (core instance $m (instantiate $M))
    (func (export "bump") (result u32) (canon lift (core func $m "bump"))))
  (component $B
    (import "a" (instance $a (export "bump" (func (result u32)))))
    (export "direct" (func $a "bump"))
    (core func $bump_l (canon lower (func $a "bump")))
    (core module $M
      (import "e" "bump" (func $bump (result i32)))
      (func (export "bump") (result i32) (call $bump)))
    (core instance $m (instantiate $M
      (with "e" (instance (export "bump" (func $bump_l))))))
    (func (export "wrapped") (result u32) (canon lift (core func $m "bump"))))
  (instance $a (instantiate $A))
  (instance $b (instantiate $B (with "a" (instance $a))))
  (func (export "direct") (alias export $b "direct"))
  (func (export "wrapped") (alias export $b "wrapped"))
)

(assert_return (invoke "direct") (u32.const 1))
(assert_return (invoke "wrapped") (u32.const 2))
(assert_return (invoke "direct") (u32.const 3))
