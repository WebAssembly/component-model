;; Test thread.{get,set}-task and task.drop

;; Basic task switching and error cases
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
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "__indirect_function_table" (table $indirect-function-table 2 funcref))

      (global $a-task (mut i32) (i32.const 0xdead))             ;; handle for resolved task A
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

      ;; task A: publish a handle for itself, spawn the two threads above,
      ;; resolve, then let the implicit thread exit
      (func (export "setup")
        (global.set $a-task (call $thread.get-task))
        (global.set $worker-thread (call $thread.new-indirect (i32.const 0) (i32.const 0)))
        (global.set $worker-bad-thread (call $thread.new-indirect (i32.const 1) (i32.const 0)))
        (call $task.return-u8 (i32.const 1)))

      ;; task B: publish a handle for itself and switch to $worker-thread,
      ;; which returns 42 on B's behalf
      (func (export "join")
        (global.set $join-implicit (call $thread.index))
        (global.set $join-task (call $thread.get-task))
        (drop (call $thread.suspend-then-resume (global.get $worker-thread)))
        (call $task.drop (global.get $join-task)))

      ;; task B2: switch to $worker-bad-thread, which joins B2 and then traps
      ;; returning with the wrong task.return
      (func (export "join-bad")
        (global.set $join-implicit (call $thread.index))
        (global.set $join-task (call $thread.get-task))
        (drop (call $thread.suspend-then-resume (global.get $worker-bad-thread)))
        unreachable)

      (func (export "join-unknown-set")
        (call $thread.set-task (global.get $a-task))
        (call $thread.set-task (i32.const 100))
        unreachable)
      (func (export "join-unknown-drop")
        (call $thread.set-task (global.get $a-task))
        (call $task.drop (i32.const 100))
        unreachable)
      (func (export "join-wrong-set")
        (call $thread.set-task (global.get $a-task))
        (call $thread.set-task (call $waitable-set.new))
        unreachable)
      (func (export "join-wrong-drop")
        (call $thread.set-task (global.get $a-task))
        (call $task.drop (call $waitable-set.new))
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
    (canon waitable-set.new (core func $waitable-set.new))
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
      (export "waitable-set.new" (func $waitable-set.new))
      (export "__indirect_function_table" (table $indirect-function-table))
    ))))
    (func (export "setup") async (result u8)
      (canon lift (core func $core "setup") async))
    (func (export "join") async (result u32)
      (canon lift (core func $core "join") async))
    (func (export "join-bad") async (result u32)
      (canon lift (core func $core "join-bad") async))
    (func (export "join-unknown-set") async (result u32)
      (canon lift (core func $core "join-unknown-set") async))
    (func (export "join-unknown-drop") async (result u32)
      (canon lift (core func $core "join-unknown-drop") async))
    (func (export "join-wrong-set") async (result u32)
      (canon lift (core func $core "join-wrong-set") async))
    (func (export "join-wrong-drop") async (result u32)
      (canon lift (core func $core "join-wrong-drop") async))
  )
  (instance $c (instantiate $C))
  (func (export "setup") (alias export $c "setup"))
  (func (export "join") (alias export $c "join"))
  (func (export "join-bad") (alias export $c "join-bad"))
  (func (export "join-unknown-set") (alias export $c "join-unknown-set"))
  (func (export "join-unknown-drop") (alias export $c "join-unknown-drop"))
  (func (export "join-wrong-set") (alias export $c "join-wrong-set"))
  (func (export "join-wrong-drop") (alias export $c "join-wrong-drop"))
)
(component instance $j1 $Join)
(assert_return (invoke "setup") (u8.const 1))
(assert_return (invoke "join") (u32.const 42))
(component instance $j2 $Join)
(assert_return (invoke "setup") (u8.const 1))
(assert_trap (invoke "join-bad") "wasm trap: invalid `task.return` signature and/or options for current task")
(component instance $j3 $Join)
(assert_return (invoke "setup") (u8.const 1))
(assert_trap (invoke "join-unknown-set") "unknown handle index 100")
(component instance $j4 $Join)
(assert_return (invoke "setup") (u8.const 1))
(assert_trap (invoke "join-unknown-drop") "unknown handle index 100")
(component instance $j5 $Join)
(assert_return (invoke "setup") (u8.const 1))
(assert_trap (invoke "join-wrong-set") "handle is not a task")
(component instance $j6 $Join)
(assert_return (invoke "setup") (u8.const 1))
(assert_trap (invoke "join-wrong-drop") "handle is not a task")

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
      ;; to A - not to the most-recently-left B1, whose u8-typed, already
      ;; resolved task would trap the u32-typed task.return - and resolves A
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
      (func (export "victim1")
        (global.set $b1-task (call $thread.get-task))
        (call $task.return-u8 (i32.const 1)))
      (func (export "victim2")
        (global.set $b2-task (call $thread.get-task))
        (call $task.return-u8 (i32.const 1)))

      ;; task A: spawn $last-thread and $mover-thread and exit the implicit
      ;; thread *without* returning a value, leaving A unresolved with two
      ;; threads
      (func (export "unresolved")
        (global.set $last-thread (call $thread.new-indirect (i32.const 1) (i32.const 0)))
        (global.set $mover-thread (call $thread.new-indirect (i32.const 0) (i32.const 0)))
        (call $thread.resume-later (global.get $mover-thread)))
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
      (canon lift (core func $core "victim1") async))
    (func (export "victim2") async (result u8)
      (canon lift (core func $core "victim2") async))
    (func (export "unresolved") async (result u32)
      (canon lift (core func $core "unresolved") async))
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
      (func (export "setup")
        (global.set $worker-thread (call $thread.new-indirect (i32.const 0) (i32.const 0)))
        (call $task.return (i32.const 1)))

      ;; task B: switch to $worker-thread, then exit the implicit thread while
      ;; B is still unresolved, leaving B to retain $worker-thread and
      ;; $child-thread; $child-thread then returns 42 on B's behalf
      (func (export "run")
        (global.set $run-implicit (call $thread.index))
        (global.set $run-task (call $thread.get-task))
        (drop (call $thread.suspend-then-resume (global.get $worker-thread)))
        (call $thread.resume-later (global.get $child-thread)))
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
      (canon lift (core func $core "setup") async))
    (func (export "run") async (result u32)
      (canon lift (core func $core "run") async))
  )
  (instance $c (instantiate $C))
  (func (export "setup") (alias export $c "setup"))
  (func (export "run") (alias export $c "run"))
)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run") (u32.const 42))

