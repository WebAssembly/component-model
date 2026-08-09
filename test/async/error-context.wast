;; Port of Wasmtime's async_error_context test.
;; Exercises error-context.new and error-context.debug-message without trapping.
;; The debug message contents are intentionally not asserted (nondeterministic per spec).
(component
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

    (func $run (export "run")
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
  (func (export "run") async (canon lift (core func $cm "run")))
)
(invoke "run")
