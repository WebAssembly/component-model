;; This test exercises the 'cancellable' immediate on waitable-set.wait,
;; waitable-set.poll, and thread.yield.
;;
;; Component $C exports five async callback-lifted functions that block in
;; their initial core function (the callbacks are never invoked):
;;   wait-cancel: blocks on cancellable waitable-set.wait, expects TASK_CANCELLED
;;   poll-cancel: blocks on cancellable waitable-set.poll, expects TASK_CANCELLED
;;   yield-cancel: yields with cancellable, caller cancels during yield
;;   poll-cancel-pending: blocks on non-cancellable wait, then polls with cancellable
;;   yield-cancel-pending: blocks on non-cancellable wait, then yields with cancellable
;;
;; Component $D calls each function and cancels it, verifying the cancel is
;; delivered correctly through the cancellable built-in in each case.
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
      (import "" "waitable-set.wait-cancellable" (func $waitable-set.wait-cancellable (param i32 i32) (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (import "" "waitable-set.poll-cancellable" (func $waitable-set.poll-cancellable (param i32 i32) (result i32)))
      (import "" "thread.yield-cancellable" (func $thread.yield-cancellable (result i32)))

      ;; Test 1: direct cancel delivery through cancellable waitable-set.wait
      (func $wait-cancel (export "wait-cancel") (result i32)
        (local $event_code i32)
        (local $ws i32)
        (local.set $ws (call $waitable-set.new))
        ;; wait on empty waitable set with cancellable; blocks until cancelled
        (local.set $event_code (call $waitable-set.wait-cancellable (local.get $ws) (i32.const 0)))
        (if (i32.ne (local.get $event_code) (i32.const 6 (; TASK_CANCELLED ;)))
          (then unreachable))
        (call $task.cancel)
        (i32.const 0 (; EXIT ;))
      )

      ;; Test 2: direct cancel delivery through cancellable waitable-set.poll
      (func $poll-cancel (export "poll-cancel") (result i32)
        (local $ws i32)
        (local $event_code i32)
        (local.set $ws (call $waitable-set.new))
        ;; poll on empty waitable set with cancellable; blocks until cancelled
        (local.set $event_code (call $waitable-set.poll-cancellable (local.get $ws) (i32.const 0)))
        (if (i32.ne (local.get $event_code) (i32.const 6 (; TASK_CANCELLED ;)))
          (then unreachable))
        (call $task.cancel)
        (i32.const 0 (; EXIT ;))
      )

      ;; Test 3: direct cancel delivery through cancellable thread.yield
      (func $yield-cancel (export "yield-cancel") (result i32)
        (local $ret i32)
        ;; yield with cancellable; suspends with cancellable=true, caller cancels
        (local.set $ret (call $thread.yield-cancellable))
        (if (i32.ne (i32.const 1 (; CANCELLED ;)) (local.get $ret))
          (then unreachable))
        (call $task.cancel)
        (i32.const 0 (; EXIT ;))
      )

      ;; Test 4: deferred cancel delivered through cancellable waitable-set.poll
      (func $poll-cancel-pending (export "poll-cancel-pending") (param $futr i32) (result i32)
        (local $ws i32)
        (local $ret i32)
        (local $event_code i32)
        (local.set $ws (call $waitable-set.new))
        ;; read future - blocks (caller hasn't written yet)
        (local.set $ret (call $future.read (local.get $futr) (i32.const 0)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))
        (call $waitable.join (local.get $futr) (local.get $ws))
        ;; wait WITHOUT cancellable - cancel will be deferred as PENDING_CANCEL
        (local.set $event_code (call $waitable-set.wait (local.get $ws) (i32.const 0)))
        (if (i32.ne (i32.const 4 (; FUTURE_READ ;)) (local.get $event_code))
          (then unreachable))
        ;; poll WITH cancellable - delivers the pending cancel
        (local.set $event_code (call $waitable-set.poll-cancellable (local.get $ws) (i32.const 0)))
        (if (i32.ne (i32.const 6 (; TASK_CANCELLED ;)) (local.get $event_code))
          (then unreachable))
        (call $task.cancel)
        (i32.const 0 (; EXIT ;))
      )

      ;; Test 5: deferred cancel delivered through cancellable thread.yield
      (func $yield-cancel-pending (export "yield-cancel-pending") (param $futr i32) (result i32)
        (local $ws i32)
        (local $ret i32)
        (local $event_code i32)
        (local.set $ws (call $waitable-set.new))
        ;; read future - blocks (caller hasn't written yet)
        (local.set $ret (call $future.read (local.get $futr) (i32.const 0)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))
        (call $waitable.join (local.get $futr) (local.get $ws))
        ;; wait WITHOUT cancellable - cancel will be deferred as PENDING_CANCEL
        (local.set $event_code (call $waitable-set.wait (local.get $ws) (i32.const 0)))
        (if (i32.ne (i32.const 4 (; FUTURE_READ ;)) (local.get $event_code))
          (then unreachable))
        ;; yield WITH cancellable - delivers the pending cancel
        (local.set $ret (call $thread.yield-cancellable))
        (if (i32.ne (i32.const 1 (; CANCELLED ;)) (local.get $ret))
          (then unreachable))
        (call $task.cancel)
        (i32.const 0 (; EXIT ;))
      )

      ;; callback that should never be called
      (func (export "unreachable-cb") (param i32 i32 i32) (result i32)
        unreachable
      )
    )
    (type $FT (future))
    (canon task.cancel (core func $task.cancel))
    (canon future.read $FT async (memory $memory "mem") (core func $future.read))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait cancellable (memory $memory "mem") (core func $waitable-set.wait-cancellable))
    (canon waitable-set.wait (memory $memory "mem") (core func $waitable-set.wait))
    (canon waitable-set.poll cancellable (memory $memory "mem") (core func $waitable-set.poll-cancellable))
    (canon thread.yield cancellable (core func $thread.yield-cancellable))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "task.cancel" (func $task.cancel))
      (export "future.read" (func $future.read))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait-cancellable" (func $waitable-set.wait-cancellable))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "waitable-set.poll-cancellable" (func $waitable-set.poll-cancellable))
      (export "thread.yield-cancellable" (func $thread.yield-cancellable))
    ))))
    (func (export "wait-cancel") async (result u32) (canon lift
      (core func $cm "wait-cancel")
      async (callback (func $cm "unreachable-cb"))
    ))
    (func (export "poll-cancel") async (result u32) (canon lift
      (core func $cm "poll-cancel")
      async (callback (func $cm "unreachable-cb"))
    ))
    (func (export "yield-cancel") async (result u32) (canon lift
      (core func $cm "yield-cancel")
      async (callback (func $cm "unreachable-cb"))
    ))
    (func (export "poll-cancel-pending") async (param "fut" $FT) (result u32) (canon lift
      (core func $cm "poll-cancel-pending")
      async (callback (func $cm "unreachable-cb"))
    ))
    (func (export "yield-cancel-pending") async (param "fut" $FT) (result u32) (canon lift
      (core func $cm "yield-cancel-pending")
      async (callback (func $cm "unreachable-cb"))
    ))
  )

  (component $D
    (type $FT (future))
    (import "wait-cancel" (func $wait-cancel async (result u32)))
    (import "poll-cancel" (func $poll-cancel async (result u32)))
    (import "yield-cancel" (func $yield-cancel async (result u32)))
    (import "poll-cancel-pending" (func $poll-cancel-pending async (param "fut" $FT) (result u32)))
    (import "yield-cancel-pending" (func $yield-cancel-pending async (param "fut" $FT) (result u32)))

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
      (import "" "wait-cancel" (func $wait-cancel (param i32) (result i32)))
      (import "" "poll-cancel" (func $poll-cancel (param i32) (result i32)))
      (import "" "yield-cancel" (func $yield-cancel (param i32) (result i32)))
      (import "" "poll-cancel-pending" (func $poll-cancel-pending (param i32 i32) (result i32)))
      (import "" "yield-cancel-pending" (func $yield-cancel-pending (param i32 i32) (result i32)))

      (func $run (export "run") (result i32)
        (local $ret i32) (local $ret64 i64)
        (local $retp i32) (local $retp2 i32)
        (local $subtask i32)
        (local $event_code i32)
        (local $futr i32) (local $futw i32)
        (local $ws i32)

        ;; ==========================================
        ;; Test 1: waitable-set.wait cancellable
        ;; ==========================================

        ;; call wait-cancel; it should block in cancellable wait
        (local.set $retp (i32.const 4))
        (local.set $ret (call $wait-cancel (local.get $retp)))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; cancel; completes immediately (C is in cancellable wait)
        (local.set $ret (call $subtask.cancel (local.get $subtask)))
        (if (i32.ne (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)) (local.get $ret))
          (then unreachable))
        (call $subtask.drop (local.get $subtask))

        ;; ==========================================
        ;; Test 2: waitable-set.poll cancellable
        ;; ==========================================

        ;; call poll-cancel; it should block in cancellable poll
        (local.set $ret (call $poll-cancel (local.get $retp)))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; cancel; completes immediately (C is in cancellable poll)
        (local.set $ret (call $subtask.cancel (local.get $subtask)))
        (if (i32.ne (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)) (local.get $ret))
          (then unreachable))
        (call $subtask.drop (local.get $subtask))

        ;; ==========================================
        ;; Test 3: thread.yield cancellable
        ;; ==========================================

        ;; call yield-cancel; it should suspend in cancellable yield
        (local.set $ret (call $yield-cancel (local.get $retp)))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; cancel; completes immediately (C is in cancellable yield)
        (local.set $ret (call $subtask.cancel (local.get $subtask)))
        (if (i32.ne (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)) (local.get $ret))
          (then unreachable))
        (call $subtask.drop (local.get $subtask))

        ;; ==========================================
        ;; Test 4: waitable-set.poll cancellable (pending)
        ;; ==========================================

        ;; create future for poll-cancel-pending to read
        (local.set $ret64 (call $future.new))
        (local.set $futr (i32.wrap_i64 (local.get $ret64)))
        (local.set $futw (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))

        ;; call poll-cancel-pending; it should block in non-cancellable wait
        (local.set $retp (i32.const 4))
        (local.set $retp2 (i32.const 8))
        (local.set $ret (call $poll-cancel-pending (local.get $futr) (local.get $retp)))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; cancel; blocks because C's wait is not cancellable
        (local.set $ret (call $subtask.cancel (local.get $subtask)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))

        ;; write to future; unblocks C's non-cancellable wait
        (local.set $ret (call $future.write (local.get $futw) (i32.const 0)))
        (if (i32.ne (i32.const 0 (; COMPLETED ;)) (local.get $ret))
          (then unreachable))

        ;; wait for subtask to complete
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $subtask) (local.get $ws))
        (local.set $event_code (call $waitable-set.wait (local.get $ws) (local.get $retp2)))
        (if (i32.ne (i32.const 1 (; SUBTASK ;)) (local.get $event_code))
          (then unreachable))
        (if (i32.ne (local.get $subtask) (i32.load (local.get $retp2)))
          (then unreachable))
        (if (i32.ne (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)) (i32.load offset=4 (local.get $retp2)))
          (then unreachable))
        (call $subtask.drop (local.get $subtask))

        ;; ==========================================
        ;; Test 5: thread.yield cancellable (pending)
        ;; ==========================================

        ;; create future for yield-cancel-pending to read
        (local.set $ret64 (call $future.new))
        (local.set $futr (i32.wrap_i64 (local.get $ret64)))
        (local.set $futw (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))

        ;; call yield-cancel-pending; it should block in non-cancellable wait
        (local.set $ret (call $yield-cancel-pending (local.get $futr) (local.get $retp)))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; cancel; blocks because C's wait is not cancellable
        (local.set $ret (call $subtask.cancel (local.get $subtask)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))

        ;; write to future; unblocks C's non-cancellable wait
        (local.set $ret (call $future.write (local.get $futw) (i32.const 0)))
        (if (i32.ne (i32.const 0 (; COMPLETED ;)) (local.get $ret))
          (then unreachable))

        ;; wait for subtask to complete
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $subtask) (local.get $ws))
        (local.set $event_code (call $waitable-set.wait (local.get $ws) (local.get $retp2)))
        (if (i32.ne (i32.const 1 (; SUBTASK ;)) (local.get $event_code))
          (then unreachable))
        (if (i32.ne (local.get $subtask) (i32.load (local.get $retp2)))
          (then unreachable))
        (if (i32.ne (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)) (i32.load offset=4 (local.get $retp2)))
          (then unreachable))
        (call $subtask.drop (local.get $subtask))

        ;; all tests passed
        (i32.const 42)
      )
    )
    (canon subtask.cancel async (core func $subtask.cancel))
    (canon subtask.drop (core func $subtask.drop))
    (canon future.new $FT (core func $future.new))
    (canon future.write $FT async (memory $memory "mem") (core func $future.write))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory $memory "mem") (core func $waitable-set.wait))
    (canon lower (func $wait-cancel) async (memory $memory "mem") (core func $wait-cancel'))
    (canon lower (func $poll-cancel) async (memory $memory "mem") (core func $poll-cancel'))
    (canon lower (func $yield-cancel) async (memory $memory "mem") (core func $yield-cancel'))
    (canon lower (func $poll-cancel-pending) async (memory $memory "mem") (core func $poll-cancel-pending'))
    (canon lower (func $yield-cancel-pending) async (memory $memory "mem") (core func $yield-cancel-pending'))
    (core instance $dm (instantiate $DM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "subtask.cancel" (func $subtask.cancel))
      (export "subtask.drop" (func $subtask.drop))
      (export "future.new" (func $future.new))
      (export "future.write" (func $future.write))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "wait-cancel" (func $wait-cancel'))
      (export "poll-cancel" (func $poll-cancel'))
      (export "yield-cancel" (func $yield-cancel'))
      (export "poll-cancel-pending" (func $poll-cancel-pending'))
      (export "yield-cancel-pending" (func $yield-cancel-pending'))
    ))))
    (func (export "run") async (result u32) (canon lift (core func $dm "run")))
  )

  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "wait-cancel" (func $c "wait-cancel"))
    (with "poll-cancel" (func $c "poll-cancel"))
    (with "yield-cancel" (func $c "yield-cancel"))
    (with "poll-cancel-pending" (func $c "poll-cancel-pending"))
    (with "yield-cancel-pending" (func $c "yield-cancel-pending"))
  ))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 42))
