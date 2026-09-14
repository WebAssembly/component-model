;; Test thread.{get,set}-task and task.drop

;; Task handles: `thread.get-task` hands out a fresh handle each time and
;; `task.drop` invalidates one without touching the task, so both built-ins
;; reject anything that is not a live task handle. No second task is needed for
;; any of this; each case runs on its own instance, where the first handle
;; `thread.get-task` or `waitable-set.new` hands out has index 1.
(component definition $Handles
  (component $C
    (core module $Core
      (import "" "thread.get-task" (func $thread.get-task (result i32)))
      (import "" "thread.set-task" (func $thread.set-task (param i32)))
      (import "" "task.drop" (func $task.drop (param i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))

      (func (export "unknown-set") (result i32)
        (call $thread.set-task (i32.const 100))
        unreachable)
      (func (export "unknown-drop") (result i32)
        (call $task.drop (i32.const 100))
        unreachable)

      ;; tasks share an index space with the other handle types, so a handle
      ;; that exists can still be the wrong kind
      (func (export "wrong-set") (result i32)
        (call $thread.set-task (call $waitable-set.new))
        unreachable)
      (func (export "wrong-drop") (result i32)
        (call $task.drop (call $waitable-set.new))
        unreachable)

      ;; `task.drop` invalidates the handle without touching the task, so both
      ;; built-ins reject a dropped handle
      (func (export "dropped-set") (result i32)
        (local $t i32)
        (local.set $t (call $thread.get-task))
        (call $task.drop (local.get $t))
        (call $thread.set-task (local.get $t))
        unreachable)
      (func (export "double-drop") (result i32)
        (local $t i32)
        (local.set $t (call $thread.get-task))
        (call $task.drop (local.get $t))
        (call $task.drop (local.get $t))
        unreachable)

      ;; index 0 is permanently reserved and so is never a task handle
      (func (export "zero-set") (result i32)
        (call $thread.set-task (i32.const 0))
        unreachable)
      (func (export "zero-drop") (result i32)
        (call $task.drop (i32.const 0))
        unreachable)

      ;; a dropped index goes back on the free list and is handed out again by
      ;; the next `thread.get-task`; the recycled handle is a normal handle,
      ;; and moving to a handle for one's own task is a no-op
      (func (export "reuse") (result i32)
        (local $first i32)
        (local $second i32)
        (local.set $first (call $thread.get-task))
        (call $task.drop (local.get $first))
        (local.set $second (call $thread.get-task))
        (if (i32.ne (local.get $first) (local.get $second))
          (then unreachable))
        (call $thread.set-task (local.get $second))
        (call $task.drop (local.get $second))
        (i32.const 42))
    )
    (canon thread.get-task (core func $thread.get-task))
    (canon thread.set-task (core func $thread.set-task))
    (canon task.drop (core func $task.drop))
    (canon waitable-set.new (core func $waitable-set.new))
    (core instance $core (instantiate $Core (with "" (instance
      (export "thread.get-task" (func $thread.get-task))
      (export "thread.set-task" (func $thread.set-task))
      (export "task.drop" (func $task.drop))
      (export "waitable-set.new" (func $waitable-set.new))
    ))))
    (func (export "unknown-set") (result u32)
      (canon lift (core func $core "unknown-set")))
    (func (export "unknown-drop") (result u32)
      (canon lift (core func $core "unknown-drop")))
    (func (export "wrong-set") (result u32)
      (canon lift (core func $core "wrong-set")))
    (func (export "wrong-drop") (result u32)
      (canon lift (core func $core "wrong-drop")))
    (func (export "dropped-set") (result u32)
      (canon lift (core func $core "dropped-set")))
    (func (export "double-drop") (result u32)
      (canon lift (core func $core "double-drop")))
    (func (export "zero-set") (result u32)
      (canon lift (core func $core "zero-set")))
    (func (export "zero-drop") (result u32)
      (canon lift (core func $core "zero-drop")))
    (func (export "reuse") (result u32)
      (canon lift (core func $core "reuse")))
  )
  (instance $c (instantiate $C))
  (func (export "unknown-set") (alias export $c "unknown-set"))
  (func (export "unknown-drop") (alias export $c "unknown-drop"))
  (func (export "wrong-set") (alias export $c "wrong-set"))
  (func (export "wrong-drop") (alias export $c "wrong-drop"))
  (func (export "dropped-set") (alias export $c "dropped-set"))
  (func (export "double-drop") (alias export $c "double-drop"))
  (func (export "zero-set") (alias export $c "zero-set"))
  (func (export "zero-drop") (alias export $c "zero-drop"))
  (func (export "reuse") (alias export $c "reuse"))
)
(component instance $h1 $Handles)
(assert_trap (invoke "unknown-set") "unknown handle index 100")
(component instance $h2 $Handles)
(assert_trap (invoke "unknown-drop") "unknown handle index 100")
(component instance $h3 $Handles)
(assert_trap (invoke "wrong-set") "handle is not a task")
(component instance $h4 $Handles)
(assert_trap (invoke "wrong-drop") "handle is not a task")
(component instance $h5 $Handles)
(assert_trap (invoke "dropped-set") "unknown handle index 1")
(component instance $h6 $Handles)
(assert_trap (invoke "double-drop") "unknown handle index 1")
(component instance $h7 $Handles)
(assert_trap (invoke "zero-set") "unknown handle index 0")
(component instance $h8 $Handles)
(assert_trap (invoke "zero-drop") "unknown handle index 0")
(component instance $h9 $Handles)
(assert_return (invoke "reuse") (u32.const 42))

;; Basic task switching: an explicit thread of task A joins task B, returns B's
;; value and moves back home again. `task.return`'s result type is checked
;; against the task the calling thread is in, not the one it started in, so the
;; u8-typed `task.return` in "join-bad" traps against B2's u32 result.
(component definition $Join
  (component $C
    (core module $Table
      (table (export "__indirect_function_table") 2 funcref))
    (core instance $table (instantiate $Table))
    (core module $Core
      (import "" "task.return-u8" (func $task.return-u8 (param i32)))
      (import "" "task.return-u32" (func $task.return-u32 (param i32)))
      (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "thread.get-task" (func $thread.get-task (result i32)))
      (import "" "thread.set-task" (func $thread.set-task (param i32)))
      (import "" "task.drop" (func $task.drop (param i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "thread.suspend-then-resume" (func $thread.suspend-then-resume (param i32) (result i32)))
      (import "" "__indirect_function_table" (table $indirect-function-table 2 funcref))

      (global $worker-thread (mut i32) (i32.const 0xdead))      ;; explicit thread spawned into task A
      (global $worker-bad-thread (mut i32) (i32.const 0xdead))  ;; second mover, used by join-bad
      (global $join-implicit (mut i32) (i32.const 0xdead))      ;; implicit thread of the current join task
      (global $join-task (mut i32) (i32.const 0xdead))          ;; handle for the current join task

      ;; $worker-thread: starts in task A (already resolved), joins task B,
      ;; returns for B
      (func $worker (param i32)
        (local $home i32)
        (local $alias i32)
        (local.set $home (call $thread.get-task))

        ;; each thread.get-task hands out a fresh handle for the same task and
        ;; moving to a handle for one's own task is a no-op
        (local.set $alias (call $thread.get-task))
        (if (i32.eq (local.get $home) (local.get $alias))
          (then unreachable))
        (call $thread.set-task (local.get $alias))
        (call $task.drop (local.get $alias))

        ;; task.return for task B (not for task A)
        (call $thread.set-task (global.get $join-task))
        (call $task.return-u32 (i32.const 42))

        ;; the handle saved on entry moves this thread back to task A, from
        ;; which it exits after making $join-implicit runnable again
        (call $thread.set-task (local.get $home))
        (call $task.drop (local.get $home))
        (call $thread.resume-later (global.get $join-implicit)))

      ;; $worker-bad-thread: joins task B2 and calls task A's u8-typed
      ;; task.return: the declared result type is checked against the
      ;; *current* task, which is now B2 with a u32 result, so this traps
      (func $worker-bad (param i32)
        (call $thread.set-task (global.get $join-task))
        (call $task.return-u8 (i32.const 33))
        unreachable)

      (elem (table $indirect-function-table) (i32.const 0) func $worker $worker-bad)

      ;; task A: spawn the two threads above, resolve, then let the implicit
      ;; thread exit
      (func (export "setup") (result i32)
        (global.set $worker-thread (call $thread.new-indirect (i32.const 0) (i32.const 0)))
        (global.set $worker-bad-thread (call $thread.new-indirect (i32.const 1) (i32.const 0)))
        (call $task.return-u8 (i32.const 1))
        (i32.const 0 (; EXIT ;)))

      ;; task B: publish a handle for itself and switch to $worker-thread,
      ;; which returns 42 on B's behalf
      (func (export "join") (result i32)
        (global.set $join-implicit (call $thread.index))
        (global.set $join-task (call $thread.get-task))
        (drop (call $thread.suspend-then-resume (global.get $worker-thread)))
        (call $task.drop (global.get $join-task))
        (i32.const 0 (; EXIT ;)))

      ;; task B2: switch to $worker-bad-thread, which joins B2 and then traps
      ;; returning with the wrong task.return
      (func (export "join-bad") (result i32)
        (global.set $join-implicit (call $thread.index))
        (global.set $join-task (call $thread.get-task))
        (drop (call $thread.suspend-then-resume (global.get $worker-bad-thread)))
        unreachable)

      (func (export "never") (param i32 i32 i32) (result i32)
        unreachable)
    )
    (core type $start-func-ty (func (param i32)))
    (alias core export $table "__indirect_function_table" (core table $indirect-function-table))
    (core func $thread.new-indirect
      (canon thread.new-indirect $start-func-ty (core table $indirect-function-table)))
    (canon task.return (result u8) (core func $task.return-u8))
    (canon task.return (result u32) (core func $task.return-u32))
    (canon thread.index (core func $thread.index))
    (canon thread.get-task (core func $thread.get-task))
    (canon thread.set-task (core func $thread.set-task))
    (canon task.drop (core func $task.drop))
    (canon thread.resume-later (core func $thread.resume-later))
    (canon thread.suspend-then-resume (core func $thread.suspend-then-resume))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return-u8" (func $task.return-u8))
      (export "task.return-u32" (func $task.return-u32))
      (export "thread.new-indirect" (func $thread.new-indirect))
      (export "thread.index" (func $thread.index))
      (export "thread.get-task" (func $thread.get-task))
      (export "thread.set-task" (func $thread.set-task))
      (export "task.drop" (func $task.drop))
      (export "thread.resume-later" (func $thread.resume-later))
      (export "thread.suspend-then-resume" (func $thread.suspend-then-resume))
      (export "__indirect_function_table" (table $indirect-function-table))
    ))))
    (func (export "setup") async (result u8)
      (canon lift (core func $core "setup") async (callback (core func $core "never"))))
    (func (export "join") async (result u32)
      (canon lift (core func $core "join") async (callback (core func $core "never"))))
    (func (export "join-bad") async (result u32)
      (canon lift (core func $core "join-bad") async (callback (core func $core "never"))))
  )
  (instance $c (instantiate $C))
  (func (export "setup") (alias export $c "setup"))
  (func (export "join") (alias export $c "join"))
  (func (export "join-bad") (alias export $c "join-bad"))
)
(component instance $j1 $Join)
(assert_return (invoke "setup") (u8.const 1))
(assert_return (invoke "join") (u32.const 42))
(component instance $j2 $Join)
(assert_return (invoke "setup") (u8.const 1))
(assert_trap (invoke "join-bad") "wasm trap: invalid `task.return` signature and/or options for current task")

