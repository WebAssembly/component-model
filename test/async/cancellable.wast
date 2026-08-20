;; This test exercises the 'cancellable' immediate on waitable-set.wait,
;; waitable-set.poll, thread.yield and the four directed-switch built-ins
;; thread.{suspend,yield}-then-{resume,promote}.
;;
;; Component $C exports five async callback-lifted functions that block in
;; their initial core function (the callbacks are never invoked):
;;   wait-cancel: blocks on cancellable waitable-set.wait, expects TASK_CANCELLED
;;   yield-cancel: yields with cancellable until the caller cancels
;;   poll-cancel-pending: blocks on non-cancellable wait, then polls with cancellable
;;   yield-cancel-pending: blocks on non-cancellable wait, then yields with cancellable
;;   pending-survives-nc-yield: blocks on non-cancellable wait, then a
;;     non-cancellable yield (which must not report the pending cancel), then
;;     yields with cancellable
;;
;; Component $D calls each function and cancels it, verifying the cancel is
;; delivered correctly through the cancellable built-in in each case.
;;
;; Two further components below cover the directed-switch built-ins: first all
;; four of them with the pending request belonging to the switching thread's
;; own task, then the *-then-resume pair with the request belonging to the
;; *target* thread's task instead.
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
      (import "" "thread.yield" (func $thread.yield (result i32)))

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

      ;; Test 2: direct cancel delivery through cancellable thread.yield
      (func $yield-cancel (export "yield-cancel") (result i32)
        ;; yield with cancellable until cancelled by the caller (a single
        ;; yield may nondeterministically complete without suspending and
        ;; thus without the cancellation being delivered)
        (loop $again
          (br_if $again (i32.eqz (call $thread.yield-cancellable))))
        (call $task.cancel)
        (i32.const 0 (; EXIT ;))
      )

      ;; Test 3: deferred cancel delivered through cancellable waitable-set.poll
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

      ;; Test 4: deferred cancel delivered through cancellable thread.yield
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

      ;; Test 5: a pending cancellation is not delivered to a *non*-cancellable
      ;; blocking built-in, and survives it to be delivered at the next
      ;; cancellable one
      (func $pending-survives-nc-yield (export "pending-survives-nc-yield") (param $futr i32) (result i32)
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
        ;; yield WITHOUT cancellable - must not report the pending cancel, and
        ;; must leave it pending
        (local.set $ret (call $thread.yield))
        (if (i32.ne (i32.const 0 (; NOT CANCELLED ;)) (local.get $ret))
          (then unreachable))
        ;; yield WITH cancellable - delivers the still-pending cancel
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
    (canon future.read $FT async (memory (core memory $memory "mem")) (core func $future.read))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait cancellable (memory (core memory $memory "mem")) (core func $waitable-set.wait-cancellable))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (canon waitable-set.poll cancellable (memory (core memory $memory "mem")) (core func $waitable-set.poll-cancellable))
    (canon thread.yield cancellable (core func $thread.yield-cancellable))
    (canon thread.yield (core func $thread.yield))
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
      (export "thread.yield" (func $thread.yield))
    ))))
    (func (export "wait-cancel") async (result u32) (canon lift
      (core func $cm "wait-cancel")
      async (callback (core func $cm "unreachable-cb"))
    ))
    (func (export "yield-cancel") async (result u32) (canon lift
      (core func $cm "yield-cancel")
      async (callback (core func $cm "unreachable-cb"))
    ))
    (func (export "poll-cancel-pending") async (param "fut" $FT) (result u32) (canon lift
      (core func $cm "poll-cancel-pending")
      async (callback (core func $cm "unreachable-cb"))
    ))
    (func (export "yield-cancel-pending") async (param "fut" $FT) (result u32) (canon lift
      (core func $cm "yield-cancel-pending")
      async (callback (core func $cm "unreachable-cb"))
    ))
    (func (export "pending-survives-nc-yield") async (param "fut" $FT) (result u32) (canon lift
      (core func $cm "pending-survives-nc-yield")
      async (callback (core func $cm "unreachable-cb"))
    ))
  )

  (component $D
    (type $FT (future))
    (import "wait-cancel" (func $wait-cancel async (result u32)))
    (import "yield-cancel" (func $yield-cancel async (result u32)))
    (import "poll-cancel-pending" (func $poll-cancel-pending async (param "fut" $FT) (result u32)))
    (import "yield-cancel-pending" (func $yield-cancel-pending async (param "fut" $FT) (result u32)))
    (import "pending-survives-nc-yield" (func $pending-survives-nc-yield async (param "fut" $FT) (result u32)))

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
      (import "" "yield-cancel" (func $yield-cancel (param i32) (result i32)))
      (import "" "poll-cancel-pending" (func $poll-cancel-pending (param i32 i32) (result i32)))
      (import "" "yield-cancel-pending" (func $yield-cancel-pending (param i32 i32) (result i32)))
      (import "" "pending-survives-nc-yield" (func $pending-survives-nc-yield (param i32 i32) (result i32)))

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
        ;; Test 2: thread.yield cancellable
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
        ;; Test 3: waitable-set.poll cancellable (pending)
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
        ;; Test 4: thread.yield cancellable (pending)
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

        ;; ==========================================
        ;; Test 5: pending cancel survives a non-cancellable yield
        ;; ==========================================

        ;; create future for pending-survives-nc-yield to read
        (local.set $ret64 (call $future.new))
        (local.set $futr (i32.wrap_i64 (local.get $ret64)))
        (local.set $futw (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))

        ;; call pending-survives-nc-yield; it should block in non-cancellable wait
        (local.set $ret (call $pending-survives-nc-yield (local.get $futr) (local.get $retp)))
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
    (canon future.write $FT async (memory (core memory $memory "mem")) (core func $future.write))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (canon lower (func $wait-cancel) async (memory (core memory $memory "mem")) (core func $wait-cancel'))
    (canon lower (func $yield-cancel) async (memory (core memory $memory "mem")) (core func $yield-cancel'))
    (canon lower (func $poll-cancel-pending) async (memory (core memory $memory "mem")) (core func $poll-cancel-pending'))
    (canon lower (func $yield-cancel-pending) async (memory (core memory $memory "mem")) (core func $yield-cancel-pending'))
    (canon lower (func $pending-survives-nc-yield) async (memory (core memory $memory "mem")) (core func $pending-survives-nc-yield'))
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
      (export "yield-cancel" (func $yield-cancel'))
      (export "poll-cancel-pending" (func $poll-cancel-pending'))
      (export "yield-cancel-pending" (func $yield-cancel-pending'))
      (export "pending-survives-nc-yield" (func $pending-survives-nc-yield'))
    ))))
    (func (export "run") async (result u32) (canon lift (core func $dm "run")))
  )

  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "wait-cancel" (func $c "wait-cancel"))
    (with "yield-cancel" (func $c "yield-cancel"))
    (with "poll-cancel-pending" (func $c "poll-cancel-pending"))
    (with "yield-cancel-pending" (func $c "yield-cancel-pending"))
    (with "pending-survives-nc-yield" (func $c "pending-survives-nc-yield"))
  ))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 42))

;; This component exercises the 'cancellable' immediate on the
;; thread.{suspend,yield}-then-{resume,promote} built-ins.
;;
;; When a cancellation request is already pending, all four deliver it to the
;; *calling* thread and return without switching to the target thread. The
;; target must be left exactly as it was found, rather than stranded:
;;   *-then-promote takes a target that is already `ready`, which must stay
;;     ready (the scheduler must still run it);
;;   *-then-resume takes a `suspended` target, which must stay suspended (a
;;     subsequent non-cancellable resume must still switch to it).
(component
  (component $C
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Table
      (table (export "tbl") 1 1 funcref))
    (core instance $table (instantiate $Table))
    (core module $CM
      (import "" "mem" (memory 1))
      (import "" "tbl" (table $tbl 1 1 funcref))
      (import "" "task.cancel" (func $task.cancel))
      (import "" "future.read" (func $future.read (param i32 i32) (result i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "thread.yield" (func $thread.yield (result i32)))
      (import "" "thread.suspend-then-promote-cancellable" (func $thread.suspend-then-promote-cancellable (param i32) (result i32)))
      (import "" "thread.yield-then-promote-cancellable" (func $thread.yield-then-promote-cancellable (param i32) (result i32)))
      (import "" "thread.yield-then-resume" (func $thread.yield-then-resume (param i32) (result i32)))
      (import "" "thread.suspend-then-resume-cancellable" (func $thread.suspend-then-resume-cancellable (param i32) (result i32)))
      (import "" "thread.yield-then-resume-cancellable" (func $thread.yield-then-resume-cancellable (param i32) (result i32)))

      (global $x-ran (mut i32) (i32.const 0))
      (func $x (param i32)
        (global.set $x-ran (i32.const 1)))
      (elem (table $tbl) (i32.const 0) func $x)

      ;; The *-then-promote pair, whose target must be `ready`.
      ;; $suspend selects which of the two to test.
      (func (export "promote-cancel-pending") (param $futr i32) (param $suspend i32)
        (local $ws i32) (local $xi i32) (local $ret i32) (local $i i32)
        (global.set $x-ran (i32.const 0))

        ;; create X; it is armed (made `ready`) only after the block below, so
        ;; that it is still ready and unrun at the moment of the promote
        (local.set $xi (call $thread.new-indirect (i32.const 0) (i32.const 0)))

        ;; block non-cancellably: the caller's cancellation request arrives
        ;; while we are here, so it can only be remembered as pending
        (if (i32.ne (i32.const -1 (; BLOCKED ;))
                    (call $future.read (local.get $futr) (i32.const 0)))
          (then unreachable))
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $futr) (local.get $ws))
        (if (i32.ne (i32.const 4 (; FUTURE_READ ;))
                    (call $waitable-set.wait (local.get $ws) (i32.const 0)))
          (then unreachable))

        ;; arm X so that the promote below has a ready target
        (call $thread.resume-later (local.get $xi))

        ;; a cancellable promote reports the pending cancellation instead of
        ;; switching to X
        (local.set $ret (if (result i32) (local.get $suspend)
          (then (call $thread.suspend-then-promote-cancellable (local.get $xi)))
          (else (call $thread.yield-then-promote-cancellable (local.get $xi)))))
        (if (i32.ne (i32.const 1 (; CANCELLED ;)) (local.get $ret))
          (then unreachable))
        (if (global.get $x-ran)
          (then unreachable))

        ;; X must not have been stranded by the cancelled promote: it is still
        ;; ready, so plain yielding lets the scheduler run it
        (block $done
          (loop $again
            (br_if $done (global.get $x-ran))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br_if $done (i32.gt_u (local.get $i) (i32.const 1000)))
            (drop (call $thread.yield))
            (br $again)))
        (if (i32.eqz (global.get $x-ran))
          (then unreachable))

        (call $task.cancel)
      )

      ;; The same shape for the *-then-resume pair, whose target must be
      ;; `suspended` rather than ready. $suspend selects which of the two.
      (func (export "resume-cancel-pending") (param $futr i32) (param $suspend i32)
        (local $ws i32) (local $xi i32) (local $ret i32)
        (global.set $x-ran (i32.const 0))

        ;; create X and leave it suspended, which is what *-then-resume requires
        (local.set $xi (call $thread.new-indirect (i32.const 0) (i32.const 0)))

        ;; block non-cancellably: the caller's cancellation request arrives
        ;; while we are here, so it can only be remembered as pending
        (if (i32.ne (i32.const -1 (; BLOCKED ;))
                    (call $future.read (local.get $futr) (i32.const 0)))
          (then unreachable))
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $futr) (local.get $ws))
        (if (i32.ne (i32.const 4 (; FUTURE_READ ;))
                    (call $waitable-set.wait (local.get $ws) (i32.const 0)))
          (then unreachable))

        ;; a cancellable resume reports the pending cancellation instead of
        ;; switching to X
        (local.set $ret (if (result i32) (local.get $suspend)
          (then (call $thread.suspend-then-resume-cancellable (local.get $xi)))
          (else (call $thread.yield-then-resume-cancellable (local.get $xi)))))
        (if (i32.ne (i32.const 1 (; CANCELLED ;)) (local.get $ret))
          (then unreachable))
        (if (global.get $x-ran)
          (then unreachable))

        ;; X was left in exactly the suspended state it started in, so a
        ;; non-cancellable resume still switches to it
        (drop (call $thread.yield-then-resume (local.get $xi)))
        (if (i32.eqz (global.get $x-ran))
          (then unreachable))

        (call $task.cancel)
      )
    )
    (type $FT (future))
    (core type $start-func-ty (func (param i32)))
    (alias core export $table "tbl" (core table $tbl))
    (canon task.cancel (core func $task.cancel))
    (canon future.read $FT async (memory (core memory $memory "mem")) (core func $future.read))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (canon thread.new-indirect $start-func-ty (core table $tbl) (core func $thread.new-indirect))
    (canon thread.resume-later (core func $thread.resume-later))
    (canon thread.yield (core func $thread.yield))
    (canon thread.suspend-then-promote cancellable (core func $thread.suspend-then-promote-cancellable))
    (canon thread.yield-then-promote cancellable (core func $thread.yield-then-promote-cancellable))
    (canon thread.yield-then-resume (core func $thread.yield-then-resume))
    (canon thread.suspend-then-resume cancellable (core func $thread.suspend-then-resume-cancellable))
    (canon thread.yield-then-resume cancellable (core func $thread.yield-then-resume-cancellable))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "tbl" (table $tbl))
      (export "task.cancel" (func $task.cancel))
      (export "future.read" (func $future.read))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "thread.new-indirect" (func $thread.new-indirect))
      (export "thread.resume-later" (func $thread.resume-later))
      (export "thread.yield" (func $thread.yield))
      (export "thread.suspend-then-promote-cancellable" (func $thread.suspend-then-promote-cancellable))
      (export "thread.yield-then-promote-cancellable" (func $thread.yield-then-promote-cancellable))
      (export "thread.yield-then-resume" (func $thread.yield-then-resume))
      (export "thread.suspend-then-resume-cancellable" (func $thread.suspend-then-resume-cancellable))
      (export "thread.yield-then-resume-cancellable" (func $thread.yield-then-resume-cancellable))
    ))))
    (func (export "promote-cancel-pending") async (param "fut" $FT) (param "suspend" u32) (canon lift
      (core func $cm "promote-cancel-pending")
      async
    ))
    (func (export "resume-cancel-pending") async (param "fut" $FT) (param "suspend" u32) (canon lift
      (core func $cm "resume-cancel-pending")
      async
    ))
  )

  (component $D
    (type $FT (future))
    (import "promote-cancel-pending" (func $promote-cancel-pending async (param "fut" $FT) (param "suspend" u32)))
    (import "resume-cancel-pending" (func $resume-cancel-pending async (param "fut" $FT) (param "suspend" u32)))

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
      (import "" "promote-cancel-pending" (func $promote-cancel-pending (param i32 i32) (result i32)))
      (import "" "resume-cancel-pending" (func $resume-cancel-pending (param i32 i32) (result i32)))

      ;; One round against one of the four built-ins: $promote picks the
      ;; promote pair over the resume pair, $suspend picks suspend- over yield-.
      ;; Every round has the same observable outcome, since the callee checks
      ;; the built-in's own result and the state of its target internally.
      (func $one-round (param $promote i32) (param $suspend i32)
        (local $ret i32) (local $ret64 i64)
        (local $subtask i32) (local $futr i32) (local $futw i32) (local $ws i32)

        (local.set $ret64 (call $future.new))
        (local.set $futr (i32.wrap_i64 (local.get $ret64)))
        (local.set $futw (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))

        ;; the callee blocks non-cancellably on the future
        (local.set $ret (if (result i32) (local.get $promote)
          (then (call $promote-cancel-pending (local.get $futr) (local.get $suspend)))
          (else (call $resume-cancel-pending (local.get $futr) (local.get $suspend)))))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; cancellation can't be delivered yet, so it is remembered as pending
        (local.set $ret (call $subtask.cancel (local.get $subtask)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))

        ;; unblock the callee, which then reaches its cancellable switch
        (if (i32.ne (i32.const 0 (; COMPLETED ;))
                    (call $future.write (local.get $futw) (i32.const 0)))
          (then unreachable))

        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $subtask) (local.get $ws))
        (if (i32.ne (i32.const 1 (; SUBTASK ;))
                    (call $waitable-set.wait (local.get $ws) (i32.const 8)))
          (then unreachable))
        (if (i32.ne (local.get $subtask) (i32.load (i32.const 8)))
          (then unreachable))
        (if (i32.ne (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)) (i32.load offset=4 (i32.const 8)))
          (then unreachable))
        (call $subtask.drop (local.get $subtask))
      )

      (func $run (export "run") (result i32)
        (call $one-round (i32.const 1) (i32.const 1) (; thread.suspend-then-promote ;))
        (call $one-round (i32.const 1) (i32.const 0) (; thread.yield-then-promote ;))
        (call $one-round (i32.const 0) (i32.const 1) (; thread.suspend-then-resume ;))
        (call $one-round (i32.const 0) (i32.const 0) (; thread.yield-then-resume ;))
        (i32.const 42)
      )
    )
    (canon subtask.cancel async (core func $subtask.cancel))
    (canon subtask.drop (core func $subtask.drop))
    (canon future.new $FT (core func $future.new))
    (canon future.write $FT async (memory (core memory $memory "mem")) (core func $future.write))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (canon lower (func $promote-cancel-pending) async (memory (core memory $memory "mem")) (core func $promote-cancel-pending'))
    (canon lower (func $resume-cancel-pending) async (memory (core memory $memory "mem")) (core func $resume-cancel-pending'))
    (core instance $dm (instantiate $DM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "subtask.cancel" (func $subtask.cancel))
      (export "subtask.drop" (func $subtask.drop))
      (export "future.new" (func $future.new))
      (export "future.write" (func $future.write))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "promote-cancel-pending" (func $promote-cancel-pending'))
      (export "resume-cancel-pending" (func $resume-cancel-pending'))
    ))))
    (func (export "run") async (result u32) (canon lift (core func $dm "run")))
  )

  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "promote-cancel-pending" (func $c "promote-cancel-pending"))
    (with "resume-cancel-pending" (func $c "resume-cancel-pending"))
  ))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 42))

