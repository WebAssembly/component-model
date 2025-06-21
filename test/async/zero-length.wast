;; This example defines 3 nested components $Producer, $Consumer and $Parent
;; $Parent imports $Consumer and $Producer, calling $Producer.produce, which
;; returns a stream that $Parent passes to $Consumer.consume.
;; $Producer and $Consumer both start by performing 0-length reads/writes to
;; detect when the other side is ready. Once signalled ready, a 4-byte
;; payload is written/read.
(component
  (component $Producer
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $CoreProducer
      (import "" "mem" (memory 1))
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "stream.new" (func $stream.new (result i64)))
      (import "" "stream.write" (func $stream.write (param i32 i32 i32) (result i32)))
      (import "" "stream.drop-writable" (func $stream.drop-writable (param i32)))

      ;; $ws is waited on by 'produce'
      (global $ws (mut i32) (i32.const 0))
      (func $start (global.set $ws (call $waitable-set.new)))
      (start $start)

      ;; $outsw is written by 'produce'
      (global $outsw (mut i32) (i32.const 0))
      (global $outbufp (mut i32) (i32.const 0x20))

      (global $state (mut i32) (i32.const 0))

      (func $produce (export "produce") (result i32)
        (local $ret i32) (local $ret64 i64) (local $outsr i32)

        ;; create a new stream r/w pair $outsr/$outsw
        (local.set $ret64 (call $stream.new))
        (local.set $outsr (i32.wrap_i64 (local.get $ret64)))
        (global.set $outsw (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))

        ;; return the readable end of the stream to the caller
        (call $task.return (local.get $outsr))

        ;; initiate a zero-length write
        (local.set $ret (call $stream.write (global.get $outsw) (i32.const 0xdeadbeef) (i32.const 0)))
        (if (i32.ne (i32.const -1) (local.get $ret))
          (then unreachable))

        ;; wait for the stream.write to complete
        (call $waitable.join (global.get $outsw) (global.get $ws))
        (i32.or (i32.const 2 (; WAIT ;)) (i32.shl (global.get $ws) (i32.const 4)))
      )
      (func $produce_cb (export "produce_cb") (param $event_code i32) (param $index i32) (param $payload i32) (result i32)
        (local $ret i32)

        ;; confirm we're getting a write for the stream $outsw
        (if (i32.ne (local.get $event_code) (i32.const 3 (; STREAM_WRITE ;)))
          (then unreachable))
        (if (i32.ne (local.get $index) (global.get $outsw))
          (then unreachable))

        ;; the first call to produce_cb:
        (if (i32.eq (global.get $state) (i32.const 0)) (then
            ;; confirm we're seeing the zero-length write complete
            (if (i32.ne (local.get $payload) (i32.const 0 (; COMPLETED=0 | (0 << 4) ;)))
              (then unreachable))

            ;; issue an async non-zero-length write which should block per spec
            (i32.store (i32.const 0) (i32.const 0x12345678))
            (local.set $ret (call $stream.write (global.get $outsw) (i32.const 0) (i32.const 4)))
            (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
              (then unreachable))

            (global.set $state (i32.const 1))

            ;; wait on $ws
            (return (i32.or (i32.const 2 (; WAIT ;)) (i32.shl (global.get $ws) (i32.const 4))))
        ))

        ;; the second call to produce_cb:
        (if (i32.eq (global.get $state) (i32.const 1)) (then
          ;; confirm we're seeing the non-zero-length write complete
          (if (i32.ne (local.get $payload) (i32.const 0x41 (; DROPPED=1 | (4 << 4) ;)))
            (then unreachable))

          (call $stream.drop-writable (global.get $outsw))
          (return (i32.const 0 (; EXIT ;)))
        ))

        unreachable
      )
    )
    (type $ST (stream u8))
    (canon task.return (result $ST) (core func $task.return))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon stream.new $ST (core func $stream.new))
    (canon stream.write $ST async (memory $memory "mem") (core func $stream.write))
    (canon stream.drop-writable $ST (core func $stream.drop-writable))
    (core instance $core_producer (instantiate $CoreProducer (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "task.return" (func $task.return))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "stream.new" (func $stream.new))
      (export "stream.write" (func $stream.write))
      (export "stream.drop-writable" (func $stream.drop-writable))
    ))))
    (func (export "produce") (result (stream u8)) (canon lift
      (core func $core_producer "produce")
      async (callback (func $core_producer "produce_cb"))
    ))
  )

  (component $Consumer
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $CoreConsumer
      (import "" "mem" (memory 1))
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "stream.read" (func $stream.read (param i32 i32 i32) (result i32)))
      (import "" "stream.drop-readable" (func $stream.drop-readable (param i32)))

      ;; $ws is waited on by 'consume'
      (global $ws (mut i32) (i32.const 0))
      (func $start (global.set $ws (call $waitable-set.new)))
      (start $start)

      ;; $insr is read by 'consume'
      (global $insr (mut i32) (i32.const 0))
      (global $inbufp (mut i32) (i32.const 0x20))

      (func $consume (export "consume") (param $insr i32) (result i32)
        (local $ret i32)
        (global.set $insr (local.get $insr))

        ;; initiate a zero-length read which will also block (even though there is
        ;; a pending write, b/c the pending write is 0-length, per spec)
        (local.set $ret (call $stream.read (global.get $insr) (i32.const 0xdeadbeef) (i32.const 0)))
        (if (i32.ne (i32.const -1) (local.get $ret))
          (then unreachable))

        ;; wait for the stream.read to complete
        (call $waitable.join (global.get $insr) (global.get $ws))
        (i32.or (i32.const 2 (; WAIT ;)) (i32.shl (global.get $ws) (i32.const 4)))
      )
      (func $consume_cb (export "consume_cb") (param $event_code i32) (param $index i32) (param $payload i32) (result i32)
        (local $ret i32)

        ;; confirm we're seeing the zero-length read complete
        (if (i32.ne (local.get $event_code) (i32.const 2 (; STREAM_READ ;)))
          (then unreachable))
        (if (i32.ne (local.get $index) (global.get $insr))
          (then unreachable))
        (if (i32.ne (local.get $payload) (i32.const 0 (; COMPLETED=0 | (0 << 4) ;)))
          (then unreachable))

        ;; perform a non-zero-length read which should succeed without blocking
        (local.set $ret (call $stream.read (global.get $insr) (i32.const 0) (i32.const 100)))
        (if (i32.ne (i32.const 0x40 (; (4 << 4) | COMPLETED=0 ;)) (local.get $ret))
          (then unreachable))
        (local.set $ret (i32.load (i32.const 0)))
        (if (i32.ne (i32.const 0x12345678) (local.get $ret))
          (then unreachable))

        (call $stream.drop-readable (global.get $insr))

        ;; return 42 to the top-level assert_return
        (call $task.return (i32.const 42))
        (i32.const 0 (; EXIT ;))
      )
    )
    (type $ST (stream u8))
    (canon task.return (result u32) (core func $task.return))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon stream.read $ST async (memory $memory "mem") (core func $stream.read))
    (canon stream.drop-readable $ST (core func $stream.drop-readable))
    (core instance $core_consumer (instantiate $CoreConsumer (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "task.return" (func $task.return))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "stream.read" (func $stream.read))
      (export "stream.drop-readable" (func $stream.drop-readable))
    ))))
    (func (export "consume") (param "in" (stream u8)) (result u32) (canon lift
      (core func $core_consumer "consume")
      async (callback (func $core_consumer "consume_cb"))
    ))
  )

  (component $Parent
    (import "produce" (func $produce (result (stream u8))))
    (import "consume" (func $consume (param "in" (stream u8)) (result u32)))

    (core module $CoreParent
      (import "" "produce" (func $produce (result i32)))
      (import "" "consume" (func $consume (param i32) (result i32)))
      (memory 1)
      (func $run (export "run") (result i32)
        (call $consume (call $produce))
      )
    )

    (canon lower (func $produce) (core func $produce'))
    (canon lower (func $consume) (core func $consume'))
    (core instance $core_parent (instantiate $CoreParent (with "" (instance
      (export "produce" (func $produce'))
      (export "consume" (func $consume'))
    ))))
    (func (export "run") (result u32) (canon lift (core func $core_parent "run")))
  )

  (instance $producer (instantiate $Producer))
  (instance $consumer (instantiate $Consumer))
  (instance $parent (instantiate $Parent
    (with "produce" (func $producer "produce"))
    (with "consume" (func $consumer "consume"))
  ))
  (func (export "run") (alias export $parent "run"))
)
(assert_return (invoke "run") (u32.const 42))
