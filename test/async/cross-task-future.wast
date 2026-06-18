;; This exercises that future ends are not tied to the task that created them.
(component
  (component $C
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $CM
      (import "" "mem" (memory 1))
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "future.new" (func $future.new (result i64)))
      (import "" "future.write" (func $future.write (param i32 i32) (result i32)))

      (global $futr (mut i32) (i32.const 0))
      (global $futw (mut i32) (i32.const 0))

      (func $one (export "one")
        (local $ret i32) (local $ret64 i64)
        (local.set $ret64 (call $future.new))
        (global.set $futr (i32.wrap_i64 (local.get $ret64)))
        (global.set $futw (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
      )
      (func $two (export "two") (result i32)
        (local $ret i32) (local $ptr i32)
        (call $task.return (global.get $futr))
        (local.set $ptr (i32.const 32))
        (i32.store (local.get $ptr) (i32.const 0x42))
        (local.set $ret (call $future.write (global.get $futw) (local.get $ptr)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))
        (i32.const 0 (; EXIT ;))
      )
      (func $two_cb (export "two_cb") (param i32 i32 i32) (result i32)
        unreachable
      )
    )
    (type $FT (future u8))
    (canon task.return (result $FT) (core func $task.return))
    (canon future.new $FT (core func $future.new))
    (canon future.write $FT async (memory $memory "mem") (core func $future.write))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "task.return" (func $task.return))
      (export "future.new" (func $future.new))
      (export "future.write" (func $future.write))
    ))))
    (func (export "one") (canon lift
      (core func $cm "one")
    ))
    (func (export "two") async (result (future u8)) (canon lift
      (core func $cm "two")
      async (callback (func $cm "two_cb"))
    ))
  )

  (component $D
    (import "c" (instance $c
      (export "one" (func))
      (export "two" (func async (result (future u8))))
    ))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $DM
      (import "" "mem" (memory 1))
      (import "" "future.read" (func $future.read (param i32 i32) (result i32)))
      (import "" "one" (func $one))
      (import "" "two" (func $two (result i32)))

      (func $run (export "run") (result i32)
        (local $ret i32)
        (local $retp i32)
        (local $futr i32)

        (call $one)
        (local.set $futr (call $two))
        (local.set $retp (i32.const 32))
        (local.set $ret (call $future.read (local.get $futr) (local.get $retp)))
        (if (i32.ne (i32.const 0 (; COMPLETED ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (i32.load8_u (local.get $retp)) (i32.const 0x42))
          (then unreachable))

        (i32.const 42)
      )
    )
    (type $FT (future u8))
    (canon future.read $FT async (memory $memory "mem") (core func $future.read))
    (canon lower (func $c "one") (core func $one'))
    (canon lower (func $c "two") (core func $two'))
    (core instance $dm (instantiate $DM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "future.read" (func $future.read))
      (export "one" (func $one'))
      (export "two" (func $two'))
    ))))
    (func (export "run") async (result u32) (canon lift (core func $dm "run")))
  )

  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "c" (instance $c))))
  (func (export "run") (alias export $d "run"))
)

(assert_return (invoke "run") (u32.const 42))