;; Any thread can leave an unresolved task, even the last one: the task is
;; simply left unresolved until (and unless) some thread rejoins it and
;; resolves it. A handle saved before the move is what brings a thread back.
(component
  (component $C
    (core module $Table
      (table (export "__indirect_function_table") 2 funcref))
    (core instance $table (instantiate $Table))
    (core module $Core
      (import "" "task.return-u8" (func $task.return-u8 (param i32)))
      (import "" "task.return-u32" (func $task.return-u32 (param i32)))
      (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
      (import "" "thread.get-task" (func $thread.get-task (result i32)))
      (import "" "thread.set-task" (func $thread.set-task (param i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "thread.suspend-then-resume" (func $thread.suspend-then-resume (param i32) (result i32)))
      (import "" "__indirect_function_table" (table $indirect-function-table 2 funcref))

      (global $last-thread (mut i32) (i32.const 0xdead))   ;; second thread of task A
      (global $mover-thread (mut i32) (i32.const 0xdead))  ;; thread that moves A -> B1 -> B2 -> A
      (global $b1-task (mut i32) (i32.const 0xdead))       ;; handle for resolved task B1
      (global $b2-task (mut i32) (i32.const 0xdead))       ;; handle for resolved task B2

      ;; $mover-thread: hops from its original task A to B1 and on to B2,
      ;; parking there so that $last-thread has somewhere to move to as well.
      ;; Resumed by $last-thread, it uses the handle saved on entry to return
      ;; to A (not to the most-recently-left B1, whose u8-typed, already
      ;; resolved task would trap the u32-typed task.return) and resolves A
      ;; even though A contained no threads at all for a while.
      (func $mover (param i32)
        (local $home i32)
        (local.set $home (call $thread.get-task))
        (call $thread.set-task (global.get $b1-task))
        (call $thread.set-task (global.get $b2-task))
        (drop (call $thread.suspend-then-resume (global.get $last-thread)))
        (call $thread.set-task (local.get $home))
        (call $task.return-u32 (i32.const 42)))

      ;; $last-thread: after $mover-thread has left, the only thread of the
      ;; unresolved task A. Joining B2 leaves A with no threads at all, which
      ;; does not trap: an unresolved task is simply not required to ever
      ;; resolve.
      (func $last (param i32)
        (call $thread.set-task (global.get $b2-task))
        (call $thread.resume-later (global.get $mover-thread)))

      (elem (table $indirect-function-table) (i32.const 0) func $mover $last)

      ;; tasks B1 and B2: publish a handle for themselves, resolve, then let
      ;; the implicit thread exit
      (func (export "victim1") (result i32)
        (global.set $b1-task (call $thread.get-task))
        (call $task.return-u8 (i32.const 1))
        (i32.const 0 (; EXIT ;)))
      (func (export "victim2") (result i32)
        (global.set $b2-task (call $thread.get-task))
        (call $task.return-u8 (i32.const 1))
        (i32.const 0 (; EXIT ;)))

      ;; task A: spawn $last-thread and $mover-thread and exit the implicit
      ;; thread *without* returning a value, leaving A unresolved with two
      ;; threads
      (func (export "unresolved") (result i32)
        (global.set $last-thread (call $thread.new-indirect (i32.const 1) (i32.const 0)))
        (global.set $mover-thread (call $thread.new-indirect (i32.const 0) (i32.const 0)))
        (call $thread.resume-later (global.get $mover-thread))
        (i32.const 0 (; EXIT ;)))

      (func (export "never") (param i32 i32 i32) (result i32)
        unreachable)
    )
    (core type $start-func-ty (func (param i32)))
    (alias core export $table "__indirect_function_table" (core table $indirect-function-table))
    (core func $thread.new-indirect
      (canon thread.new-indirect $start-func-ty (core table $indirect-function-table)))
    (canon task.return (result u8) (core func $task.return-u8))
    (canon task.return (result u32) (core func $task.return-u32))
    (canon thread.get-task (core func $thread.get-task))
    (canon thread.set-task (core func $thread.set-task))
    (canon thread.resume-later (core func $thread.resume-later))
    (canon thread.suspend-then-resume (core func $thread.suspend-then-resume))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return-u8" (func $task.return-u8))
      (export "task.return-u32" (func $task.return-u32))
      (export "thread.new-indirect" (func $thread.new-indirect))
      (export "thread.get-task" (func $thread.get-task))
      (export "thread.set-task" (func $thread.set-task))
      (export "thread.resume-later" (func $thread.resume-later))
      (export "thread.suspend-then-resume" (func $thread.suspend-then-resume))
      (export "__indirect_function_table" (table $indirect-function-table))
    ))))
    (func (export "victim1") async (result u8)
      (canon lift (core func $core "victim1") async (callback (core func $core "never"))))
    (func (export "victim2") async (result u8)
      (canon lift (core func $core "victim2") async (callback (core func $core "never"))))
    (func (export "unresolved") async (result u32)
      (canon lift (core func $core "unresolved") async (callback (core func $core "never"))))
  )
  (instance $c (instantiate $C))
  (func (export "victim1") (alias export $c "victim1"))
  (func (export "victim2") (alias export $c "victim2"))
  (func (export "unresolved") (alias export $c "unresolved"))
)
(assert_return (invoke "victim1") (u8.const 1))
(assert_return (invoke "victim2") (u8.const 1))
(assert_return (invoke "unresolved") (u32.const 42))

