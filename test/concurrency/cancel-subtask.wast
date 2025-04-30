;; This test contains two components $C and $D where $D imports and calls $C.
;;  $D.run calls $C.f, which blocks on an empty waitable set
;;  $D.run then subtask.cancels $C.f, which resumes $C.f which promptly resolves
;;    without returning a value.
(component
  (component $C
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $CM
      (import "" "mem" (memory 1))
      (import "" "task.cancel" (func $task.cancel))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))

      ;; $ws is waited on by 'f'
      (global $ws (mut i32) (i32.const 0))
      (func $start (global.set $ws (call $waitable-set.new)))
      (start $start)

      (func $f (export "f") (result i32)
        ;; wait on $ws which is currently empty, expected to get cancelled
        (i32.or (i32.const 2 (; WAIT ;)) (i32.shl (global.get $ws) (i32.const 4)))
      )
      (func $f_cb (export "f_cb") (param $event_code i32) (param $index i32) (param $payload i32) (result i32)
        ;; confirm that we've received a cancellation request
        (if (i32.ne (local.get $event_code) (i32.const 6 (; TASK_CANCELLED ;)))
          (then unreachable))
        (if (i32.ne (local.get $index) (i32.const 0))
          (then unreachable))
        (if (i32.ne (local.get $payload) (i32.const 0))
          (then unreachable))

        ;; finish without returning a value
        (call $task.cancel)
        (i32.const 0 (; EXIT ;))
      )
    )
    (canon task.cancel (core func $task.cancel))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "task.cancel" (func $task.cancel))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
    ))))
    (func (export "f") (result u32) (canon lift
      (core func $cm "f")
      async (callback (func $cm "f_cb"))
    ))
  )

  (component $D
    (import "f" (func $f (result u32)))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $DM
      (import "" "mem" (memory 1))
      (import "" "subtask.cancel" (func $subtask.cancel (param i32) (result i32)))
      (import "" "subtask.drop" (func $subtask.drop (param i32)))
      (import "" "f" (func $f (param i32 i32) (result i32)))

      (func $run (export "run") (result i32)
        (local $ret i32) (local $retp i32)
        (local $subtask i32)
        (local $event_code i32)

        ;; call 'f'; it should block
        (local.set $retp (i32.const 4))
        (i32.store (local.get $retp) (i32.const 0xbad0bad0))
        (local.set $ret (call $f (i32.const 0xdeadbeef) (local.get $retp)))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; cancel 'f'; it should complete without blocking
        (local.set $ret (call $subtask.cancel (local.get $subtask)))
        (if (i32.ne (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)) (local.get $ret))
          (then unreachable))

        ;; The $retp memory shouldn't have changed
        (if (i32.ne (i32.load (local.get $retp)) (i32.const 0xbad0bad0))
          (then unreachable))

        (call $subtask.drop (local.get $subtask))

        ;; return to the top-level assert_return
        (i32.const 42)
      )
    )
    (canon subtask.cancel (core func $subtask.cancel))
    (canon subtask.drop (core func $subtask.drop))
    (canon lower (func $f) async (memory $memory "mem") (core func $f'))
    (core instance $dm (instantiate $DM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "subtask.cancel" (func $subtask.cancel))
      (export "subtask.drop" (func $subtask.drop))
      (export "f" (func $f'))
    ))))
    (func (export "run") (result u32) (canon lift (core func $dm "run")))
  )

  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "f" (func $c "f"))))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 42))
