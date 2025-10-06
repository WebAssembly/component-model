;; This test calls waitable-set.wait from under an async-callback-lifted export.
(component
  (core module $Memory (memory (export "mem") 1))
  (core instance $memory (instantiate $Memory))
  (core module $CM
    (import "" "mem" (memory 1))
    (import "" "task.return" (func $task.return (param i32)))
    (import "" "waitable.join" (func $waitable.join (param i32 i32)))
    (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
    (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
    (import "" "future.new" (func $future.new (result i64)))
    (import "" "future.read" (func $future.read (param i32 i32) (result i32)))
    (import "" "future.write" (func $future.write (param i32 i32) (result i32)))

    (func $run (export "run") (result i32)
      (local $ret i32) (local $ret64 i64)
      (local $futr i32) (local $futw i32) (local $ws i32)
      (local $event_code i32) (local $retp i32)

      ;; create a future pair
      (local.set $ret64 (call $future.new))
      (local.set $futr (i32.wrap_i64 (local.get $ret64)))
      (local.set $futw (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))

      ;; start a pending read that will block
      (local.set $ret (call $future.read (local.get $futr) (i32.const 0xdeadbeef)))
      (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
        (then unreachable))

      ;; perform a write to make the above read ready
      (local.set $ret (call $future.write (local.get $futw) (i32.const 0xdeadbeef)))
      (if (i32.ne (i32.const 0 (; COMPLETED ;)) (local.get $ret))
        (then unreachable))

      ;; wait on a waitable set containing our now-ready future.read which
      ;; should then immediately resolve
      (local.set $ws (call $waitable-set.new))
      (call $waitable.join (local.get $futr) (local.get $ws))
      (local.set $retp (i32.const 0))
      (local.set $event_code (call $waitable-set.wait (local.get $ws) (local.get $retp)))
      (if (i32.ne (i32.const 4 (; FUTURE_READ ;)) (local.get $event_code))
        (then unreachable))
      (if (i32.ne (local.get $futr) (i32.load (local.get $retp)))
        (then unreachable))

      ;; return 42
      (call $task.return (i32.const 42))
      (i32.const 0 (; EXIT ;))
    )
    (func (export "run_cb") (param i32 i32 i32) (result i32)
      unreachable
    )
  )
  (type $FT (future))
  (canon task.return (result u32) (core func $task.return))
  (canon waitable.join (core func $waitable.join))
  (canon waitable-set.new (core func $waitable-set.new))
  (canon waitable-set.wait (memory $memory "mem") (core func $waitable-set.wait))
  (canon future.new $FT (core func $future.new))
  (canon future.read $FT async (core func $future.read))
  (canon future.write $FT async (core func $future.write))
  (core instance $cm (instantiate $CM (with "" (instance
    (export "mem" (memory $memory "mem"))
    (export "task.return" (func $task.return))
    (export "waitable.join" (func $waitable.join))
    (export "waitable-set.new" (func $waitable-set.new))
    (export "waitable-set.wait" (func $waitable-set.wait))
    (export "future.new" (func $future.new))
    (export "future.read" (func $future.read))
    (export "future.write" (func $future.write))
  ))))
  (func (export "run") (result u32) (canon lift
    (core func $cm "run")
    async (callback (func $cm "run_cb"))
  ))
)
(assert_return (invoke "run") (u32.const 42))
