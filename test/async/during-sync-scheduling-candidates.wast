;; Test which threads may be resumed while a non-async-typed export call is in
;; progress, in two contexts:
;;  - implicitly, as part of sync-call scheduling: when the implicit thread of
;;    a non-async-typed call blocks, the runtime resumes (nondeterministically)
;;    ready threads of the same component instance until the call resolves
;;  - explicitly, via the thread.{suspend,yield}-then-promote built-ins, which
;;    switch directly to the target thread when it is ready
;;
;; Every ready thread of the same component instance is a valid candidate,
;; including the implicit threads of async-typed tasks using the sync or
;; callback ABIs (which take the instance's exclusive lock while they execute
;; core wasm). Each component below tests one kind of thread in both contexts,
;; side by side: 'run' blocks with plain thread.yield, so resumption happens
;; implicitly as part of sync-call scheduling, while 'run-promote' targets the
;; thread in question explicitly with thread.yield-then-promote. In each case,
;; 'run' and 'run-promote' can only complete if the target thread is resumed.

;; Explicit threads (including of the sync task itself)
(component
  (core module $Table (table (export "__indirect_function_table") 1 funcref))
  (core instance $table (instantiate $Table))
  (core module $Core
    (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
    (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
    (import "" "thread.yield" (func $thread.yield (result i32)))
    (import "" "thread.yield-then-promote" (func $thread.yield-then-promote (param i32) (result i32)))
    (import "" "__indirect_function_table" (table $tbl 1 funcref))

    (global $worker-ran (mut i32) (i32.const 0))
    (global $worker-thread (mut i32) (i32.const 0))

    (func $worker (param i32)
      (global.set $worker-ran (i32.const 1)))
    (elem (table $tbl) (i32.const 0) func $worker)

    (func $spawn-worker
      (global.set $worker-ran (i32.const 0))
      (global.set $worker-thread (call $thread.new-indirect (i32.const 0) (i32.const 0)))
      (call $thread.resume-later (global.get $worker-thread)))

    (func (export "run") (result i32)
      (call $spawn-worker)
      (loop $again
        (drop (call $thread.yield))
        (br_if $again (i32.eqz (global.get $worker-ran))))
      (i32.const 42))

    (func (export "run-promote") (result i32)
      (call $spawn-worker)
      (drop (call $thread.yield-then-promote (global.get $worker-thread)))
      (if (i32.eqz (global.get $worker-ran))
        (then unreachable))
      (i32.const 42))
  )
  (core type $start-func-ty (func (param i32)))
  (alias core export $table "__indirect_function_table" (core table $indirect-function-table))
  (core func $thread.new-indirect
    (canon thread.new-indirect $start-func-ty (core table $indirect-function-table)))
  (canon thread.resume-later (core func $thread.resume-later))
  (canon thread.yield (core func $thread.yield))
  (canon thread.yield-then-promote (core func $thread.yield-then-promote))
  (core instance $core (instantiate $Core (with "" (instance
    (export "thread.new-indirect" (func $thread.new-indirect))
    (export "thread.resume-later" (func $thread.resume-later))
    (export "thread.yield" (func $thread.yield))
    (export "thread.yield-then-promote" (func $thread.yield-then-promote))
    (export "__indirect_function_table" (table $indirect-function-table))
  ))))
  (func (export "run") (result u32)
    (canon lift (core func $core "run")))
  (func (export "run-promote") (result u32)
    (canon lift (core func $core "run-promote")))
)
(assert_return (invoke "run") (u32.const 42))
(assert_return (invoke "run-promote") (u32.const 42))

;; Implicit thread of a stackful async task
(component
  (core module $Core
    (import "" "task.return" (func $task.return (param i32)))
    (import "" "thread.index" (func $thread.index (result i32)))
    (import "" "thread.yield" (func $thread.yield (result i32)))
    (import "" "thread.yield-then-promote" (func $thread.yield-then-promote (param i32) (result i32)))

    (global $finished (mut i32) (i32.const 0))
    (global $may-finish (mut i32) (i32.const 0))
    (global $setup-thread (mut i32) (i32.const 0))

    (func (export "setup")
      (global.set $finished (i32.const 0))
      (global.set $may-finish (i32.const 0))
      (global.set $setup-thread (call $thread.index))
      (call $task.return (i32.const 1))
      ;; keep yielding (and thus keep $setup-thread valid) until 'run' or
      ;; 'run-promote' says it's ok to finish
      (loop $again
        (drop (call $thread.yield))
        (br_if $again (i32.eqz (global.get $may-finish))))
      (global.set $finished (i32.const 1)))

    (func (export "run") (result i32)
      (global.set $may-finish (i32.const 1))
      (loop $again
        (drop (call $thread.yield))
        (br_if $again (i32.eqz (global.get $finished))))
      (i32.const 42))

    (func (export "run-promote") (result i32)
      (global.set $may-finish (i32.const 1))
      (drop (call $thread.yield-then-promote (global.get $setup-thread)))
      (if (i32.eqz (global.get $finished))
        (then unreachable))
      (i32.const 42))
  )
  (canon task.return (result u32) (core func $task.return))
  (canon thread.index (core func $thread.index))
  (canon thread.yield (core func $thread.yield))
  (canon thread.yield-then-promote (core func $thread.yield-then-promote))
  (core instance $core (instantiate $Core (with "" (instance
    (export "task.return" (func $task.return))
    (export "thread.index" (func $thread.index))
    (export "thread.yield" (func $thread.yield))
    (export "thread.yield-then-promote" (func $thread.yield-then-promote))
  ))))
  (func (export "setup") async (result u32)
    (canon lift (core func $core "setup") async))
  (func (export "run") (result u32)
    (canon lift (core func $core "run")))
  (func (export "run-promote") (result u32)
    (canon lift (core func $core "run-promote")))
)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run") (u32.const 42))
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run-promote") (u32.const 42))

;; Implicit thread of an async callback task waiting in an event loop: it is
;; ready while parked, so it may be resumed during a non-async-typed call,
;; running its callback in the middle of the sync call. Here, 'run' and
;; 'run-promote' cannot complete until 'setup-cb' observes the sync call in
;; progress. 'run' is additionally called from an async callback task in a
;; separate driver component instance to check that this scheduling is
;; unaffected by the caller's task kind.
(component
  (component $C
    (core module $Core
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "thread.yield" (func $thread.yield (result i32)))
      (import "" "thread.yield-then-promote" (func $thread.yield-then-promote (param i32) (result i32)))

      (global $setup-thread (mut i32) (i32.const 0))
      (global $in-sync-call (mut i32) (i32.const 0))
      (global $cb-ran (mut i32) (i32.const 0))

      (func (export "setup") (result i32)
        (global.set $setup-thread (call $thread.index))
        (call $task.return (i32.const 1))
        (i32.const 1 (; YIELD ;)))

      ;; Since setup's YIELD may nondeterministically complete without
      ;; suspending, 'setup-cb' may also be called (with a NONE event) while no
      ;; non-async-typed call is in progress; either way it parks the thread
      ;; again so it stays available for the next 'run*'.
      (func (export "setup-cb") (param i32 i32 i32) (result i32)
        (if (global.get $in-sync-call)
          (then (global.set $cb-ran (i32.const 1))))
        (i32.const 1 (; YIELD ;)))

      (func (export "run") (result i32)
        (global.set $cb-ran (i32.const 0))
        (global.set $in-sync-call (i32.const 1))
        (loop $again
          (drop (call $thread.yield))
          (br_if $again (i32.eqz (global.get $cb-ran))))
        (global.set $in-sync-call (i32.const 0))
        (i32.const 42))

      (func (export "run-promote") (result i32)
        (global.set $cb-ran (i32.const 0))
        (global.set $in-sync-call (i32.const 1))
        (drop (call $thread.yield-then-promote (global.get $setup-thread)))
        (if (i32.eqz (global.get $cb-ran))
          (then unreachable))
        (global.set $in-sync-call (i32.const 0))
        (i32.const 42))
    )
    (canon task.return (result u32) (core func $task.return))
    (canon thread.index (core func $thread.index))
    (canon thread.yield (core func $thread.yield))
    (canon thread.yield-then-promote (core func $thread.yield-then-promote))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return" (func $task.return))
      (export "thread.index" (func $thread.index))
      (export "thread.yield" (func $thread.yield))
      (export "thread.yield-then-promote" (func $thread.yield-then-promote))
    ))))
    (func (export "setup") async (result u32)
      (canon lift (core func $core "setup") async (callback (core func $core "setup-cb"))))
    (func (export "run") (result u32)
      (canon lift (core func $core "run")))
    (func (export "run-promote") (result u32)
      (canon lift (core func $core "run-promote")))
  )
  (component $D
    (import "run" (func $run (result u32)))
    (core module $Core
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "run" (func $run (result i32)))

      (func (export "driver") (result i32)
        (call $task.return (call $run))
        (i32.const 0 (; EXIT ;)))

      (func (export "driver-cb") (param i32 i32 i32) (result i32)
        unreachable)
    )
    (canon task.return (result u32) (core func $task.return))
    (canon lower (func $run) (core func $run'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return" (func $task.return))
      (export "run" (func $run'))
    ))))
    (func (export "driver") async (result u32)
      (canon lift (core func $core "driver") async (callback (core func $core "driver-cb"))))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "run" (func $c "run"))))
  (func (export "setup") (alias export $c "setup"))
  (func (export "run") (alias export $c "run"))
  (func (export "run-promote") (alias export $c "run-promote"))
  (func (export "driver") (alias export $d "driver"))
)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run") (u32.const 42))
(assert_return (invoke "driver") (u32.const 42))
(assert_return (invoke "run-promote") (u32.const 42))

