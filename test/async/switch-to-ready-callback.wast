;; This test has two components $C and $D, where $D imports and calls $C.
;; $C exports 'yielder' and 'waiter': async callback-lifted functions whose
;; initial core function returns the YIELD or WAIT code, resp., with a
;; waitable-set containing a pending (blocked) empty-future read. $C also
;; exports 4 more async callback-lifted functions, one per
;; thread.{suspend,yield}-then-{resume,promote} built-in, that run while
;; their implicit thread holds the component instance's exclusive lock. In the
;; WAIT case, they first complete the waiter's pending future read, so that
;; the waiter's waitable-set now holds a ready waitable. They then target the
;; parked task's implicit thread with their built-in:
;;  - *-then-resume traps: the parked thread is "waiting", not "suspended".
;;  - *-then-promote must NOT switch to the parked thread: it is not ready,
;;    because its readiness condition requires the exclusive lock to be
;;    released (even in the WAIT case where the waitable-set has a pending
;;    event).
(component definition $Tester
  (component $C
    (core module $CM
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "thread.suspend-then-resume" (func $thread.suspend-then-resume (param i32) (result i32)))
      (import "" "thread.yield-then-resume" (func $thread.yield-then-resume (param i32) (result i32)))
      (import "" "thread.suspend-then-promote" (func $thread.suspend-then-promote (param i32) (result i32)))
      (import "" "thread.yield-then-promote" (func $thread.yield-then-promote (param i32) (result i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "future.new" (func $future.new (result i64)))
      (import "" "future.read" (func $future.read (param i32 i32) (result i32)))
      (import "" "future.write" (func $future.write (param i32 i32) (result i32)))
      (import "" "future.drop-readable" (func $future.drop-readable (param i32)))
      (import "" "future.drop-writable" (func $future.drop-writable (param i32)))

      (global $ws (mut i32) (i32.const 0))
      (func $start (global.set $ws (call $waitable-set.new)))
      (start $start)

      (global $parked-tidx (mut i32) (i32.const 0))
      (global $futr (mut i32) (i32.const 0))
      (global $futw (mut i32) (i32.const 0))
      (global $phase (mut i32) (i32.const 0))

      (func (export "yielder") (result i32)
        (global.set $parked-tidx (call $thread.index))
        (i32.or (i32.const 1 (; YIELD ;)) (i32.shl (i32.const 0xdead) (i32.const 4)))
      )
      (func (export "yielder-cb") (param $event i32) (param $idx i32) (param $payload i32) (result i32)
        (if (i32.ne (i32.const 0 (; NONE ;)) (local.get $event))
          (then unreachable))
        (if (i32.eqz (global.get $phase))
          (then (return (i32.or (i32.const 1 (; YIELD ;)) (i32.shl (i32.const 0xdead) (i32.const 4))))))
        (call $task.return (i32.const 43))
        (i32.const 0 (; EXIT ;))
      )

      (func (export "waiter") (result i32)
        (local $ret64 i64)
        (global.set $parked-tidx (call $thread.index))
        (local.set $ret64 (call $future.new))
        (global.set $futr (i32.wrap_i64 (local.get $ret64)))
        (global.set $futw (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (call $future.read (global.get $futr) (i32.const 0xdeadbeef)))
          (then unreachable))
        (call $waitable.join (global.get $futr) (global.get $ws))
        (i32.or (i32.const 2 (; WAIT ;)) (i32.shl (global.get $ws) (i32.const 4)))
      )
      (func (export "waiter-cb") (param $event i32) (param $idx i32) (param $payload i32) (result i32)
        (if (i32.eqz (global.get $phase))
          (then unreachable))
        (if (i32.ne (i32.const 4 (; FUTURE_READ ;)) (local.get $event))
          (then unreachable))
        (if (i32.ne (global.get $futr) (local.get $idx))
          (then unreachable))
        (if (i32.ne (i32.const 0 (; COMPLETED ;)) (local.get $payload))
          (then unreachable))
        (call $future.drop-readable (global.get $futr))
        (call $task.return (i32.const 43))
        (i32.const 0 (; EXIT ;))
      )

      (func $complete-pending-read
        (if (i32.ne (i32.const 0) (global.get $futw))
          (then
            (if (i32.ne (i32.const 0 (; COMPLETED ;)) (call $future.write (global.get $futw) (i32.const 0xdeadbeef)))
              (then unreachable))
            (call $future.drop-writable (global.get $futw))))
      )

      (func (export "suspend-then-resume-parked") (result i32)
        (call $complete-pending-read)
        (drop (call $thread.suspend-then-resume (global.get $parked-tidx)))
        unreachable
      )
      (func (export "yield-then-resume-parked") (result i32)
        (call $complete-pending-read)
        (drop (call $thread.yield-then-resume (global.get $parked-tidx)))
        unreachable
      )
      (func (export "suspend-then-promote-parked") (result i32)
        (call $complete-pending-read)
        (drop (call $thread.suspend-then-promote (global.get $parked-tidx)))
        unreachable
      )
      (func (export "yield-then-promote-parked") (result i32)
        (call $complete-pending-read)
        (drop (call $thread.yield-then-promote (global.get $parked-tidx)))
        (if (i32.ne (i32.const 0) (global.get $phase))
          (then unreachable))
        (global.set $phase (i32.const 1))
        (call $task.return (i32.const 42))
        (i32.const 0 (; EXIT ;))
      )
      (func (export "unreachable-cb") (param i32 i32 i32) (result i32)
        unreachable
      )
    )
    (type $FT (future))
    (canon task.return (result u32) (core func $task.return))
    (canon thread.index (core func $thread.index))
    (canon thread.suspend-then-resume (core func $thread.suspend-then-resume))
    (canon thread.yield-then-resume (core func $thread.yield-then-resume))
    (canon thread.suspend-then-promote (core func $thread.suspend-then-promote))
    (canon thread.yield-then-promote (core func $thread.yield-then-promote))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon future.new $FT (core func $future.new))
    (canon future.read $FT async (core func $future.read))
    (canon future.write $FT async (core func $future.write))
    (canon future.drop-readable $FT (core func $future.drop-readable))
    (canon future.drop-writable $FT (core func $future.drop-writable))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "task.return" (func $task.return))
      (export "thread.index" (func $thread.index))
      (export "thread.suspend-then-resume" (func $thread.suspend-then-resume))
      (export "thread.yield-then-resume" (func $thread.yield-then-resume))
      (export "thread.suspend-then-promote" (func $thread.suspend-then-promote))
      (export "thread.yield-then-promote" (func $thread.yield-then-promote))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "future.new" (func $future.new))
      (export "future.read" (func $future.read))
      (export "future.write" (func $future.write))
      (export "future.drop-readable" (func $future.drop-readable))
      (export "future.drop-writable" (func $future.drop-writable))
    ))))
    (func (export "yielder") async (result u32) (canon lift
      (core func $cm "yielder")
      async (callback (core func $cm "yielder-cb"))
    ))
    (func (export "waiter") async (result u32) (canon lift
      (core func $cm "waiter")
      async (callback (core func $cm "waiter-cb"))
    ))
    (func (export "suspend-then-resume-parked") async (result u32) (canon lift
      (core func $cm "suspend-then-resume-parked")
      async (callback (core func $cm "unreachable-cb"))
    ))
    (func (export "yield-then-resume-parked") async (result u32) (canon lift
      (core func $cm "yield-then-resume-parked")
      async (callback (core func $cm "unreachable-cb"))
    ))
    (func (export "suspend-then-promote-parked") async (result u32) (canon lift
      (core func $cm "suspend-then-promote-parked")
      async (callback (core func $cm "unreachable-cb"))
    ))
    (func (export "yield-then-promote-parked") async (result u32) (canon lift
      (core func $cm "yield-then-promote-parked")
      async (callback (core func $cm "unreachable-cb"))
    ))
  )

  (component $D
    (import "c" (instance $c
      (export "yielder" (func async (result u32)))
      (export "waiter" (func async (result u32)))
      (export "suspend-then-resume-parked" (func async (result u32)))
      (export "yield-then-resume-parked" (func async (result u32)))
      (export "suspend-then-promote-parked" (func async (result u32)))
      (export "yield-then-promote-parked" (func async (result u32)))
    ))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $DM
      (import "" "mem" (memory 1))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (import "" "subtask.drop" (func $subtask.drop (param i32)))
      (import "" "yielder" (func $yielder (param i32) (result i32)))
      (import "" "waiter" (func $waiter (param i32) (result i32)))
      (import "" "suspend-then-resume-parked" (func $suspend-then-resume-parked (param i32) (result i32)))
      (import "" "yield-then-resume-parked" (func $yield-then-resume-parked (param i32) (result i32)))
      (import "" "suspend-then-promote-parked" (func $suspend-then-promote-parked (param i32) (result i32)))
      (import "" "yield-then-promote-parked" (func $yield-then-promote-parked (param i32) (result i32)))

      (global $ws (mut i32) (i32.const 0))
      (func $start (global.set $ws (call $waitable-set.new)))
      (start $start)

      (global $retp-parked i32 (i32.const 4))
      (global $retp-t i32 (i32.const 8))
      (global $eventp i32 (i32.const 16))

      ;; call 'yielder'/'waiter' and check that it parked in its event loop
      ;; as subtask handle 2
      (func $start-yielder
        (local $ret i32)
        (local.set $ret (call $yielder (global.get $retp-parked)))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (if (i32.ne (i32.const 2) (i32.shr_u (local.get $ret) (i32.const 4)))
          (then unreachable))
      )
      (func $start-waiter
        (local $ret i32)
        (local.set $ret (call $waiter (global.get $retp-parked)))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (if (i32.ne (i32.const 2) (i32.shr_u (local.get $ret) (i32.const 4)))
          (then unreachable))
      )

      ;; join $subtask to $ws, wait for it to return, check the result value
      ;; at $retp and drop the subtask
      (func $await-subtask-returns (param $subtask i32) (param $retp i32) (param $expected i32)
        (call $waitable.join (local.get $subtask) (global.get $ws))
        (if (i32.ne (i32.const 1 (; SUBTASK ;)) (call $waitable-set.wait (global.get $ws) (global.get $eventp)))
          (then unreachable))
        (if (i32.ne (local.get $subtask) (i32.load (global.get $eventp)))
          (then unreachable))
        (if (i32.ne (i32.const 2 (; RETURNED ;)) (i32.load offset=4 (global.get $eventp)))
          (then unreachable))
        (if (i32.ne (local.get $expected) (i32.load (local.get $retp)))
          (then unreachable))
        (call $subtask.drop (local.get $subtask))
      )

      ;; wait for the test function (running as subtask handle 3, expected to
      ;; return 42) and then for the parked task (as subtask handle 2,
      ;; expected to return 43, now that the test function has set $phase),
      ;; and return 44
      (func $reap-test-then-parked (param $ret i32) (result i32)
        (if (i32.eq (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then
            (if (i32.ne (i32.const 3) (i32.shr_u (local.get $ret) (i32.const 4)))
              (then unreachable))
            (call $await-subtask-returns (i32.const 3) (global.get $retp-t) (i32.const 42)))
          (else
            ;; the plain-yield fallback may nondeterministically not block at
            ;; all, in which case the test function completed eagerly
            (if (i32.ne (i32.const 2 (; RETURNED ;)) (local.get $ret))
              (then unreachable))
            (if (i32.ne (i32.const 42) (i32.load (global.get $retp-t)))
              (then unreachable))))
        (call $await-subtask-returns (i32.const 2) (global.get $retp-parked) (i32.const 43))
        (i32.const 44)
      )

      ;; wait for the test function, which is suspended and never resumed,
      ;; while the parked task is never ready, so this deadlocks
      (func $wait-forever (param $ret i32)
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (if (i32.ne (i32.const 3) (i32.shr_u (local.get $ret) (i32.const 4)))
          (then unreachable))
        (call $waitable.join (i32.const 3) (global.get $ws))
        (drop (call $waitable-set.wait (global.get $ws) (global.get $eventp)))
        unreachable
      )

      (func (export "trap-if-suspend-then-resume-yielded-callback")
        (call $start-yielder)
        (drop (call $suspend-then-resume-parked (global.get $retp-t)))
        unreachable
      )
      (func (export "trap-if-yield-then-resume-yielded-callback")
        (call $start-yielder)
        (drop (call $yield-then-resume-parked (global.get $retp-t)))
        unreachable
      )
      (func (export "deadlock-if-suspend-then-promote-yielded-callback")
        (call $start-yielder)
        (call $wait-forever (call $suspend-then-promote-parked (global.get $retp-t)))
      )
      (func (export "yield-then-promote-yielded-callback-is-fine") (result i32)
        (call $start-yielder)
        (call $reap-test-then-parked (call $yield-then-promote-parked (global.get $retp-t)))
      )

      (func (export "trap-if-suspend-then-resume-waiting-callback")
        (call $start-waiter)
        (drop (call $suspend-then-resume-parked (global.get $retp-t)))
        unreachable
      )
      (func (export "trap-if-yield-then-resume-waiting-callback")
        (call $start-waiter)
        (drop (call $yield-then-resume-parked (global.get $retp-t)))
        unreachable
      )
      (func (export "deadlock-if-suspend-then-promote-waiting-callback")
        (call $start-waiter)
        (call $wait-forever (call $suspend-then-promote-parked (global.get $retp-t)))
      )
      (func (export "yield-then-promote-waiting-callback-is-fine") (result i32)
        (call $start-waiter)
        (call $reap-test-then-parked (call $yield-then-promote-parked (global.get $retp-t)))
      )
    )
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (canon subtask.drop (core func $subtask.drop))
    (canon lower (func $c "yielder") async (memory (core memory $memory "mem")) (core func $yielder'))
    (canon lower (func $c "waiter") async (memory (core memory $memory "mem")) (core func $waiter'))
    (canon lower (func $c "suspend-then-resume-parked") async (memory (core memory $memory "mem")) (core func $suspend-then-resume-parked'))
    (canon lower (func $c "yield-then-resume-parked") async (memory (core memory $memory "mem")) (core func $yield-then-resume-parked'))
    (canon lower (func $c "suspend-then-promote-parked") async (memory (core memory $memory "mem")) (core func $suspend-then-promote-parked'))
    (canon lower (func $c "yield-then-promote-parked") async (memory (core memory $memory "mem")) (core func $yield-then-promote-parked'))
    (core instance $dm (instantiate $DM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "subtask.drop" (func $subtask.drop))
      (export "yielder" (func $yielder'))
      (export "waiter" (func $waiter'))
      (export "suspend-then-resume-parked" (func $suspend-then-resume-parked'))
      (export "yield-then-resume-parked" (func $yield-then-resume-parked'))
      (export "suspend-then-promote-parked" (func $suspend-then-promote-parked'))
      (export "yield-then-promote-parked" (func $yield-then-promote-parked'))
    ))))
    (func (export "trap-if-suspend-then-resume-yielded-callback") async (canon lift (core func $dm "trap-if-suspend-then-resume-yielded-callback")))
    (func (export "trap-if-yield-then-resume-yielded-callback") async (canon lift (core func $dm "trap-if-yield-then-resume-yielded-callback")))
    (func (export "deadlock-if-suspend-then-promote-yielded-callback") async (canon lift (core func $dm "deadlock-if-suspend-then-promote-yielded-callback")))
    (func (export "yield-then-promote-yielded-callback-is-fine") async (result u32) (canon lift (core func $dm "yield-then-promote-yielded-callback-is-fine")))
    (func (export "trap-if-suspend-then-resume-waiting-callback") async (canon lift (core func $dm "trap-if-suspend-then-resume-waiting-callback")))
    (func (export "trap-if-yield-then-resume-waiting-callback") async (canon lift (core func $dm "trap-if-yield-then-resume-waiting-callback")))
    (func (export "deadlock-if-suspend-then-promote-waiting-callback") async (canon lift (core func $dm "deadlock-if-suspend-then-promote-waiting-callback")))
    (func (export "yield-then-promote-waiting-callback-is-fine") async (result u32) (canon lift (core func $dm "yield-then-promote-waiting-callback-is-fine")))
  )

  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "c" (instance $c))))
  (func (export "trap-if-suspend-then-resume-yielded-callback") (alias export $d "trap-if-suspend-then-resume-yielded-callback"))
  (func (export "trap-if-yield-then-resume-yielded-callback") (alias export $d "trap-if-yield-then-resume-yielded-callback"))
  (func (export "deadlock-if-suspend-then-promote-yielded-callback") (alias export $d "deadlock-if-suspend-then-promote-yielded-callback"))
  (func (export "yield-then-promote-yielded-callback-is-fine") (alias export $d "yield-then-promote-yielded-callback-is-fine"))
  (func (export "trap-if-suspend-then-resume-waiting-callback") (alias export $d "trap-if-suspend-then-resume-waiting-callback"))
  (func (export "trap-if-yield-then-resume-waiting-callback") (alias export $d "trap-if-yield-then-resume-waiting-callback"))
  (func (export "deadlock-if-suspend-then-promote-waiting-callback") (alias export $d "deadlock-if-suspend-then-promote-waiting-callback"))
  (func (export "yield-then-promote-waiting-callback-is-fine") (alias export $d "yield-then-promote-waiting-callback-is-fine"))
)

(component instance $i $Tester)
(assert_trap (invoke "trap-if-suspend-then-resume-yielded-callback") "cannot resume thread which is not suspended")
(component instance $i $Tester)
(assert_trap (invoke "trap-if-yield-then-resume-yielded-callback") "cannot resume thread which is not suspended")
(component instance $i $Tester)
(assert_trap (invoke "deadlock-if-suspend-then-promote-yielded-callback") "deadlock detected: event loop cannot make further progress")
(component instance $i $Tester)
(assert_return (invoke "yield-then-promote-yielded-callback-is-fine") (u32.const 44))
(component instance $i $Tester)
(assert_trap (invoke "trap-if-suspend-then-resume-waiting-callback") "cannot resume thread which is not suspended")
(component instance $i $Tester)
(assert_trap (invoke "trap-if-yield-then-resume-waiting-callback") "cannot resume thread which is not suspended")
(component instance $i $Tester)
(assert_trap (invoke "deadlock-if-suspend-then-promote-waiting-callback") "deadlock detected: event loop cannot make further progress")
(component instance $i $Tester)
(assert_return (invoke "yield-then-promote-waiting-callback-is-fine") (u32.const 44))