;; A thread spawned by a moved thread inherits the spawner's new task, and a
;; task's implicit thread can exit while the task is unresolved, leaving adopted
;; and spawned threads to resolve it afterwards.
(component
  (component $C
    (core module $Table
      (table (export "__indirect_function_table") 2 funcref))
    (core instance $table (instantiate $Table))
    (core module $Core
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "thread.get-task" (func $thread.get-task (result i32)))
      (import "" "thread.set-task" (func $thread.set-task (param i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "thread.suspend" (func $thread.suspend (result i32)))
      (import "" "thread.suspend-then-resume" (func $thread.suspend-then-resume (param i32) (result i32)))
      (import "" "__indirect_function_table" (table $indirect-function-table 2 funcref))

      (global $worker-thread (mut i32) (i32.const 0xdead))  ;; thread that moves from task A to task B
      (global $child-thread (mut i32) (i32.const 0xdead))   ;; spawned by $worker-thread after its move
      (global $run-implicit (mut i32) (i32.const 0xdead))   ;; implicit thread of task B
      (global $run-task (mut i32) (i32.const 0xdead))       ;; handle for task B

      ;; $worker-thread: joins task B and spawns $child-thread, which inherits
      ;; the spawner's *current* task (B). It then parks and, resumed by
      ;; $child-thread after B has resolved, exits as the last thread of B.
      (func $worker (param i32)
        (call $thread.set-task (global.get $run-task))
        (global.set $child-thread (call $thread.new-indirect (i32.const 1) (i32.const 0)))
        (call $thread.resume-later (global.get $run-implicit))
        (drop (call $thread.suspend)))

      ;; $child-thread: returns for the task it was spawned into. Task A has
      ;; already resolved, so this only succeeds if $child-thread inherited B
      ;; from $worker-thread's post-move task.
      (func $child (param i32)
        (call $task.return (i32.const 42))
        (call $thread.resume-later (global.get $worker-thread)))

      (elem (table $indirect-function-table) (i32.const 0) func $worker $child)

      ;; task A: spawn $worker-thread, resolve, then let the implicit thread
      ;; exit
      (func (export "setup") (result i32)
        (global.set $worker-thread (call $thread.new-indirect (i32.const 0) (i32.const 0)))
        (call $task.return (i32.const 1))
        (i32.const 0 (; EXIT ;)))

      ;; task B: switch to $worker-thread, then exit the implicit thread while
      ;; B is still unresolved, leaving B to retain $worker-thread and
      ;; $child-thread; $child-thread then returns 42 on B's behalf
      (func (export "run") (result i32)
        (global.set $run-implicit (call $thread.index))
        (global.set $run-task (call $thread.get-task))
        (drop (call $thread.suspend-then-resume (global.get $worker-thread)))
        (call $thread.resume-later (global.get $child-thread))
        (i32.const 0 (; EXIT ;)))

      (func (export "never") (param i32 i32 i32) (result i32)
        unreachable)
    )
    (core type $start-func-ty (func (param i32)))
    (alias core export $table "__indirect_function_table" (core table $indirect-function-table))
    (core func $thread.new-indirect
      (canon thread.new-indirect $start-func-ty (core table $indirect-function-table)))
    (canon task.return (result u32) (core func $task.return))
    (canon thread.index (core func $thread.index))
    (canon thread.get-task (core func $thread.get-task))
    (canon thread.set-task (core func $thread.set-task))
    (canon thread.resume-later (core func $thread.resume-later))
    (canon thread.suspend (core func $thread.suspend))
    (canon thread.suspend-then-resume (core func $thread.suspend-then-resume))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return" (func $task.return))
      (export "thread.new-indirect" (func $thread.new-indirect))
      (export "thread.index" (func $thread.index))
      (export "thread.get-task" (func $thread.get-task))
      (export "thread.set-task" (func $thread.set-task))
      (export "thread.resume-later" (func $thread.resume-later))
      (export "thread.suspend" (func $thread.suspend))
      (export "thread.suspend-then-resume" (func $thread.suspend-then-resume))
      (export "__indirect_function_table" (table $indirect-function-table))
    ))))
    (func (export "setup") async (result u32)
      (canon lift (core func $core "setup") async (callback (core func $core "never"))))
    (func (export "run") async (result u32)
      (canon lift (core func $core "run") async (callback (core func $core "never"))))
  )
  (instance $c (instantiate $C))
  (func (export "setup") (alias export $c "setup"))
  (func (export "run") (alias export $c "run"))
)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run") (u32.const 42))

