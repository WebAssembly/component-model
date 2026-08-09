;; Port of Wasmtime's async_error_context test.
;;
;; Component $C exports async run(), which creates an error-context, calls
;; error-context.debug-message, and drops it. The debug message contents are
;; intentionally not asserted (nondeterministic per spec).
;;
;; Component $D mirrors Wasmtime's test_run_with_count(..., 3): it starts three
;; concurrent $C.run subtasks before joining them, matching host-side
;; run_concurrent over the same guest component.
(component
  (component $C
    (core module $Memory
      (memory (export "mem") 1)
      (func (export "realloc") (param i32 i32 i32 i32) (result i32)
        i32.const 0 ;; cheat -- there's never more than 1 allocation alive
      )
    )
    (core instance $memory (instantiate $Memory))
    (core module $CM
      (import "" "mem" (memory 1))
      (import "" "task.return" (func $task.return))
      (import "" "error-context.new" (func $error-context.new (param i32 i32) (result i32)))
      (import "" "error-context.debug-message" (func $error-context.debug-message (param i32 i32)))
      (import "" "error-context.drop" (func $error-context.drop (param i32)))

      (func $run (export "run") (result i32)
        (i32.const 1 (; YIELD ;))
      )
      (func $run_cb (export "run_cb") (param i32 i32 i32) (result i32)
        (local $errctx i32)

        ;; store UTF-8 "error" at offset 32
        (i32.store8 (i32.const 32) (i32.const 0x65))
        (i32.store8 (i32.const 33) (i32.const 0x72))
        (i32.store8 (i32.const 34) (i32.const 0x72))
        (i32.store8 (i32.const 35) (i32.const 0x6f))
        (i32.store8 (i32.const 36) (i32.const 0x72))

        (local.set $errctx (call $error-context.new (i32.const 32) (i32.const 5)))
        (call $error-context.debug-message (local.get $errctx) (i32.const 8))
        (call $error-context.drop (local.get $errctx))

        (call $task.return)
        (i32.const 0 (; EXIT ;))
      )
    )
    (canon task.return (core func $task.return))
    (canon error-context.new (memory $memory "mem") (core func $error-context.new))
    (canon error-context.debug-message (memory $memory "mem") (realloc (func $memory "realloc")) (core func $error-context.debug-message))
    (canon error-context.drop (core func $error-context.drop))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "task.return" (func $task.return))
      (export "error-context.new" (func $error-context.new))
      (export "error-context.debug-message" (func $error-context.debug-message))
      (export "error-context.drop" (func $error-context.drop))
    ))))
    (func (export "run") async (canon lift
      (core func $cm "run") async (memory $memory "mem") (callback (func $cm "run_cb"))
    ))
  )

  (component $D
    (import "c" (instance $c (export "run" (func async))))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $DM
      (import "" "mem" (memory 1))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (import "" "subtask.drop" (func $subtask.drop (param i32)))
      (import "" "run" (func $run (result i32)))

      (func $start-run (param $ws i32) (param $remainp i32)
        (local $ret i32) (local $st i32) (local $subtask i32)
        (local.set $ret (call $run))
        (local.set $st (i32.and (local.get $ret) (i32.const 0xf)))
        (if (i32.eq (local.get $st) (i32.const 1 (; STARTED ;))) (then
          (local.set $subtask (i32.shr_u (local.get $ret) (i32.const 4)))
          (call $waitable.join (local.get $subtask) (local.get $ws))
          (i32.store (local.get $remainp) (i32.add (i32.load (local.get $remainp)) (i32.const 1)))
        ) (else
          (if (i32.ne (local.get $st) (i32.const 2 (; RETURNED ;)))
            (then unreachable))
        ))
      )

      (func $test (export "test") (result i32)
        (local $ws i32)
        (local $remain i32)
        (local $event i32)
        (local $subtask i32)

        (local.set $ws (call $waitable-set.new))
        (i32.store (i32.const 0) (i32.const 0))

        ;; Start 3 concurrent calls before waiting for any of them.
        (call $start-run (local.get $ws) (i32.const 0))
        (call $start-run (local.get $ws) (i32.const 0))
        (call $start-run (local.get $ws) (i32.const 0))
        (local.set $remain (i32.load (i32.const 0)))

        (block $done
          (loop $wait
            (if (i32.eqz (local.get $remain)) (then br $done))
            (local.set $event (call $waitable-set.wait (local.get $ws) (i32.const 4)))
            (if (i32.ne (i32.const 1 (; SUBTASK ;)) (local.get $event))
              (then unreachable))
            (local.set $subtask (i32.load (i32.const 4)))
            (if (i32.ne (i32.const 2 (; RETURNED ;)) (i32.load (i32.const 8)))
              (then unreachable))
            (call $subtask.drop (local.get $subtask))
            (local.set $remain (i32.sub (local.get $remain) (i32.const 1)))
            br $wait
          )
        )

        (i32.const 42)
      )
    )
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory $memory "mem") (core func $waitable-set.wait))
    (canon subtask.drop (core func $subtask.drop))
    (canon lower (func $c "run") async (memory $memory "mem") (core func $run'))
    (core instance $dm (instantiate $DM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "subtask.drop" (func $subtask.drop))
      (export "run" (func $run'))
    ))))
    (func (export "test") async (result u32) (canon lift (core func $dm "test")))
  )

  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "c" (instance $c))))
  (func (export "test") (alias export $d "test"))
)
(assert_return (invoke "test") (u32.const 42))