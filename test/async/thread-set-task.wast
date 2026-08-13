;; Test thread.set-task's observable effects on the semantics of task.return,
;; cancellation, thread spawning and the no-threads-but-not-resolved trap.

;; Self/sibling moves are no-ops; a joined thread returns for its new task and
;; traps if it returns with a task.return typed for its old task.
(component
  (component $C
    (core module $Table
      (table (export "__indirect_function_table") 3 funcref))
    (core instance $table (instantiate $Table))
    (core module $Core
      (import "" "task.return-u8" (func $task.return-u8 (param i32)))
      (import "" "task.return-u32" (func $task.return-u32 (param i32)))
      (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "thread.set-task" (func $thread.set-task (param i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "thread.suspend-then-resume" (func $thread.suspend-then-resume (param i32) (result i32)))
      (import "" "__indirect_function_table" (table $indirect-function-table 3 funcref))

      (global $x (mut i32) (i32.const 0xdead))   ;; explicit thread spawned into task A
      (global $y (mut i32) (i32.const 0xdead))   ;; sibling thread, also in task A
      (global $x2 (mut i32) (i32.const 0xdead))  ;; second mover, used by join-bad
      (global $b0 (mut i32) (i32.const 0xdead))  ;; implicit thread of the current join task

      ;; X: starts in task A (already resolved), joins task B, returns for B
      (func $worker (param i32)
        (local $xi i32)
        (local.set $xi (call $thread.index))

        ;; moving to one's own task is a no-op, not a trap...
        (call $thread.set-task (local.get $xi))
        (if (i32.ne (local.get $xi) (call $thread.index))
          (then unreachable))

        ;; ...as is moving to the task of a sibling thread of the same task
        (call $thread.set-task (global.get $y))
        (if (i32.ne (local.get $xi) (call $thread.index))
          (then unreachable))

        ;; join task B. The thread's index in the instance's thread table is
        ;; unchanged by the move.
        (call $thread.set-task (global.get $b0))
        (if (i32.ne (local.get $xi) (call $thread.index))
          (then unreachable))

        ;; task.return now returns for task B, not for task A: A returns a u8
        ;; and has in any case already resolved, so returning a u32 here is
        ;; only well-typed (and only permitted) against B
        (call $task.return-u32 (i32.const 42))

        ;; make B's implicit thread runnable again and exit, which unregisters
        ;; this thread from its new task (B) rather than from A
        (call $thread.resume-later (global.get $b0)))

      ;; Y: never resumed; exists only to be the sibling-move target above
      (func $parker (param i32)
        unreachable)

      ;; X2: joins task B2 and calls task A's u8-typed task.return: the
      ;; declared result type is checked against the *current* task, which is
      ;; now B2 with a u32 result, so this traps
      (func $worker-bad (param i32)
        (call $thread.set-task (global.get $b0))
        (call $task.return-u8 (i32.const 33))
        unreachable)

      (elem (table $indirect-function-table) (i32.const 0) func $worker $parker $worker-bad)

      ;; task A: spawn X, Y and X2, resolve, then let the implicit thread exit
      (func (export "setup")
        (global.set $x (call $thread.new-indirect (i32.const 0) (i32.const 0)))
        (global.set $y (call $thread.new-indirect (i32.const 1) (i32.const 0)))
        (global.set $x2 (call $thread.new-indirect (i32.const 2) (i32.const 0)))
        (call $task.return-u8 (i32.const 1)))

      ;; task B: switch to X, which returns 42 on B's behalf
      (func (export "join")
        (global.set $b0 (call $thread.index))
        (drop (call $thread.suspend-then-resume (global.get $x))))

      ;; task B2: switch to X2, which joins B2 and then traps returning with
      ;; the wrong task.return
      (func (export "join-bad")
        (global.set $b0 (call $thread.index))
        (drop (call $thread.suspend-then-resume (global.get $x2)))
        unreachable)
    )
    (core type $start-func-ty (func (param i32)))
    (alias core export $table "__indirect_function_table" (core table $indirect-function-table))
    (core func $thread.new-indirect
      (canon thread.new-indirect $start-func-ty (core table $indirect-function-table)))
    (canon task.return (result u8) (core func $task.return-u8))
    (canon task.return (result u32) (core func $task.return-u32))
    (canon thread.index (core func $thread.index))
    (canon thread.set-task (core func $thread.set-task))
    (canon thread.resume-later (core func $thread.resume-later))
    (canon thread.suspend-then-resume (core func $thread.suspend-then-resume))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return-u8" (func $task.return-u8))
      (export "task.return-u32" (func $task.return-u32))
      (export "thread.new-indirect" (func $thread.new-indirect))
      (export "thread.index" (func $thread.index))
      (export "thread.set-task" (func $thread.set-task))
      (export "thread.resume-later" (func $thread.resume-later))
      (export "thread.suspend-then-resume" (func $thread.suspend-then-resume))
      (export "__indirect_function_table" (table $indirect-function-table))
    ))))
    (func (export "setup") async (result u8)
      (canon lift (core func $core "setup") async))
    (func (export "join") async (result u32)
      (canon lift (core func $core "join") async))
    (func (export "join-bad") async (result u32)
      (canon lift (core func $core "join-bad") async))
  )
  (instance $c (instantiate $C))
  (func (export "setup") (alias export $c "setup"))
  (func (export "join") (alias export $c "join"))
  (func (export "join-bad") (alias export $c "join-bad"))
)
(assert_return (invoke "setup") (u8.const 1))
(assert_return (invoke "join") (u32.const 42))
(assert_trap (invoke "join-bad") "wasm trap: invalid `task.return` signature and/or options for current task")