;; A task can be resolved by an implicit thread that belongs to another task,
;; and task.return's result type is checked against the thread's *current*
;; task. These three implicit threads form a relay: each leaves its own task
;; started, unresolved and with no threads at all, and the next one joins that
;; task, returns its value and exits while still contained by it. The result
;; types alternate, so every task.return here would trap if it were checked
;; against the task whose export the calling thread entered; "hop3" performs
;; both a u8 return for its own task and a u32 return for the task it joined.
(component
  (component $C
    (core module $Core
      (import "" "task.return-u8" (func $task.return-u8 (param i32)))
      (import "" "task.return-u32" (func $task.return-u32 (param i32)))
      (import "" "thread.get-task" (func $thread.get-task (result i32)))
      (import "" "thread.set-task" (func $thread.set-task (param i32)))

      (global $a-task (mut i32) (i32.const 0xdead))  ;; handle for task A (u8 result)
      (global $b-task (mut i32) (i32.const 0xdead))  ;; handle for task B (u32 result)

      ;; task A: publish a handle for itself and leave at once, so that A is
      ;; started, unresolved and contains no threads at all
      (func (export "hop1") (result i32)
        (global.set $a-task (call $thread.get-task))
        (i32.const 0 (; EXIT ;)))

      ;; task B: publish a handle for itself, then join task A and return A's
      ;; u8-typed value (which would trap against B's own u32 result) before
      ;; exiting while still contained by A, leaving B threadless in turn
      (func (export "hop2") (result i32)
        (global.set $b-task (call $thread.get-task))
        (call $thread.set-task (global.get $a-task))
        (call $task.return-u8 (i32.const 11))
        (i32.const 0 (; EXIT ;)))

      ;; task C: return C's own u8-typed value, then join task B and return its
      ;; u32-typed value; the two calls differ only in which task this thread
      ;; is in at the time
      (func (export "hop3") (result i32)
        (call $task.return-u8 (i32.const 33))
        (call $thread.set-task (global.get $b-task))
        (call $task.return-u32 (i32.const 222))
        (i32.const 0 (; EXIT ;)))

      (func (export "never") (param i32 i32 i32) (result i32)
        unreachable)
    )
    (canon task.return (result u8) (core func $task.return-u8))
    (canon task.return (result u32) (core func $task.return-u32))
    (canon thread.get-task (core func $thread.get-task))
    (canon thread.set-task (core func $thread.set-task))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return-u8" (func $task.return-u8))
      (export "task.return-u32" (func $task.return-u32))
      (export "thread.get-task" (func $thread.get-task))
      (export "thread.set-task" (func $thread.set-task))
    ))))
    (func (export "hop1") async (result u8)
      (canon lift (core func $core "hop1") async (callback (core func $core "never"))))
    (func (export "hop2") async (result u32)
      (canon lift (core func $core "hop2") async (callback (core func $core "never"))))
    (func (export "hop3") async (result u8)
      (canon lift (core func $core "hop3") async (callback (core func $core "never"))))
  )
  (component $D
    (import "hop1" (func $hop1 async (result u8)))
    (import "hop2" (func $hop2 async (result u32)))
    (import "hop3" (func $hop3 async (result u8)))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Core
      (import "" "mem" (memory 1))
      (import "" "subtask.drop" (func $subtask.drop (param i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.poll" (func $waitable-set.poll (param i32 i32) (result i32)))
      (import "" "hop1" (func $hop1 (param i32) (result i32)))
      (import "" "hop2" (func $hop2 (param i32) (result i32)))
      (import "" "hop3" (func $hop3 (param i32) (result i32)))

      (func (export "run") (result i32)
        (local $ret i32)
        (local $a-subtask i32)
        (local $b-subtask i32)
        (local $ws i32)
        (local $n i32)

        ;; start hop1, which leaves task A behind unresolved
        (local.set $ret (call $hop1 (i32.const 0 (; retp ;))))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $a-subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; start hop2: within this call task A is resolved with 11, while task
        ;; B is left behind unresolved in the same way
        (local.set $ret (call $hop2 (i32.const 4 (; retp ;))))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $b-subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; start hop3, which resolves task B with 222 as well as its own task
        ;; with 33, so this call completes eagerly
        (if (i32.ne (i32.const 2 (; RETURNED ;)) (call $hop3 (i32.const 8 (; retp ;))))
          (then unreachable))

        ;; each abandoned task was resolved by the thread that came after it,
        ;; so both resolutions are already pending and a poll collects them
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $a-subtask) (local.get $ws))
        (call $waitable.join (local.get $b-subtask) (local.get $ws))
        (loop $l
          (if (i32.ne (i32.const 1 (; SUBTASK ;))
                      (call $waitable-set.poll (local.get $ws) (i32.const 16 (; eventp ;))))
            (then unreachable))
          (if (i32.ne (i32.const 2 (; RETURNED ;)) (i32.load offset=4 (i32.const 16)))
            (then unreachable))
          (call $subtask.drop (i32.load (i32.const 16)))
          (local.set $n (i32.add (local.get $n) (i32.const 1)))
          (br_if $l (i32.lt_u (local.get $n) (i32.const 2))))

        (if (i32.ne (i32.const 11) (i32.load8_u (i32.const 0)))
          (then unreachable))
        (if (i32.ne (i32.const 222) (i32.load (i32.const 4)))
          (then unreachable))
        (if (i32.ne (i32.const 33) (i32.load8_u (i32.const 8)))
          (then unreachable))

        (i32.const 42))
    )
    (canon subtask.drop (core func $subtask.drop))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.poll (memory (core memory $memory "mem")) (core func $waitable-set.poll))
    (canon lower (func $hop1) async (memory (core memory $memory "mem")) (core func $hop1'))
    (canon lower (func $hop2) async (memory (core memory $memory "mem")) (core func $hop2'))
    (canon lower (func $hop3) async (memory (core memory $memory "mem")) (core func $hop3'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "subtask.drop" (func $subtask.drop))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.poll" (func $waitable-set.poll))
      (export "hop1" (func $hop1'))
      (export "hop2" (func $hop2'))
      (export "hop3" (func $hop3'))
    ))))
    (func (export "run") async (result u32) (canon lift (core func $core "run")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "hop1" (func $c "hop1"))
    (with "hop2" (func $c "hop2"))
    (with "hop3" (func $c "hop3"))))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 42))

;; The implicit thread of a synchronously-lifted export may change tasks while
;; the core function executes and need not move back: on return it implicitly
;; rejoins the task it was spawned in, which is the task the lifted results are
;; returned for. Task A is u8-typed while all four exports below are u32-typed,
;; so these results can only come out right if they are lifted with the lift's
;; own options and result type rather than the current task's.
(component definition $VisitOrStay
  (component $C
    (core module $Core
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "thread.get-task" (func $thread.get-task (result i32)))
      (import "" "thread.set-task" (func $thread.set-task (param i32)))

      (global $a-task (mut i32) (i32.const 0xdead))  ;; handle for resolved task A

      (func (export "setup") (result i32)
        (global.set $a-task (call $thread.get-task))
        (call $task.return (i32.const 1))
        (i32.const 0 (; EXIT ;)))

      (func (export "never") (param i32 i32 i32) (result i32)
        unreachable)

      (func (export "sync-visit") (result i32)
        (local $home i32)
        (local.set $home (call $thread.get-task))
        (call $thread.set-task (global.get $a-task))
        (call $thread.set-task (local.get $home))
        (i32.const 42))

      ;; returns while still contained by task A
      (func (export "sync-stay") (result i32)
        (call $thread.set-task (global.get $a-task))
        (i32.const 33))

      (func (export "async-visit") (result i32)
        (local $home i32)
        (local.set $home (call $thread.get-task))
        (call $thread.set-task (global.get $a-task))
        (call $thread.set-task (local.get $home))
        (i32.const 44))

      ;; likewise, and `async`-typed rather than plain
      (func (export "async-stay") (result i32)
        (call $thread.set-task (global.get $a-task))
        (i32.const 55))
    )
    (canon task.return (result u8) (core func $task.return))
    (canon thread.get-task (core func $thread.get-task))
    (canon thread.set-task (core func $thread.set-task))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return" (func $task.return))
      (export "thread.get-task" (func $thread.get-task))
      (export "thread.set-task" (func $thread.set-task))
    ))))
    (func (export "setup") async (result u8)
      (canon lift (core func $core "setup") async (callback (core func $core "never"))))
    (func (export "sync-visit") (result u32)
      (canon lift (core func $core "sync-visit")))
    (func (export "sync-stay") (result u32)
      (canon lift (core func $core "sync-stay")))
    (func (export "async-visit") async (result u32)
      (canon lift (core func $core "async-visit")))
    (func (export "async-stay") async (result u32)
      (canon lift (core func $core "async-stay")))
  )
  (instance $c (instantiate $C))
  (func (export "setup") (alias export $c "setup"))
  (func (export "sync-visit") (alias export $c "sync-visit"))
  (func (export "sync-stay") (alias export $c "sync-stay"))
  (func (export "async-visit") (alias export $c "async-visit"))
  (func (export "async-stay") (alias export $c "async-stay"))
)
(component instance $visit-or-stay $VisitOrStay)
(assert_return (invoke "setup") (u8.const 1))
(assert_return (invoke "sync-visit") (u32.const 42))
(assert_return (invoke "sync-stay") (u32.const 33))
(assert_return (invoke "async-visit") (u32.const 44))
(assert_return (invoke "async-stay") (u32.const 55))

