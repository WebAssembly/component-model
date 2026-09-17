;; Test that a cancellation request that is *pending* but not yet *delivered*
;; traps if the task tries to call `task.cancel` early.
(component
  (component $C
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $CM
      (import "" "mem" (memory 1))
      (import "" "task.cancel" (func $task.cancel))
      (import "" "future.read" (func $future.read (param i32 i32) (result i32)))

      (func $f (export "f") (param $futr i32)
        (if (i32.ne (call $future.read (local.get $futr) (i32.const 0))
                    (i32.const 0 (; COMPLETED ;)))
          (then unreachable))
        (call $task.cancel) ;; boom
        unreachable
      )
    )
    (type $FT (future))
    (canon task.cancel (core func $task.cancel))
    (canon future.read $FT (memory (core memory $memory "mem")) (core func $future.read))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "task.cancel" (func $task.cancel))
      (export "future.read" (func $future.read))
    ))))
    (func (export "f") async (param "fut" $FT) (canon lift (core func $cm "f") async))
  )

  (component $D
    (type $FT (future))
    (import "f" (func $f async (param "fut" $FT)))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $DM
      (import "" "mem" (memory 1))
      (import "" "subtask.cancel" (func $subtask.cancel (param i32) (result i32)))
      (import "" "future.new" (func $future.new (result i64)))
      (import "" "future.write" (func $future.write (param i32 i32) (result i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (import "" "f" (func $f (param i32) (result i32)))

      (func $run (export "run") (result i32)
        (local $ret64 i64) (local $futr i32) (local $futw i32) (local $ret i32) (local $subtask i32)
        (local $ws i32)
        (local.set $ret64 (call $future.new))
        (local.set $futr (i32.wrap_i64 (local.get $ret64)))
        (local.set $futw (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))

        ;; call f; it blocks in the sync future.read
        (local.set $ret (call $f (local.get $futr)))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; cancel; deterministically BLOCKED since the callee is blocked in
        ;; its initial core function and cannot receive the request
        (if (i32.ne (call $subtask.cancel (local.get $subtask)) (i32.const -1 (; BLOCKED ;)))
          (then unreachable))

        ;; write the future, unblocking the callee, which now calls
        ;; task.cancel directly while its cancellation is still pending; per
        ;; spec this must trap before the callee ever resolves
        (if (i32.ne (call $future.write (local.get $futw) (i32.const 0)) (i32.const 0 (; COMPLETED ;)))
          (then unreachable))

        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $subtask) (local.get $ws))
        (drop (call $waitable-set.wait (local.get $ws) (i32.const 8)))
        (i32.const 42)
      )
    )
    (canon subtask.cancel async (core func $subtask.cancel))
    (canon future.new $FT (core func $future.new))
    (canon future.write $FT async (memory (core memory $memory "mem")) (core func $future.write))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (canon lower (func $f) async (memory (core memory $memory "mem")) (core func $f'))
    (core instance $dm (instantiate $DM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "subtask.cancel" (func $subtask.cancel))
      (export "future.new" (func $future.new))
      (export "future.write" (func $future.write))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "f" (func $f'))
    ))))
    (func (export "run") async (result u32) (canon lift (core func $dm "run")))
  )

  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "f" (func $c "f"))))
  (func (export "run") (alias export $d "run"))
)
(assert_trap (invoke "run") "`task.cancel` called by task which has not been cancelled")
