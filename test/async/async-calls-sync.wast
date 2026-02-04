;; This test contains 3 components, $AsyncInner, $SyncMiddle and $AsyncOuter,
;; where there are two instances of $SyncMiddle that import a single instance
;; of $AsyncInner, and $AsyncOuter imports all 3 preceding instances.
;;
;; $AsyncOuter.run asynchronously calls $SyncMiddle.sync-func twice concurrently
;; in each instance (4 total calls), hitting the synchronous backpressure case
;; in 2 of the 4 calls.
;;
;; $SyncMiddle.sync-func makes a blocking call to $AsyncInner.blocking-call
;; which is used to emulate a host call that blocks until $AsyncOuter.run
;; calls $AsyncInner.unblock to unblock all the 'blocking-call' calls.
(component
  (component $AsyncInner
    (core module $CoreAsyncInner
      (import "" "context.set" (func $context.set (param i32)))
      (import "" "context.get" (func $context.get (result i32)))
      (import "" "task.return0" (func $task.return0))
      (import "" "task.return1" (func $task.return1 (param i32)))

      (memory 1)
      (global $blocked (mut i32) (i32.const 1))
      (global $counter (mut i32) (i32.const 2))

      ;; 'blocking-call' cooperatively "spin-waits" until $blocked is 0.
      (func $blocking-call (export "blocking-call") (result i32)
        (call $context.set (global.get $counter))
        (global.set $counter (i32.add (i32.const 1) (global.get $counter)))
        (i32.const 1 (; YIELD ;))
      )
      (func $blocking-call-cb (export "blocking-call-cb") (param i32 i32 i32) (result i32)
        (if (i32.eqz (global.get $blocked)) (then
          (call $task.return1 (call $context.get))
          (return (i32.const 0 (; EXIT ;)))
        ))
        (i32.const 1 (; YIELD ;))
      )
      (func $unblock (export "unblock") (result i32)
        (global.set $blocked (i32.const 0))
        (call $task.return0)
        (i32.const 0 (; EXIT ;))
      )
      (func $unblock-cb (export "unblock-cb") (param i32 i32 i32) (result i32)
        unreachable
      )
    )
    (canon task.return (core func $task.return0))
    (canon task.return (result u32) (core func $task.return1))
    (canon context.set i32 0 (core func $context.set))
    (canon context.get i32 0 (core func $context.get))
    (core instance $core_async_inner (instantiate $CoreAsyncInner (with "" (instance
      (export "task.return0" (func $task.return0))
      (export "task.return1" (func $task.return1))
      (export "context.set" (func $context.set))
      (export "context.get" (func $context.get))
    ))))
    (func (export "blocking-call") async (result u32) (canon lift
      (core func $core_async_inner "blocking-call")
      async (callback (func $core_async_inner "blocking-call-cb"))
    ))
    (func (export "unblock") async (canon lift
      (core func $core_async_inner "unblock")
      async (callback (func $core_async_inner "unblock-cb"))
    ))
  )

  (component $SyncMiddle
    (import "blocking-call" (func $blocking-call async (result u32)))
    (core module $CoreSyncMiddle
      (import "" "blocking-call" (func $blocking-call (result i32)))
      (func $sync-func (export "sync-func") (result i32)
        (call $blocking-call)
      )
    )
    (canon lower (func $blocking-call) (core func $blocking-call'))
    (core instance $core_sync_middle (instantiate $CoreSyncMiddle (with "" (instance
      (export "blocking-call" (func $blocking-call'))
    ))))
    (func (export "sync-func") async (result u32) (canon lift
      (core func $core_sync_middle "sync-func")
    ))
  )

  (component $AsyncMiddle
    (import "blocking-call" (func $blocking-call async (result u32)))
    (core module $CoreSyncMiddle
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "blocking-call" (func $blocking-call (result i32)))
      (func $sync-func (export "sync-func") (result i32)
        (call $task.return (call $blocking-call))
        (i32.const 0 (; EXIT ;))
      )
      (func $sync-func-cb (export "sync-func-cb") (param i32 i32 i32) (result i32)
        unreachable
      )
    )
    (canon task.return (result u32) (core func $task.return))
    (canon lower (func $blocking-call) (core func $blocking-call'))
    (core instance $core_sync_middle (instantiate $CoreSyncMiddle (with "" (instance
      (export "task.return" (func $task.return))
      (export "blocking-call" (func $blocking-call'))
    ))))
    (func (export "sync-func") async (result u32) (canon lift
      (core func $core_sync_middle "sync-func")
      async (callback (func $core_sync_middle "sync-func-cb"))
    ))
  )

  (component $AsyncOuter
    (import "unblock" (func $unblock async))
    (import "sync-func1" (func $sync-func1 async (result u32)))
    (import "sync-func2" (func $sync-func2 async (result u32)))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $CoreAsyncOuter
      (import "" "mem" (memory 1))
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "subtask.drop" (func $subtask.drop (param i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "unblock" (func $unblock))
      (import "" "sync-func1" (func $sync-func1 (param i32) (result i32)))
      (import "" "sync-func2" (func $sync-func2 (param i32) (result i32)))

      (global $ws (mut i32) (i32.const 0))
      (func $start (global.set $ws (call $waitable-set.new)))
      (start $start)

      ;; set $remain to the number of tasks to wait to complete
      (global $remain (mut i32) (i32.const 4))

      (func $run (export "run") (result i32)
        (local $ret i32)

        ;; call 'sync-func1' and 'sync-func2' asynchronously, both of which will block
        ;; (on $AsyncInner.blocking-call). because 'sync-func1/2' are in different instances,
        ;; both calls will reach the STARTED state.
        (local.set $ret (call $sync-func1 (i32.const 8)))
        (if (i32.ne (i32.const 0x21 (; STARTED=1 | (subtask=2 << 4) ;)) (local.get $ret))
          (then unreachable))
        (call $waitable.join (i32.const 2) (global.get $ws))
        (local.set $ret (call $sync-func2 (i32.const 12)))
        (if (i32.ne (i32.const 0x31 (; STARTED=1 | (subtask=3 << 4) ;)) (local.get $ret))
          (then unreachable))
        (call $waitable.join (i32.const 3) (global.get $ws))

        ;; now start another pair of 'sync-func1/2' calls, both of which should see auto
        ;; backpressure and get stuck in the STARTING state.
        (local.set $ret (call $sync-func1 (i32.const 16)))
        (if (i32.ne (i32.const 0x40 (; STARTING=0 | (subtask=4 << 4) ;)) (local.get $ret))
          (then unreachable))
        (call $waitable.join (i32.const 4) (global.get $ws))
        (local.set $ret (call $sync-func2 (i32.const 20)))
        (if (i32.ne (i32.const 0x50 (; STARTING=0 | (subtask=5 << 4) ;)) (local.get $ret))
          (then unreachable))
        (call $waitable.join (i32.const 5) (global.get $ws))

        ;; unblock all the tasks and start waiting to complete
        (call $unblock)
        (i32.or (i32.const 2 (; WAIT ;)) (i32.shl (global.get $ws) (i32.const 4)))
      )
      (func $run-cb (export "run-cb") (param $event_code i32) (param $index i32) (param $payload i32) (result i32)
        (local $ret i32)

        ;; confirm we only receive SUBTASK events.
        (if (i32.ne (local.get $event_code) (i32.const 1 (; SUBTASK ;)))
          (then unreachable))

        ;; if we receive a SUBTASK STARTED event, it should only be for the 3rd or
        ;; 4th subtask (at indices 4/5, resp), so keep waiting for completion
        (if (i32.eq (local.get $payload) (i32.const 1 (; STARTED ;))) (then
          (if (i32.and
                (i32.ne (local.get $index) (i32.const 4))
                (i32.ne (local.get $index) (i32.const 5)))
            (then unreachable))
          (return (i32.or (i32.const 2 (; WAIT ;)) (i32.shl (global.get $ws) (i32.const 4))))
        ))

        ;; when we receive a SUBTASK RETURNED event, check the return value is equal to the
        ;; subtask index (which we've ensured by having $AsyncInner.$counter start at 2, the
        ;; first subtask index. The address of the return buffer is the index*4.
        (if (i32.ne (local.get $payload) (i32.const 2 (; RETURNED ;)))
          (then unreachable))
        (if (i32.ne (local.get $index) (i32.load (i32.mul (local.get $index) (i32.const 4))))
          (then unreachable))

        ;; decrement $remain and exit if 0
        (call $subtask.drop (local.get $index))
        (global.set $remain (i32.sub (global.get $remain) (i32.const 1)))
        (if (i32.gt_u (global.get $remain) (i32.const 0)) (then
          (return (i32.or (i32.const 2 (; WAIT ;)) (i32.shl (global.get $ws) (i32.const 4))))
        ))
        (call $task.return (i32.const 42))
        (i32.const 0 (; EXIT ;))
      )
    )
    (canon task.return (result u32) (core func $task.return))
    (canon subtask.drop (core func $subtask.drop))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon lower (func $unblock) (core func $unblock))
    (canon lower (func $sync-func1) async (memory $memory "mem") (core func $sync-func1'))
    (canon lower (func $sync-func2) async (memory $memory "mem") (core func $sync-func2'))
    (core instance $em (instantiate $CoreAsyncOuter (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "task.return" (func $task.return))
      (export "subtask.drop" (func $subtask.drop))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "unblock" (func $unblock))
      (export "sync-func1" (func $sync-func1'))
      (export "sync-func2" (func $sync-func2'))
    ))))
    (func (export "run") async (result u32) (canon lift
      (core func $em "run")
      async (callback (func $em "run-cb"))
    ))
  )

  ;; run1 uses $SyncMiddle
  (instance $async_inner1 (instantiate $AsyncInner))
  (instance $sync_middle11 (instantiate $SyncMiddle
    (with "blocking-call" (func $async_inner1 "blocking-call"))
  ))
  (instance $sync_middle12 (instantiate $SyncMiddle
    (with "blocking-call" (func $async_inner1 "blocking-call"))
  ))
  (instance $async_outer1 (instantiate $AsyncOuter
    (with "unblock" (func $async_inner1 "unblock"))
    (with "sync-func1" (func $sync_middle11 "sync-func"))
    (with "sync-func2" (func $sync_middle12 "sync-func"))
  ))
  (func (export "run1") (alias export $async_outer1 "run"))

  ;; run2 uses $AsyncMiddle
  (instance $async_inner2 (instantiate $AsyncInner))
  (instance $sync_middle21 (instantiate $SyncMiddle
    (with "blocking-call" (func $async_inner2 "blocking-call"))
  ))
  (instance $sync_middle22 (instantiate $AsyncMiddle
    (with "blocking-call" (func $async_inner2 "blocking-call"))
  ))
  (instance $async_outer2 (instantiate $AsyncOuter
    (with "unblock" (func $async_inner2 "unblock"))
    (with "sync-func1" (func $sync_middle21 "sync-func"))
    (with "sync-func2" (func $sync_middle22 "sync-func"))
  ))
  (func (export "run2") (alias export $async_outer2 "run"))
)
(assert_return (invoke "run1") (u32.const 42))
(assert_return (invoke "run2") (u32.const 42))