;; Test switching between sync-typed and async-typed tasks.
(component definition $SyncTasks
  (component $C
    (core module $Core
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "thread.get-task" (func $thread.get-task (result i32)))
      (import "" "thread.set-task" (func $thread.set-task (param i32)))

      (global $target-task (mut i32) (i32.const 0xdead))      ;; callback-lifted task
      (global $sync-task (mut i32) (i32.const 0xdead))        ;; sync-lifted, not async-typed
      (global $async-sync-task (mut i32) (i32.const 0xdead))  ;; sync-lifted, async-typed

      ;; callback-lifted, so this task's value can be returned by any thread
      ;; that joins it; leaving the event loop keeps it unresolved
      (func (export "target") (result i32)
        (global.set $target-task (call $thread.get-task))
        (i32.const 0 (; EXIT ;)))

      ;; not async-typed, and so sync-lifted: this thread returns 99 for the
      ;; task it joined and 42 for its own task, the latter by returning
      (func (export "from-sync") (result i32)
        (local $home i32)
        (local.set $home (call $thread.get-task))
        (global.set $sync-task (call $thread.get-task))
        (call $thread.set-task (global.get $target-task))
        (call $task.return (i32.const 99))
        (call $thread.set-task (local.get $home))
        (i32.const 42))

      ;; async-typed but still lifted with the sync ABI, so task.return is
      ;; equally unavailable for this task
      (func (export "async-sync") (result i32)
        (global.set $async-sync-task (call $thread.get-task))
        (i32.const 7))

      ;; both of these join a sync-lifted task and then try to return its
      ;; value; everything but the current task's lift ABI is in order, since
      ;; the same task.return resolves "target" above
      (func (export "to-sync") (result i32)
        (call $thread.set-task (global.get $sync-task))
        (call $task.return (i32.const 11))
        unreachable)
      (func (export "to-async-sync") (result i32)
        (call $thread.set-task (global.get $async-sync-task))
        (call $task.return (i32.const 11))
        unreachable)

      (func (export "never") (param i32 i32 i32) (result i32)
        unreachable)
    )
    (canon task.return (result u32) (core func $task.return))
    (canon thread.get-task (core func $thread.get-task))
    (canon thread.set-task (core func $thread.set-task))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return" (func $task.return))
      (export "thread.get-task" (func $thread.get-task))
      (export "thread.set-task" (func $thread.set-task))
    ))))
    (func (export "target") async (result u32)
      (canon lift (core func $core "target") async (callback (core func $core "never"))))
    (func (export "from-sync") (result u32)
      (canon lift (core func $core "from-sync")))
    (func (export "async-sync") async (result u32)
      (canon lift (core func $core "async-sync")))
    (func (export "to-sync") async (result u32)
      (canon lift (core func $core "to-sync") async (callback (core func $core "never"))))
    (func (export "to-async-sync") async (result u32)
      (canon lift (core func $core "to-async-sync") async (callback (core func $core "never"))))
  )
  (component $D
    (import "target" (func $target async (result u32)))
    (import "from-sync" (func $from-sync (result u32)))
    (import "async-sync" (func $async-sync async (result u32)))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Core
      (import "" "mem" (memory 1))
      (import "" "subtask.drop" (func $subtask.drop (param i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.poll" (func $waitable-set.poll (param i32 i32) (result i32)))
      (import "" "target" (func $target (param i32) (result i32)))
      (import "" "from-sync" (func $from-sync (result i32)))
      (import "" "async-sync" (func $async-sync (result i32)))

      (func (export "run") (result i32)
        (local $ret i32)
        (local $target-subtask i32)
        (local $ws i32)

        ;; start target, whose implicit thread leaves at once
        (local.set $ret (call $target (i32.const 0 (; retp ;))))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $target-subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; the sync-lifted task's thread returns target's value on its way
        ;; through, and its own by returning
        (if (i32.ne (i32.const 42) (call $from-sync))
          (then unreachable))

        ;; that task.return ran inside the call above, so target's resolution
        ;; is already pending and a poll is enough to collect it
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $target-subtask) (local.get $ws))
        (if (i32.ne (i32.const 1 (; SUBTASK ;))
                    (call $waitable-set.poll (local.get $ws) (i32.const 16 (; eventp ;))))
          (then unreachable))
        (if (i32.ne (local.get $target-subtask) (i32.load (i32.const 16)))
          (then unreachable))
        (if (i32.ne (i32.const 2 (; RETURNED ;)) (i32.load offset=4 (i32.const 16)))
          (then unreachable))
        (if (i32.ne (i32.const 99) (i32.load (i32.const 0)))
          (then unreachable))
        (call $subtask.drop (local.get $target-subtask))

        ;; publish the async-typed, sync-lifted task as well
        (if (i32.ne (i32.const 7) (call $async-sync))
          (then unreachable))

        (i32.const 42))
    )
    (canon subtask.drop (core func $subtask.drop))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.poll (memory (core memory $memory "mem")) (core func $waitable-set.poll))
    (canon lower (func $target) async (memory (core memory $memory "mem")) (core func $target'))
    (canon lower (func $from-sync) (core func $from-sync'))
    (canon lower (func $async-sync) (core func $async-sync'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "subtask.drop" (func $subtask.drop))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.poll" (func $waitable-set.poll))
      (export "target" (func $target'))
      (export "from-sync" (func $from-sync'))
      (export "async-sync" (func $async-sync'))
    ))))
    (func (export "run") async (result u32) (canon lift (core func $core "run")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "target" (func $c "target"))
    (with "from-sync" (func $c "from-sync"))
    (with "async-sync" (func $c "async-sync"))))
  (func (export "run") (alias export $d "run"))
  (func (export "to-sync") (alias export $c "to-sync"))
  (func (export "to-async-sync") (alias export $c "to-async-sync"))
)
(component instance $sync-tasks1 $SyncTasks)
(assert_return (invoke "run") (u32.const 42))
(assert_trap (invoke "to-sync") "wasm trap: invalid `task.return` signature and/or options for current task")
(component instance $sync-tasks2 $SyncTasks)
(assert_return (invoke "run") (u32.const 42))
(assert_trap (invoke "to-async-sync") "wasm trap: invalid `task.return` signature and/or options for current task")

;; The implicit thread of an async callback-lifted export can change tasks too:
;; parked in its event loop after joining task B, it is not a target for its
;; own task's cancellation request (which stays pending), but receives task B's
;; cancellation as a TASK_CANCELLED event, acknowledges it on B's behalf, then
;; moves back home and resolves its own task from inside the callback before
;; exiting the event loop.
(component
  (component $C
    (core module $Core
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "task.cancel" (func $task.cancel))
      (import "" "thread.get-task" (func $thread.get-task (result i32)))
      (import "" "thread.set-task" (func $thread.set-task (param i32)))
      (import "" "task.drop" (func $task.drop (param i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))

      (global $target-task (mut i32) (i32.const 0xdead))  ;; handle for task B
      (global $cbmove-task (mut i32) (i32.const 0xdead))  ;; handle for the cbmove task

      ;; task B: publish a handle for itself and leave the event loop at once,
      ;; so that B has no thread of its own and the callback thread that joins
      ;; it is its only cancellable thread
      (func (export "target") (result i32)
        (global.set $target-task (call $thread.get-task))
        (i32.const 0 (; EXIT ;)))

      ;; the cbmove task's implicit thread: join task B, then wait on an empty
      ;; waitable set in the event loop, which releases the exclusive lock and
      ;; leaves this thread parked as task B's only cancellable thread
      (func (export "cbmove") (result i32)
        (global.set $cbmove-task (call $thread.get-task))
        (call $thread.set-task (global.get $target-task))
        (i32.or (i32.const 2 (; WAIT ;))
                (i32.shl (call $waitable-set.new) (i32.const 4))))

      ;; the only event this thread can receive is task B's cancellation
      (func (export "cbmove-cb") (param i32 i32 i32) (result i32)
        (if (i32.ne (i32.const 6 (; TASK_CANCELLED ;)) (local.get 0))
          (then unreachable))
        (call $task.cancel)                               ;; acknowledge on B's behalf
        (call $thread.set-task (global.get $cbmove-task)) ;; move back home
        (call $task.drop (global.get $target-task))
        (call $task.drop (global.get $cbmove-task))
        (call $task.return (i32.const 42))                ;; resolve the cbmove task
        (i32.const 0 (; EXIT ;)))

      ;; "target" leaves its event loop before any event can arrive
      (func (export "never") (param i32 i32 i32) (result i32)
        unreachable)
    )
    (canon task.return (result u32) (core func $task.return))
    (canon task.cancel (core func $task.cancel))
    (canon thread.get-task (core func $thread.get-task))
    (canon thread.set-task (core func $thread.set-task))
    (canon task.drop (core func $task.drop))
    (canon waitable-set.new (core func $waitable-set.new))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return" (func $task.return))
      (export "task.cancel" (func $task.cancel))
      (export "thread.get-task" (func $thread.get-task))
      (export "thread.set-task" (func $thread.set-task))
      (export "task.drop" (func $task.drop))
      (export "waitable-set.new" (func $waitable-set.new))
    ))))
    (func (export "target") async (result u32)
      (canon lift (core func $core "target") async (callback (core func $core "never"))))
    (func (export "cbmove") async (result u32)
      (canon lift (core func $core "cbmove")
        async (callback (core func $core "cbmove-cb"))))
  )
  (component $D
    (import "target" (func $target async (result u32)))
    (import "cbmove" (func $cbmove async (result u32)))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Core
      (import "" "mem" (memory 1))
      (import "" "subtask.cancel" (func $subtask.cancel (param i32) (result i32)))
      (import "" "subtask.drop" (func $subtask.drop (param i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.poll" (func $waitable-set.poll (param i32 i32) (result i32)))
      (import "" "target" (func $target (param i32) (result i32)))
      (import "" "cbmove" (func $cbmove (param i32) (result i32)))

      (func (export "run") (result i32)
        (local $ret i32)
        (local $target-subtask i32)
        (local $cbmove-subtask i32)
        (local $ws i32)

        ;; start target, whose implicit thread leaves at once
        (local.set $ret (call $target (i32.const 4 (; retp ;))))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $target-subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; start cbmove, whose implicit thread joins target's task and parks
        ;; in its event loop
        (local.set $ret (call $cbmove (i32.const 8 (; retp ;))))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $cbmove-subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; the callback thread is parked, but no longer in its own task, so
        ;; this request can only be remembered as pending
        (local.set $ret (call $subtask.cancel (local.get $cbmove-subtask)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))

        ;; the request against the joined task is delivered to the callback
        ;; thread as a TASK_CANCELLED event and acknowledged there
        (local.set $ret (call $subtask.cancel (local.get $target-subtask)))
        (if (i32.ne (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)) (local.get $ret))
          (then unreachable))
        (call $subtask.drop (local.get $target-subtask))

        ;; the callback moved home and resolved its own task with 42 inside the
        ;; cancel above, so that resolution is already pending
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $cbmove-subtask) (local.get $ws))
        (local.set $ret (call $waitable-set.poll (local.get $ws) (i32.const 16 (; eventp ;))))
        (if (i32.ne (i32.const 1 (; SUBTASK ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (local.get $cbmove-subtask) (i32.load (i32.const 16)))
          (then unreachable))
        (if (i32.ne (i32.const 2 (; RETURNED ;)) (i32.load offset=4 (i32.const 16)))
          (then unreachable))
        (if (i32.ne (i32.const 42) (i32.load (i32.const 8)))
          (then unreachable))
        (call $subtask.drop (local.get $cbmove-subtask))

        (i32.const 42))
    )
    (canon subtask.cancel async (core func $subtask.cancel))
    (canon subtask.drop (core func $subtask.drop))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.poll (memory (core memory $memory "mem")) (core func $waitable-set.poll))
    (canon lower (func $target) async (memory (core memory $memory "mem")) (core func $target'))
    (canon lower (func $cbmove) async (memory (core memory $memory "mem")) (core func $cbmove'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "subtask.cancel" (func $subtask.cancel))
      (export "subtask.drop" (func $subtask.drop))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.poll" (func $waitable-set.poll))
      (export "target" (func $target'))
      (export "cbmove" (func $cbmove'))
    ))))
    (func (export "run") async (result u32) (canon lift (core func $core "run")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "target" (func $c "target"))
    (with "cbmove" (func $c "cbmove"))))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 42))

;; A cancellation request is delivered to exactly one of the cancelled task's
;; threads, chosen nondeterministically among those parked in a callback event
;; loop. thread.set-task makes it possible for more than one thread to
;; qualify, since a thread that joins a task becomes a candidate for that
;; task's cancellation just as it stops being one for its own.
(component definition $TwoCandidates
  (component $C
    (core module $Core
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "task.cancel" (func $task.cancel))
      (import "" "thread.get-task" (func $thread.get-task (result i32)))
      (import "" "thread.set-task" (func $thread.set-task (param i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))

      (global $joined-task (mut i32) (i32.const 0xdead))  ;; handle for the task being cancelled
      (global $abandoned-task (mut i32) (i32.const 0))    ;; handle for a task left without threads
      (global $deliveries (mut i32) (i32.const 0))        ;; TASK_CANCELLED events received

      ;; this task's own implicit thread leaves the event loop at once, so the
      ;; task has no cancellable thread of its own and only joining threads are
      ;; candidates for its cancellation
      (func (export "target") (result i32)
        (global.set $joined-task (call $thread.get-task))
        (i32.const 0 (; EXIT ;)))

      ;; callback-lifted: this task's own implicit thread parks in its event
      ;; loop and so is a candidate alongside any thread that joins it
      (func (export "owner") (result i32)
        (global.set $joined-task (call $thread.get-task))
        (i32.or (i32.const 2 (; WAIT ;))
                (i32.shl (call $waitable-set.new) (i32.const 4))))

      ;; callback-lifted: resolve this thread's own task before joining the task
      ;; published above, then park in the event loop as one of its candidates
      (func (export "joiner") (result i32)
        (call $task.return (i32.const 42))
        (call $thread.set-task (global.get $joined-task))
        (i32.or (i32.const 2 (; WAIT ;))
                (i32.shl (call $waitable-set.new) (i32.const 4))))

      ;; callback-lifted: keep a handle for this thread's own task, join the
      ;; task published above and leave the event loop at once. That abandons
      ;; this thread's own task, started and unresolved with no threads at all;
      ;; the saved handle is all that is left to reach it by.
      (func (export "exiter") (result i32)
        (global.set $abandoned-task (call $thread.get-task))
        (call $thread.set-task (global.get $joined-task))
        (i32.const 0 (; EXIT ;)))

      ;; shared by every export above, though "target" and "exiter" leave
      ;; before any event can reach them: the only event that can arrive is the
      ;; cancellation of the task this thread is currently in, which it
      ;; acknowledges on that task's behalf. An abandoned task has no thread of
      ;; its own left to resolve it, so this thread returns for it through the
      ;; saved handle on its way out.
      (func (export "cb") (param i32 i32 i32) (result i32)
        (if (i32.ne (i32.const 6 (; TASK_CANCELLED ;)) (local.get 0))
          (then unreachable))
        (global.set $deliveries (i32.add (global.get $deliveries) (i32.const 1)))
        (call $task.cancel)
        (if (global.get $abandoned-task)  ;; index 0 is never a task handle
          (then
            (call $thread.set-task (global.get $abandoned-task))
            (call $task.return (i32.const 42))))
        (i32.const 0 (; EXIT ;)))

      (func (export "deliveries") (result i32)
        (global.get $deliveries))
    )
    (canon task.return (result u32) (core func $task.return))
    (canon task.cancel (core func $task.cancel))
    (canon thread.get-task (core func $thread.get-task))
    (canon thread.set-task (core func $thread.set-task))
    (canon waitable-set.new (core func $waitable-set.new))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return" (func $task.return))
      (export "task.cancel" (func $task.cancel))
      (export "thread.get-task" (func $thread.get-task))
      (export "thread.set-task" (func $thread.set-task))
      (export "waitable-set.new" (func $waitable-set.new))
    ))))
    (func (export "target") async (result u32)
      (canon lift (core func $core "target") async (callback (core func $core "cb"))))
    (func (export "owner") async (result u32)
      (canon lift (core func $core "owner") async (callback (core func $core "cb"))))
    (func (export "joiner") async (result u32)
      (canon lift (core func $core "joiner") async (callback (core func $core "cb"))))
    (func (export "exiter") async (result u32)
      (canon lift (core func $core "exiter") async (callback (core func $core "cb"))))
    (func (export "deliveries") (result u32)
      (canon lift (core func $core "deliveries")))
  )
  (component $D
    (import "target" (func $target async (result u32)))
    (import "owner" (func $owner async (result u32)))
    (import "joiner" (func $joiner async (result u32)))
    (import "exiter" (func $exiter async (result u32)))
    (import "deliveries" (func $deliveries (result u32)))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Core
      (import "" "mem" (memory 1))
      (import "" "subtask.cancel" (func $subtask.cancel (param i32) (result i32)))
      (import "" "subtask.drop" (func $subtask.drop (param i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.poll" (func $waitable-set.poll (param i32 i32) (result i32)))
      (import "" "target" (func $target (param i32) (result i32)))
      (import "" "owner" (func $owner (param i32) (result i32)))
      (import "" "joiner" (func $joiner (param i32) (result i32)))
      (import "" "exiter" (func $exiter (param i32) (result i32)))
      (import "" "deliveries" (func $deliveries (result i32)))

      ;; start a joiner, which resolves eagerly with 42 and leaves its implicit
      ;; thread parked in the joined task's event loop; since it has already
      ;; resolved, there is no subtask index in the packed result to keep
      (func $start-joiner (param $retp i32)
        (if (i32.ne (i32.const 2 (; RETURNED ;)) (call $joiner (local.get $retp)))
          (then unreachable))
        (if (i32.ne (i32.const 42) (i32.load (local.get $retp)))
          (then unreachable)))

      ;; both candidates joined the cancelled task from elsewhere
      (func (export "cancel-two-joined") (result i32)
        (local $ret i32)
        (local $target-subtask i32)

        ;; start target, whose implicit thread leaves at once
        (local.set $ret (call $target (i32.const 0 (; retp ;))))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $target-subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        (call $start-joiner (i32.const 4 (; retp ;)))
        (call $start-joiner (i32.const 8 (; retp ;)))

        ;; target's task now contains two cancellable threads and neither of
        ;; them is its own, so the request goes to one of the two joining
        ;; threads, which acknowledges it from its event loop
        (if (i32.ne (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;))
                    (call $subtask.cancel (local.get $target-subtask)))
          (then unreachable))
        (call $subtask.drop (local.get $target-subtask))

        ;; exactly one of the two threads received the event
        (if (i32.ne (i32.const 1) (call $deliveries))
          (then unreachable))

        (i32.const 42))

      ;; the cancelled task's own implicit thread is a candidate too
      (func (export "cancel-own-and-joined") (result i32)
        (local $ret i32)
        (local $owner-subtask i32)

        ;; start owner, which parks its implicit thread in its own event loop
        (local.set $ret (call $owner (i32.const 0 (; retp ;))))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $owner-subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        (call $start-joiner (i32.const 4 (; retp ;)))

        ;; owner's task now contains two cancellable threads: its own implicit
        ;; thread and the joining one. Both acknowledge the request the same
        ;; way, so the outcome does not depend on which is chosen.
        (if (i32.ne (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;))
                    (call $subtask.cancel (local.get $owner-subtask)))
          (then unreachable))
        (call $subtask.drop (local.get $owner-subtask))

        (if (i32.ne (i32.const 1) (call $deliveries))
          (then unreachable))

        (i32.const 42))

      ;; the same two candidates, plus a third joining thread that leaves its
      ;; event loop immediately: the chosen candidate resolves that abandoned
      ;; task as well, through the handle the thread left behind
      (func (export "cancel-two-joined-and-abandoned") (result i32)
        (local $ret i32)
        (local $target-subtask i32)
        (local $exiter-subtask i32)
        (local $ws i32)

        ;; start target, whose implicit thread leaves at once
        (local.set $ret (call $target (i32.const 0 (; retp ;))))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $target-subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; start exiter, which joins target's task and exits, leaving its own
        ;; task started-but-unresolved and threadless
        (local.set $ret (call $exiter (i32.const 12 (; retp ;))))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $exiter-subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        (call $start-joiner (i32.const 4 (; retp ;)))
        (call $start-joiner (i32.const 8 (; retp ;)))

        ;; exiter's thread is gone and so is not a candidate: the request goes
        ;; to one of the two threads still parked in target's task
        (if (i32.ne (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;))
                    (call $subtask.cancel (local.get $target-subtask)))
          (then unreachable))
        (call $subtask.drop (local.get $target-subtask))
        (if (i32.ne (i32.const 1) (call $deliveries))
          (then unreachable))

        ;; whichever thread that was, it returned 42 for the abandoned task
        ;; inside the cancel above, so that resolution is already pending
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $exiter-subtask) (local.get $ws))
        (if (i32.ne (i32.const 1 (; SUBTASK ;))
                    (call $waitable-set.poll (local.get $ws) (i32.const 16 (; eventp ;))))
          (then unreachable))
        (if (i32.ne (local.get $exiter-subtask) (i32.load (i32.const 16)))
          (then unreachable))
        (if (i32.ne (i32.const 2 (; RETURNED ;)) (i32.load offset=4 (i32.const 16)))
          (then unreachable))
        (if (i32.ne (i32.const 42) (i32.load (i32.const 12)))
          (then unreachable))
        (call $subtask.drop (local.get $exiter-subtask))

        (i32.const 42))
    )
    (canon subtask.cancel async (core func $subtask.cancel))
    (canon subtask.drop (core func $subtask.drop))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.poll (memory (core memory $memory "mem")) (core func $waitable-set.poll))
    (canon lower (func $target) async (memory (core memory $memory "mem")) (core func $target'))
    (canon lower (func $owner) async (memory (core memory $memory "mem")) (core func $owner'))
    (canon lower (func $joiner) async (memory (core memory $memory "mem")) (core func $joiner'))
    (canon lower (func $exiter) async (memory (core memory $memory "mem")) (core func $exiter'))
    (canon lower (func $deliveries) (core func $deliveries'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "subtask.cancel" (func $subtask.cancel))
      (export "subtask.drop" (func $subtask.drop))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.poll" (func $waitable-set.poll))
      (export "target" (func $target'))
      (export "owner" (func $owner'))
      (export "joiner" (func $joiner'))
      (export "exiter" (func $exiter'))
      (export "deliveries" (func $deliveries'))
    ))))
    (func (export "cancel-two-joined") async (result u32)
      (canon lift (core func $core "cancel-two-joined")))
    (func (export "cancel-own-and-joined") async (result u32)
      (canon lift (core func $core "cancel-own-and-joined")))
    (func (export "cancel-two-joined-and-abandoned") async (result u32)
      (canon lift (core func $core "cancel-two-joined-and-abandoned")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "target" (func $c "target"))
    (with "owner" (func $c "owner"))
    (with "joiner" (func $c "joiner"))
    (with "exiter" (func $c "exiter"))
    (with "deliveries" (func $c "deliveries"))))
  (func (export "cancel-two-joined") (alias export $d "cancel-two-joined"))
  (func (export "cancel-own-and-joined") (alias export $d "cancel-own-and-joined"))
  (func (export "cancel-two-joined-and-abandoned")
    (alias export $d "cancel-two-joined-and-abandoned"))
)
(component instance $tc1 $TwoCandidates)
(assert_return (invoke "cancel-two-joined") (u32.const 42))
(component instance $tc2 $TwoCandidates)
(assert_return (invoke "cancel-own-and-joined") (u32.const 42))
(component instance $tc3 $TwoCandidates)
(assert_return (invoke "cancel-two-joined-and-abandoned") (u32.const 42))

;; The exclusive lock belongs to the task that acquired it, not to
;; whatever task its thread is currently executing on behalf of. A
;; synchronously-lifted async-typed export holds the lock for the whole core
;; call, so while its implicit thread is parked *inside another task*, a second
;; sync-lifted task must still be held at the implicit-backpressure gate.
;; Non-async-typed exports ignore backpressure entirely and can still barge
;; in, which is what releases the parked thread here.
(component
  (component $C
    (core module $Core
      (import "" "task.return-u32" (func $task.return-u32 (param i32)))
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "thread.get-task" (func $thread.get-task (result i32)))
      (import "" "thread.set-task" (func $thread.set-task (param i32)))
      (import "" "task.drop" (func $task.drop (param i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "thread.suspend" (func $thread.suspend (result i32)))

      (global $target-task (mut i32) (i32.const 0xdead))      ;; handle for task B
      (global $holder-implicit (mut i32) (i32.const 0xdead))  ;; implicit thread of $holder

      ;; task B: its implicit thread publishes a handle and leaves the event
      ;; loop at once, so B holds no exclusive lock and has no thread of its
      ;; own; B is resolved by $holder's thread.
      (func (export "target") (result i32)
        (global.set $target-task (call $thread.get-task))
        (i32.const 0 (; EXIT ;)))

      ;; "target" leaves its event loop before any event can arrive
      (func (export "never") (param i32 i32 i32) (result i32)
        unreachable)

      ;; sync-lifted: acquires the exclusive lock on entry and releases it only
      ;; when this core function returns
      (func (export "holder") (result i32)
        (local $home i32)
        (local.set $home (call $thread.get-task))
        (global.set $holder-implicit (call $thread.index))

        ;; resolve task B from inside B, still holding the lock
        (call $thread.set-task (global.get $target-task))
        (call $task.return-u32 (i32.const 99))

        ;; park while still contained by B: the lock stays held
        (drop (call $thread.suspend))

        ;; no move back home: the sync lift rejoins its original task for us
        (call $task.drop (local.get $home))
        (call $task.drop (global.get $target-task))
        (i32.const 42))

      ;; also sync-lifted, and so also gated on the exclusive lock
      (func (export "blocked") (result i32)
        (i32.const 11))

      ;; not async-typed, so this ignores both the exclusive lock and the
      ;; task queued behind it
      (func (export "release") (result i32)
        (call $thread.resume-later (global.get $holder-implicit))
        (i32.const 0))
    )
    (canon task.return (result u32) (core func $task.return-u32))
    (canon thread.index (core func $thread.index))
    (canon thread.get-task (core func $thread.get-task))
    (canon thread.set-task (core func $thread.set-task))
    (canon task.drop (core func $task.drop))
    (canon thread.resume-later (core func $thread.resume-later))
    (canon thread.suspend (core func $thread.suspend))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return-u32" (func $task.return-u32))
      (export "thread.index" (func $thread.index))
      (export "thread.get-task" (func $thread.get-task))
      (export "thread.set-task" (func $thread.set-task))
      (export "task.drop" (func $task.drop))
      (export "thread.resume-later" (func $thread.resume-later))
      (export "thread.suspend" (func $thread.suspend))
    ))))
    (func (export "target") async (result u32)
      (canon lift (core func $core "target") async (callback (core func $core "never"))))
    (func (export "holder") async (result u32)
      (canon lift (core func $core "holder")))
    (func (export "blocked") async (result u32)
      (canon lift (core func $core "blocked")))
    (func (export "release") (result u32)
      (canon lift (core func $core "release")))
  )
  (component $D
    (import "target" (func $target async (result u32)))
    (import "holder" (func $holder async (result u32)))
    (import "blocked" (func $blocked async (result u32)))
    (import "release" (func $release (result u32)))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Core
      (import "" "mem" (memory 1))
      (import "" "subtask.drop" (func $subtask.drop (param i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (import "" "target" (func $target (param i32) (result i32)))
      (import "" "holder" (func $holder (param i32) (result i32)))
      (import "" "blocked" (func $blocked (param i32) (result i32)))
      (import "" "release" (func $release (result i32)))

      (func (export "run") (result i32)
        (local $ret i32)
        (local $ws i32)
        (local $n i32)

        (local.set $ws (call $waitable-set.new))

        ;; start target, whose implicit thread leaves at once
        (local.set $ret (call $target (i32.const 0 (; retp ;))))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (call $waitable.join (i32.shr_u (local.get $ret) (i32.const 4)) (local.get $ws))

        ;; start holder: takes the lock, resolves target from inside target's
        ;; task, then parks there with the lock still held
        (local.set $ret (call $holder (i32.const 4 (; retp ;))))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (call $waitable.join (i32.shr_u (local.get $ret) (i32.const 4)) (local.get $ws))

        ;; the lock is still held even though its owner is running as another
        ;; task, so this one cannot even start
        (local.set $ret (call $blocked (i32.const 8 (; retp ;))))
        (if (i32.ne (i32.const 0 (; STARTING ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (call $waitable.join (i32.shr_u (local.get $ret) (i32.const 4)) (local.get $ws))

        ;; barge past both the lock and the task queued behind it
        (if (i32.ne (i32.const 0) (call $release))
          (then unreachable))

        ;; holder returns 42 and drops the lock, which lets blocked start and
        ;; return 11; target was resolved with 99 by holder's thread
        (loop $l
          (if (i32.ne (i32.const 1 (; SUBTASK ;))
                      (call $waitable-set.wait (local.get $ws) (i32.const 16 (; eventp ;))))
            (then unreachable))
          (if (i32.ne (i32.const 2 (; RETURNED ;)) (i32.load offset=4 (i32.const 16)))
            (then unreachable))
          (call $waitable.join (i32.load (i32.const 16)) (i32.const 0))
          (call $subtask.drop (i32.load (i32.const 16)))
          (local.set $n (i32.add (local.get $n) (i32.const 1)))
          (br_if $l (i32.lt_u (local.get $n) (i32.const 3))))

        (if (i32.ne (i32.const 99) (i32.load (i32.const 0)))
          (then unreachable))
        (if (i32.ne (i32.const 42) (i32.load (i32.const 4)))
          (then unreachable))
        (if (i32.ne (i32.const 11) (i32.load (i32.const 8)))
          (then unreachable))
        (i32.const 42))
    )
    (canon subtask.drop (core func $subtask.drop))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (canon lower (func $target) async (memory (core memory $memory "mem")) (core func $target'))
    (canon lower (func $holder) async (memory (core memory $memory "mem")) (core func $holder'))
    (canon lower (func $blocked) async (memory (core memory $memory "mem")) (core func $blocked'))
    (canon lower (func $release) (core func $release'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "subtask.drop" (func $subtask.drop))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "target" (func $target'))
      (export "holder" (func $holder'))
      (export "blocked" (func $blocked'))
      (export "release" (func $release'))
    ))))
    (func (export "run") async (result u32) (canon lift (core func $core "run")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "target" (func $c "target"))
    (with "holder" (func $c "holder"))
    (with "blocked" (func $c "blocked"))
    (with "release" (func $c "release"))))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 42))

;; A callback-lifted export also holds the exclusive lock across each turn of
;; its event loop, so exiting the loop must release the lock even when the
;; thread has moved to another task in the meantime. Doing so abandons the
;; export's own task, unresolved and with no threads at all, which is *not* a
;; trap: the caller simply never hears back, and waiting for it deadlocks once
;; nothing else in the store can run.
(component
  (component $C
    (core module $Core
      (import "" "thread.get-task" (func $thread.get-task (result i32)))
      (import "" "thread.set-task" (func $thread.set-task (param i32)))

      (global $target-task (mut i32) (i32.const 0xdead))  ;; handle for task B

      ;; task B: publish a handle and leave the event loop; B keeps no thread
      ;; of its own and is never resolved
      (func (export "target") (result i32)
        (global.set $target-task (call $thread.get-task))
        (i32.const 0 (; EXIT ;)))

      ;; join task B and exit the event loop immediately, while still
      ;; contained by B: this task is left unresolved with no threads
      (func (export "abandon") (result i32)
        (call $thread.set-task (global.get $target-task))
        (i32.const 0 (; EXIT ;)))

      ;; neither export above stays in its event loop long enough to be given
      ;; an event
      (func (export "never") (param i32 i32 i32) (result i32)
        unreachable)

      ;; sync-lifted, and so gated on the exclusive lock: this can only
      ;; complete if "abandon" released the lock on its way out
      (func (export "prove") (result i32)
        (i32.const 7))
    )
    (canon thread.get-task (core func $thread.get-task))
    (canon thread.set-task (core func $thread.set-task))
    (core instance $core (instantiate $Core (with "" (instance
      (export "thread.get-task" (func $thread.get-task))
      (export "thread.set-task" (func $thread.set-task))
    ))))
    (func (export "target") async (result u32)
      (canon lift (core func $core "target") async (callback (core func $core "never"))))
    (func (export "abandon") async (result u32)
      (canon lift (core func $core "abandon")
        async (callback (core func $core "never"))))
    (func (export "prove") async (result u32)
      (canon lift (core func $core "prove")))
  )
  (component $D
    (import "target" (func $target async (result u32)))
    (import "abandon" (func $abandon async (result u32)))
    (import "prove" (func $prove async (result u32)))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Core
      (import "" "mem" (memory 1))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (import "" "target" (func $target (param i32) (result i32)))
      (import "" "abandon" (func $abandon (param i32) (result i32)))
      (import "" "prove" (func $prove (param i32) (result i32)))

      (func (export "run") (result i32)
        (local $ret i32)
        (local $ws i32)

        ;; start target, whose implicit thread leaves at once
        (local.set $ret (call $target (i32.const 0 (; retp ;))))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))

        ;; start abandon: it joins target's task and exits, leaving its own
        ;; task started-but-unresolved with no threads
        (local.set $ret (call $abandon (i32.const 4 (; retp ;))))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))

        ;; the exclusive lock was released on the way out, so this sync-lifted
        ;; export runs to completion eagerly instead of blocking on the gate
        (if (i32.ne (i32.const 2 (; RETURNED ;)) (call $prove (i32.const 8 (; retp ;))))
          (then unreachable))
        (if (i32.ne (i32.const 7) (i32.load (i32.const 8)))
          (then unreachable))

        ;; abandon's task can never resolve and nothing else can run
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (i32.shr_u (local.get $ret) (i32.const 4)) (local.get $ws))
        (call $waitable-set.wait (local.get $ws) (i32.const 16 (; eventp ;)))
        unreachable)
    )
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (canon lower (func $target) async (memory (core memory $memory "mem")) (core func $target'))
    (canon lower (func $abandon) async (memory (core memory $memory "mem")) (core func $abandon'))
    (canon lower (func $prove) async (memory (core memory $memory "mem")) (core func $prove'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "target" (func $target'))
      (export "abandon" (func $abandon'))
      (export "prove" (func $prove'))
    ))))
    (func (export "run") async (result u32) (canon lift (core func $core "run")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "target" (func $c "target"))
    (with "abandon" (func $c "abandon"))
    (with "prove" (func $c "prove"))))
  (func (export "run") (alias export $d "run"))
)
(assert_trap (invoke "run") "wasm trap: deadlock detected: event loop cannot make further progress")
