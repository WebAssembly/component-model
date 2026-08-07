;; Whether a thread may synchronously call an async-typed function does not
;; depend on the thread's task's function type (since threads can arbitrarily
;; switch to any other thread running in the same component instance). Rather,
;; it depends on whether, at the point of blocking, there are any other
;; threads that are ready to run (b/c they yielded or are waiting on a waitable
;; that is now ready).
;;
;; To test this, each tester below has two non-async-typed exports, so both
;; run their bodies inside a dynamic scope where the "cannot block before
;; returning" requirement is active, and both synchronously call the same
;; eagerly-completing async-typed import. The only difference is which task
;; the executing thread belongs to:
;;   * async-task-thread-caller performs the call from a thread belonging to
;;     a (resolved) async-typed task
;;   * sync-task-thread-caller performs the call from its own thread (which
;;     belongs to a non-async-typed task)
;; Per spec, both should succeed for the same reason since the thread's task's
;; function type doesn't matter; only whether there are other ready threads.

;; The first tester only uses 0.3.0 features: "setup" resolves via task.return,
;; then returns YIELD, leaving its implicit thread X ready in $D; the two
;; non-async-typed exports of $D are sync-called from async-typed $Driver
;; tasks:
;;   * async-task-thread-caller thread.yields in a loop until the scheduler
;;     switches to X, whose callback performs the call and sets a flag; the
;;     yield-looping implicit thread is the other ready thread at the point of
;;     the call
;;   * sync-task-thread-caller performs the call from its own thread, with X
;;     (left ready by a preceding "setup" call) as the other ready thread
(component definition $Tester1
  (component $C
    (core module $CM
      (func (export "eager-async-func") (result i32)
        (i32.const 43))
    )
    (core instance $cm (instantiate $CM))
    ;; async-typed, but completes eagerly (sync-lifted, returns immediately)
    (func (export "eager-async-func") async (result u32)
      (canon lift (core func $cm "eager-async-func")))
  )
  (component $D
    (import "c" (instance $c
      (export "eager-async-func" (func async (result u32)))
    ))
    (core module $Core
      (import "" "eager-async-func" (func $eager-async-func (result i32)))
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "thread.yield" (func $thread.yield (result i32)))

      (global $x-ran (mut i32) (i32.const 0))
      (global $result (mut i32) (i32.const 0xdead))

      ;; async callback task resolves, then leaves X (its implicit thread)
      ;; ready by returning YIELD
      (func (export "setup") (result i32)
        (call $task.return (i32.const 1))
        (i32.const 1 (; YIELD ;)))

      ;; X: resumed with EVENT_NONE some time after the YIELD; sync-call the
      ;; async-typed import (which completes eagerly) from this thread of a
      ;; resolved async-typed task, then record completion and exit
      (func (export "setup-cb") (param i32 i32 i32) (result i32)
        (if (i32.ne (local.get 0) (i32.const 0 (; EVENT_NONE ;)))
          (then unreachable))
        (global.set $result (call $eager-async-func))
        (global.set $x-ran (i32.const 1))
        (i32.const 0 (; EXIT ;)))

      ;; non-async-typed: yield until the scheduler (which may keep
      ;; nondeterministically resuming this thread instead) actually switches
      ;; to X, which performs the call; this yield-looping thread is the ready
      ;; thread that would allow X to block at the point of its call
      (func (export "async-task-thread-caller") (result i32)
        (loop $again
          (drop (call $thread.yield))
          (br_if $again (i32.eqz (global.get $x-ran))))
        (global.get $result))

      ;; non-async-typed: perform the call from this task's own thread; X is
      ;; the ready thread that would allow this thread to block at the point
      ;; of its call
      (func (export "sync-task-thread-caller") (result i32)
        (call $eager-async-func))
    )
    (canon task.return (result u32) (core func $task.return))
    (canon thread.yield (core func $thread.yield))
    (canon lower (func $c "eager-async-func") (core func $eager-async-func'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "eager-async-func" (func $eager-async-func'))
      (export "task.return" (func $task.return))
      (export "thread.yield" (func $thread.yield))
    ))))
    (func (export "setup") async (result u32)
      (canon lift (core func $core "setup") async (callback (core func $core "setup-cb"))))
    (func (export "async-task-thread-caller") (result u32)
      (canon lift (core func $core "async-task-thread-caller")))
    (func (export "sync-task-thread-caller") (result u32)
      (canon lift (core func $core "sync-task-thread-caller")))
  )
  (component $Driver
    (import "d" (instance $d
      (export "async-task-thread-caller" (func (result u32)))
      (export "sync-task-thread-caller" (func (result u32)))
    ))
    (core module $Core
      (import "" "async-task-thread-caller" (func $async-task-thread-caller (result i32)))
      (import "" "sync-task-thread-caller" (func $sync-task-thread-caller (result i32)))
      (import "" "task.return" (func $task.return (param i32)))
      (func (export "never-cb") (param i32 i32 i32) (result i32)
        unreachable)
      (func (export "async-task-thread-caller") (result i32)
        (call $task.return (call $async-task-thread-caller))
        (i32.const 0 (; EXIT ;)))
      (func (export "sync-task-thread-caller") (result i32)
        (call $task.return (call $sync-task-thread-caller))
        (i32.const 0 (; EXIT ;))))
    (canon task.return (result u32) (core func $task.return))
    (canon lower (func $d "async-task-thread-caller") (core func $async-task-thread-caller'))
    (canon lower (func $d "sync-task-thread-caller") (core func $sync-task-thread-caller'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "async-task-thread-caller" (func $async-task-thread-caller'))
      (export "sync-task-thread-caller" (func $sync-task-thread-caller'))
      (export "task.return" (func $task.return))
    ))))
    (func (export "async-task-thread-caller") async (result u32)
      (canon lift (core func $core "async-task-thread-caller") async (callback (core func $core "never-cb"))))
    (func (export "sync-task-thread-caller") async (result u32)
      (canon lift (core func $core "sync-task-thread-caller") async (callback (core func $core "never-cb"))))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "c" (instance $c))))
  (instance $driver (instantiate $Driver (with "d" (instance $d))))
  (func (export "setup") (alias export $d "setup"))
  (func (export "async-task-thread-caller") (alias export $driver "async-task-thread-caller"))
  (func (export "sync-task-thread-caller") (alias export $driver "sync-task-thread-caller"))
)

