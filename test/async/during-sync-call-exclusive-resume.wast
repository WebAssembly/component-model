;; While a non-async-typed export call is in progress, the runtime may resume
;; *any* ready thread of the same component instance, including the implicit
;; threads of async-typed tasks using the sync or callback ABIs (which take
;; the instance's exclusive lock while they execute core wasm). To test this
;; deterministically, a sync call suspends its implicit thread in a state
;; where the *only* ready thread in the instance is the parked event-loop
;; thread of an async callback task, which must therefore be resumed (running
;; its callback in the middle of the sync call) to unblock the sync call.
(component
  (core module $Core
    (import "" "task.return" (func $task.return (param i32)))
    (import "" "thread.index" (func $thread.index (result i32)))
    (import "" "thread.suspend" (func $thread.suspend (result i32)))
    (import "" "thread.resume-later" (func $thread.resume-later (param i32)))

    (global $sync-thread-index (mut i32) (i32.const 0xdead))
    (global $pinged (mut i32) (i32.const 0))

    ;; async callback task resolves, then parks its implicit thread, ready, in
    ;; its event loop by returning YIELD
    (func (export "arm") (result i32)
      (call $task.return (i32.const 1))
      (i32.const 1 (; YIELD ;)))

    ;; Since arm's YIELD may nondeterministically complete without suspending,
    ;; 'ping-cb' may be called (with a NONE event) while no sync call is in
    ;; progress; it then just parks the thread again. When resumed during
    ;; 'sync-block', it wakes the suspended sync thread and exits.
    (func (export "ping-cb") (param i32 i32 i32) (result i32)
      (if (i32.eq (global.get $sync-thread-index) (i32.const 0xdead))
        (then (return (i32.const 1 (; YIELD ;)))))
      (global.set $pinged (i32.const 1))
      (call $thread.resume-later (global.get $sync-thread-index))
      (i32.const 0 (; EXIT ;)))

    ;; non-async-typed: suspend; only ping-cb can wake us
    (func (export "sync-block") (result i32)
      (global.set $sync-thread-index (call $thread.index))
      (drop (call $thread.suspend))
      (if (i32.eqz (global.get $pinged))
        (then unreachable))
      (i32.const 42))
  )
  (canon task.return (result u32) (core func $task.return))
  (canon thread.index (core func $thread.index))
  (canon thread.suspend (core func $thread.suspend))
  (canon thread.resume-later (core func $thread.resume-later))
  (core instance $core (instantiate $Core (with "" (instance
    (export "task.return" (func $task.return))
    (export "thread.index" (func $thread.index))
    (export "thread.suspend" (func $thread.suspend))
    (export "thread.resume-later" (func $thread.resume-later))
  ))))
  (func (export "arm") async (result u32)
    (canon lift (core func $core "arm") async (callback (core func $core "ping-cb"))))
  (func (export "sync-block") (result u32)
    (canon lift (core func $core "sync-block")))
)
(assert_return (invoke "arm") (u32.const 1))
(assert_return (invoke "sync-block") (u32.const 42))

;; A ready needs-exclusive thread allows the sync call to block, but if that
;; thread exits without waking the sync call's own thread, the runtime traps
;; once no ready threads remain in the instance.
(component
  (core module $Core
    (import "" "task.return" (func $task.return (param i32)))
    (import "" "thread.suspend" (func $thread.suspend (result i32)))

    (global $in-sync-call (mut i32) (i32.const 0))

    ;; async callback task resolves, then parks its implicit thread, ready, in
    ;; its event loop by returning YIELD
    (func (export "arm") (result i32)
      (call $task.return (i32.const 1))
      (i32.const 1 (; YIELD ;)))

    ;; Park again on a spurious wake-up outside the sync call; exit (without
    ;; waking anyone) when resumed during it.
    (func (export "exit-cb") (param i32 i32 i32) (result i32)
      (if (i32.eqz (global.get $in-sync-call))
        (then (return (i32.const 1 (; YIELD ;)))))
      (i32.const 0 (; EXIT ;)))

    ;; non-async-typed: suspend with nothing left to wake us
    (func (export "sync-block")
      (global.set $in-sync-call (i32.const 1))
      (drop (call $thread.suspend))
      unreachable)
  )
  (canon task.return (result u32) (core func $task.return))
  (canon thread.suspend (core func $thread.suspend))
  (core instance $core (instantiate $Core (with "" (instance
    (export "task.return" (func $task.return))
    (export "thread.suspend" (func $thread.suspend))
  ))))
  (func (export "arm") async (result u32)
    (canon lift (core func $core "arm") async (callback (core func $core "exit-cb"))))
  (func (export "sync-block")
    (canon lift (core func $core "sync-block")))
)
(assert_return (invoke "arm") (u32.const 1))
(assert_trap (invoke "sync-block") "cannot block a synchronous task before returning")
