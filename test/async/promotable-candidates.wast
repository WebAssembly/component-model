;; Test the thread "promotion" predicate, which is used in two cases:
;;  - the thread.{suspend,yield}-then-promote built-ins
;;  - the implicit promotion that happens during a sync-typed function
;;    when the implicit thread blocks but other threads (which may unblock
;;    the implicit thread) can be resumed
;;
;; The following tests test the various cases of which threads are allowed or
;; disallowed to be promoted. Each component below tests one such case in both
;; contexts, side by side: 'run' blocks with plain thread.yield, so promotion
;; happens implicitly as part of sync-call scheduling, while 'run-promote'
;; targets the thread in question explicitly with thread.yield-then-promote.
;; For allowed threads, both must (eventually) promote the target thread; for
;; excluded threads, the target thread must never run during the
;; non-async-typed call, with the promote built-ins falling back to plain
;; thread.{suspend,yield} behavior.

;; Allowed: any explicit thread (including of the sync task itself)
(component
  (core module $Table (table (export "__indirect_function_table") 1 funcref))
  (core instance $table (instantiate $Table))
  (core module $Core
    (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
    (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
    (import "" "thread.yield" (func $thread.yield (result i32)))
    (import "" "thread.yield-then-promote" (func $thread.yield-then-promote (param i32) (result i32)))
    (import "" "__indirect_function_table" (table $tbl 1 funcref))

    (global $worker-ran (mut i32) (i32.const 0))
    (global $worker-thread (mut i32) (i32.const 0))

    (func $worker (param i32)
      (global.set $worker-ran (i32.const 1)))
    (elem (table $tbl) (i32.const 0) func $worker)

    (func $spawn-worker
      (global.set $worker-ran (i32.const 0))
      (global.set $worker-thread (call $thread.new-indirect (i32.const 0) (i32.const 0)))
      (call $thread.resume-later (global.get $worker-thread)))

    (func (export "run") (result i32)
      (call $spawn-worker)
      (loop $again
        (drop (call $thread.yield))
        (br_if $again (i32.eqz (global.get $worker-ran))))
      (i32.const 42))

    (func (export "run-promote") (result i32)
      (call $spawn-worker)
      (loop $again
        (drop (call $thread.yield-then-promote (global.get $worker-thread)))
        (br_if $again (i32.eqz (global.get $worker-ran))))
      (i32.const 42))
  )
  (core type $start-func-ty (func (param i32)))
  (alias core export $table "__indirect_function_table" (core table $indirect-function-table))
  (core func $thread.new-indirect
    (canon thread.new-indirect $start-func-ty (core table $indirect-function-table)))
  (canon thread.resume-later (core func $thread.resume-later))
  (canon thread.yield (core func $thread.yield))
  (canon thread.yield-then-promote (core func $thread.yield-then-promote))
  (core instance $core (instantiate $Core (with "" (instance
    (export "thread.new-indirect" (func $thread.new-indirect))
    (export "thread.resume-later" (func $thread.resume-later))
    (export "thread.yield" (func $thread.yield))
    (export "thread.yield-then-promote" (func $thread.yield-then-promote))
    (export "__indirect_function_table" (table $indirect-function-table))
  ))))
  (func (export "run") (result u32)
    (canon lift (core func $core "run")))
  (func (export "run-promote") (result u32)
    (canon lift (core func $core "run-promote")))
)
(assert_return (invoke "run") (u32.const 42))
(assert_return (invoke "run-promote") (u32.const 42))

;; Allowed: implicit thread of a stackful async task
(component
  (core module $Core
    (import "" "task.return" (func $task.return (param i32)))
    (import "" "thread.index" (func $thread.index (result i32)))
    (import "" "thread.yield" (func $thread.yield (result i32)))
    (import "" "thread.yield-then-promote" (func $thread.yield-then-promote (param i32) (result i32)))

    (global $finished (mut i32) (i32.const 0))
    (global $setup-thread (mut i32) (i32.const 0))

    (func (export "setup")
      (global.set $finished (i32.const 0))
      (global.set $setup-thread (call $thread.index))
      (call $task.return (i32.const 1))
      (drop (call $thread.yield))
      (global.set $finished (i32.const 1)))

    (func (export "run") (result i32)
      (loop $again
        (drop (call $thread.yield))
        (br_if $again (i32.eqz (global.get $finished))))
      (i32.const 42))

    (func (export "run-promote") (result i32)
      ;; check $finished before promoting: setup's yield may
      ;; nondeterministically complete without suspending, in which case
      ;; setup's thread index is already gone
      (block $done
        (loop $again
          (br_if $done (global.get $finished))
          (drop (call $thread.yield-then-promote (global.get $setup-thread)))
          (br $again)))
      (i32.const 42))
  )
  (canon task.return (result u32) (core func $task.return))
  (canon thread.index (core func $thread.index))
  (canon thread.yield (core func $thread.yield))
  (canon thread.yield-then-promote (core func $thread.yield-then-promote))
  (core instance $core (instantiate $Core (with "" (instance
    (export "task.return" (func $task.return))
    (export "thread.index" (func $thread.index))
    (export "thread.yield" (func $thread.yield))
    (export "thread.yield-then-promote" (func $thread.yield-then-promote))
  ))))
  (func (export "setup") async (result u32)
    (canon lift (core func $core "setup") async))
  (func (export "run") (result u32)
    (canon lift (core func $core "run")))
  (func (export "run-promote") (result u32)
    (canon lift (core func $core "run-promote")))
)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run") (u32.const 42))
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run-promote") (u32.const 42))

;; Excluded: implicit thread of an async callback task waiting in an event loop
(component
  (component $C
    (core module $Core
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "thread.yield" (func $thread.yield (result i32)))
      (import "" "thread.yield-then-promote" (func $thread.yield-then-promote (param i32) (result i32)))
      (import "" "thread.suspend-then-promote" (func $thread.suspend-then-promote (param i32) (result i32)))

      (global $setup-thread (mut i32) (i32.const 0))
      (global $in-sync-call (mut i32) (i32.const 0))

      (func (export "setup") (result i32)
        (global.set $setup-thread (call $thread.index))
        (call $task.return (i32.const 1))
        (i32.const 1 (; YIELD ;)))

      ;; Since setup's YIELD may nondeterministically complete without
      ;; suspending, 'setup-cb' may be called (with a NONE event) while no
      ;; non-async-typed call is in progress and parks the thread again; it
      ;; must never be called during 'run*'.
      (func (export "setup-cb") (param i32 i32 i32) (result i32)
        (if (global.get $in-sync-call)
          (then unreachable))
        (i32.const 1 (; YIELD ;)))

      (func (export "run") (result i32)
        (local $i i32)
        (global.set $in-sync-call (i32.const 1))
        (loop $again
          (drop (call $thread.yield))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br_if $again (i32.lt_u (local.get $i) (i32.const 50))))
        (global.set $in-sync-call (i32.const 0))
        (i32.const 42))

      (func (export "run-promote") (result i32)
        (local $i i32)
        (global.set $in-sync-call (i32.const 1))
        (loop $again
          (drop (call $thread.yield-then-promote (global.get $setup-thread)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br_if $again (i32.lt_u (local.get $i) (i32.const 50))))
        (global.set $in-sync-call (i32.const 0))
        (i32.const 42))

      (func (export "run-suspend-promote")
        (global.set $in-sync-call (i32.const 1))
        (drop (call $thread.suspend-then-promote (global.get $setup-thread)))
        unreachable)
    )
    (canon task.return (result u32) (core func $task.return))
    (canon thread.index (core func $thread.index))
    (canon thread.yield (core func $thread.yield))
    (canon thread.yield-then-promote (core func $thread.yield-then-promote))
    (canon thread.suspend-then-promote (core func $thread.suspend-then-promote))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return" (func $task.return))
      (export "thread.index" (func $thread.index))
      (export "thread.yield" (func $thread.yield))
      (export "thread.yield-then-promote" (func $thread.yield-then-promote))
      (export "thread.suspend-then-promote" (func $thread.suspend-then-promote))
    ))))
    (func (export "setup") async (result u32)
      (canon lift (core func $core "setup") async (callback (core func $core "setup-cb"))))
    (func (export "run") (result u32)
      (canon lift (core func $core "run")))
    (func (export "run-promote") (result u32)
      (canon lift (core func $core "run-promote")))
    (func (export "run-suspend-promote")
      (canon lift (core func $core "run-suspend-promote")))
  )
  (component $D
    (import "run" (func $run (result u32)))
    (core module $Core
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "run" (func $run (result i32)))

      (func (export "driver") (result i32)
        (call $task.return (call $run))
        (i32.const 0 (; EXIT ;)))

      (func (export "driver-cb") (param i32 i32 i32) (result i32)
        unreachable)
    )
    (canon task.return (result u32) (core func $task.return))
    (canon lower (func $run) (core func $run'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return" (func $task.return))
      (export "run" (func $run'))
    ))))
    (func (export "driver") async (result u32)
      (canon lift (core func $core "driver") async (callback (core func $core "driver-cb"))))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "run" (func $c "run"))))
  (func (export "setup") (alias export $c "setup"))
  (func (export "run") (alias export $c "run"))
  (func (export "run-promote") (alias export $c "run-promote"))
  (func (export "run-suspend-promote") (alias export $c "run-suspend-promote"))
  (func (export "driver") (alias export $d "driver"))
)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run") (u32.const 42))
(assert_return (invoke "driver") (u32.const 42))
(assert_return (invoke "run-promote") (u32.const 42))
(assert_trap (invoke "run-suspend-promote") "cannot block a synchronous task before returning")

