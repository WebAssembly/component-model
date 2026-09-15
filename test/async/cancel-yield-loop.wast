;; 'subtask.cancel' may keep resuming ready threads of the callee's instance
;; until the cancelled task resolves, but it is only *allowed* to, never
;; required to: the host may stop at any point. This test checks that, given an
;; infinite yield loop, the host eventually declares the cancellation blocked.
(component
  (component $C
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $CM
      (import "" "mem" (memory 1))
      (import "" "task.cancel" (func $task.cancel))
      (import "" "future.read" (func $future.read (param i32 i32) (result i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.poll" (func $waitable-set.poll (param i32 i32) (result i32)))
      (global $ws (mut i32) (i32.const 0))
      (global $cancelled (mut i32) (i32.const 0))

      (func (export "yielder") (param $futr i32) (result i32)
        (if (i32.ne (i32.const -1 (; BLOCKED ;))
                    (call $future.read (local.get $futr) (i32.const 0)))
          (then unreachable))
        (global.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $futr) (global.get $ws))
        (i32.const 1 (; YIELD ;)))

      (func (export "yielder-cb") (param $event i32) (param i32 i32) (result i32)
        ;; A delivered cancellation is remembered but cannot be acted on yet:
        ;; this task must first see its future read complete.
        (if (i32.eq (local.get $event) (i32.const 6 (; TASK_CANCELLED ;)))
          (then
            (if (global.get $cancelled) (then unreachable))
            (global.set $cancelled (i32.const 1))
            (return (i32.const 1 (; YIELD ;)))))
        (if (i32.ne (local.get $event) (i32.const 0 (; NONE ;)))
          (then unreachable))
        ;; Keep spinning until the caller writes the future. Every turn of this
        ;; loop leaves the thread ready again, so a host that resumed until the
        ;; task resolved would never get here.
        (if (i32.eq (i32.const 0 (; NONE ;))
                    (call $waitable-set.poll (global.get $ws) (i32.const 8)))
          (then (return (i32.const 1 (; YIELD ;)))))
        ;; the read completed; the cancellation must already have arrived
        (if (i32.eqz (global.get $cancelled)) (then unreachable))
        (call $task.cancel)
        (i32.const 0 (; EXIT ;)))
    )
    (type $FT (future))
    (canon task.cancel (core func $task.cancel))
    (canon future.read $FT async (memory (core memory $memory "mem")) (core func $future.read))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.poll (memory (core memory $memory "mem")) (core func $waitable-set.poll))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "task.cancel" (func $task.cancel))
      (export "future.read" (func $future.read))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.poll" (func $waitable-set.poll))))))
    (func (export "yielder") async (param "fut" $FT)
      (canon lift (core func $cm "yielder") async (callback (core func $cm "yielder-cb"))))
  )
  (instance $c (instantiate $C))
  (core module $Memory (memory (export "mem") 1))
  (core instance $memory (instantiate $Memory))
  (type $FT (future))
  (canon future.new $FT (core func $future.new))
  (canon future.write $FT (memory (core memory $memory "mem")) (core func $future.write))
  (canon lower (func $c "yielder") async (core func $yielder'))
  (canon subtask.cancel async (core func $subtask.cancel-async))
  (canon subtask.drop (core func $subtask.drop))
  (canon waitable.join (core func $waitable.join))
  (canon waitable-set.new (core func $waitable-set.new))
  (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))

  (core module $Main
    (import "" "mem" (memory 1))
    (import "" "future.new" (func $future.new (result i64)))
    (import "" "future.write" (func $future.write (param i32 i32) (result i32)))
    (import "" "yielder" (func $yielder (param i32) (result i32)))
    (import "" "subtask.cancel-async" (func $subtask.cancel-async (param i32) (result i32)))
    (import "" "subtask.drop" (func $subtask.drop (param i32)))
    (import "" "waitable.join" (func $waitable.join (param i32 i32)))
    (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
    (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
    (func (export "run") (result i32)
      (local $ret64 i64) (local $futr i32) (local $futw i32)
      (local $packed i32) (local $sub i32) (local $ws i32)
      (local.set $ret64 (call $future.new))
      (local.set $futr (i32.wrap_i64 (local.get $ret64)))
      (local.set $futw (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))

      (local.set $packed (call $yielder (local.get $futr)))
      (if (i32.ne (i32.and (local.get $packed) (i32.const 0xf)) (i32.const 1 (; STARTED ;)))
        (then unreachable))
      (local.set $sub (i32.shr_u (local.get $packed) (i32.const 4)))

      ;; The callee cannot resolve until this task writes the future, which it
      ;; cannot do from inside the call, so the cancel must give up and report
      ;; BLOCKED rather than resuming the yield loop forever.
      (if (i32.ne (call $subtask.cancel-async (local.get $sub))
                  (i32.const -1 (; BLOCKED ;)))
        (then unreachable))

      ;; now let the yield loop see its read complete and resolve
      (if (i32.ne (i32.const 0 (; COMPLETED ;))
                  (call $future.write (local.get $futw) (i32.const 16)))
        (then unreachable))
      (local.set $ws (call $waitable-set.new))
      (call $waitable.join (local.get $sub) (local.get $ws))
      (if (i32.ne (call $waitable-set.wait (local.get $ws) (i32.const 0))
                  (i32.const 1 (; SUBTASK ;)))
        (then unreachable))
      (if (i32.ne (i32.load (i32.const 0)) (local.get $sub))
        (then unreachable))
      (if (i32.ne (i32.load (i32.const 4)) (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)))
        (then unreachable))
      (call $waitable.join (local.get $sub) (i32.const 0))
      (call $subtask.drop (local.get $sub))
      (i32.const 42))
  )
  (core instance $main (instantiate $Main (with "" (instance
    (export "mem" (memory $memory "mem"))
    (export "future.new" (func $future.new))
    (export "future.write" (func $future.write))
    (export "yielder" (func $yielder'))
    (export "subtask.cancel-async" (func $subtask.cancel-async))
    (export "subtask.drop" (func $subtask.drop))
    (export "waitable.join" (func $waitable.join))
    (export "waitable-set.new" (func $waitable-set.new))
    (export "waitable-set.wait" (func $waitable-set.wait))))))
  (func (export "run") async (result u32) (canon lift (core func $main "run")))
)
(assert_return (invoke "run") (u32.const 42))
