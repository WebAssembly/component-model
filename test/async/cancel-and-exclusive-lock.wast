;; This test exercises how a component instance's "exclusive" lock interacts
;; with the delivery of cancellation requests.
;;
;; A `callback`-lifted task waiting in its event loop is only cancellable while
;; the exclusive lock is free, since delivering cancellation resumes the task,
;; which re-enters core wasm. Cancellation requested while the lock is held by
;; another task therefore cannot be delivered immediately and is remembered as
;; pending. It must then be delivered as soon as the lock frees, even if the
;; waiting task's own readiness condition is never met.
(component
  (component $C
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $CM
      (import "" "mem" (memory 1))
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "task.cancel" (func $task.cancel))
      (import "" "future.read" (func $future.read (param i32 i32) (result i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))

      ;; Parks in the event loop by returning WAIT on an empty waitable set.
      ;; No event can ever arrive on that set, so the only thing that can wake
      ;; this task is the pending cancellation request itself.
      (func (export "park") (result i32)
        (i32.or (i32.const 2 (; WAIT ;))
                (i32.shl (call $waitable-set.new) (i32.const 4)))
      )
      (func (export "park-cb") (param i32 i32 i32) (result i32)
        (if (i32.ne (i32.const 6 (; TASK_CANCELLED ;)) (local.get 0))
          (then unreachable))
        (call $task.cancel)
        (i32.const 0 (; EXIT ;))
      )

      ;; Blocks inside its *initial core function*, which means it holds the
      ;; instance's exclusive lock for as long as it is blocked. It blocks on a
      ;; future the caller hasn't written yet, so that it blocks deterministically
      ;; (a bare thread.yield may complete without ever blocking).
      (func (export "hold-lock") (param $futr i32) (result i32)
        (local $ws i32)
        (if (i32.ne (i32.const -1 (; BLOCKED ;))
                    (call $future.read (local.get $futr) (i32.const 0)))
          (then unreachable))
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $futr) (local.get $ws))
        (if (i32.ne (i32.const 4 (; FUTURE_READ ;))
                    (call $waitable-set.wait (local.get $ws) (i32.const 0)))
          (then unreachable))
        (call $task.return (i32.const 43))
        (i32.const 0 (; EXIT ;))
      )

      (func (export "unreachable-cb") (param i32 i32 i32) (result i32)
        unreachable
      )
    )
    (type $FT (future))
    (canon task.return (result u32) (core func $task.return))
    (canon task.cancel (core func $task.cancel))
    (canon future.read $FT async (memory (core memory $memory "mem")) (core func $future.read))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "task.return" (func $task.return))
      (export "task.cancel" (func $task.cancel))
      (export "future.read" (func $future.read))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
    ))))
    (func (export "park") async (result u32) (canon lift
      (core func $cm "park")
      async (callback (core func $cm "park-cb"))
    ))
    (func (export "hold-lock") async (param "fut" $FT) (result u32) (canon lift
      (core func $cm "hold-lock")
      async (callback (core func $cm "unreachable-cb"))
    ))
  )

  (component $D
    (type $FT (future))
    (import "park" (func $park async (result u32)))
    (import "hold-lock" (func $hold-lock async (param "fut" $FT) (result u32)))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $DM
      (import "" "mem" (memory 1))
      (import "" "subtask.cancel" (func $subtask.cancel (param i32) (result i32)))
      (import "" "subtask.drop" (func $subtask.drop (param i32)))
      (import "" "future.new" (func $future.new (result i64)))
      (import "" "future.write" (func $future.write (param i32 i32) (result i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (import "" "park" (func $park (param i32) (result i32)))
      (import "" "hold-lock" (func $hold-lock (param i32 i32) (result i32)))

      (func $run (export "run") (result i32)
        (local $ret i32) (local $ret64 i64)
        (local $sub-park i32) (local $sub-hold i32)
        (local $futr i32) (local $futw i32) (local $ws i32)

        ;; start the task that parks in its event loop; returning WAIT releases
        ;; the exclusive lock, so at this point the lock is free
        (local.set $ret (call $park (i32.const 0)))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $sub-park (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; start the task that takes the exclusive lock and blocks while holding it
        (local.set $ret64 (call $future.new))
        (local.set $futr (i32.wrap_i64 (local.get $ret64)))
        (local.set $futw (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
        (local.set $ret (call $hold-lock (local.get $futr) (i32.const 4)))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $sub-hold (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; cancellation of the parked task can't be delivered while the lock is
        ;; held by the other task, so the request is remembered as pending
        (local.set $ret (call $subtask.cancel (local.get $sub-park)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))

        ;; release the lock holder; the parked task must now be woken and
        ;; receive the pending cancellation, even though the waitable set it is
        ;; waiting on is still empty
        (if (i32.ne (i32.const 0 (; COMPLETED ;))
                    (call $future.write (local.get $futw) (i32.const 0)))
          (then unreachable))

        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $sub-park) (local.get $ws))
        (if (i32.ne (i32.const 1 (; SUBTASK ;))
                    (call $waitable-set.wait (local.get $ws) (i32.const 8)))
          (then unreachable))
        (if (i32.ne (local.get $sub-park) (i32.load (i32.const 8)))
          (then unreachable))
        (if (i32.ne (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)) (i32.load offset=4 (i32.const 8)))
          (then unreachable))
        (call $subtask.drop (local.get $sub-park))

        ;; the lock holder itself returned normally
        (call $waitable.join (local.get $sub-hold) (local.get $ws))
        (if (i32.ne (i32.const 1 (; SUBTASK ;))
                    (call $waitable-set.wait (local.get $ws) (i32.const 8)))
          (then unreachable))
        (if (i32.ne (local.get $sub-hold) (i32.load (i32.const 8)))
          (then unreachable))
        (if (i32.ne (i32.const 2 (; RETURNED ;)) (i32.load offset=4 (i32.const 8)))
          (then unreachable))
        (if (i32.ne (i32.const 43) (i32.load (i32.const 4)))
          (then unreachable))
        (call $subtask.drop (local.get $sub-hold))

        (i32.const 42)
      )
    )
    (canon subtask.cancel async (core func $subtask.cancel))
    (canon subtask.drop (core func $subtask.drop))
    (canon future.new $FT (core func $future.new))
    (canon future.write $FT async (memory (core memory $memory "mem")) (core func $future.write))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (canon lower (func $park) async (memory (core memory $memory "mem")) (core func $park'))
    (canon lower (func $hold-lock) async (memory (core memory $memory "mem")) (core func $hold-lock'))
    (core instance $dm (instantiate $DM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "subtask.cancel" (func $subtask.cancel))
      (export "subtask.drop" (func $subtask.drop))
      (export "future.new" (func $future.new))
      (export "future.write" (func $future.write))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "park" (func $park'))
      (export "hold-lock" (func $hold-lock'))
    ))))
    (func (export "run") async (result u32) (canon lift (core func $dm "run")))
  )

  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "park" (func $c "park"))
    (with "hold-lock" (func $c "hold-lock"))
  ))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 42))