;; A cancellation request is delivered to the thread that joined the task, which
;; acknowledges it with task.cancel on the new task's behalf.
(component
  (component $C
    (core module $Table
      (table (export "__indirect_function_table") 1 funcref))
    (core instance $table (instantiate $Table))
    (core module $Core
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "task.cancel" (func $task.cancel))
      (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "thread.set-task" (func $thread.set-task (param i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "thread.suspend-cancellable" (func $thread.suspend-cancellable (result i32)))
      (import "" "thread.suspend-then-resume" (func $thread.suspend-then-resume (param i32) (result i32)))
      (import "" "__indirect_function_table" (table $indirect-function-table 1 funcref))

      (global $x (mut i32) (i32.const 0xdead))
      (global $b0 (mut i32) (i32.const 0xdead))

      ;; X: joins task B and then blocks cancellably, making it the only
      ;; cancellable thread of B (B's implicit thread suspended without
      ;; `cancellable`), so B's cancellation must be delivered here.
      (func $worker (param i32)
        (call $thread.set-task (global.get $b0))
        (if (i32.ne (i32.const 1 (; CANCELLED ;)) (call $thread.suspend-cancellable))
          (then unreachable))
        (call $task.cancel)
        (call $thread.resume-later (global.get $b0)))

      (elem (table $indirect-function-table) (i32.const 0) func $worker)

      ;; task A: spawn X, resolve, then let the implicit thread exit
      (func (export "setup")
        (global.set $x (call $thread.new-indirect (i32.const 0) (i32.const 0)))
        (call $task.return (i32.const 1)))

      ;; task B: switch to X, which joins B and waits to be cancelled
      (func (export "cancel-me")
        (global.set $b0 (call $thread.index))
        (drop (call $thread.suspend-then-resume (global.get $x))))
    )
    (core type $start-func-ty (func (param i32)))
    (alias core export $table "__indirect_function_table" (core table $indirect-function-table))
    (core func $thread.new-indirect
      (canon thread.new-indirect $start-func-ty (core table $indirect-function-table)))
    (canon task.return (result u32) (core func $task.return))
    (canon task.cancel (core func $task.cancel))
    (canon thread.index (core func $thread.index))
    (canon thread.set-task (core func $thread.set-task))
    (canon thread.resume-later (core func $thread.resume-later))
    (canon thread.suspend cancellable (core func $thread.suspend-cancellable))
    (canon thread.suspend-then-resume (core func $thread.suspend-then-resume))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return" (func $task.return))
      (export "task.cancel" (func $task.cancel))
      (export "thread.new-indirect" (func $thread.new-indirect))
      (export "thread.index" (func $thread.index))
      (export "thread.set-task" (func $thread.set-task))
      (export "thread.resume-later" (func $thread.resume-later))
      (export "thread.suspend-cancellable" (func $thread.suspend-cancellable))
      (export "thread.suspend-then-resume" (func $thread.suspend-then-resume))
      (export "__indirect_function_table" (table $indirect-function-table))
    ))))
    (func (export "setup") async (result u32)
      (canon lift (core func $core "setup") async))
    (func (export "cancel-me") async (result u32)
      (canon lift (core func $core "cancel-me") async))
  )
  (component $D
    (import "cancel-me" (func $cancel-me async (result u32)))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Core
      (import "" "mem" (memory 1))
      (import "" "subtask.cancel" (func $subtask.cancel (param i32) (result i32)))
      (import "" "subtask.drop" (func $subtask.drop (param i32)))
      (import "" "cancel-me" (func $cancel-me (param i32) (result i32)))

      (func (export "run") (result i32)
        (local $ret i32)
        (local $subtask i32)

        ;; start cancel-me; it blocks with X parked in a cancellable suspend
        (local.set $ret (call $cancel-me (i32.const 4 (; retp ;))))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; the request is delivered to X, which calls task.cancel, so the
        ;; subtask is already resolved by the time subtask.cancel returns
        (local.set $ret (call $subtask.cancel (local.get $subtask)))
        (if (i32.ne (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)) (local.get $ret))
          (then unreachable))
        (call $subtask.drop (local.get $subtask))

        (i32.const 42))
    )
    (canon subtask.cancel async (core func $subtask.cancel))
    (canon subtask.drop (core func $subtask.drop))
    (canon lower (func $cancel-me) async (memory (core memory $memory "mem")) (core func $cancel-me'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "subtask.cancel" (func $subtask.cancel))
      (export "subtask.drop" (func $subtask.drop))
      (export "cancel-me" (func $cancel-me'))
    ))))
    (func (export "run") async (result u32) (canon lift (core func $core "run")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "cancel-me" (func $c "cancel-me"))))
  (func (export "setup") (alias export $c "setup"))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run") (u32.const 42))