;; Two implicit threads swap tasks and each returns the value of its *new*
;; task. The two task.returns are differently typed, so each would trap if the
;; calling thread were still in its original task. $swap1-implicit briefly
;; leaves its unresolved task A with no threads at all when it joins task B,
;; and moves back afterwards with the handle it saved on entry; $swap2-implicit
;; exits while still contained by task A, which has no effect on its original
;; task B.
(component
  (component $C
    (core module $Core
      (import "" "task.return-u8" (func $task.return-u8 (param i32)))
      (import "" "task.return-u32" (func $task.return-u32 (param i32)))
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "thread.get-task" (func $thread.get-task (result i32)))
      (import "" "thread.set-task" (func $thread.set-task (param i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "thread.suspend" (func $thread.suspend (result i32)))
      (import "" "thread.suspend-then-resume" (func $thread.suspend-then-resume (param i32) (result i32)))

      (global $swap1-implicit (mut i32) (i32.const 0xdead))  ;; implicit thread of task A (swap1)
      (global $swap2-implicit (mut i32) (i32.const 0xdead))  ;; implicit thread of task B (swap2)
      (global $a-task (mut i32) (i32.const 0xdead))          ;; handle for task A
      (global $b-task (mut i32) (i32.const 0xdead))          ;; handle for task B

      ;; task A: its implicit thread ($swap1-implicit) parks until
      ;; $swap2-implicit switches to it. It then joins task B (whose only
      ;; thread is the still-parked $swap2-implicit), returns task B's value,
      ;; moves back to its original task A and parks again so that
      ;; $swap2-implicit can join task A.
      (func (export "swap1")
        (global.set $swap1-implicit (call $thread.index))
        (global.set $a-task (call $thread.get-task))
        (drop (call $thread.suspend))
        ;; woken by $swap2-implicit, which is still in task B
        (call $thread.set-task (global.get $b-task))
        ;; the u32-typed task.return is only well-typed against task B
        (call $task.return-u32 (i32.const 222))
        (call $thread.set-task (global.get $a-task))
        (call $thread.resume-later (global.get $swap2-implicit))
        (drop (call $thread.suspend)))

      ;; task B: its implicit thread ($swap2-implicit) switches to
      ;; $swap1-implicit and, once $swap1-implicit has resolved task B and
      ;; moved back home to task A, joins task A, returns task A's value and
      ;; exits while still contained by task A.
      (func (export "swap2")
        (global.set $swap2-implicit (call $thread.index))
        (global.set $b-task (call $thread.get-task))
        (drop (call $thread.suspend-then-resume (global.get $swap1-implicit)))
        (call $thread.set-task (global.get $a-task))
        ;; the u8-typed task.return is only well-typed against task A
        (call $task.return-u8 (i32.const 11))
        (call $thread.resume-later (global.get $swap1-implicit)))
    )
    (canon task.return (result u8) (core func $task.return-u8))
    (canon task.return (result u32) (core func $task.return-u32))
    (canon thread.index (core func $thread.index))
    (canon thread.get-task (core func $thread.get-task))
    (canon thread.set-task (core func $thread.set-task))
    (canon thread.resume-later (core func $thread.resume-later))
    (canon thread.suspend (core func $thread.suspend))
    (canon thread.suspend-then-resume (core func $thread.suspend-then-resume))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return-u8" (func $task.return-u8))
      (export "task.return-u32" (func $task.return-u32))
      (export "thread.index" (func $thread.index))
      (export "thread.get-task" (func $thread.get-task))
      (export "thread.set-task" (func $thread.set-task))
      (export "thread.resume-later" (func $thread.resume-later))
      (export "thread.suspend" (func $thread.suspend))
      (export "thread.suspend-then-resume" (func $thread.suspend-then-resume))
    ))))
    (func (export "swap1") async (result u8)
      (canon lift (core func $core "swap1") async))
    (func (export "swap2") async (result u32)
      (canon lift (core func $core "swap2") async))
  )
  (component $D
    (import "swap1" (func $swap1 async (result u8)))
    (import "swap2" (func $swap2 async (result u32)))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Core
      (import "" "mem" (memory 1))
      (import "" "subtask.drop" (func $subtask.drop (param i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (import "" "swap1" (func $swap1 (param i32) (result i32)))
      (import "" "swap2" (func $swap2 (param i32) (result i32)))

      (func (export "run") (result i32)
        (local $ret i32)
        (local $subtask1 i32)
        (local $ws i32)

        ;; start swap1, whose implicit thread parks immediately
        (local.set $ret (call $swap1 (i32.const 4 (; retp ;))))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $subtask1 (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; start swap2: within this call, task A's implicit thread joins task
        ;; B and returns 222 on its behalf, so the call completes eagerly
        (local.set $ret (call $swap2 (i32.const 8 (; retp ;))))
        (if (i32.ne (i32.const 2 (; RETURNED ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (i32.const 222) (i32.load (i32.const 8)))
          (then unreachable))

        ;; block, letting task B's erstwhile implicit thread join task A and
        ;; return 11 on task A's behalf
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $subtask1) (local.get $ws))
        (local.set $ret (call $waitable-set.wait (local.get $ws) (i32.const 16 (; eventp ;))))
        (if (i32.ne (i32.const 1 (; SUBTASK ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (local.get $subtask1) (i32.load (i32.const 16)))
          (then unreachable))
        (if (i32.ne (i32.const 2 (; RETURNED ;)) (i32.load offset=4 (i32.const 16)))
          (then unreachable))
        (if (i32.ne (i32.const 11) (i32.load8_u (i32.const 4)))
          (then unreachable))
        (call $subtask.drop (local.get $subtask1))

        (i32.const 42))
    )
    (canon subtask.drop (core func $subtask.drop))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (canon lower (func $swap1) async (memory (core memory $memory "mem")) (core func $swap1'))
    (canon lower (func $swap2) async (memory (core memory $memory "mem")) (core func $swap2'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "subtask.drop" (func $subtask.drop))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "swap1" (func $swap1'))
      (export "swap2" (func $swap2'))
    ))))
    (func (export "run") async (result u32) (canon lift (core func $core "run")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "swap1" (func $c "swap1"))
    (with "swap2" (func $c "swap2"))))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 42))

;; The implicit thread of a synchronously-lifted export may temporarily change
;; tasks while the core function executes, but must have moved back to its
;; original task by the time the core function returns, or there is a trap.
;; This follows the *lift* ABI, not the function type: an async-typed export
;; lifted with the sync ABI (which also holds the instance's exclusive lock
;; for the duration of the core call) is subject to the same rule.  Since each
;; trap poisons its instance, the two trapping cases use separate instances of
;; the same component.
(component definition $VisitOrStay
  (component $C
    (core module $Core
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "thread.get-task" (func $thread.get-task (result i32)))
      (import "" "thread.set-task" (func $thread.set-task (param i32)))

      (global $a-task (mut i32) (i32.const 0xdead))  ;; handle for resolved task A

      (func (export "setup")
        (global.set $a-task (call $thread.get-task))
        (call $task.return (i32.const 1)))

      (func (export "sync-visit") (result i32)
        (local $home i32)
        (local.set $home (call $thread.get-task))
        (call $thread.set-task (global.get $a-task))
        (call $thread.set-task (local.get $home))
        (i32.const 42))

      (func (export "sync-stay") (result i32)
        (call $thread.set-task (global.get $a-task))
        (i32.const 33))

      (func (export "async-visit") (result i32)
        (local $home i32)
        (local.set $home (call $thread.get-task))
        (call $thread.set-task (global.get $a-task))
        (call $thread.set-task (local.get $home))
        (i32.const 44))

      (func (export "async-stay") (result i32)
        (call $thread.set-task (global.get $a-task))
        (i32.const 55))
    )
    (canon task.return (result u32) (core func $task.return))
    (canon thread.get-task (core func $thread.get-task))
    (canon thread.set-task (core func $thread.set-task))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return" (func $task.return))
      (export "thread.get-task" (func $thread.get-task))
      (export "thread.set-task" (func $thread.set-task))
    ))))
    (func (export "setup") async (result u32)
      (canon lift (core func $core "setup") async))
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
(component instance $visit-or-sync-stay $VisitOrStay)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "sync-visit") (u32.const 42))
(assert_return (invoke "async-visit") (u32.const 44))
(assert_trap (invoke "sync-stay") "wasm trap: sync-lifted export returned outside its original task")
(component instance $async-stay $VisitOrStay)
(assert_return (invoke "setup") (u32.const 1))
(assert_trap (invoke "async-stay") "wasm trap: sync-lifted export returned outside its original task")

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
      (import "" "thread.suspend" (func $thread.suspend (result i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))

      (global $target-task (mut i32) (i32.const 0xdead))  ;; handle for task B
      (global $cbmove-task (mut i32) (i32.const 0xdead))  ;; handle for the cbmove task

      ;; task B: park the implicit thread, so B's only cancellable thread is
      ;; the callback thread that joins it
      (func (export "target")
        (global.set $target-task (call $thread.get-task))
        (drop (call $thread.suspend))
        unreachable)

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
    )
    (canon task.return (result u32) (core func $task.return))
    (canon task.cancel (core func $task.cancel))
    (canon thread.get-task (core func $thread.get-task))
    (canon thread.set-task (core func $thread.set-task))
    (canon task.drop (core func $task.drop))
    (canon thread.suspend (core func $thread.suspend))
    (canon waitable-set.new (core func $waitable-set.new))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return" (func $task.return))
      (export "task.cancel" (func $task.cancel))
      (export "thread.get-task" (func $thread.get-task))
      (export "thread.set-task" (func $thread.set-task))
      (export "task.drop" (func $task.drop))
      (export "thread.suspend" (func $thread.suspend))
      (export "waitable-set.new" (func $waitable-set.new))
    ))))
    (func (export "target") async (result u32)
      (canon lift (core func $core "target") async))
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
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (import "" "target" (func $target (param i32) (result i32)))
      (import "" "cbmove" (func $cbmove (param i32) (result i32)))

      ;; wait for $sub to resolve as CANCELLED_BEFORE_RETURNED, then drop it
      (func $await-cancelled (param $sub i32)
        (local $ws i32)
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $sub) (local.get $ws))
        (if (i32.ne (i32.const 1 (; SUBTASK ;))
                    (call $waitable-set.wait (local.get $ws) (i32.const 24 (; eventp ;))))
          (then unreachable))
        (if (i32.ne (local.get $sub) (i32.load (i32.const 24)))
          (then unreachable))
        (if (i32.ne (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)) (i32.load offset=4 (i32.const 24)))
          (then unreachable))
        (call $waitable.join (local.get $sub) (i32.const 0))
        (call $subtask.drop (local.get $sub)))

      (func (export "run") (result i32)
        (local $ret i32)
        (local $target-subtask i32)
        (local $cbmove-subtask i32)
        (local $ws i32)

        ;; start target, which parks its implicit thread
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
        ;; thread as a TASK_CANCELLED event and acknowledged there; the
        ;; cooperative yield may or may not have reached that thread already
        (local.set $ret (call $subtask.cancel (local.get $target-subtask)))
        (if (i32.eq (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then (call $await-cancelled (local.get $target-subtask)))
          (else
            (if (i32.ne (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)) (local.get $ret))
              (then unreachable))
            (call $subtask.drop (local.get $target-subtask))))

        ;; the callback moved home and resolved its own task with 42
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $cbmove-subtask) (local.get $ws))
        (local.set $ret (call $waitable-set.wait (local.get $ws) (i32.const 16 (; eventp ;))))
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
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (canon lower (func $target) async (memory (core memory $memory "mem")) (core func $target'))
    (canon lower (func $cbmove) async (memory (core memory $memory "mem")) (core func $cbmove'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "subtask.cancel" (func $subtask.cancel))
      (export "subtask.drop" (func $subtask.drop))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
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
