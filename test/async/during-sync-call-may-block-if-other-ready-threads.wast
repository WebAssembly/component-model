;; Whether a thread may synchronously call an async-typed function does not
;; depend on the thread's task's function type (since threads can arbitrarily
;; switch to any other thread running in the same component instance). Rather,
;; it depends on whether, at the point of blocking, there are any other
;; threads that are ready to run.
;;
;; To test this, the tester below has two non-async-typed exports, so both
;; run their bodies inside a dynamic scope where the "cannot block before
;; returning" requirement is active, and both synchronously call the same
;; eagerly-completing async-typed import, but from different threads which
;; belong to different tasks.
(component definition $Tester
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

(component instance $i $Tester)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "async-task-thread-caller") (u32.const 43))

(component instance $i $Tester)
(assert_return (invoke "sync-task-thread-caller") (u32.const 43))

;; A non-async-typed call may also block by suspending its implicit thread
;; outright, so long as control flow eventually finds its way back to that
;; thread so it can return. Whenever a thread blocks or finishes without
;; switching directly to another thread, control returns to the sync call's
;; mini-scheduler, which resumes ready threads of the same component instance
;; until the call resolves (trapping if there are none).
;;
;; The chain below runs that mini-scheduler three times:
;;  1. 'setup' is an async callback task whose implicit thread T1 resolves the
;;     task and then returns YIELD to park itself, ready, in its event loop;
;;     the async call returns to the top level once T1 is parked.
;;  2. The non-async-typed 'run' runs on T2, which creates the (suspended)
;;     explicit thread T3, sets $may-exit and then suspends itself, leaving the
;;     parked T1 as the mini-scheduler's only candidate; T1 is thus resumed
;;     (running its callback) in the middle of the sync call.
;;  3. T1's callback makes T3 ready and returns EXIT; T1 exiting drops back
;;     into the mini-scheduler, whose only candidate is now T3.
;;  4. T3 makes T2 ready and exits, dropping back into the mini-scheduler
;;     again, which resumes T2, which returns without having blocked the call.
(component
  (core module $Table
    (table (export "__indirect_function_table") 1 funcref))
  (core instance $table (instantiate $Table))
  (core module $Core
    (import "" "task.return" (func $task.return (param i32)))
    (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
    (import "" "thread.index" (func $thread.index (result i32)))
    (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
    (import "" "thread.suspend" (func $thread.suspend (result i32)))
    (import "" "__indirect_function_table" (table $indirect-function-table 1 funcref))

    (global $setup-thread (mut i32) (i32.const 0xdead))   ;; T1
    (global $sync-thread (mut i32) (i32.const 0xdead))    ;; T2
    (global $worker-thread (mut i32) (i32.const 0xdead))  ;; T3
    (global $may-exit (mut i32) (i32.const 0))
    (global $worker-ran (mut i32) (i32.const 0))

    ;; T1: resolve, then park the implicit thread, ready, in the event loop
    (func (export "setup") (result i32)
      (global.set $setup-thread (call $thread.index))
      (call $task.return (i32.const 1))
      (i32.const 1 (; YIELD ;)))

    ;; Park again on a spurious wake-up outside the sync call; once resumed by
    ;; the mini-scheduler during it, make T3 ready and exit.
    (func (export "setup-cb") (param i32 i32 i32) (result i32)
      (if (i32.eqz (global.get $may-exit))
        (then (return (i32.const 1 (; YIELD ;)))))
      (call $thread.resume-later (global.get $worker-thread))
      (i32.const 0 (; EXIT ;)))

    ;; T3: resumed by the mini-scheduler after T1 exits; the only thread left
    ;; that can wake T2
    (func $worker (param i32)
      (global.set $worker-ran (i32.const 1))
      (call $thread.resume-later (global.get $sync-thread)))
    (elem (table $indirect-function-table) (i32.const 0) func $worker)

    ;; T2: non-async-typed, so it must not block before returning
    (func (export "run") (result i32)
      (global.set $sync-thread (call $thread.index))
      (global.set $worker-thread (call $thread.new-indirect (i32.const 0) (i32.const 0)))
      (global.set $may-exit (i32.const 1))
      (drop (call $thread.suspend))
      (if (i32.eqz (global.get $worker-ran))
        (then unreachable))
      (i32.const 42))
  )
  (core type $start-func-ty (func (param i32)))
  (alias core export $table "__indirect_function_table" (core table $indirect-function-table))
  (core func $thread.new-indirect
    (canon thread.new-indirect $start-func-ty (core table $indirect-function-table)))
  (canon task.return (result u32) (core func $task.return))
  (canon thread.index (core func $thread.index))
  (canon thread.resume-later (core func $thread.resume-later))
  (canon thread.suspend (core func $thread.suspend))
  (core instance $core (instantiate $Core (with "" (instance
    (export "task.return" (func $task.return))
    (export "thread.new-indirect" (func $thread.new-indirect))
    (export "thread.index" (func $thread.index))
    (export "thread.resume-later" (func $thread.resume-later))
    (export "thread.suspend" (func $thread.suspend))
    (export "__indirect_function_table" (table $indirect-function-table))
  ))))
  (func (export "setup") async (result u32)
    (canon lift (core func $core "setup") async (callback (core func $core "setup-cb"))))
  (func (export "run") (result u32)
    (canon lift (core func $core "run")))
)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run") (u32.const 42))