;; A pending cancellation is delivered to the joined thread at its next cancellable built-in.
(component
  (component $C
    (core module $Table
      (table (export "__indirect_function_table") 1 funcref))
    (core instance $table (instantiate $Table))
    (core module $Core
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "task.cancel" (func $task.cancel))
      (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "thread.set-task" (func $thread.set-task (param i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "thread.suspend" (func $thread.suspend (result i32)))
      (import "" "thread.suspend-cancellable" (func $thread.suspend-cancellable (result i32)))
      (import "" "thread.suspend-then-resume" (func $thread.suspend-then-resume (param i32) (result i32)))
      (import "" "__indirect_function_table" (table $indirect-function-table 1 funcref))

      (global $x (mut i32) (i32.const 0xdead))
      (global $b0 (mut i32) (i32.const 0xdead))

      ;; X: joins task B and then blocks non-cancellably, so that when the
      ;; caller requests cancellation no thread of B can receive it and the
      ;; request is remembered as pending. B's implicit thread is left ready
      ;; so that the caller's own blocking lets it run.
      (func $worker (param i32)
        (call $thread.set-task (global.get $b0))
        (call $thread.resume-later (global.get $b0))
        (if (i32.ne (i32.const 0 (; not cancelled ;)) (call $thread.suspend))
          (then unreachable))

        ;; resumed by B's implicit thread after the request was made: the
        ;; pending cancellation is delivered here, at the first cancellable
        ;; built-in called by a thread of B
        (if (i32.ne (i32.const 1 (; CANCELLED ;)) (call $thread.suspend-cancellable))
          (then unreachable))
        (call $task.cancel)
        (call $thread.resume-later (global.get $b0)))

      (elem (table $indirect-function-table) (i32.const 0) func $worker)

      ;; task A: spawn X, resolve, then let the implicit thread exit
      (func (export "setup")
        (global.set $x (call $thread.new-indirect (i32.const 0) (i32.const 0)))
        (call $task.return (i32.const 1)))

      ;; task B: switch to X twice - once to let it join B and block
      ;; non-cancellably, and once (after the caller has requested
      ;; cancellation) to let it reach a cancellable built-in
      (func (export "cancel-pending")
        (global.set $b0 (call $thread.index))
        (drop (call $thread.suspend-then-resume (global.get $x)))
        (drop (call $thread.suspend-then-resume (global.get $x))))
    )
    (core type $start-func-ty (func (param i32)))
    (alias core export $table "__indirect_function_table" (core table $indirect-function-table))
    (core func $thread.new-indirect
      (canon thread.new-indirect $start-func-ty (core table $indirect-function-table)))
    (canon task.return (result u32) (core func $task.return))
    (canon task.cancel (core func $task.cancel))
    (canon thread.index (core func $thread.index))
    (canon thread.set-task (core func $thread.set-task))
    (canon thread.resume-later (core func $thread.resume-later))
    (canon thread.suspend (core func $thread.suspend))
    (canon thread.suspend cancellable (core func $thread.suspend-cancellable))
    (canon thread.suspend-then-resume (core func $thread.suspend-then-resume))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return" (func $task.return))
      (export "task.cancel" (func $task.cancel))
      (export "thread.new-indirect" (func $thread.new-indirect))
      (export "thread.index" (func $thread.index))
      (export "thread.set-task" (func $thread.set-task))
      (export "thread.resume-later" (func $thread.resume-later))
      (export "thread.suspend" (func $thread.suspend))
      (export "thread.suspend-cancellable" (func $thread.suspend-cancellable))
      (export "thread.suspend-then-resume" (func $thread.suspend-then-resume))
      (export "__indirect_function_table" (table $indirect-function-table))
    ))))
    (func (export "setup") async (result u32)
      (canon lift (core func $core "setup") async))
    (func (export "cancel-pending") async (result u32)
      (canon lift (core func $core "cancel-pending") async))
  )
  (component $D
    (import "cancel-pending" (func $cancel-pending async (result u32)))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Core
      (import "" "mem" (memory 1))
      (import "" "subtask.cancel" (func $subtask.cancel (param i32) (result i32)))
      (import "" "subtask.drop" (func $subtask.drop (param i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (import "" "cancel-pending" (func $cancel-pending (param i32) (result i32)))

      (func (export "run") (result i32)
        (local $ret i32)
        (local $subtask i32)
        (local $ws i32)

        ;; start cancel-pending; it blocks with no cancellable thread
        (local.set $ret (call $cancel-pending (i32.const 4 (; retp ;))))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; no thread of the callee's task is cancellable, so the request is
        ;; remembered rather than delivered
        (local.set $ret (call $subtask.cancel (local.get $subtask)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))

        ;; block, which lets the callee's ready implicit thread run and hand
        ;; control to X, which picks up the pending cancellation
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $subtask) (local.get $ws))
        (local.set $ret (call $waitable-set.wait (local.get $ws) (i32.const 8 (; eventp ;))))
        (if (i32.ne (i32.const 1 (; SUBTASK ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (local.get $subtask) (i32.load (i32.const 8)))
          (then unreachable))
        (if (i32.ne (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)) (i32.load offset=4 (i32.const 8)))
          (then unreachable))
        (call $subtask.drop (local.get $subtask))

        (i32.const 42))
    )
    (canon subtask.cancel async (core func $subtask.cancel))
    (canon subtask.drop (core func $subtask.drop))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (canon lower (func $cancel-pending) async (memory (core memory $memory "mem")) (core func $cancel-pending'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "subtask.cancel" (func $subtask.cancel))
      (export "subtask.drop" (func $subtask.drop))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "cancel-pending" (func $cancel-pending'))
    ))))
    (func (export "run") async (result u32) (canon lift (core func $core "run")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "cancel-pending" (func $c "cancel-pending"))))
  (func (export "setup") (alias export $c "setup"))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run") (u32.const 42))

