;; This test checks that dropping one end of a stream or future notifies the
;; other end even when that other end is idle, i.e. has no read or write in
;; flight. The notification is recorded at the time of the drop and delivered
;; exactly once, either through whatever waitable set the idle end is in or
;; inline by a subsequent read. Once it has been delivered, the end is "done"
;; and behaves like any other done end.
(component definition $Tester
  (core module $Memory (memory (export "mem") 1))
  (core instance $memory (instantiate $Memory))
  (core module $M
    (import "" "mem" (memory 1))
    (import "" "waitable.join" (func $waitable.join (param i32 i32)))
    (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
    (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
    (import "" "waitable-set.poll" (func $waitable-set.poll (param i32 i32) (result i32)))
    (import "" "waitable-set.drop" (func $waitable-set.drop (param i32)))
    (import "" "stream.new" (func $stream.new (result i64)))
    (import "" "stream.read" (func $stream.read (param i32 i32 i32) (result i32)))
    (import "" "stream.read-sync" (func $stream.read-sync (param i32 i32 i32) (result i32)))
    (import "" "stream.write" (func $stream.write (param i32 i32 i32) (result i32)))
    (import "" "stream.drop-readable" (func $stream.drop-readable (param i32)))
    (import "" "stream.drop-writable" (func $stream.drop-writable (param i32)))
    (import "" "future.new" (func $future.new (result i64)))
    (import "" "future.write" (func $future.write (param i32 i32) (result i32)))
    (import "" "future.drop-readable" (func $future.drop-readable (param i32)))
    (import "" "future.drop-writable" (func $future.drop-writable (param i32)))

    ;; The event returned by waitable-set.{wait,poll} is stored at [0,8): the
    ;; waitable index at 0 and the payload at 4. Its event code is stashed at
    ;; 0x100 and stream/future payloads land at 16.
    (global $ws (mut i32) (i32.const 0))
    (global $rx (mut i32) (i32.const 0))
    (global $tx (mut i32) (i32.const 0))

    (func $start (global.set $ws (call $waitable-set.new)))
    (start $start)

    (func $poll
      (i32.store (i32.const 0x100) (call $waitable-set.poll (global.get $ws) (i32.const 0)))
    )
    (func $wait
      (i32.store (i32.const 0x100) (call $waitable-set.wait (global.get $ws) (i32.const 0)))
    )
    (func $check-event (param $code i32) (param $index i32) (param $payload i32)
      (if (i32.ne (local.get $code) (i32.load (i32.const 0x100))) (then unreachable))
      (if (i32.ne (local.get $index) (i32.load (i32.const 0))) (then unreachable))
      (if (i32.ne (local.get $payload) (i32.load (i32.const 4))) (then unreachable))
    )
    (func $assert-no-event
      (call $poll)
      (if (i32.ne (i32.const 0 (; NONE ;)) (i32.load (i32.const 0x100))) (then unreachable))
    )
    (func $new-stream
      (local $ret64 i64)
      (local.set $ret64 (call $stream.new))
      (global.set $rx (i32.wrap_i64 (local.get $ret64)))
      (global.set $tx (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
    )
    (func $new-future
      (local $ret64 i64)
      (local.set $ret64 (call $future.new))
      (global.set $rx (i32.wrap_i64 (local.get $ret64)))
      (global.set $tx (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
    )

    ;; Park the readable end of a fresh stream in the waitable set, drop the
    ;; writable end and consume the resulting DROPPED notification. The
    ;; readable end is left joined to the set unless $unjoin.
    (func $notify-reader (param $unjoin i32)
      (call $new-stream)
      (call $waitable.join (global.get $rx) (global.get $ws))
      (call $stream.drop-writable (global.get $tx))
      (call $poll)
      (call $check-event (i32.const 2 (; STREAM_READ ;)) (global.get $rx)
                         (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)))
      (if (local.get $unjoin)
        (then (call $waitable.join (global.get $rx) (i32.const 0))))
    )
    ;; The mirror: park the writable end and drop the readable end.
    (func $notify-writer
      (call $new-stream)
      (call $waitable.join (global.get $tx) (global.get $ws))
      (call $stream.drop-readable (global.get $rx))
      (call $poll)
      (call $check-event (i32.const 3 (; STREAM_WRITE ;)) (global.get $tx)
                         (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)))
    )
    ;; Same for a future: park the writable end and drop the readable end.
    (func $notify-future-writer
      (call $new-future)
      (call $waitable.join (global.get $tx) (global.get $ws))
      (call $future.drop-readable (global.get $rx))
      (call $poll)
      (call $check-event (i32.const 5 (; FUTURE_WRITE ;)) (global.get $tx)
                         (i32.const 1 (; DROPPED ;)))
      (call $waitable.join (global.get $tx) (i32.const 0))
    )

    ;; A parked (idle, in a waitable set) readable stream end is notified when
    ;; the writable end is dropped, and the notification is one-shot.
    (func (export "reader-parked-poll") (result i32)
      (call $notify-reader (i32.const 0))
      (call $assert-no-event)
      (call $stream.drop-readable (global.get $rx))
      (call $waitable-set.drop (global.get $ws))
      (i32.const 42)
    )

    ;; Same, but delivered by waitable-set.wait, which must return immediately
    ;; instead of blocking forever: this is the motivating case for delivering
    ;; drops to idle ends at all.
    (func (export "reader-parked-wait") (result i32)
      (call $new-stream)
      (call $waitable.join (global.get $rx) (global.get $ws))
      (call $stream.drop-writable (global.get $tx))
      (call $wait)
      (call $check-event (i32.const 2 (; STREAM_READ ;)) (global.get $rx)
                         (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)))
      (call $assert-no-event)
      (call $stream.drop-readable (global.get $rx))
      (call $waitable-set.drop (global.get $ws))
      (i32.const 42)
    )

    ;; The mirror case: a parked writable stream end is notified when the
    ;; readable end is dropped.
    (func (export "writer-parked") (result i32)
      (call $notify-writer)
      (call $assert-no-event)
      (call $stream.drop-writable (global.get $tx))
      (call $waitable-set.drop (global.get $ws))
      (i32.const 42)
    )

    ;; A parked writable future end is notified when the readable end is
    ;; dropped. (Dropping it afterwards is "future-drop-writable-after-
    ;; notification" below.)
    (func (export "future-writer-parked") (result i32)
      (call $notify-future-writer)
      (call $assert-no-event)
      (call $waitable-set.drop (global.get $ws))
      (i32.const 42)
    )

    ;; With both ends in the same waitable set, dropping the writable end
    ;; produces exactly one event (for the surviving readable end).
    (func (export "both-ends-in-set") (result i32)
      (call $new-stream)
      (call $waitable.join (global.get $rx) (global.get $ws))
      (call $waitable.join (global.get $tx) (global.get $ws))
      (call $stream.drop-writable (global.get $tx))
      (call $poll)
      (call $check-event (i32.const 2 (; STREAM_READ ;)) (global.get $rx)
                         (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)))
      (call $assert-no-event)
      (call $stream.drop-readable (global.get $rx))
      (call $waitable-set.drop (global.get $ws))
      (i32.const 42)
    )

    ;; The notification is set pending when the peer is dropped, independently of
    ;; waitable set membership: joining the set afterwards still delivers it.
    (func (export "drop-before-join") (result i32)
      (call $new-stream)
      (call $stream.drop-writable (global.get $tx))
      (call $waitable.join (global.get $rx) (global.get $ws))
      (call $poll)
      (call $check-event (i32.const 2 (; STREAM_READ ;)) (global.get $rx)
                         (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)))
      (call $assert-no-event)
      (call $stream.drop-readable (global.get $rx))
      (call $waitable-set.drop (global.get $ws))
      (i32.const 42)
    )

    ;; A synchronous stream.read on an end that is in no waitable set: the
    ;; pending notification means the read reports DROPPED without blocking.
    (func (export "sync-read-consumes-notification") (result i32)
      (call $new-stream)
      (call $stream.drop-writable (global.get $tx))
      (if (i32.ne (i32.const 0x01 (; DROPPED=1 | (0<<4) ;))
                  (call $stream.read-sync (global.get $rx) (i32.const 16) (i32.const 4)))
        (then unreachable))
      (call $stream.drop-readable (global.get $rx))
      (i32.const 42)
    )

    ;; An async stream.read consumes the pending notification inline, returning
    ;; DROPPED immediately; the waitable set must then be empty (no double
    ;; delivery of the same drop).
    (func (export "read-consumes-notification") (result i32)
      (call $new-stream)
      (call $waitable.join (global.get $rx) (global.get $ws))
      (call $stream.drop-writable (global.get $tx))
      (if (i32.ne (i32.const 0x01 (; DROPPED=1 | (0<<4) ;))
                  (call $stream.read (global.get $rx) (i32.const 16) (i32.const 4)))
        (then unreachable))
      (call $assert-no-event)
      (call $stream.drop-readable (global.get $rx))
      (call $waitable-set.drop (global.get $ws))
      (i32.const 42)
    )

    ;; A notified writable future end may be dropped without having written.
    (func (export "future-drop-writable-after-notification") (result i32)
      (call $notify-future-writer)
      (call $future.drop-writable (global.get $tx))
      (call $waitable-set.drop (global.get $ws))
      (i32.const 42)
    )

    (func (export "trap-read-after-notification")
      (call $notify-reader (i32.const 0))
      (drop (call $stream.read (global.get $rx) (i32.const 16) (i32.const 4)))
      unreachable
    )

    (func (export "trap-write-after-notification")
      (call $notify-writer)
      (drop (call $stream.write (global.get $tx) (i32.const 16) (i32.const 4)))
      unreachable
    )

    (func (export "trap-future-write-after-notification")
      (call $notify-future-writer)
      (drop (call $future.write (global.get $tx) (i32.const 16)))
      unreachable
    )

    ;; Lifting a notified readable stream end out of the component traps just
    ;; like lifting any other done end.
    (func (export "trap-lift-after-notification") (result i32)
      (call $notify-reader (i32.const 1))
      (global.get $rx)
    )
  )
  (type $ST (stream u8))
  (type $FT (future u8))
  (canon waitable.join (core func $waitable.join))
  (canon waitable-set.new (core func $waitable-set.new))
  (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
  (canon waitable-set.poll (memory (core memory $memory "mem")) (core func $waitable-set.poll))
  (canon waitable-set.drop (core func $waitable-set.drop))
  (canon stream.new $ST (core func $stream.new))
  (canon stream.read $ST async (memory (core memory $memory "mem")) (core func $stream.read))
  (canon stream.read $ST (memory (core memory $memory "mem")) (core func $stream.read-sync))
  (canon stream.write $ST async (memory (core memory $memory "mem")) (core func $stream.write))
  (canon stream.drop-readable $ST (core func $stream.drop-readable))
  (canon stream.drop-writable $ST (core func $stream.drop-writable))
  (canon future.new $FT (core func $future.new))
  (canon future.write $FT async (memory (core memory $memory "mem")) (core func $future.write))
  (canon future.drop-readable $FT (core func $future.drop-readable))
  (canon future.drop-writable $FT (core func $future.drop-writable))
  (core instance $m (instantiate $M (with "" (instance
    (export "mem" (memory $memory "mem"))
    (export "waitable.join" (func $waitable.join))
    (export "waitable-set.new" (func $waitable-set.new))
    (export "waitable-set.wait" (func $waitable-set.wait))
    (export "waitable-set.poll" (func $waitable-set.poll))
    (export "waitable-set.drop" (func $waitable-set.drop))
    (export "stream.new" (func $stream.new))
    (export "stream.read" (func $stream.read))
    (export "stream.read-sync" (func $stream.read-sync))
    (export "stream.write" (func $stream.write))
    (export "stream.drop-readable" (func $stream.drop-readable))
    (export "stream.drop-writable" (func $stream.drop-writable))
    (export "future.new" (func $future.new))
    (export "future.write" (func $future.write))
    (export "future.drop-readable" (func $future.drop-readable))
    (export "future.drop-writable" (func $future.drop-writable))
  ))))
  (func (export "reader-parked-poll") (result u32) (canon lift (core func $m "reader-parked-poll")))
  (func (export "reader-parked-wait") (result u32) (canon lift (core func $m "reader-parked-wait")))
  (func (export "writer-parked") (result u32) (canon lift (core func $m "writer-parked")))
  (func (export "future-writer-parked") (result u32) (canon lift (core func $m "future-writer-parked")))
  (func (export "both-ends-in-set") (result u32) (canon lift (core func $m "both-ends-in-set")))
  (func (export "drop-before-join") (result u32) (canon lift (core func $m "drop-before-join")))
  (func (export "sync-read-consumes-notification") (result u32) (canon lift (core func $m "sync-read-consumes-notification")))
  (func (export "read-consumes-notification") (result u32) (canon lift (core func $m "read-consumes-notification")))
  (func (export "future-drop-writable-after-notification") (result u32) (canon lift (core func $m "future-drop-writable-after-notification")))
  (func (export "trap-read-after-notification") (canon lift (core func $m "trap-read-after-notification")))
  (func (export "trap-write-after-notification") (canon lift (core func $m "trap-write-after-notification")))
  (func (export "trap-future-write-after-notification") (canon lift (core func $m "trap-future-write-after-notification")))
  (func (export "trap-lift-after-notification") (result (stream u8)) (canon lift (core func $m "trap-lift-after-notification")))
)

;; $TransferTester checks that a readable stream end whose writable end has
;; already been dropped is an ordinary, transferrable value: it can be passed
;; as a parameter or returned as a result, and whichever component ends up
;; holding it observes the DROPPED notification (by reading, or by parking the
;; idle end in a waitable set). It also checks that the notification produced
;; by dropping one end reaches an idle peer held by a *different* component
;; instance, in both directions.
(component definition $TransferTester
  (component $C
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $CM
      (import "" "mem" (memory 1))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.poll" (func $waitable-set.poll (param i32 i32) (result i32)))
      (import "" "waitable-set.drop" (func $waitable-set.drop (param i32)))
      (import "" "stream.new" (func $stream.new (result i64)))
      (import "" "stream.read" (func $stream.read (param i32 i32 i32) (result i32)))
      (import "" "stream.drop-readable" (func $stream.drop-readable (param i32)))
      (import "" "stream.drop-writable" (func $stream.drop-writable (param i32)))

      (global $ws (mut i32) (i32.const 0))
      (global $tx (mut i32) (i32.const 0))

      (func $start (global.set $ws (call $waitable-set.new)))
      (start $start)

      ;; Create a stream, drop the writable end immediately and hand the
      ;; readable end (which now has a pending DROPPED notification) to the
      ;; caller.
      (func (export "make-dropped-stream") (result i32)
        (local $ret64 i64)
        (local.set $ret64 (call $stream.new))
        (call $stream.drop-writable
          (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
        (i32.wrap_i64 (local.get $ret64))
      )

      ;; Create a stream, park the writable end in our waitable set and hand
      ;; the readable end to the caller.
      (func (export "make-stream") (result i32)
        (local $ret64 i64)
        (local.set $ret64 (call $stream.new))
        (global.set $tx (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
        (call $waitable.join (global.get $tx) (global.get $ws))
        (i32.wrap_i64 (local.get $ret64))
      )

      (func (export "drop-writable")
        (call $stream.drop-writable (global.get $tx))
      )

      ;; Confirm that our parked writable end was notified that the caller
      ;; dropped the readable end, exactly once.
      (func (export "check-writer-notified") (result i32)
        (if (i32.ne (i32.const 3 (; STREAM_WRITE ;))
                    (call $waitable-set.poll (global.get $ws) (i32.const 0)))
          (then unreachable))
        (if (i32.ne (global.get $tx) (i32.load (i32.const 0))) (then unreachable))
        (if (i32.ne (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)) (i32.load (i32.const 4)))
          (then unreachable))
        (if (i32.ne (i32.const 0 (; NONE ;))
                    (call $waitable-set.poll (global.get $ws) (i32.const 0)))
          (then unreachable))
        (call $stream.drop-writable (global.get $tx))
        (call $waitable-set.drop (global.get $ws))
        (i32.const 42)
      )

      ;; Read from a stream handed to us whose writable end is already gone.
      (func (export "consume-dropped") (param $rx i32) (result i32)
        (if (i32.ne (i32.const 0x01 (; DROPPED=1 | (0<<4) ;))
                    (call $stream.read (local.get $rx) (i32.const 16) (i32.const 4)))
          (then unreachable))
        (call $stream.drop-readable (local.get $rx))
        (i32.const 42)
      )
    )
    (type $ST (stream u8))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.poll (memory (core memory $memory "mem")) (core func $waitable-set.poll))
    (canon waitable-set.drop (core func $waitable-set.drop))
    (canon stream.new $ST (core func $stream.new))
    (canon stream.read $ST async (memory (core memory $memory "mem")) (core func $stream.read))
    (canon stream.drop-readable $ST (core func $stream.drop-readable))
    (canon stream.drop-writable $ST (core func $stream.drop-writable))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.poll" (func $waitable-set.poll))
      (export "waitable-set.drop" (func $waitable-set.drop))
      (export "stream.new" (func $stream.new))
      (export "stream.read" (func $stream.read))
      (export "stream.drop-readable" (func $stream.drop-readable))
      (export "stream.drop-writable" (func $stream.drop-writable))
    ))))
    (func (export "make-dropped-stream") (result (stream u8)) (canon lift (core func $cm "make-dropped-stream")))
    (func (export "make-stream") (result (stream u8)) (canon lift (core func $cm "make-stream")))
    (func (export "drop-writable") (canon lift (core func $cm "drop-writable")))
    (func (export "check-writer-notified") (result u32) (canon lift (core func $cm "check-writer-notified")))
    (func (export "consume-dropped") (param "rx" (stream u8)) (result u32) (canon lift (core func $cm "consume-dropped")))
  )

  (component $D
    (import "c" (instance $c
      (export "make-dropped-stream" (func (result (stream u8))))
      (export "make-stream" (func (result (stream u8))))
      (export "drop-writable" (func))
      (export "check-writer-notified" (func (result u32)))
      (export "consume-dropped" (func (param "rx" (stream u8)) (result u32)))
    ))
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $DM
      (import "" "mem" (memory 1))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.poll" (func $waitable-set.poll (param i32 i32) (result i32)))
      (import "" "waitable-set.drop" (func $waitable-set.drop (param i32)))
      (import "" "stream.new" (func $stream.new (result i64)))
      (import "" "stream.read" (func $stream.read (param i32 i32 i32) (result i32)))
      (import "" "stream.drop-readable" (func $stream.drop-readable (param i32)))
      (import "" "stream.drop-writable" (func $stream.drop-writable (param i32)))
      (import "" "make-dropped-stream" (func $make-dropped-stream (result i32)))
      (import "" "make-stream" (func $make-stream (result i32)))
      (import "" "drop-writable" (func $drop-writable))
      (import "" "check-writer-notified" (func $check-writer-notified (result i32)))
      (import "" "consume-dropped" (func $consume-dropped (param i32) (result i32)))

      (func $check-dropped-event (param $ws i32) (param $rx i32)
        (if (i32.ne (i32.const 2 (; STREAM_READ ;))
                    (call $waitable-set.poll (local.get $ws) (i32.const 0)))
          (then unreachable))
        (if (i32.ne (local.get $rx) (i32.load (i32.const 0))) (then unreachable))
        (if (i32.ne (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)) (i32.load (i32.const 4)))
          (then unreachable))
        (if (i32.ne (i32.const 0 (; NONE ;))
                    (call $waitable-set.poll (local.get $ws) (i32.const 0)))
          (then unreachable))
      )

      ;; Pass an already-dropped-peer readable end to $C as a parameter.
      (func (export "transfer-as-param") (result i32)
        (local $ret64 i64) (local $rx i32)
        (local.set $ret64 (call $stream.new))
        (local.set $rx (i32.wrap_i64 (local.get $ret64)))
        (call $stream.drop-writable
          (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
        (if (i32.ne (i32.const 42) (call $consume-dropped (local.get $rx)))
          (then unreachable))
        (i32.const 42)
      )

      ;; Receive an already-dropped-peer readable end from $C as a result and
      ;; read from it.
      (func (export "transfer-as-result") (result i32)
        (local $rx i32)
        (local.set $rx (call $make-dropped-stream))
        (if (i32.ne (i32.const 0x01 (; DROPPED=1 | (0<<4) ;))
                    (call $stream.read (local.get $rx) (i32.const 16) (i32.const 4)))
          (then unreachable))
        (call $stream.drop-readable (local.get $rx))
        (i32.const 42)
      )

      ;; Same, but instead of reading, park the received end in a waitable set:
      ;; the notification travelled with the end and is reported under the
      ;; receiver's own index.
      (func (export "transfer-then-park") (result i32)
        (local $rx i32) (local $ws i32)
        (local.set $ws (call $waitable-set.new))
        (local.set $rx (call $make-dropped-stream))
        (call $waitable.join (local.get $rx) (local.get $ws))
        (call $check-dropped-event (local.get $ws) (local.get $rx))
        (call $stream.drop-readable (local.get $rx))
        (call $waitable-set.drop (local.get $ws))
        (i32.const 42)
      )

      ;; $C parks its writable end; we drop our readable end; $C is notified.
      (func (export "notify-writer-in-other-component") (result i32)
        (call $stream.drop-readable (call $make-stream))
        (if (i32.ne (i32.const 42) (call $check-writer-notified))
          (then unreachable))
        (i32.const 42)
      )

      ;; We park the readable end; $C drops its writable end; we are notified.
      (func (export "notify-reader-in-other-component") (result i32)
        (local $rx i32) (local $ws i32)
        (local.set $ws (call $waitable-set.new))
        (local.set $rx (call $make-stream))
        (call $waitable.join (local.get $rx) (local.get $ws))
        (call $drop-writable)
        (call $check-dropped-event (local.get $ws) (local.get $rx))
        (call $stream.drop-readable (local.get $rx))
        (call $waitable-set.drop (local.get $ws))
        (i32.const 42)
      )
    )
    (type $ST (stream u8))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.poll (memory (core memory $memory "mem")) (core func $waitable-set.poll))
    (canon waitable-set.drop (core func $waitable-set.drop))
    (canon stream.new $ST (core func $stream.new))
    (canon stream.read $ST async (memory (core memory $memory "mem")) (core func $stream.read))
    (canon stream.drop-readable $ST (core func $stream.drop-readable))
    (canon stream.drop-writable $ST (core func $stream.drop-writable))
    (canon lower (func $c "make-dropped-stream") (core func $make-dropped-stream'))
    (canon lower (func $c "make-stream") (core func $make-stream'))
    (canon lower (func $c "drop-writable") (core func $drop-writable'))
    (canon lower (func $c "check-writer-notified") (core func $check-writer-notified'))
    (canon lower (func $c "consume-dropped") (core func $consume-dropped'))
    (core instance $dm (instantiate $DM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.poll" (func $waitable-set.poll))
      (export "waitable-set.drop" (func $waitable-set.drop))
      (export "stream.new" (func $stream.new))
      (export "stream.read" (func $stream.read))
      (export "stream.drop-readable" (func $stream.drop-readable))
      (export "stream.drop-writable" (func $stream.drop-writable))
      (export "make-dropped-stream" (func $make-dropped-stream'))
      (export "make-stream" (func $make-stream'))
      (export "drop-writable" (func $drop-writable'))
      (export "check-writer-notified" (func $check-writer-notified'))
      (export "consume-dropped" (func $consume-dropped'))
    ))))
    (func (export "transfer-as-param") (result u32) (canon lift (core func $dm "transfer-as-param")))
    (func (export "transfer-as-result") (result u32) (canon lift (core func $dm "transfer-as-result")))
    (func (export "transfer-then-park") (result u32) (canon lift (core func $dm "transfer-then-park")))
    (func (export "notify-writer-in-other-component") (result u32) (canon lift (core func $dm "notify-writer-in-other-component")))
    (func (export "notify-reader-in-other-component") (result u32) (canon lift (core func $dm "notify-reader-in-other-component")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "c" (instance $c))))
  (func (export "transfer-as-param") (alias export $d "transfer-as-param"))
  (func (export "transfer-as-result") (alias export $d "transfer-as-result"))
  (func (export "transfer-then-park") (alias export $d "transfer-then-park"))
  (func (export "notify-writer-in-other-component") (alias export $d "notify-writer-in-other-component"))
  (func (export "notify-reader-in-other-component") (alias export $d "notify-reader-in-other-component"))
)
;; Cases that only require the idle-end notification to be delivered.
(component instance $i $Tester)
(assert_return (invoke "reader-parked-poll") (u32.const 42))
(component instance $i $Tester)
(assert_return (invoke "reader-parked-wait") (u32.const 42))
(component instance $i $Tester)
(assert_return (invoke "writer-parked") (u32.const 42))
(component instance $i $Tester)
(assert_return (invoke "future-writer-parked") (u32.const 42))
(component instance $i $Tester)
(assert_return (invoke "both-ends-in-set") (u32.const 42))
(component instance $i $Tester)
(assert_return (invoke "drop-before-join") (u32.const 42))
(component instance $i $Tester)
(assert_return (invoke "sync-read-consumes-notification") (u32.const 42))
(component instance $i $TransferTester)
(assert_return (invoke "transfer-as-param") (u32.const 42))
(component instance $i $TransferTester)
(assert_return (invoke "transfer-as-result") (u32.const 42))
(component instance $i $TransferTester)
(assert_return (invoke "transfer-then-park") (u32.const 42))
(component instance $i $TransferTester)
(assert_return (invoke "notify-writer-in-other-component") (u32.const 42))
(component instance $i $TransferTester)
(assert_return (invoke "notify-reader-in-other-component") (u32.const 42))

;; Cases that additionally require the notified end to become "done".
(component instance $i $Tester)
(assert_return (invoke "read-consumes-notification") (u32.const 42))
(component instance $i $Tester)
(assert_return (invoke "future-drop-writable-after-notification") (u32.const 42))
(component instance $i $Tester)
(assert_trap (invoke "trap-read-after-notification") "cannot read from stream after being notified that the writable end dropped")
(component instance $i $Tester)
(assert_trap (invoke "trap-write-after-notification") "cannot write to stream after being notified that the readable end dropped")
(component instance $i $Tester)
(assert_trap (invoke "trap-future-write-after-notification") "cannot write to future after previous write succeeded or readable end dropped")
(component instance $i $Tester)
(assert_trap (invoke "trap-lift-after-notification") "cannot lift stream after being notified that the writable end dropped")