;; thread.{suspend,yield}-then-resume can target a thread belonging to a
;; *different* task in the same component instance. This component covers the
;; case where it is the *target's* task that has a pending cancellation
;; request, which can only be delivered once the switch has started the target
;; thread running.
;;
;; Task B owns a thread X that has never run, and B's own implicit thread is
;; suspended non-cancellably, so a cancellation request against B has no
;; cancellable thread to go to and is remembered as pending. Task A then
;; switches to X. Two things must hold:
;;   - the switch reports "not cancelled" to A, since `cancellable` is about
;;     the *calling* thread's task, and A has no pending request of its own;
;;   - X, once running, receives B's pending request at its first cancellable
;;     built-in.
;;
;; Only the *-then-resume pair is covered here. The *-then-promote pair
;; behaves the same way in this interleaving, differing only in requiring an
;; already-`ready` target instead of a `suspended` one, which the component
;; above already covers.
(component
  (component $C
    (core module $Table
      (table (export "tbl") 1 1 funcref))
    (core instance $table (instantiate $Table))
    (core module $CM
      (import "" "tbl" (table $tbl 1 1 funcref))
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "task.cancel" (func $task.cancel))
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "thread.suspend" (func $thread.suspend (result i32)))
      (import "" "thread.yield-cancellable" (func $thread.yield-cancellable (result i32)))
      (import "" "thread.suspend-then-resume-cancellable" (func $thread.suspend-then-resume-cancellable (param i32) (result i32)))
      (import "" "thread.yield-then-resume-cancellable" (func $thread.yield-then-resume-cancellable (param i32) (result i32)))

      (global $xi (mut i32) (i32.const 0))        ;; X's thread index
      (global $b-index (mut i32) (i32.const 0))   ;; B's implicit thread index
      (global $a-index (mut i32) (i32.const 0))   ;; A's implicit thread index
      (global $x-cancelled (mut i32) (i32.const 0))

      ;; X: a thread of task B that has never run until A switches to it. Its
      ;; start argument is the $suspend flag threaded through from "owner".
      (func $x (param $suspend i32)
        ;; first cancellable point: must report B's pending cancellation
        (if (i32.ne (i32.const 1 (; CANCELLED ;)) (call $thread.yield-cancellable))
          (then unreachable))
        (global.set $x-cancelled (i32.const 1))
        (call $task.cancel)
        ;; let B's implicit thread wake up and exit cleanly
        (call $thread.resume-later (global.get $b-index))
        ;; suspend-then-resume left A suspended, so hand control back to it
        (if (local.get $suspend)
          (then (call $thread.resume-later (global.get $a-index))))
      )
      (elem (table $tbl) (i32.const 0) func $x)

      ;; B: creates X and then parks non-cancellably, so that the whole task
      ;; has no cancellable thread when the cancellation request arrives
      (func (export "owner") (param $suspend i32)
        (global.set $b-index (call $thread.index))
        (global.set $x-cancelled (i32.const 0))
        (global.set $xi (call $thread.new-indirect (i32.const 0) (local.get $suspend)))
        (if (i32.ne (i32.const 0 (; NOT CANCELLED ;)) (call $thread.suspend))
          (then unreachable))
      )

      ;; A: switches to B's thread X
      (func (export "switcher") (param $suspend i32)
        (local $ret i32)
        (global.set $a-index (call $thread.index))
        (local.set $ret (if (result i32) (local.get $suspend)
          (then (call $thread.suspend-then-resume-cancellable (global.get $xi)))
          (else (call $thread.yield-then-resume-cancellable (global.get $xi)))))
        ;; A's own task has no pending cancellation, so A is not cancelled...
        (if (i32.ne (i32.const 0 (; NOT CANCELLED ;)) (local.get $ret))
          (then unreachable))
        ;; ...but X was
        (if (i32.ne (i32.const 1) (global.get $x-cancelled))
          (then unreachable))
        (call $task.return (i32.const 42))
      )
    )
    (core type $start-func-ty (func (param i32)))
    (alias core export $table "tbl" (core table $tbl))
    (canon task.return (result u32) (core func $task.return))
    (canon task.cancel (core func $task.cancel))
    (canon thread.index (core func $thread.index))
    (canon thread.new-indirect $start-func-ty (core table $tbl) (core func $thread.new-indirect))
    (canon thread.resume-later (core func $thread.resume-later))
    (canon thread.suspend (core func $thread.suspend))
    (canon thread.yield cancellable (core func $thread.yield-cancellable))
    (canon thread.suspend-then-resume cancellable (core func $thread.suspend-then-resume-cancellable))
    (canon thread.yield-then-resume cancellable (core func $thread.yield-then-resume-cancellable))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "tbl" (table $tbl))
      (export "task.return" (func $task.return))
      (export "task.cancel" (func $task.cancel))
      (export "thread.index" (func $thread.index))
      (export "thread.new-indirect" (func $thread.new-indirect))
      (export "thread.resume-later" (func $thread.resume-later))
      (export "thread.suspend" (func $thread.suspend))
      (export "thread.yield-cancellable" (func $thread.yield-cancellable))
      (export "thread.suspend-then-resume-cancellable" (func $thread.suspend-then-resume-cancellable))
      (export "thread.yield-then-resume-cancellable" (func $thread.yield-then-resume-cancellable))
    ))))
    (func (export "owner") async (param "suspend" u32) (canon lift
      (core func $cm "owner")
      async
    ))
    (func (export "switcher") async (param "suspend" u32) (result u32) (canon lift
      (core func $cm "switcher")
      async
    ))
  )

  (component $D
    (import "owner" (func $owner async (param "suspend" u32)))
    (import "switcher" (func $switcher async (param "suspend" u32) (result u32)))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $DM
      (import "" "mem" (memory 1))
      (import "" "subtask.cancel" (func $subtask.cancel (param i32) (result i32)))
      (import "" "subtask.drop" (func $subtask.drop (param i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (import "" "owner" (func $owner (param i32) (result i32)))
      (import "" "switcher" (func $switcher (param i32 i32) (result i32)))

      (func $one-round (param $suspend i32)
        (local $ret i32) (local $sub-b i32) (local $sub-a i32) (local $ws i32)

        ;; start B: it creates X and parks non-cancellably
        (local.set $ret (call $owner (local.get $suspend)))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $sub-b (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; B has no cancellable thread, so the request is only remembered
        (local.set $ret (call $subtask.cancel (local.get $sub-b)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))

        ;; start A: it switches to B's thread X, which then picks up B's
        ;; pending cancellation and resolves B
        (local.set $ret (call $switcher (local.get $suspend) (i32.const 0)))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $sub-a (i32.shr_u (local.get $ret) (i32.const 4)))

        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $sub-b) (local.get $ws))
        (if (i32.ne (i32.const 1 (; SUBTASK ;))
                    (call $waitable-set.wait (local.get $ws) (i32.const 8)))
          (then unreachable))
        (if (i32.ne (local.get $sub-b) (i32.load (i32.const 8)))
          (then unreachable))
        (if (i32.ne (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)) (i32.load offset=4 (i32.const 8)))
          (then unreachable))
        (call $subtask.drop (local.get $sub-b))

        (call $waitable.join (local.get $sub-a) (local.get $ws))
        (if (i32.ne (i32.const 1 (; SUBTASK ;))
                    (call $waitable-set.wait (local.get $ws) (i32.const 8)))
          (then unreachable))
        (if (i32.ne (local.get $sub-a) (i32.load (i32.const 8)))
          (then unreachable))
        (if (i32.ne (i32.const 2 (; RETURNED ;)) (i32.load offset=4 (i32.const 8)))
          (then unreachable))
        (if (i32.ne (i32.const 42) (i32.load (i32.const 0)))
          (then unreachable))
        (call $subtask.drop (local.get $sub-a))
      )

      (func $run (export "run") (result i32)
        (call $one-round (i32.const 1 (; thread.suspend-then-resume ;)))
        (call $one-round (i32.const 0 (; thread.yield-then-resume ;)))
        (i32.const 42)
      )
    )
    (canon subtask.cancel async (core func $subtask.cancel))
    (canon subtask.drop (core func $subtask.drop))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (canon lower (func $owner) async (memory (core memory $memory "mem")) (core func $owner'))
    (canon lower (func $switcher) async (memory (core memory $memory "mem")) (core func $switcher'))
    (core instance $dm (instantiate $DM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "subtask.cancel" (func $subtask.cancel))
      (export "subtask.drop" (func $subtask.drop))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "owner" (func $owner'))
      (export "switcher" (func $switcher'))
    ))))
    (func (export "run") async (result u32) (canon lift (core func $dm "run")))
  )

  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "owner" (func $c "owner"))
    (with "switcher" (func $c "switcher"))
  ))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 42))