;; Leaving an unresolved task is allowed while it retains another thread, and
;; moving to one's own task never empties a task, but leaving an unresolved task
;; with no threads at all traps. The task joined is the target thread's
;; *current* task, which reflects the target's own earlier moves.
(component
  (component $C
    (core module $Table
      (table (export "__indirect_function_table") 3 funcref))
    (core instance $table (instantiate $Table))
    (core module $Core
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "thread.set-task" (func $thread.set-task (param i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "thread.suspend-then-resume" (func $thread.suspend-then-resume (param i32) (result i32)))
      (import "" "__indirect_function_table" (table $indirect-function-table 3 funcref))

      (global $z (mut i32) (i32.const 0xdead))   ;; second thread of task A
      (global $x (mut i32) (i32.const 0xdead))   ;; thread that moves A -> B -> A -> B
      (global $b0 (mut i32) (i32.const 0xdead))  ;; parked thread of resolved task B

      ;; X: leaves task A while Z is still in it. A has not resolved, but it
      ;; is not left empty, so this must not trap. X then moves back to A (by
      ;; targeting Z) and to B once more: a thread can move any number of
      ;; times, with each move joining the target's *current* task and
      ;; updating the membership accounting that the trap below depends on.
      ;; Finally, X parks (rather than exiting) so that it can be the target
      ;; of Z's move below.
      (func $mover (param i32)
        (call $thread.set-task (global.get $b0))
        (call $thread.set-task (global.get $z))
        (call $thread.set-task (global.get $b0))
        (drop (call $thread.suspend-then-resume (global.get $z)))
        unreachable)

      ;; Z: now the only thread of the unresolved task A
      (func $last (param i32)
        ;; moving to one's own task removes and re-adds this thread, so even
        ;; as A's only thread it never leaves A empty and must not trap
        (call $thread.set-task (call $thread.index))
        ;; the target's containing task is determined dynamically: X has
        ;; itself moved from A to B, so targeting X moves this thread to B,
        ;; emptying A, which has not resolved: trap
        (call $thread.set-task (global.get $x))
        unreachable)

      ;; never resumed; exists only so that task B keeps a thread of its own
      ;; once its implicit thread exits, staying alive as a target to join
      (func $parker (param i32)
        unreachable)

      (elem (table $indirect-function-table) (i32.const 0) func $mover $last $parker)

      ;; task B: spawn the thread that keeps B alive, resolve, then let the
      ;; implicit thread exit
      (func (export "victim")
        (global.set $b0 (call $thread.new-indirect (i32.const 2) (i32.const 0)))
        (call $task.return (i32.const 1)))

      ;; task A: spawn X and Z and exit the implicit thread *without*
      ;; returning a value, leaving A unresolved with two threads
      (func (export "unresolved")
        (global.set $z (call $thread.new-indirect (i32.const 1) (i32.const 0)))
        (global.set $x (call $thread.new-indirect (i32.const 0) (i32.const 0)))
        (call $thread.resume-later (global.get $x)))
    )
    (core type $start-func-ty (func (param i32)))
    (alias core export $table "__indirect_function_table" (core table $indirect-function-table))
    (core func $thread.new-indirect
      (canon thread.new-indirect $start-func-ty (core table $indirect-function-table)))
    (canon task.return (result u32) (core func $task.return))
    (canon thread.index (core func $thread.index))
    (canon thread.set-task (core func $thread.set-task))
    (canon thread.resume-later (core func $thread.resume-later))
    (canon thread.suspend-then-resume (core func $thread.suspend-then-resume))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return" (func $task.return))
      (export "thread.new-indirect" (func $thread.new-indirect))
      (export "thread.index" (func $thread.index))
      (export "thread.set-task" (func $thread.set-task))
      (export "thread.resume-later" (func $thread.resume-later))
      (export "thread.suspend-then-resume" (func $thread.suspend-then-resume))
      (export "__indirect_function_table" (table $indirect-function-table))
    ))))
    (func (export "victim") async (result u32)
      (canon lift (core func $core "victim") async))
    (func (export "unresolved") async (result u32)
      (canon lift (core func $core "unresolved") async))
  )
  (instance $c (instantiate $C))
  (func (export "victim") (alias export $c "victim"))
  (func (export "unresolved") (alias export $c "unresolved"))
)
(assert_return (invoke "victim") (u32.const 1))
(assert_trap (invoke "unresolved") "wasm trap: async-lifted export failed to produce a result")