(component instance $i $Tester1)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "async-task-thread-caller") (u32.const 43))

(component instance $i $Tester1)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "sync-task-thread-caller") (u32.const 43))

;; The second tester does the same using cooperative threading features: both
;; exports run the same shared body $arm-and-call: arm a ready cooperative
;; (noop) thread, then synchronously call the eagerly-completing async-typed
;; import. async-task-thread-caller suspend-then-resumes X (spawned by "setup"
;; on its resolved async-typed task), which runs the shared body and switches
;; back; sync-task-thread-caller runs the shared body on its own thread.
(component definition $Tester2
  (component $C
    (core module $CM
      (func (export "eager-async-func") (result i32)
        (i32.const 43))
    )
    (core instance $cm (instantiate $CM))
    ;; async-typed, but completes eagerly (sync-lifted, returns immediately)
    (func (export "eager-async-func") async (result u32)
      (canon lift (core func $cm "eager-async-func")))
  )
  (component $D
    (import "c" (instance $c
      (export "eager-async-func" (func async (result u32)))
    ))
    (core module $Table
      (table (export "__indirect_function_table") 2 funcref))
    (core instance $table (instantiate $Table))
    (core module $Core
      (import "" "eager-async-func" (func $eager-async-func (result i32)))
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "thread.suspend-then-resume" (func $thread.suspend-then-resume (param i32) (result i32)))
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "__indirect_function_table" (table $indirect-function-table 2 funcref))

      (global $x-index (mut i32) (i32.const 0xdead))
      (global $i-index (mut i32) (i32.const 0xdead))
      (global $result (mut i32) (i32.const 0xdead))

      (func (export "never-cb") (param i32 i32 i32) (result i32)
        unreachable)

      (func $thread-start-noop (param i32))
      (elem (table $indirect-function-table) (i32.const 0) func $thread-start-noop)

      ;; shared body: arm a ready cooperative thread, then sync-call the
      ;; async-typed import (which completes eagerly)
      (func $arm-and-call (result i32)
        (call $thread.resume-later (call $thread.new-indirect (i32.const 0) (i32.const 0)))
        (call $eager-async-func))

      ;; X: run the shared body on a thread of the async-typed "setup" task,
      ;; then switch back to the non-async-typed call's implicit thread
      (func $thread-start-call (param i32)
        (global.set $result (call $arm-and-call))
        (drop (call $thread.suspend-then-resume (global.get $i-index))))
      (elem (table $indirect-function-table) (i32.const 1) func $thread-start-call)

      ;; async-typed callback task spawns X (left suspended) and resolves
      (func (export "setup") (result i32)
        (global.set $x-index (call $thread.new-indirect (i32.const 1) (i32.const 0)))
        (call $task.return (i32.const 1))
        (i32.const 0 (; EXIT ;)))

      ;; non-async-typed: the shared body runs on this task's own thread
      (func (export "sync-task-thread-caller") (result i32)
        (call $arm-and-call))

      ;; non-async-typed: the shared body runs on X, switched-to mid-call
      (func (export "async-task-thread-caller") (result i32)
        (global.set $i-index (call $thread.index))
        (drop (call $thread.suspend-then-resume (global.get $x-index)))
        (global.get $result))
    )
    (core type $start-func-ty (func (param i32)))
    (alias core export $table "__indirect_function_table" (core table $indirect-function-table))
    (core func $thread.new-indirect
      (canon thread.new-indirect $start-func-ty (core table $indirect-function-table)))
    (canon task.return (result u32) (core func $task.return))
    (canon thread.resume-later (core func $thread.resume-later))
    (canon thread.suspend-then-resume (core func $thread.suspend-then-resume))
    (canon thread.index (core func $thread.index))
    (canon lower (func $c "eager-async-func") (core func $eager-async-func'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "eager-async-func" (func $eager-async-func'))
      (export "task.return" (func $task.return))
      (export "thread.new-indirect" (func $thread.new-indirect))
      (export "thread.resume-later" (func $thread.resume-later))
      (export "thread.suspend-then-resume" (func $thread.suspend-then-resume))
      (export "thread.index" (func $thread.index))
      (export "__indirect_function_table" (table $indirect-function-table))
    ))))
    (func (export "setup") async (result u32)
      (canon lift (core func $core "setup") async (callback (core func $core "never-cb"))))
    (func (export "sync-task-thread-caller") (result u32)
      (canon lift (core func $core "sync-task-thread-caller")))
    (func (export "async-task-thread-caller") (result u32)
      (canon lift (core func $core "async-task-thread-caller")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "c" (instance $c))))
  (func (export "setup") (alias export $d "setup"))
  (func (export "sync-task-thread-caller") (alias export $d "sync-task-thread-caller"))
  (func (export "async-task-thread-caller") (alias export $d "async-task-thread-caller"))
)

(component instance $i $Tester2)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "async-task-thread-caller") (u32.const 43))

(component instance $i $Tester2)
(assert_return (invoke "sync-task-thread-caller") (u32.const 43))
