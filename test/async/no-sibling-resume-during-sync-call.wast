;; While a non-async-typed export call is in progress, the runtime must only
;; ever resume threads of that call's own component instance (which is necessary
;; to prevent accidental and unexpected reentrance).

;; To test this, the first test (which only uses 0.3.0 features) calls:
;;   1. "setup" ($Inner, async-typed): resolves via task.return, then returns
;;      YIELD, leaving its implicit thread X ready in $Inner (X belongs to a
;;      resolved async-typed task, so it may later block).
;;   2. "block" ($Driver, async-typed, called by the host):
;;      a. calls $Sibling.arm, which resolves and returns YIELD, leaving a
;;         ready thread T in $Sibling whose callback calls $Inner.poke;
;;      b. sync-calls $Inner.inner-block (non-async-typed), entering $Inner;
;;      c. inner-block thread.yields in a loop until X has run: X, once
;;         (eventually, nondeterministically) scheduled, sets a flag and then
;;         sync-calls $Blocker's blocking async-typed import, blocking
;;         forever; inner-block then sync-calls the same blocking import.
;; Once both of $Inner's threads block, $Inner has no ready threads, so the
;; call must trap immediately and T must never run.
(component definition $Tester1
  (component $Blocker
    (core module $CM
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (func (export "blocking-async-func") (result i32)
        ;; WAIT (2) on a fresh empty waitable set to block forever
        (i32.or (i32.const 2) (i32.shl (call $waitable-set.new) (i32.const 4))))
      (func (export "never-cb") (param i32 i32 i32) (result i32)
        unreachable)
    )
    (canon waitable-set.new (core func $waitable-set.new))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "waitable-set.new" (func $waitable-set.new))))))
    (func (export "blocking-async-func") async
      (canon lift (core func $cm "blocking-async-func") async (callback (core func $cm "never-cb"))))
  )
  (component $Inner
    (import "blocker" (instance $blocker
      (export "blocking-async-func" (func async))
    ))
    (core module $Core
      (import "" "blocking-async-func" (func $blocking-async-func))
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "thread.yield" (func $thread.yield (result i32)))

      (global $x-ran (mut i32) (i32.const 0))

      ;; async callback task resolves, then leaves X (its implicit thread)
      ;; ready by returning YIELD
      (func (export "setup") (result i32)
        (call $task.return (i32.const 1))
        (i32.const 1 (; YIELD ;)))

      ;; X: resumed with EVENT_NONE some time after the YIELD; record that X
      ;; ran, then sync-call the blocking async-typed import and block forever
      (func (export "setup-cb") (param i32 i32 i32) (result i32)
        (if (i32.ne (local.get 0) (i32.const 0 (; EVENT_NONE ;)))
          (then unreachable))
        (global.set $x-ran (i32.const 1))
        (call $blocking-async-func)
        unreachable)

      ;; non-async-typed: yield until the scheduler (which may keep
      ;; nondeterministically resuming this thread instead) actually switches
      ;; to X, then block on the blocking import as well; control must never
      ;; return here (both of $Inner's threads are left blocked forever)
      (func (export "inner-block")
        (loop $again
          (drop (call $thread.yield))
          (br_if $again (i32.eqz (global.get $x-ran))))
        (call $blocking-async-func)
        unreachable)

      ;; trivial reentry probe called by $Sibling's thread
      (func (export "poke"))
    )
    (canon task.return (result u32) (core func $task.return))
    (canon thread.yield (core func $thread.yield))
    (canon lower (func $blocker "blocking-async-func") (core func $blocking-async-func'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "blocking-async-func" (func $blocking-async-func'))
      (export "task.return" (func $task.return))
      (export "thread.yield" (func $thread.yield))
    ))))
    (func (export "setup") async (result u32)
      (canon lift (core func $core "setup") async (callback (core func $core "setup-cb"))))
    (func (export "inner-block")
      (canon lift (core func $core "inner-block")))
    (func (export "poke")
      (canon lift (core func $core "poke")))
  )
  (component $Sibling
    (import "inner" (instance $inner
      (export "poke" (func))
    ))
    (core module $Core
      (import "" "poke" (func $poke))
      (import "" "task.return" (func $task.return))

      ;; async callback task resolves, then leaves T (its implicit thread)
      ;; behind, ready but never legally run
      (func (export "arm") (result i32)
        (call $task.return)
        (i32.const 1 (; YIELD ;)))

      ;; T: reenter the (entered) $Inner instance; must never run while the
      ;; sync call into $Inner is blocked.
      (func (export "arm-cb") (param i32 i32 i32) (result i32)
        (call $poke)
        unreachable)
    )
    (canon task.return (core func $task.return))
    (canon lower (func $inner "poke") (core func $poke'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "poke" (func $poke'))
      (export "task.return" (func $task.return))
    ))))
    (func (export "arm") async
      (canon lift (core func $core "arm") async (callback (core func $core "arm-cb"))))
  )
  (component $Driver
    (import "sibling" (instance $sibling
      (export "arm" (func async))
    ))
    (import "inner" (instance $inner
      (export "inner-block" (func))
    ))
    (core module $Core
      (import "" "arm" (func $arm))
      (import "" "inner-block" (func $inner-block))
      (import "" "task.return" (func $task.return (param i32)))
      (func (export "never-cb") (param i32 i32 i32) (result i32)
        unreachable)
      ;; async-typed (so that the sync-lowered call to the async-typed "arm"
      ;; is made from an async-typed task); the non-async-typed call under
      ;; test is the sync-lowered call to "inner-block"
      (func (export "block") (result i32)
        (call $arm)
        (call $inner-block)
        (call $task.return (i32.const 0xbad))
        (i32.const 0 (; EXIT ;))))
    (canon task.return (result u32) (core func $task.return))
    (canon lower (func $sibling "arm") (core func $arm'))
    (canon lower (func $inner "inner-block") (core func $inner-block'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "arm" (func $arm'))
      (export "inner-block" (func $inner-block'))
      (export "task.return" (func $task.return))
    ))))
    (func (export "block") async (result u32)
      (canon lift (core func $core "block") async (callback (core func $core "never-cb"))))
  )
  (instance $blocker (instantiate $Blocker))
  (instance $inner (instantiate $Inner (with "blocker" (instance $blocker))))
  (instance $sibling (instantiate $Sibling (with "inner" (instance $inner))))
  (instance $driver (instantiate $Driver
    (with "sibling" (instance $sibling))
    (with "inner" (instance $inner))))
  (func (export "setup") (alias export $inner "setup"))
  (func (export "block") (alias export $driver "block"))
)