;; A thread spawned by a moved thread inherits the spawner's *new* task; a
;; task's implicit thread can exit while the task is unresolved as long as
;; adopted threads keep it alive; and a moved thread exiting as the last thread
;; of its adopted task runs the same not-resolved check as thread.set-task.
(component
  (component $C
    (core module $Table
      (table (export "__indirect_function_table") 3 funcref))
    (core instance $table (instantiate $Table))
    (core module $Core
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "thread.set-task" (func $thread.set-task (param i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "thread.suspend" (func $thread.suspend (result i32)))
      (import "" "thread.suspend-then-resume" (func $thread.suspend-then-resume (param i32) (result i32)))
      (import "" "__indirect_function_table" (table $indirect-function-table 3 funcref))

      (global $x (mut i32) (i32.const 0xdead))   ;; thread that moves from task A to task B
      (global $w (mut i32) (i32.const 0xdead))   ;; thread spawned by X after its move
      (global $m (mut i32) (i32.const 0xdead))   ;; thread that moves from task A to task C
      (global $b0 (mut i32) (i32.const 0xdead))  ;; implicit thread of task B
      (global $c0 (mut i32) (i32.const 0xdead))  ;; implicit thread of task C

      ;; X: joins task B and spawns W, which inherits X's *current* task (B).
      ;; X then parks and, resumed by W after B has resolved, exits as the
      ;; last thread of B, which must not trap since B has resolved.
      (func $worker (param i32)
        (call $thread.set-task (global.get $b0))
        (global.set $w (call $thread.new-indirect (i32.const 1) (i32.const 0)))
        (call $thread.resume-later (global.get $b0))
        (drop (call $thread.suspend)))

      ;; W: returns for the task it was spawned into. Task A has already
      ;; resolved, so this only succeeds if W inherited B from X's post-move
      ;; task.
      (func $child (param i32)
        (call $task.return (i32.const 42))
        (call $thread.resume-later (global.get $x)))

      ;; M: joins task C and parks. Resumed after C's implicit thread has
      ;; exited, M's own exit empties C, which has not resolved: trap.
      (func $abandoner (param i32)
        (call $thread.set-task (global.get $c0))
        (call $thread.resume-later (global.get $c0))
        (drop (call $thread.suspend)))

      (elem (table $indirect-function-table) (i32.const 0) func $worker $child $abandoner)

      ;; task A: spawn X and M, resolve, then let the implicit thread exit
      (func (export "setup")
        (global.set $x (call $thread.new-indirect (i32.const 0) (i32.const 0)))
        (global.set $m (call $thread.new-indirect (i32.const 2) (i32.const 0)))
        (call $task.return (i32.const 1)))

      ;; task B: switch to X, then exit the implicit thread while B is still
      ;; unresolved, which must not trap since B retains X and W; W then
      ;; returns 42 on B's behalf
      (func (export "run")
        (global.set $b0 (call $thread.index))
        (drop (call $thread.suspend-then-resume (global.get $x)))
        (call $thread.resume-later (global.get $w)))

      ;; task C: switch to M, then exit the implicit thread *without*
      ;; returning a value, leaving C unresolved with only M in it
      (func (export "abandon")
        (global.set $c0 (call $thread.index))
        (drop (call $thread.suspend-then-resume (global.get $m)))
        (call $thread.resume-later (global.get $m)))
    )
    (core type $start-func-ty (func (param i32)))
    (alias core export $table "__indirect_function_table" (core table $indirect-function-table))
    (core func $thread.new-indirect
      (canon thread.new-indirect $start-func-ty (core table $indirect-function-table)))
    (canon task.return (result u32) (core func $task.return))
    (canon thread.index (core func $thread.index))
    (canon thread.set-task (core func $thread.set-task))
    (canon thread.resume-later (core func $thread.resume-later))
    (canon thread.suspend (core func $thread.suspend))
    (canon thread.suspend-then-resume (core func $thread.suspend-then-resume))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return" (func $task.return))
      (export "thread.new-indirect" (func $thread.new-indirect))
      (export "thread.index" (func $thread.index))
      (export "thread.set-task" (func $thread.set-task))
      (export "thread.resume-later" (func $thread.resume-later))
      (export "thread.suspend" (func $thread.suspend))
      (export "thread.suspend-then-resume" (func $thread.suspend-then-resume))
      (export "__indirect_function_table" (table $indirect-function-table))
    ))))
    (func (export "setup") async (result u32)
      (canon lift (core func $core "setup") async))
    (func (export "run") async (result u32)
      (canon lift (core func $core "run") async))
    (func (export "abandon") async (result u32)
      (canon lift (core func $core "abandon") async))
  )
  (instance $c (instantiate $C))
  (func (export "setup") (alias export $c "setup"))
  (func (export "run") (alias export $c "run"))
  (func (export "abandon") (alias export $c "abandon"))
)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run") (u32.const 42))
(assert_trap (invoke "abandon") "wasm trap: async-lifted export failed to produce a result")

