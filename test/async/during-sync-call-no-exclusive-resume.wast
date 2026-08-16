;; While a non-async-typed export call is in progress, the runtime must only
;; ever resume threads that can use the stack: in particular, the implicit
;; threads of async-typed tasks that need exclusive use of the stack must never
;; be resumed, even when they are ready and in the same component instance. To
;; test this, a number of ready-but-excluded threads are created, all of which
;; trap if ever resumed, and the sync call must instead make progress through
;; one valid resumable thread.
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
      (global $in-sync-call (mut i32) (i32.const 0))

      (func $thread-start (param i32)
        (local $r i32)
        (loop $rounds
          (call $thread.resume-later (global.get $implicit-thread-index))
          (drop (call $thread.suspend))
          (local.set $r (i32.add (local.get $r) (i32.const 1)))
          (br_if $rounds (i32.lt_u (local.get $r) (i32.const 4))))
        unreachable)
      (elem (table $indirect-function-table) (i32.const 0) func $thread-start)

      (func (export "setup") (result i32)
        (global.set $setup-thread-index (call $thread.new-indirect (i32.const 0) (i32.const 0)))
        (call $task.return (i32.const 1))
        (i32.const 0 (; EXIT ;)))

      ;; async callback task resolves, then parks its implicit thread, ready,
      ;; in its event loop by returning YIELD. Since a YIELD may
      ;; nondeterministically complete without suspending, 'never-cb' may be
      ;; called (with a NONE event) while no non-async-typed call is in
      ;; progress and parks the thread again; it must never be called during
      ;; 'sync-block'.
      (func (export "arm") (result i32)
        (call $task.return (i32.const 1))
        (i32.const 1 (; YIELD ;)))

      (func (export "never-cb") (param i32 i32 i32) (result i32)
        (if (global.get $in-sync-call)
          (then unreachable))
        (i32.const 1 (; YIELD ;)))

      ;; non-async-typed: 4 rounds of switching to $thread-start and being made ready
      ;; again by it
      (func (export "sync-block") (result i32)
        (local $r i32)
        (global.set $in-sync-call (i32.const 1))
        (global.set $implicit-thread-index (call $thread.index))
        (loop $rounds
          (drop (call $thread.suspend-then-resume (global.get $setup-thread-index)))
          (local.set $r (i32.add (local.get $r) (i32.const 1)))
          (br_if $rounds (i32.lt_u (local.get $r) (i32.const 4))))
        (global.set $in-sync-call (i32.const 0))
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
    (func (export "arm") async (result u32)
      (canon lift (core func $core "arm") async (callback (core func $core "never-cb"))))
    (func (export "sync-block") (result u32)
      (canon lift (core func $core "sync-block")))
  )
  (component $Driver
    (import "inner" (instance $inner
      (export "sync-block" (func (result u32)))
    ))
    (core module $Core
      (import "" "sync-block" (func $sync-block (result i32)))
      (func (export "run") (result i32)
        (call $sync-block)))
    (canon lower (func $inner "sync-block") (core func $sync-block'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "sync-block" (func $sync-block'))
    ))))
    (func (export "run") (result u32)
      (canon lift (core func $core "run")))
  )
  (instance $inner (instantiate $Inner))
  (instance $driver (instantiate $Driver (with "inner" (instance $inner))))
  (func (export "setup") (alias export $inner "setup"))
  (func (export "arm") (alias export $inner "arm"))
  (func (export "run") (alias export $driver "run"))
)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "arm") (u32.const 1))
(assert_return (invoke "arm") (u32.const 1))
(assert_return (invoke "arm") (u32.const 1))
(assert_return (invoke "run") (u32.const 42))

;; A ready-but-excluded thread does not allow the sync call to block: when
;; the only other thread in the instance needs exclusive use of the stack,
;; blocking must trap immediately rather than resume that thread.
(component
  (core module $Core
    (import "" "task.return" (func $task.return (param i32)))
    (import "" "thread.suspend" (func $thread.suspend (result i32)))

    (global $in-sync-call (mut i32) (i32.const 0))

    ;; async callback task resolves, then parks its implicit thread, ready,
    ;; in its event loop by returning YIELD. Since a YIELD may
    ;; nondeterministically complete without suspending, 'never-cb' may be
    ;; called (with a NONE event) while no non-async-typed call is in progress
    ;; and parks the thread again; it must never be called during 'sync-block'.
    (func (export "arm") (result i32)
      (call $task.return (i32.const 1))
      (i32.const 1 (; YIELD ;)))

    (func (export "never-cb") (param i32 i32 i32) (result i32)
      (if (global.get $in-sync-call)
        (then unreachable))
      (i32.const 1 (; YIELD ;)))

    ;; non-async-typed: suspend with no valid thread to switch to
    (func (export "sync-block")
      (global.set $in-sync-call (i32.const 1))
      (drop (call $thread.suspend))
      unreachable)
  )
  (canon task.return (result u32) (core func $task.return))
  (canon thread.suspend (core func $thread.suspend))
  (core instance $core (instantiate $Core (with "" (instance
    (export "task.return" (func $task.return))
    (export "thread.suspend" (func $thread.suspend))
  ))))
  (func (export "arm") async (result u32)
    (canon lift (core func $core "arm") async (callback (core func $core "never-cb"))))
  (func (export "sync-block")
    (canon lift (core func $core "sync-block")))
)
(assert_return (invoke "arm") (u32.const 1))
(assert_trap (invoke "sync-block") "deadlock detected: event loop cannot make further progress")
