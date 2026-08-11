;; While a non-async-typed export call is in progress, the runtime must only
;; ever resume threads of that call's own component instance (which is necessary
;; to prevent accidental and unexpected reentrance). To test this behavior, the
;; following test creates a bunch of ready-but-excluded threads which sit in a
;; sibling instance and must not be resumed when a sync call in the primary
;; component instance blocks.
;;
;; In particular:
;;   1. "setup" spawns thread X inside $Inner (X belongs to a resolved
;;      async-typed task, so it may block).
;;   2. "run" ($Driver, non-async-typed, called by the host):
;;      a. calls $Sibling.arm(8), leaving 8 ready-but-excluded threads;
;;      b. sync-calls $Inner.inner-block (non-async-typed), which runs 4
;;         rounds: each round suspend-then-resumes X, and X makes the
;;         implicit thread ready again (thread.resume-later) and suspends.
(component
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
      ;; (same instance) and the armed sibling threads.
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
  )
  (component $Sibling
    (core module $Table
      (table (export "__indirect_function_table") 1 funcref))
    (core instance $table (instantiate $Table))
    (core module $Core
      (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "__indirect_function_table" (table $indirect-function-table 1 funcref))

      (func $thread-start-func (param i32)
        unreachable)
      (elem (table $indirect-function-table) (i32.const 0) func $thread-start-func)

      ;; spawns $count ready-but-must-not-resume threads
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
    (core instance $core (instantiate $Core (with "" (instance
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
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run") (u32.const 42))

;; A ready thread in a sibling instance does not allow the sync call to
;; block: even though the sibling's thread could use the stack, it does not
;; belong to the sync call's component instance, so blocking must trap
;; immediately rather than resume it.
(component
  (component $Inner
    (core module $Core
      (import "" "thread.suspend" (func $thread.suspend (result i32)))

      ;; non-async-typed: suspend with no thread of this instance to switch to
      (func (export "sync-block")
        (drop (call $thread.suspend))
        unreachable)
    )
    (canon thread.suspend (core func $thread.suspend))
    (core instance $core (instantiate $Core (with "" (instance
      (export "thread.suspend" (func $thread.suspend))
    ))))
    (func (export "sync-block")
      (canon lift (core func $core "sync-block")))
  )
  (component $Sibling
    (core module $Table
      (table (export "__indirect_function_table") 1 funcref))
    (core instance $table (instantiate $Table))
    (core module $Core
      (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "__indirect_function_table" (table $indirect-function-table 1 funcref))

      (func $thread-start-func (param i32)
        unreachable)
      (elem (table $indirect-function-table) (i32.const 0) func $thread-start-func)

      ;; spawns one ready-but-must-not-resume thread
      (func (export "arm")
        (call $thread.resume-later (call $thread.new-indirect (i32.const 0) (i32.const 0))))
    )
    (core type $start-func-ty (func (param i32)))
    (alias core export $table "__indirect_function_table" (core table $indirect-function-table))
    (core func $thread.new-indirect
      (canon thread.new-indirect $start-func-ty (core table $indirect-function-table)))
    (canon thread.resume-later (core func $thread.resume-later))
    (core instance $core (instantiate $Core (with "" (instance
      (export "thread.new-indirect" (func $thread.new-indirect))
      (export "thread.resume-later" (func $thread.resume-later))
      (export "__indirect_function_table" (table $indirect-function-table))
    ))))
    (func (export "arm")
      (canon lift (core func $core "arm")))
  )
  (instance $inner (instantiate $Inner))
  (instance $sibling (instantiate $Sibling))
  (func (export "arm") (alias export $sibling "arm"))
  (func (export "sync-block") (alias export $inner "sync-block"))
)
(assert_return (invoke "arm"))
(assert_trap (invoke "sync-block") "cannot block a synchronous task before returning")