;; Calling thread.set-task on the implicit thread of an export call traps, even
;; when the given thread is the implicit thread itself.
(component
  (component $C
    (core module $Core
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "thread.set-task" (func $thread.set-task (param i32)))

      (func (export "implicit")
        (call $thread.set-task (call $thread.index))
        unreachable)
    )
    (canon thread.index (core func $thread.index))
    (canon thread.set-task (core func $thread.set-task))
    (core instance $core (instantiate $Core (with "" (instance
      (export "thread.index" (func $thread.index))
      (export "thread.set-task" (func $thread.set-task))
    ))))
    (func (export "implicit") async (result u32)
      (canon lift (core func $core "implicit") async))
  )
  (instance $c (instantiate $C))
  (func (export "implicit") (alias export $c "implicit"))
)
(assert_trap (invoke "implicit") "wasm trap: `thread.set-task` called by an implicit thread")

;; A cancellation request against the task a thread has *left* is not
;; deliverable to that thread: task A's request must be remembered as pending
;; (X is cancellable, but only for B), while task B's request is delivered to X
;; immediately.
(component
  (component $C
    (core module $Table
      (table (export "__indirect_function_table") 1 funcref))
    (core instance $table (instantiate $Table))
    (core module $Core
      (import "" "task.cancel" (func $task.cancel))
      (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "thread.set-task" (func $thread.set-task (param i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "thread.suspend" (func $thread.suspend (result i32)))
      (import "" "thread.suspend-cancellable" (func $thread.suspend-cancellable (result i32)))
      (import "" "thread.suspend-then-resume" (func $thread.suspend-then-resume (param i32) (result i32)))
      (import "" "__indirect_function_table" (table $indirect-function-table 1 funcref))

      (global $a0 (mut i32) (i32.const 0xdead))  ;; implicit thread of task A
      (global $b0 (mut i32) (i32.const 0xdead))  ;; implicit thread of task B

      ;; X: spawned into task A, immediately leaves for task B and blocks
      ;; cancellably. A keeps its implicit thread, so leaving is allowed even
      ;; though A has not resolved.
      (func $worker (param i32)
        (call $thread.set-task (global.get $b0))
        ;; cancelling A must not wake this thread; cancelling B must
        (if (i32.ne (i32.const 1 (; CANCELLED ;)) (call $thread.suspend-cancellable))
          (then unreachable))
        (call $task.cancel)
        (call $thread.resume-later (global.get $a0)))

      (elem (table $indirect-function-table) (i32.const 0) func $worker)

      ;; task B: park the implicit thread non-cancellably, so B's only
      ;; cancellable thread is the one that joins it
      (func (export "target")
        (global.set $b0 (call $thread.index))
        (drop (call $thread.suspend))
        unreachable)

      ;; task A: spawn X and switch to it; A's implicit thread blocks
      ;; non-cancellably, so once X leaves, A has no cancellable thread
      (func (export "moving")
        (global.set $a0 (call $thread.index))
        (drop (call $thread.suspend-then-resume
          (call $thread.new-indirect (i32.const 0) (i32.const 0))))
        ;; resumed by X after B was cancelled: A's request is still pending
        ;; and is delivered here
        (if (i32.ne (i32.const 1 (; CANCELLED ;)) (call $thread.suspend-cancellable))
          (then unreachable))
        (call $task.cancel))
    )
    (core type $start-func-ty (func (param i32)))
    (alias core export $table "__indirect_function_table" (core table $indirect-function-table))
    (core func $thread.new-indirect
      (canon thread.new-indirect $start-func-ty (core table $indirect-function-table)))
    (canon task.cancel (core func $task.cancel))
    (canon thread.index (core func $thread.index))
    (canon thread.set-task (core func $thread.set-task))
    (canon thread.resume-later (core func $thread.resume-later))
    (canon thread.suspend (core func $thread.suspend))
    (canon thread.suspend cancellable (core func $thread.suspend-cancellable))
    (canon thread.suspend-then-resume (core func $thread.suspend-then-resume))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.cancel" (func $task.cancel))
      (export "thread.new-indirect" (func $thread.new-indirect))
      (export "thread.index" (func $thread.index))
      (export "thread.set-task" (func $thread.set-task))
      (export "thread.resume-later" (func $thread.resume-later))
      (export "thread.suspend" (func $thread.suspend))
      (export "thread.suspend-cancellable" (func $thread.suspend-cancellable))
      (export "thread.suspend-then-resume" (func $thread.suspend-then-resume))
      (export "__indirect_function_table" (table $indirect-function-table))
    ))))
    (func (export "target") async (result u32)
      (canon lift (core func $core "target") async))
    (func (export "moving") async (result u32)
      (canon lift (core func $core "moving") async))
  )
  (component $D
    (import "target" (func $target async (result u32)))
    (import "moving" (func $moving async (result u32)))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Core
      (import "" "mem" (memory 1))
      (import "" "subtask.cancel" (func $subtask.cancel (param i32) (result i32)))
      (import "" "subtask.drop" (func $subtask.drop (param i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (import "" "target" (func $target (param i32) (result i32)))
      (import "" "moving" (func $moving (param i32) (result i32)))

      (func (export "run") (result i32)
        (local $ret i32)
        (local $target-subtask i32)
        (local $moving-subtask i32)
        (local $ws i32)

        ;; start target, which parks its implicit thread
        (local.set $ret (call $target (i32.const 4 (; retp ;))))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $target-subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; start moving, whose spawned thread joins target's task
        (local.set $ret (call $moving (i32.const 8 (; retp ;))))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $moving-subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; the thread that left is cancellable, but no longer for this task,
        ;; so this request can only be remembered as pending
        (local.set $ret (call $subtask.cancel (local.get $moving-subtask)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))

        ;; the same thread does receive the request made against the task it
        ;; joined, and acknowledges it immediately
        (local.set $ret (call $subtask.cancel (local.get $target-subtask)))
        (if (i32.ne (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)) (local.get $ret))
          (then unreachable))
        (call $subtask.drop (local.get $target-subtask))

        ;; block so that moving's implicit thread, made ready again by the
        ;; thread that left, can pick up its own pending cancellation
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $moving-subtask) (local.get $ws))
        (local.set $ret (call $waitable-set.wait (local.get $ws) (i32.const 12 (; eventp ;))))
        (if (i32.ne (i32.const 1 (; SUBTASK ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (local.get $moving-subtask) (i32.load (i32.const 12)))
          (then unreachable))
        (if (i32.ne (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)) (i32.load offset=4 (i32.const 12)))
          (then unreachable))
        (call $subtask.drop (local.get $moving-subtask))

        (i32.const 42))
    )
    (canon subtask.cancel async (core func $subtask.cancel))
    (canon subtask.drop (core func $subtask.drop))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (canon lower (func $target) async (memory (core memory $memory "mem")) (core func $target'))
    (canon lower (func $moving) async (memory (core memory $memory "mem")) (core func $moving'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "subtask.cancel" (func $subtask.cancel))
      (export "subtask.drop" (func $subtask.drop))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "target" (func $target'))
      (export "moving" (func $moving'))
    ))))
    (func (export "run") async (result u32) (canon lift (core func $core "run")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "target" (func $c "target"))
    (with "moving" (func $c "moving"))))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 42))