;; Implicit thread of an async callback task blocked not in the event loop
;; (suspended mid-frame, still holding the instance's exclusive lock): once
;; made ready, it may be resumed during a non-async-typed call; here its
;; resumption is required for 'run' and 'run-promote' to complete. Since 'run'
;; and 'run-promote' each make setup's suspended thread ready and then consume
;; it, each runs in a fresh instance.
(component definition $BlockedCallbackTester
  (core module $Core
    (import "" "task.return" (func $task.return (param i32)))
    (import "" "thread.index" (func $thread.index (result i32)))
    (import "" "thread.suspend" (func $thread.suspend (result i32)))
    (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
    (import "" "thread.yield" (func $thread.yield (result i32)))
    (import "" "thread.yield-then-promote" (func $thread.yield-then-promote (param i32) (result i32)))

    (global $setup-thread (mut i32) (i32.const 0))
    (global $resumed (mut i32) (i32.const 0))

    (func (export "setup") (result i32)
      (global.set $setup-thread (call $thread.index))
      (call $task.return (i32.const 1))
      (drop (call $thread.suspend))
      (global.set $resumed (i32.const 1))
      (i32.const 0 (; EXIT ;)))

    (func (export "setup-cb") (param i32 i32 i32) (result i32)
      unreachable)

    (func (export "run") (result i32)
      (call $thread.resume-later (global.get $setup-thread))
      (loop $again
        (drop (call $thread.yield))
        (br_if $again (i32.eqz (global.get $resumed))))
      (i32.const 42))

    (func (export "run-promote") (result i32)
      (call $thread.resume-later (global.get $setup-thread))
      (drop (call $thread.yield-then-promote (global.get $setup-thread)))
      (if (i32.eqz (global.get $resumed))
        (then unreachable))
      (i32.const 42))
  )
  (canon task.return (result u32) (core func $task.return))
  (canon thread.index (core func $thread.index))
  (canon thread.suspend (core func $thread.suspend))
  (canon thread.resume-later (core func $thread.resume-later))
  (canon thread.yield (core func $thread.yield))
  (canon thread.yield-then-promote (core func $thread.yield-then-promote))
  (core instance $core (instantiate $Core (with "" (instance
    (export "task.return" (func $task.return))
    (export "thread.index" (func $thread.index))
    (export "thread.suspend" (func $thread.suspend))
    (export "thread.resume-later" (func $thread.resume-later))
    (export "thread.yield" (func $thread.yield))
    (export "thread.yield-then-promote" (func $thread.yield-then-promote))
  ))))
  (func (export "setup") async (result u32)
    (canon lift (core func $core "setup") async (callback (core func $core "setup-cb"))))
  (func (export "run") (result u32)
    (canon lift (core func $core "run")))
  (func (export "run-promote") (result u32)
    (canon lift (core func $core "run-promote")))
)

(component instance $i $BlockedCallbackTester)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run") (u32.const 42))

(component instance $i $BlockedCallbackTester)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run-promote") (u32.const 42))

;; Implicit thread of a synchronously-lifted async-typed function (blocked
;; mid-frame, holding the instance's exclusive lock): once made ready, it may
;; be resumed during a non-async-typed call; here its resumption is required
;; for 'run' and 'run-promote' to complete (and also resolves the async task).
(component definition $SyncLiftedTester
  (component $I
    (core module $Core
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "thread.suspend" (func $thread.suspend (result i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "thread.yield" (func $thread.yield (result i32)))
      (import "" "thread.yield-then-promote" (func $thread.yield-then-promote (param i32) (result i32)))

      (global $f-started (mut i32) (i32.const 0))
      (global $f-thread (mut i32) (i32.const 0))
      (global $resumed (mut i32) (i32.const 0))

      (func (export "f")
        (global.set $f-started (i32.const 1))
        (global.set $f-thread (call $thread.index))
        (drop (call $thread.suspend))
        (global.set $resumed (i32.const 1)))

      (func (export "run") (result i32)
        (if (i32.eqz (global.get $f-started))
          (then unreachable))
        (call $thread.resume-later (global.get $f-thread))
        (loop $again
          (drop (call $thread.yield))
          (br_if $again (i32.eqz (global.get $resumed))))
        (i32.const 42))

      (func (export "run-promote") (result i32)
        (if (i32.eqz (global.get $f-started))
          (then unreachable))
        (call $thread.resume-later (global.get $f-thread))
        (drop (call $thread.yield-then-promote (global.get $f-thread)))
        (if (i32.eqz (global.get $resumed))
          (then unreachable))
        (i32.const 42))
    )
    (canon thread.index (core func $thread.index))
    (canon thread.suspend (core func $thread.suspend))
    (canon thread.resume-later (core func $thread.resume-later))
    (canon thread.yield (core func $thread.yield))
    (canon thread.yield-then-promote (core func $thread.yield-then-promote))
    (core instance $core (instantiate $Core (with "" (instance
      (export "thread.index" (func $thread.index))
      (export "thread.suspend" (func $thread.suspend))
      (export "thread.resume-later" (func $thread.resume-later))
      (export "thread.yield" (func $thread.yield))
      (export "thread.yield-then-promote" (func $thread.yield-then-promote))
    ))))
    (func (export "f") async
      (canon lift (core func $core "f")))
    (func (export "run") (result u32)
      (canon lift (core func $core "run")))
    (func (export "run-promote") (result u32)
      (canon lift (core func $core "run-promote")))
  )
  (component $D
    (import "f" (func $f async))
    (core module $Core
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "f" (func $f (result i32)))

      (func (export "setup") (result i32)
        ;; The async-lowered call must come back blocked in the STARTED state.
        (if (i32.ne (i32.and (call $f) (i32.const 0xf)) (i32.const 1 (; STARTED ;)))
          (then unreachable))
        (call $task.return (i32.const 1))
        (i32.const 0 (; EXIT ;)))

      (func (export "setup-cb") (param i32 i32 i32) (result i32)
        unreachable)
    )
    (canon task.return (result u32) (core func $task.return))
    (canon lower (func $f) async (core func $f'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "task.return" (func $task.return))
      (export "f" (func $f'))
    ))))
    (func (export "setup") async (result u32)
      (canon lift (core func $core "setup") async (callback (core func $core "setup-cb"))))
  )
  (instance $i (instantiate $I))
  (instance $d (instantiate $D (with "f" (func $i "f"))))
  (func (export "setup") (alias export $d "setup"))
  (func (export "run") (alias export $i "run"))
  (func (export "run-promote") (alias export $i "run-promote"))
)

(component instance $i $SyncLiftedTester)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run") (u32.const 42))

(component instance $i $SyncLiftedTester)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run-promote") (u32.const 42))

;; Explicit threads may be promoted when their task is an async callback task
;; whose own implicit thread is parked in its event loop (the parked implicit
;; thread may also be resumed during the sync call; it just parks again).
(component
  (core module $Table (table (export "__indirect_function_table") 2 funcref))
  (core instance $table (instantiate $Table))
  (core module $Core
    (import "" "task.return" (func $task.return (param i32)))
    (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
    (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
    (import "" "thread.yield" (func $thread.yield (result i32)))
    (import "" "thread.yield-then-promote" (func $thread.yield-then-promote (param i32) (result i32)))
    (import "" "__indirect_function_table" (table $tbl 2 funcref))

    (global $worker0-ran (mut i32) (i32.const 0))
    (global $worker0-thread (mut i32) (i32.const 0))
    (global $worker1-ran (mut i32) (i32.const 0))
    (global $worker1-thread (mut i32) (i32.const 0))

    (func $worker0 (param i32)
      (global.set $worker0-ran (i32.const 1)))
    (func $worker1 (param i32)
      (global.set $worker1-ran (i32.const 1)))
    (elem (table $tbl) (i32.const 0) func $worker0 $worker1)

    (func (export "setup") (result i32)
      (global.set $worker0-thread (call $thread.new-indirect (i32.const 0) (i32.const 0)))
      (global.set $worker1-thread (call $thread.new-indirect (i32.const 1) (i32.const 0)))
      (call $task.return (i32.const 1))
      (i32.const 1 (; YIELD ;)))

    (func (export "setup-cb") (param i32 i32 i32) (result i32)
      (i32.const 1 (; YIELD ;)))

    (func (export "run") (result i32)
      (call $thread.resume-later (global.get $worker0-thread))
      (loop $again
        (drop (call $thread.yield))
        (br_if $again (i32.eqz (global.get $worker0-ran))))
      (i32.const 42))

    (func (export "run-promote") (result i32)
      (call $thread.resume-later (global.get $worker1-thread))
      (loop $again
        (drop (call $thread.yield-then-promote (global.get $worker1-thread)))
        (br_if $again (i32.eqz (global.get $worker1-ran))))
      (i32.const 42))
  )
  (core type $start-func-ty (func (param i32)))
  (alias core export $table "__indirect_function_table" (core table $indirect-function-table))
  (core func $thread.new-indirect
    (canon thread.new-indirect $start-func-ty (core table $indirect-function-table)))
  (canon task.return (result u32) (core func $task.return))
  (canon thread.resume-later (core func $thread.resume-later))
  (canon thread.yield (core func $thread.yield))
  (canon thread.yield-then-promote (core func $thread.yield-then-promote))
  (core instance $core (instantiate $Core (with "" (instance
    (export "task.return" (func $task.return))
    (export "thread.new-indirect" (func $thread.new-indirect))
    (export "thread.resume-later" (func $thread.resume-later))
    (export "thread.yield" (func $thread.yield))
    (export "thread.yield-then-promote" (func $thread.yield-then-promote))
    (export "__indirect_function_table" (table $indirect-function-table))
  ))))
  (func (export "setup") async (result u32)
    (canon lift (core func $core "setup") async (callback (core func $core "setup-cb"))))
  (func (export "run") (result u32)
    (canon lift (core func $core "run")))
  (func (export "run-promote") (result u32)
    (canon lift (core func $core "run-promote")))
)
(assert_return (invoke "setup") (u32.const 1))
(assert_return (invoke "run") (u32.const 42))
(assert_return (invoke "run-promote") (u32.const 42))