;; Excluded: implicit thread of an async callback task blocked not in the event
;; loop. Since 'run' and 'run-promote' each make setup's suspended thread ready
;; themselves, each runs in a fresh instance.
(component definition $BlockedCallbackTester
  (core module $Core
    (import "" "task.return" (func $task.return (param i32)))
    (import "" "thread.index" (func $thread.index (result i32)))
    (import "" "thread.suspend" (func $thread.suspend (result i32)))
    (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
    (import "" "thread.yield" (func $thread.yield (result i32)))
    (import "" "thread.yield-then-promote" (func $thread.yield-then-promote (param i32) (result i32)))

    (global $setup-thread (mut i32) (i32.const 0))

    (func (export "setup") (result i32)
      (global.set $setup-thread (call $thread.index))
      (call $task.return (i32.const 1))
      (drop (call $thread.suspend))
      unreachable)

    (func (export "setup-cb") (param i32 i32 i32) (result i32)
      unreachable)

    (func (export "run") (result i32)
      (local $i i32)
      (call $thread.resume-later (global.get $setup-thread))
      (loop $again
        (drop (call $thread.yield))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br_if $again (i32.lt_u (local.get $i) (i32.const 50))))
      (i32.const 42))

    (func (export "run-promote") (result i32)
      (local $i i32)
      (call $thread.resume-later (global.get $setup-thread))
      (loop $again
        (drop (call $thread.yield-then-promote (global.get $setup-thread)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br_if $again (i32.lt_u (local.get $i) (i32.const 50))))
      (i32.const 42))
  )
  (canon task.return (result u32) (core func $task.return))
  (canon thread.index (core func $thread.index))
  (canon thread.suspend (core func $thread.suspend))
  (canon thread.resume-later (core func $thread.resume-later))
  (canon thread.yield (core func $thread.yield))
  (canon thread.yield-then-promote (core func $thread.yield-then-promote))
  (core instance $core (instantiate $Core (with "" (instance
    (export "task.return" (func $task.return))
    (export "thread.index" (func $thread.index))
    (export "thread.suspend" (func $thread.suspend))
    (export "thread.resume-later" (func $thread.resume-later))
    (export "thread.yield" (func $thread.yield))
    (export "thread.yield-then-promote" (func $thread.yield-then-promote))
  ))))
  (func (export "setup") async (result u32)
    (canon lift (core func $core "setup") async (callback (core func $core "setup-cb"))))
  (func (export "run") (result u32)
    (canon lift (core func $core "run")))
  (func (export "run-promote") (result u32)
    (canon lift (core func $core "run-promote")))
)

(component instance $i $BlockedCallbackTester)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run") (u32.const 42))

(component instance $i $BlockedCallbackTester)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run-promote") (u32.const 42))

;; Excluded: implicit thread of a synchronously-lifted async-typed function.
(component definition $SyncLiftedTester
  (component $I
    (core module $Core
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "thread.suspend" (func $thread.suspend (result i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "thread.yield" (func $thread.yield (result i32)))
      (import "" "thread.yield-then-promote" (func $thread.yield-then-promote (param i32) (result i32)))

      (global $f-started (mut i32) (i32.const 0))
      (global $f-thread (mut i32) (i32.const 0))

      (func (export "f")
        (global.set $f-started (i32.const 1))
        (global.set $f-thread (call $thread.index))
        (drop (call $thread.suspend))
        unreachable)

      (func (export "run") (result i32)
        (local $i i32)
        (if (i32.eqz (global.get $f-started))
          (then unreachable))
        (call $thread.resume-later (global.get $f-thread))
        (loop $again
          (drop (call $thread.yield))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br_if $again (i32.lt_u (local.get $i) (i32.const 50))))
        (i32.const 42))

      (func (export "run-promote") (result i32)
        (local $i i32)
        (if (i32.eqz (global.get $f-started))
          (then unreachable))
        (call $thread.resume-later (global.get $f-thread))
        (loop $again
          (drop (call $thread.yield-then-promote (global.get $f-thread)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br_if $again (i32.lt_u (local.get $i) (i32.const 50))))
        (i32.const 42))
    )
    (canon thread.index (core func $thread.index))
    (canon thread.suspend (core func $thread.suspend))
    (canon thread.resume-later (core func $thread.resume-later))
    (canon thread.yield (core func $thread.yield))
    (canon thread.yield-then-promote (core func $thread.yield-then-promote))
    (core instance $core (instantiate $Core (with "" (instance
      (export "thread.index" (func $thread.index))
      (export "thread.suspend" (func $thread.suspend))
      (export "thread.resume-later" (func $thread.resume-later))
      (export "thread.yield" (func $thread.yield))
      (export "thread.yield-then-promote" (func $thread.yield-then-promote))
    ))))
    (func (export "f") async
      (canon lift (core func $core "f")))
    (func (export "run") (result u32)
      (canon lift (core func $core "run")))
    (func (export "run-promote") (result u32)
      (canon lift (core func $core "run-promote")))
  )
  (component $D
    (import "f" (func $f async))
    (core module $Core
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "f" (func $f (result i32)))

      (func (export "setup") (result i32)
        ;; The async-lowered call must come back blocked in the STARTED state.
        (if (i32.ne (i32.and (call $f) (i32.const 0xf)) (i32.const 1 (; STARTED ;)))
          (then unreachable))
        (call $task.return (i32.const 1))
        (i32.const 0 (; EXIT ;)))

      (func (export "setup-cb") (param i32 i32 i32) (result i32)
        unreachable)
    )
    (canon task.return (result u32) (core func $task.return))
    (canon lower (func $f) async (core func $f'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return" (func $task.return))
      (export "f" (func $f'))
    ))))
    (func (export "setup") async (result u32)
      (canon lift (core func $core "setup") async (callback (core func $core "setup-cb"))))
  )
  (instance $i (instantiate $I))
  (instance $d (instantiate $D (with "f" (func $i "f"))))
  (func (export "setup") (alias export $d "setup"))
  (func (export "run") (alias export $i "run"))
  (func (export "run-promote") (alias export $i "run-promote"))
)

(component instance $i $SyncLiftedTester)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run") (u32.const 42))

(component instance $i $SyncLiftedTester)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run-promote") (u32.const 42))

;; Allowed and excluded together: explicit threads may be promoted even when
;; their task is an async callback task whose own implicit thread may not.
(component
  (core module $Table (table (export "__indirect_function_table") 2 funcref))
  (core instance $table (instantiate $Table))
  (core module $Core
    (import "" "task.return" (func $task.return (param i32)))
    (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
    (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
    (import "" "thread.yield" (func $thread.yield (result i32)))
    (import "" "thread.yield-then-promote" (func $thread.yield-then-promote (param i32) (result i32)))
    (import "" "__indirect_function_table" (table $tbl 2 funcref))

    (global $worker0-ran (mut i32) (i32.const 0))
    (global $worker0-thread (mut i32) (i32.const 0))
    (global $worker1-ran (mut i32) (i32.const 0))
    (global $worker1-thread (mut i32) (i32.const 0))
    (global $in-sync-call (mut i32) (i32.const 0))

    (func $worker0 (param i32)
      (global.set $worker0-ran (i32.const 1)))
    (func $worker1 (param i32)
      (global.set $worker1-ran (i32.const 1)))
    (elem (table $tbl) (i32.const 0) func $worker0 $worker1)

    (func (export "setup") (result i32)
      (global.set $worker0-thread (call $thread.new-indirect (i32.const 0) (i32.const 0)))
      (global.set $worker1-thread (call $thread.new-indirect (i32.const 1) (i32.const 0)))
      (call $task.return (i32.const 1))
      (i32.const 1 (; YIELD ;)))

    ;; Since setup's YIELD may nondeterministically complete without
    ;; suspending, 'setup-cb' may be called (with a NONE event) while no
    ;; non-async-typed call is in progress and parks the thread again; it
    ;; must never be called during 'run*'.
    (func (export "setup-cb") (param i32 i32 i32) (result i32)
      (if (global.get $in-sync-call)
        (then unreachable))
      (i32.const 1 (; YIELD ;)))

    (func (export "run") (result i32)
      (global.set $in-sync-call (i32.const 1))
      (call $thread.resume-later (global.get $worker0-thread))
      (loop $again
        (drop (call $thread.yield))
        (br_if $again (i32.eqz (global.get $worker0-ran))))
      (global.set $in-sync-call (i32.const 0))
      (i32.const 42))

    (func (export "run-promote") (result i32)
      (global.set $in-sync-call (i32.const 1))
      (call $thread.resume-later (global.get $worker1-thread))
      (loop $again
        (drop (call $thread.yield-then-promote (global.get $worker1-thread)))
        (br_if $again (i32.eqz (global.get $worker1-ran))))
      (global.set $in-sync-call (i32.const 0))
      (i32.const 42))
  )
  (core type $start-func-ty (func (param i32)))
  (alias core export $table "__indirect_function_table" (core table $indirect-function-table))
  (core func $thread.new-indirect
    (canon thread.new-indirect $start-func-ty (core table $indirect-function-table)))
  (canon task.return (result u32) (core func $task.return))
  (canon thread.resume-later (core func $thread.resume-later))
  (canon thread.yield (core func $thread.yield))
  (canon thread.yield-then-promote (core func $thread.yield-then-promote))
  (core instance $core (instantiate $Core (with "" (instance
    (export "task.return" (func $task.return))
    (export "thread.new-indirect" (func $thread.new-indirect))
    (export "thread.resume-later" (func $thread.resume-later))
    (export "thread.yield" (func $thread.yield))
    (export "thread.yield-then-promote" (func $thread.yield-then-promote))
    (export "__indirect_function_table" (table $indirect-function-table))
  ))))
  (func (export "setup") async (result u32)
    (canon lift (core func $core "setup") async (callback (core func $core "setup-cb"))))
  (func (export "run") (result u32)
    (canon lift (core func $core "run")))
  (func (export "run-promote") (result u32)
    (canon lift (core func $core "run-promote")))
)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run") (u32.const 42))
(assert_return (invoke "run-promote") (u32.const 42))