(component instance $i $Tester1)
(assert_return (invoke "setup") (u32.const 1))
(assert_trap (invoke "block") "deadlock detected: event loop cannot make further progress")

;; To further test this behavior, the following test creates a bunch of
;; "tempter" coop threads which sit in a sibling instance and must not be
;; resumed when a sync call in the primary component instance blocks.
;;
;; In particular:
;;   1. "setup" spawns thread X inside $Inner (X belongs to a resolved
;;      async-typed task, so it may block).
;;   2. "run" ($Driver, non-async-typed, called by the host):
;;      a. calls $Sibling.arm(8), leaving 8 ready tempter threads in
;;         $Sibling whose bodies call $Inner.poke and trap (unreachable) iff
;;         poke reports the pinned call still in progress;
;;      b. sync-calls $Inner.inner-block (non-async-typed), which runs 4
;;         rounds: each round suspend-then-resumes X, and X makes the
;;         implicit thread ready again (thread.resume-later) and suspends.
;;   At each of X's 4 suspends, the ready threads are: the implicit thread
;;   (same instance) and the 8 tempters (sibling instance). Per the spec the
;;   candidate set is {implicit thread} only, so every round progresses and
;;   "run" returns 42 without any trap.
(component definition $Tester2
  (component $Inner
    (core module $Table
      (table (export "__indirect_function_table") 1 funcref))
    (core instance $table (instantiate $Table))
    (core module $Core
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
      (import "" "thread.suspend-then-resume" (func $thread.suspend-then-resume (param i32) (result i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "thread.suspend" (func $thread.suspend (result i32)))
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "__indirect_function_table" (table $indirect-function-table 1 funcref))

      (global $setup-thread-index (mut i32) (i32.const 0xdead))
      (global $implicit-thread-index (mut i32) (i32.const 0xdead))
      (global $pinned (mut i32) (i32.const 0))

      (func (export "never-cb") (param i32 i32 i32) (result i32)
        unreachable)

      ;; X: each round, make the pinned call's implicit thread ready again,
      ;; then suspend, giving the scheduler a choice between the implicit thread
      ;; (same instance) and the armed tempters (sibling instance).
      (func $thread-start-block (param i32)
        (local $r i32)
        (loop $rounds
          (call $thread.resume-later (global.get $implicit-thread-index))
          (drop (call $thread.suspend))
          (local.set $r (i32.add (local.get $r) (i32.const 1)))
          (br_if $rounds (i32.lt_u (local.get $r) (i32.const 4))))
        unreachable)
      (elem (table $indirect-function-table) (i32.const 0) func $thread-start-block)

      ;; async callback task spawns X (left suspended) and resolves
      (func (export "setup") (result i32)
        (global.set $setup-thread-index (call $thread.new-indirect (i32.const 0) (i32.const 0)))
        (call $task.return (i32.const 1))
        (i32.const 0 (; EXIT ;)))

      ;; non-async-typed: 4 rounds of switching to X and being made ready
      ;; again by it
      (func (export "inner-block") (result i32)
        (local $r i32)
        (global.set $implicit-thread-index (call $thread.index))
        (global.set $pinned (i32.const 1))
        (loop $rounds
          (drop (call $thread.suspend-then-resume (global.get $setup-thread-index)))
          (local.set $r (i32.add (local.get $r) (i32.const 1)))
          (br_if $rounds (i32.lt_u (local.get $r) (i32.const 4))))
        (global.set $pinned (i32.const 0))
        (i32.const 42))

      ;; reentry probe: reports whether the sync call is still in progress
      (func (export "poke") (result i32)
        (global.get $pinned))
    )
    (core type $start-func-ty (func (param i32)))
    (alias core export $table "__indirect_function_table" (core table $indirect-function-table))
    (core func $thread.new-indirect
      (canon thread.new-indirect $start-func-ty (core table $indirect-function-table)))
    (canon task.return (result u32) (core func $task.return))
    (canon thread.suspend-then-resume (core func $thread.suspend-then-resume))
    (canon thread.resume-later (core func $thread.resume-later))
    (canon thread.suspend (core func $thread.suspend))
    (canon thread.index (core func $thread.index))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return" (func $task.return))
      (export "thread.new-indirect" (func $thread.new-indirect))
      (export "thread.suspend-then-resume" (func $thread.suspend-then-resume))
      (export "thread.resume-later" (func $thread.resume-later))
      (export "thread.suspend" (func $thread.suspend))
      (export "thread.index" (func $thread.index))
      (export "__indirect_function_table" (table $indirect-function-table))
    ))))
    (func (export "setup") async (result u32)
      (canon lift (core func $core "setup") async (callback (core func $core "never-cb"))))
    (func (export "inner-block") (result u32)
      (canon lift (core func $core "inner-block")))
    (func (export "poke") (result u32)
      (canon lift (core func $core "poke")))
  )
  (component $Sibling
    (import "inner" (instance $inner
      (export "poke" (func (result u32)))
    ))
    (core module $Table
      (table (export "__indirect_function_table") 1 funcref))
    (core instance $table (instantiate $Table))
    (core module $Core
      (import "" "poke" (func $poke (result i32)))
      (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "__indirect_function_table" (table $indirect-function-table 1 funcref))

      ;; tempter thread that traps iff wrongly run while the sync call into $Inner is run
      (func $thread-start-tempt (param i32)
        (if (i32.ne (call $poke) (i32.const 0))
          (then unreachable)))
      (elem (table $indirect-function-table) (i32.const 0) func $thread-start-tempt)

      ;; spawns $count tempter threads
      (func (export "arm") (param $count i32)
        (loop $again
          (call $thread.resume-later (call $thread.new-indirect (i32.const 0) (i32.const 0)))
          (local.set $count (i32.sub (local.get $count) (i32.const 1)))
          (br_if $again (i32.gt_u (local.get $count) (i32.const 0)))))
    )
    (core type $start-func-ty (func (param i32)))
    (alias core export $table "__indirect_function_table" (core table $indirect-function-table))
    (core func $thread.new-indirect
      (canon thread.new-indirect $start-func-ty (core table $indirect-function-table)))
    (canon thread.resume-later (core func $thread.resume-later))
    (canon lower (func $inner "poke") (core func $poke'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "poke" (func $poke'))
      (export "thread.new-indirect" (func $thread.new-indirect))
      (export "thread.resume-later" (func $thread.resume-later))
      (export "__indirect_function_table" (table $indirect-function-table))
    ))))
    (func (export "arm") (param "count" u32)
      (canon lift (core func $core "arm")))
  )
  (component $Driver
    (import "sibling" (instance $sibling
      (export "arm" (func (param "count" u32)))
    ))
    (import "inner" (instance $inner
      (export "inner-block" (func (result u32)))
    ))
    (core module $Core
      (import "" "arm" (func $arm (param i32)))
      (import "" "inner-block" (func $inner-block (result i32)))
      (func (export "run") (result i32)
        (call $arm (i32.const 8))
        (call $inner-block)))
    (canon lower (func $sibling "arm") (core func $arm'))
    (canon lower (func $inner "inner-block") (core func $inner-block'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "arm" (func $arm'))
      (export "inner-block" (func $inner-block'))
    ))))
    (func (export "run") (result u32)
      (canon lift (core func $core "run")))
  )
  (instance $inner (instantiate $Inner))
  (instance $sibling (instantiate $Sibling (with "inner" (instance $inner))))
  (instance $driver (instantiate $Driver
    (with "sibling" (instance $sibling))
    (with "inner" (instance $inner))))
  (func (export "setup") (alias export $inner "setup"))
  (func (export "run") (alias export $driver "run"))
)

(component instance $i $Tester2)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run") (u32.const 42))
