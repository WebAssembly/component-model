;; The resume performed by 'subtask.cancel' may pick any ready thread of the
;; callee's instance, not just a thread of the task being cancelled. This test
;; forces that distinction by arranging for the only ready thread in $C to
;; belong to a different task than the one being cancelled.
;;
;; At least one resume always happens, so hold-lock always runs to completion
;; here, which the caller observes by polling. Whether the host then keeps
;; resuming threads is nondeterministic: it may stop there, in which case the
;; cancel reports BLOCKED and park is woken later once the caller blocks, or it
;; may go on to resume park (now that hold-lock has released the lock) and
;; report CANCELLED_BEFORE_RETURNED eagerly.
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

      ;; Parks in the event loop on a waitable set that never gets an event, so
      ;; only the delivery of a pending cancellation can wake this task which
      ;; cannot happen while the exclusive lock is held.
      (global $never (mut i32) (i32.const 0))
      (func $start (global.set $never (call $waitable-set.new)))
      (start $start)
      (func (export "park") (result i32)
        (i32.or (i32.const 2 (; WAIT ;)) (i32.shl (global.get $never) (i32.const 4))))
      (func (export "park-cb") (param $event i32) (param i32 i32) (result i32)
        (if (i32.ne (local.get $event) (i32.const 6 (; TASK_CANCELLED ;)))
          (then unreachable))
        (call $task.cancel)
        (i32.const 0 (; EXIT ;)))

      ;; Blocks holding the instance's exclusive lock for as long as it is
      ;; blocked. Once the caller writes the future, this task's thread is ready
      ;; but the lock is still held.
      (func (export "hold-lock") (param $futr i32) (result i32)
        (local $ws i32)
        (if (i32.ne (i32.const -1 (; BLOCKED ;))
                    (call $future.read (local.get $futr) (i32.const 0)))
          (then unreachable))
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $futr) (local.get $ws))
        (if (i32.ne (i32.const 4 (; FUTURE_READ ;))
                    (call $waitable-set.wait (local.get $ws) (i32.const 8)))
          (then unreachable))
        (call $task.return (i32.const 43))
        (i32.const 0 (; EXIT ;)))
      (func (export "unreachable-cb") (param i32 i32 i32) (result i32)
        unreachable)
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
      (export "waitable-set.wait" (func $waitable-set.wait))))))
    (func (export "park") async
      (canon lift (core func $cm "park") async (callback (core func $cm "park-cb"))))
    (func (export "hold-lock") async (param "fut" $FT) (result u32)
      (canon lift (core func $cm "hold-lock") async (callback (core func $cm "unreachable-cb"))))
  )
  (instance $c (instantiate $C))
  (core module $Memory (memory (export "mem") 1))
  (core instance $memory (instantiate $Memory))
  (type $FT (future))
  (canon future.new $FT (core func $future.new))
  (canon future.write $FT (memory (core memory $memory "mem")) (core func $future.write))
  (canon lower (func $c "park") async (core func $park'))
  (canon lower (func $c "hold-lock") async (memory (core memory $memory "mem")) (core func $hold-lock'))
  (canon subtask.cancel async (core func $subtask.cancel-async))
  (canon subtask.drop (core func $subtask.drop))
  (canon waitable.join (core func $waitable.join))
  (canon waitable-set.new (core func $waitable-set.new))
  (canon waitable-set.poll (memory (core memory $memory "mem")) (core func $waitable-set.poll))
  (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))

  (core module $Main
    (import "" "mem" (memory 1))
    (import "" "future.new" (func $future.new (result i64)))
    (import "" "future.write" (func $future.write (param i32 i32) (result i32)))
    (import "" "park" (func $park (result i32)))
    (import "" "hold-lock" (func $hold-lock (param i32 i32) (result i32)))
    (import "" "subtask.cancel-async" (func $subtask.cancel-async (param i32) (result i32)))
    (import "" "subtask.drop" (func $subtask.drop (param i32)))
    (import "" "waitable.join" (func $waitable.join (param i32 i32)))
    (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
    (import "" "waitable-set.poll" (func $waitable-set.poll (param i32 i32) (result i32)))
    (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
    (func (export "run") (result i32)
      (local $ret64 i64) (local $futr i32) (local $futw i32)
      (local $packed i32) (local $ret i32)
      (local $park-sub i32) (local $hold-sub i32)
      (local $park-ws i32) (local $hold-ws i32)

      ;; start "park"; returning WAIT releases the lock, so it is free here
      (local.set $packed (call $park))
      (if (i32.ne (i32.and (local.get $packed) (i32.const 0xf)) (i32.const 1 (; STARTED ;)))
        (then unreachable))
      (local.set $park-sub (i32.shr_u (local.get $packed) (i32.const 4)))

      ;; start hold-lock; it takes the lock and blocks while holding it
      (local.set $ret64 (call $future.new))
      (local.set $futr (i32.wrap_i64 (local.get $ret64)))
      (local.set $futw (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
      (local.set $packed (call $hold-lock (local.get $futr) (i32.const 24)))
      (if (i32.ne (i32.and (local.get $packed) (i32.const 0xf)) (i32.const 1 (; STARTED ;)))
        (then unreachable))
      (local.set $hold-sub (i32.shr_u (local.get $packed) (i32.const 4)))
      (local.set $hold-ws (call $waitable-set.new))
      (call $waitable.join (local.get $hold-sub) (local.get $hold-ws))

      ;; complete the read: hold-lock's thread is now ready, but it still
      ;; holds the lock and nothing has resumed it
      (if (i32.ne (i32.const 0 (; COMPLETED ;))
                  (call $future.write (local.get $futw) (i32.const 16)))
        (then unreachable))
      (if (i32.ne (call $waitable-set.poll (local.get $hold-ws) (i32.const 0))
                  (i32.const 0 (; NONE ;)))
        (then unreachable))

      ;; cancel park: its own thread is not ready while the lock is held, so
      ;; the only candidate belongs to hold-lock
      (local.set $ret (call $subtask.cancel-async (local.get $park-sub)))

      ;; hold-lock must have been resumed by the cancel and run to completion
      (if (i32.ne (call $waitable-set.poll (local.get $hold-ws) (i32.const 0))
                  (i32.const 1 (; SUBTASK ;)))
        (then unreachable))
      (if (i32.ne (i32.load (i32.const 0)) (local.get $hold-sub))
        (then unreachable))
      (if (i32.ne (i32.load (i32.const 4)) (i32.const 2 (; RETURNED ;)))
        (then unreachable))
      (if (i32.ne (i32.load (i32.const 24)) (i32.const 43))
        (then unreachable))
      (call $waitable.join (local.get $hold-sub) (i32.const 0))
      (call $subtask.drop (local.get $hold-sub))

      ;; if the host stopped after resuming hold-lock, the request is still
      ;; only pending; with the lock now free, blocking lets park receive it
      (if (i32.eq (local.get $ret) (i32.const -1 (; BLOCKED ;)))
        (then
          (local.set $park-ws (call $waitable-set.new))
          (call $waitable.join (local.get $park-sub) (local.get $park-ws))
          (if (i32.ne (call $waitable-set.wait (local.get $park-ws) (i32.const 0))
                      (i32.const 1 (; SUBTASK ;)))
            (then unreachable))
          (if (i32.ne (i32.load (i32.const 0)) (local.get $park-sub))
            (then unreachable))
          (local.set $ret (i32.load (i32.const 4)))
          (call $waitable.join (local.get $park-sub) (i32.const 0))))
      (if (i32.ne (local.get $ret) (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)))
        (then unreachable))
      (call $subtask.drop (local.get $park-sub))
      (i32.const 42))
  )
  (core instance $main (instantiate $Main (with "" (instance
    (export "mem" (memory $memory "mem"))
    (export "future.new" (func $future.new))
    (export "future.write" (func $future.write))
    (export "park" (func $park'))
    (export "hold-lock" (func $hold-lock'))
    (export "subtask.cancel-async" (func $subtask.cancel-async))
    (export "subtask.drop" (func $subtask.drop))
    (export "waitable.join" (func $waitable.join))
    (export "waitable-set.new" (func $waitable-set.new))
    (export "waitable-set.poll" (func $waitable-set.poll))
    (export "waitable-set.wait" (func $waitable-set.wait))))))
  (func (export "run") async (result u32) (canon lift (core func $main "run")))
)
(assert_return (invoke "run") (u32.const 42))
