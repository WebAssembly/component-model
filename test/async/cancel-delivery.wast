;; This test exercises how a request for cancellation is delivered to the
;; callee: the request is recorded as pending on the callee's task and is only
;; delivered, as a TASK_CANCELLED event, via the `async callback` event loop.
;;
;; Component $C exports three async callback-lifted functions:
;;   yield-until-cancel: loops returning YIELD to its event loop until the
;;     TASK_CANCELLED event arrives; one more YIELD must then report NONE
;;     (cancellation is delivered at most once) before it calls task.cancel
;;   deferred: blocks in a synchronous future.read in its initial core
;;     function, during which a cancellation request stays pending; the pending
;;     request is delivered at the first return to the event loop
;;   pending-survives: like deferred, but additionally calls thread.yield and
;;     waitable-set.poll after the request is pending: neither may report the
;;     pending cancellation (they never return TASK_CANCELLED), which must
;;     survive until the task returns to its event loop
;;
;; Component $D calls each function and cancels it. `subtask.cancel async`
;; resumes the cancelled task directly, but the host is also allowed (not
;; required) to keep resuming ready threads, so yield-until-cancel may or may
;; not get far enough to resolve before the built-in returns and $D accepts
;; both outcomes. While a task is blocked in its initial core function it
;; cannot be cancelled at all, so those cancellations deterministically report
;; BLOCKED.
(component
  (component $C
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $CM
      (import "" "mem" (memory 1))
      (import "" "task.cancel" (func $task.cancel))
      (import "" "future.read" (func $future.read (param i32 i32) (result i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.poll" (func $waitable-set.poll (param i32 i32) (result i32)))
      (import "" "thread.yield" (func $thread.yield (result i32)))

      ;; Test 1: cancellation is delivered to a task parked in its event loop
      ;; after returning YIELD, and is delivered at most once
      (global $cancelled (mut i32) (i32.const 0))
      (func $yield-until-cancel (export "yield-until-cancel") (result i32)
        (i32.const 1 (; YIELD ;))
      )
      (func $yield-until-cancel_cb (export "yield-until-cancel_cb") (param $event_code i32) (param $index i32) (param $payload i32) (result i32)
        (if (i32.eq (local.get $event_code) (i32.const 6 (; TASK_CANCELLED ;)))
          (then
            (if (global.get $cancelled) (then unreachable))
            (global.set $cancelled (i32.const 1))
            ;; yield once more; the next event must be NONE, not a second
            ;; TASK_CANCELLED
            (return (i32.const 1 (; YIELD ;)))))
        (if (i32.ne (local.get $event_code) (i32.const 0 (; NONE ;)))
          (then unreachable))
        (if (i32.eqz (global.get $cancelled))
          ;; not yet cancelled; keep yielding
          (then (return (i32.const 1 (; YIELD ;)))))
        (call $task.cancel)
        (i32.const 0 (; EXIT ;))
      )

      ;; Test 2: a cancellation request arriving while this task is blocked in
      ;; a synchronous future.read stays pending and is delivered at the first
      ;; return to the event loop
      (func $deferred (export "deferred") (param $futr i32) (result i32)
        ;; blocks until the caller writes (the caller cancels first)
        (if (i32.ne (call $future.read (local.get $futr) (i32.const 0)) (i32.const 0 (; COMPLETED ;)))
          (then unreachable))
        ;; return to the event loop; the pending cancellation must be
        ;; delivered even though this waitable set is empty
        (i32.or (i32.const 2 (; WAIT ;)) (i32.shl (call $waitable-set.new) (i32.const 4)))
      )
      (func $expect-cancelled_cb (export "expect-cancelled_cb") (param $event_code i32) (param $index i32) (param $payload i32) (result i32)
        (if (i32.ne (local.get $event_code) (i32.const 6 (; TASK_CANCELLED ;)))
          (then unreachable))
        (call $task.cancel)
        (i32.const 0 (; EXIT ;))
      )

      ;; Test 3: a pending cancellation is not reported by the thread.yield and
      ;; waitable-set.poll built-ins (which never return TASK_CANCELLED); it
      ;; survives them and is delivered at the event loop
      (func $pending-survives (export "pending-survives") (param $futr i32) (result i32)
        (local $ws i32)
        ;; blocks until the caller writes (the caller cancels first)
        (if (i32.ne (call $future.read (local.get $futr) (i32.const 0)) (i32.const 0 (; COMPLETED ;)))
          (then unreachable))
        ;; a pending cancellation is now set; thread.yield must not report it
        (if (i32.ne (call $thread.yield) (i32.const 0))
          (then unreachable))
        ;; nor may waitable-set.poll, which must report NONE for an empty set
        (local.set $ws (call $waitable-set.new))
        (if (i32.ne (call $waitable-set.poll (local.get $ws) (i32.const 0)) (i32.const 0 (; NONE ;)))
          (then unreachable))
        ;; only the event loop delivers the still-pending cancellation
        (i32.or (i32.const 2 (; WAIT ;)) (i32.shl (local.get $ws) (i32.const 4)))
      )
    )
    (type $FT (future))
    (canon task.cancel (core func $task.cancel))
    (canon future.read $FT (memory (core memory $memory "mem")) (core func $future.read))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.poll (memory (core memory $memory "mem")) (core func $waitable-set.poll))
    (canon thread.yield (core func $thread.yield))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "task.cancel" (func $task.cancel))
      (export "future.read" (func $future.read))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.poll" (func $waitable-set.poll))
      (export "thread.yield" (func $thread.yield))
    ))))
    (func (export "yield-until-cancel") async (canon lift
      (core func $cm "yield-until-cancel")
      async (callback (core func $cm "yield-until-cancel_cb"))
    ))
    (func (export "deferred") async (param "fut" $FT) (canon lift
      (core func $cm "deferred")
      async (callback (core func $cm "expect-cancelled_cb"))
    ))
    (func (export "pending-survives") async (param "fut" $FT) (canon lift
      (core func $cm "pending-survives")
      async (callback (core func $cm "expect-cancelled_cb"))
    ))
  )

  (component $D
    (type $FT (future))
    (import "yield-until-cancel" (func $yield-until-cancel async))
    (import "deferred" (func $deferred async (param "fut" $FT)))
    (import "pending-survives" (func $pending-survives async (param "fut" $FT)))

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
      (import "" "yield-until-cancel" (func $yield-until-cancel (result i32)))
      (import "" "deferred" (func $deferred (param i32) (result i32)))
      (import "" "pending-survives" (func $pending-survives (param i32) (result i32)))

      ;; wait until $sub resolves to CANCELLED_BEFORE_RETURNED, then drop it
      (func $await-cancelled (param $sub i32)
        (local $ws i32)
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $sub) (local.get $ws))
        (if (i32.ne (call $waitable-set.wait (local.get $ws) (i32.const 8)) (i32.const 1 (; SUBTASK ;)))
          (then unreachable))
        (if (i32.ne (i32.load (i32.const 8)) (local.get $sub))
          (then unreachable))
        (if (i32.ne (i32.load (i32.const 12)) (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)))
          (then unreachable))
        (call $waitable.join (local.get $sub) (i32.const 0))
        (call $subtask.drop (local.get $sub))
      )

      (func $run (export "run") (result i32)
        (local $ret i32) (local $ret64 i64)
        (local $subtask i32)
        (local $futr i32) (local $futw i32)

        ;; ==========================================
        ;; Test 1: delivery to a YIELD-parked task
        ;; ==========================================

        ;; call yield-until-cancel; it parks in its event loop
        (local.set $ret (call $yield-until-cancel))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; cancel; the callee is resumed to receive TASK_CANCELLED, but it
        ;; needs one more turn of its event loop to resolve, which the host may
        ;; or may not give it before returning from the built-in
        (local.set $ret (call $subtask.cancel (local.get $subtask)))
        (if (i32.eq (local.get $ret) (i32.const -1 (; BLOCKED ;)))
          (then (call $await-cancelled (local.get $subtask)))
          (else
            (if (i32.ne (local.get $ret) (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)))
              (then unreachable))
            (call $subtask.drop (local.get $subtask))))

        ;; ==========================================
        ;; Test 2: deferral while blocked in a synchronous built-in
        ;; ==========================================

        ;; create future for deferred to read
        (local.set $ret64 (call $future.new))
        (local.set $futr (i32.wrap_i64 (local.get $ret64)))
        (local.set $futw (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))

        ;; call deferred; it blocks in a synchronous future.read
        (local.set $ret (call $deferred (local.get $futr)))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; cancel; deterministically blocked, since the callee cannot receive
        ;; the request while blocked in its initial core function
        (if (i32.ne (call $subtask.cancel (local.get $subtask)) (i32.const -1 (; BLOCKED ;)))
          (then unreachable))

        ;; write to the future, unblocking the callee's synchronous read
        (if (i32.ne (call $future.write (local.get $futw) (i32.const 0)) (i32.const 0 (; COMPLETED ;)))
          (then unreachable))

        ;; the pending cancellation is delivered once the callee returns to
        ;; its event loop
        (call $await-cancelled (local.get $subtask))

        ;; ==========================================
        ;; Test 3: pending cancellation survives thread.yield and
        ;; waitable-set.poll
        ;; ==========================================

        ;; create future for pending-survives to read
        (local.set $ret64 (call $future.new))
        (local.set $futr (i32.wrap_i64 (local.get $ret64)))
        (local.set $futw (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))

        ;; call pending-survives; it blocks in a synchronous future.read
        (local.set $ret (call $pending-survives (local.get $futr)))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; cancel; deterministically blocked, as in test 2
        (if (i32.ne (call $subtask.cancel (local.get $subtask)) (i32.const -1 (; BLOCKED ;)))
          (then unreachable))

        ;; write to the future, unblocking the callee's synchronous read
        (if (i32.ne (call $future.write (local.get $futw) (i32.const 0)) (i32.const 0 (; COMPLETED ;)))
          (then unreachable))

        ;; the callee's yield and poll must not observe the pending
        ;; cancellation, which is delivered at the callee's event loop
        (call $await-cancelled (local.get $subtask))

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
    (canon lower (func $yield-until-cancel) async (memory (core memory $memory "mem")) (core func $yield-until-cancel'))
    (canon lower (func $deferred) async (memory (core memory $memory "mem")) (core func $deferred'))
    (canon lower (func $pending-survives) async (memory (core memory $memory "mem")) (core func $pending-survives'))
    (core instance $dm (instantiate $DM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "subtask.cancel" (func $subtask.cancel))
      (export "subtask.drop" (func $subtask.drop))
      (export "future.new" (func $future.new))
      (export "future.write" (func $future.write))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "yield-until-cancel" (func $yield-until-cancel'))
      (export "deferred" (func $deferred'))
      (export "pending-survives" (func $pending-survives'))
    ))))
    (func (export "run") async (result u32) (canon lift (core func $dm "run")))
  )

  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "yield-until-cancel" (func $c "yield-until-cancel"))
    (with "deferred" (func $c "deferred"))
    (with "pending-survives" (func $c "pending-survives"))
  ))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 42))

;; subtask.cancel only resumes ready threads. A stackful (non-callback) task
;; parked in 'waitable-set.wait' that contains no ready waitable is not ready
;; and cannot return TASK_CANCELLED.
(component
  (component $C
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $CM
      (import "" "mem" (memory 1))
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "future.read" (func $future.read (param i32 i32) (result i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (global $futr (mut i32) (i32.const 0))
      (func (export "stash-fut") (param $f i32)
        (global.set $futr (local.get $f)))
      (func (export "stackful")
        (local $ws i32)
        (if (i32.ne (call $future.read (global.get $futr) (i32.const 0))
                    (i32.const -1 (; BLOCKED ;)))
          (then unreachable))
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (global.get $futr) (local.get $ws))
        ;; Parked here, this task is not cancellable: only a FUTURE_READ can
        ;; wake it, never a TASK_CANCELLED.
        (if (i32.ne (call $waitable-set.wait (local.get $ws) (i32.const 8))
                    (i32.const 4 (; FUTURE_READ ;)))
          (then unreachable))
        (call $task.return (i32.const 42)))
    )
    (type $FT (future))
    (canon task.return (result u32) (core func $task.return))
    (canon future.read $FT async (memory (core memory $memory "mem")) (core func $future.read))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "task.return" (func $task.return))
      (export "future.read" (func $future.read))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))))))
    (func (export "stash-fut") (param "fut" $FT) (canon lift (core func $cm "stash-fut")))
    (func (export "stackful") async (result u32) (canon lift (core func $cm "stackful") async))
  )
  (instance $c (instantiate $C))
  (core module $Memory (memory (export "mem") 1))
  (core instance $memory (instantiate $Memory))
  (type $FT (future))
  (canon future.new $FT (core func $future.new))
  (canon future.write $FT (memory (core memory $memory "mem")) (core func $future.write))
  (canon lower (func $c "stash-fut") (core func $stash-fut'))
  (canon lower (func $c "stackful") async (memory (core memory $memory "mem")) (core func $stackful'))
  (canon subtask.cancel async (core func $subtask.cancel-async))
  (canon subtask.drop (core func $subtask.drop))
  (canon waitable.join (core func $waitable.join))
  (canon waitable-set.new (core func $waitable-set.new))
  (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))

  (core module $Main
    (import "" "mem" (memory 1))
    (import "" "future.new" (func $future.new (result i64)))
    (import "" "future.write" (func $future.write (param i32 i32) (result i32)))
    (import "" "stash-fut" (func $stash-fut (param i32)))
    (import "" "stackful" (func $stackful (param i32) (result i32)))
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
      (call $stash-fut (local.get $futr))
      (local.set $packed (call $stackful (i32.const 24)))
      (if (i32.ne (i32.and (local.get $packed) (i32.const 0xf)) (i32.const 1 (; STARTED ;)))
        (then unreachable))
      (local.set $sub (i32.shr_u (local.get $packed) (i32.const 4)))
      ;; no ready thread to resume, so the request is only recorded
      (if (i32.ne (call $subtask.cancel-async (local.get $sub))
                  (i32.const -1 (; BLOCKED ;)))
        (then unreachable))
      ;; unblock the stackful task; it never sees the cancellation
      (if (i32.ne (call $future.write (local.get $futw) (i32.const 16))
                  (i32.const 0 (; COMPLETED ;)))
        (then unreachable))
      (local.set $ws (call $waitable-set.new))
      (call $waitable.join (local.get $sub) (local.get $ws))
      (if (i32.ne (call $waitable-set.wait (local.get $ws) (i32.const 0))
                  (i32.const 1 (; SUBTASK ;)))
        (then unreachable))
      (if (i32.ne (i32.load (i32.const 0)) (local.get $sub))
        (then unreachable))
      (if (i32.ne (i32.load (i32.const 4)) (i32.const 2 (; RETURNED ;)))
        (then unreachable))
      (if (i32.ne (i32.load (i32.const 24)) (i32.const 42))
        (then unreachable))
      (call $waitable.join (local.get $sub) (i32.const 0))
      (call $subtask.drop (local.get $sub))
      (i32.const 42))
  )
  (core instance $main (instantiate $Main (with "" (instance
    (export "mem" (memory $memory "mem"))
    (export "future.new" (func $future.new))
    (export "future.write" (func $future.write))
    (export "stash-fut" (func $stash-fut'))
    (export "stackful" (func $stackful'))
    (export "subtask.cancel-async" (func $subtask.cancel-async))
    (export "subtask.drop" (func $subtask.drop))
    (export "waitable.join" (func $waitable.join))
    (export "waitable-set.new" (func $waitable-set.new))
    (export "waitable-set.wait" (func $waitable-set.wait))))))
  (func (export "run") async (result u32) (canon lift (core func $main "run")))
)
(assert_return (invoke "run") (u32.const 42))
