(component
  (component $C
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $CM
      (import "" "mem" (memory 1))
      (import "" "task.return" (func $return (param i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))

      (global $ws (mut i32) (i32.const 0))
      (func $start (global.set $ws (call $waitable-set.new)))
      (start $start)

      (func (export "f") (result i32)
        (i32.or (i32.const 2 (; WAIT ;)) (i32.shl (global.get $ws) (i32.const 4)))
        ;; (i32.const 1 (; YIELD ;))
      )
      (func (export "cb") (param $event_code i32) (param $index i32) (param $payload i32) (result i32)
        unreachable
        ;; TODO
        ;; (if (i32.ne (i32.const 4 (; FUTURE_READ ;)) (local.get $event_code))
        ;;   (then unreachable))
        (if (i32.ne (i32.const 0 (; NONE ;)) (local.get $event_code))
          (then unreachable))
        (if (i32.ne (i32.const 0) (local.get $index))
          (then unreachable))
        (if (i32.ne (i32.const 0) (local.get $payload))
          (then unreachable))
        
        (call $return (i32.const 42))
        (i32.const 0))
    )
    (canon task.return (result u32) (core func $task.return))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory $memory "mem") (core func $waitable-set.wait))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "task.return" (func $task.return))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
    ))))
    (func (export "f") (result u32) (canon lift
      (core func $cm "f")
      async (memory $memory "mem") (callback (func $cm "cb"))
    ))
  )

  (component $D
    (import "f" (func $f (result u32)))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $DM
      (import "" "mem" (memory 1))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (import "" "f" (func $f (param i32 i32) (result i32)))

      (global $ws (mut i32) (i32.const 0))
      (func $start (global.set $ws (call $waitable-set.new)))
      (start $start)

      (func (export "g") (result i32)
        (local $ret i32) (local $subtaski i32) (local $event_code i32) (local $retp i32)

        ;; call async import
        (local.set $ret (call $f (i32.const 0) (i32.const 0)))
        (if (i32.ne (i32.const 1 (; STARTING ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $subtaski (i32.shr_u (local.get $ret) (i32.const 4)))
        (if (i32.ne (i32.const 2) (local.get $subtaski))
          (then unreachable))

        ;; wait on the subtask
        (call $waitable.join (local.get $subtaski) (global.get $ws))
        (local.set $retp (i32.const 0))
        (local.set $event_code (call $waitable-set.wait (global.get $ws) (local.get $retp)))
        unreachable
        (if (i32.ne (i32.const 1 (; SUBTASK ;)) (local.get $event_code))
          (then unreachable))
        (if (i32.ne (local.get $subtaski) (i32.load (local.get $retp)))
          (then unreachable))
        (if (i32.ne (i32.const 2 (; RETURNED ;)) (i32.load offset=4 (local.get $retp)))
          (then unreachable))

        (i32.const 42)
      )
    )
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory $memory "mem") (core func $waitable-set.wait))
    (canon lower (func $f) async (memory $memory "mem") (core func $f'))
    (core instance $dm (instantiate $DM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "f" (func $f'))
    ))))
    (func (export "f") (result u32) (canon lift (core func $dm "g")))
  )

  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "f" (func $c "f"))))
  (func (export "f") (alias export $d "f"))
)
(assert_return (invoke "f") (u32.const 42))
