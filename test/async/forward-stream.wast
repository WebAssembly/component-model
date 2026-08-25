;; This test contains two components $C and $D where $C writes into a stream
;; it created (the "source", ends $r.src/$w.src) and $D forwards that stream
;; into a second stream (the "destination", ends $r.dst/$w.dst) using the
;; stream.forward built-in, reading the forwarded elements back out of the
;; destination stream itself.
;;
;; $D exports one function per scenario. Since traps take out their containing
;; instance, a fresh instance of $Tester is created for each invoke.
(component definition $Tester
  (component $C
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $CM
      (import "" "mem" (memory 1))
      (import "" "stream.new" (func $stream.new (result i64)))
      (import "" "stream.write" (func $stream.write (param i32 i32 i32) (result i32)))
      (import "" "stream.drop-writable" (func $stream.drop-writable (param i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))

      (global $w.src (mut i32) (i32.const 0))

      (func $start-stream (export "start-stream") (result i32)
        ;; create a new stream, return the readable end to the caller
        (local $ret64 i64)
        (local.set $ret64 (call $stream.new))
        (global.set $w.src (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
        (i32.wrap_i64 (local.get $ret64))
      )
      (func $write4 (export "write4")
        ;; write 4 bytes into the stream, expecting to rendezvous with a read
        (local $ret i32)
        (i32.store (i32.const 8) (i32.const 0x12345678))
        (local.set $ret (call $stream.write (global.get $w.src) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 0x40 (; COMPLETED=0 | (4<<4) ;)) (local.get $ret))
          (then unreachable))
      )
      (func $write4-dropped (export "write4-dropped")
        ;; write expecting to observe DROPPED synchronously
        (local $ret i32)
        (local.set $ret (call $stream.write (global.get $w.src) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)) (local.get $ret))
          (then unreachable))
      )
      (func $write0 (export "write0")
        ;; zero-length write: completes with 0 elements, leaving a pending
        ;; read pending
        (local $ret i32)
        (local.set $ret (call $stream.write (global.get $w.src) (i32.const 8) (i32.const 0)))
        (if (i32.ne (i32.const 0x00 (; COMPLETED=0 | (0<<4) ;)) (local.get $ret))
          (then unreachable))
      )
      (func $start-blocking-write (export "start-blocking-write")
        (local $ret i32)

        ;; prepare the write buffer
        (i64.store (i32.const 8) (i64.const 0x123456789abcdef))

        ;; start a blocking write
        (local.set $ret (call $stream.write (global.get $w.src) (i32.const 8) (i32.const 8)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))
      )
      (func $check-write-event (export "check-write-event")
        ;; confirm the blocking write completed with all 8 elements accepted
        (local $ret i32) (local $seti i32)
        (local.set $seti (call $waitable-set.new))
        (call $waitable.join (global.get $w.src) (local.get $seti))
        (local.set $ret (call $waitable-set.wait (local.get $seti) (i32.const 0)))
        (if (i32.ne (i32.const 3 (; STREAM_WRITE ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (global.get $w.src) (i32.load (i32.const 0)))
          (then unreachable))
        (if (i32.ne (i32.const 0x80 (; COMPLETED=0 | (8<<4) ;)) (i32.load (i32.const 4)))
          (then unreachable))
        (call $waitable.join (global.get $w.src) (i32.const 0))
      )
      (func $check-write-event4 (export "check-write-event4")
        ;; confirm the blocking write completed with only 4 of its 8 elements
        (local $ret i32) (local $seti i32)
        (local.set $seti (call $waitable-set.new))
        (call $waitable.join (global.get $w.src) (local.get $seti))
        (local.set $ret (call $waitable-set.wait (local.get $seti) (i32.const 0)))
        (if (i32.ne (i32.const 3 (; STREAM_WRITE ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (global.get $w.src) (i32.load (i32.const 0)))
          (then unreachable))
        (if (i32.ne (i32.const 0x40 (; COMPLETED=0 | (4<<4) ;)) (i32.load (i32.const 4)))
          (then unreachable))
        (call $waitable.join (global.get $w.src) (i32.const 0))
      )
      (func $check-write-dropped (export "check-write-dropped")
        ;; confirm the blocking write observed DROPPED with nothing written
        (local $ret i32) (local $seti i32)
        (local.set $seti (call $waitable-set.new))
        (call $waitable.join (global.get $w.src) (local.get $seti))
        (local.set $ret (call $waitable-set.wait (local.get $seti) (i32.const 0)))
        (if (i32.ne (i32.const 3 (; STREAM_WRITE ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (global.get $w.src) (i32.load (i32.const 0)))
          (then unreachable))
        (if (i32.ne (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)) (i32.load (i32.const 4)))
          (then unreachable))
        (call $waitable.join (global.get $w.src) (i32.const 0))
      )
      (func $check-write-dropped4 (export "check-write-dropped4")
        ;; confirm the blocking write observed DROPPED after 4 of its 8
        ;; elements were accepted
        (local $ret i32) (local $seti i32)
        (local.set $seti (call $waitable-set.new))
        (call $waitable.join (global.get $w.src) (local.get $seti))
        (local.set $ret (call $waitable-set.wait (local.get $seti) (i32.const 0)))
        (if (i32.ne (i32.const 3 (; STREAM_WRITE ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (global.get $w.src) (i32.load (i32.const 0)))
          (then unreachable))
        (if (i32.ne (i32.const 0x41 (; DROPPED=1 | (4<<4) ;)) (i32.load (i32.const 4)))
          (then unreachable))
        (call $waitable.join (global.get $w.src) (i32.const 0))
      )
      (func $drop-writable (export "drop-writable")
        (call $stream.drop-writable (global.get $w.src))
      )
    )
    (type $ST (stream u8))
    (canon stream.new $ST (core func $stream.new))
    (canon stream.write $ST async (memory (core memory $memory "mem")) (core func $stream.write))
    (canon stream.drop-writable $ST (core func $stream.drop-writable))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "stream.new" (func $stream.new))
      (export "stream.write" (func $stream.write))
      (export "stream.drop-writable" (func $stream.drop-writable))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
    ))))
    (func (export "start-stream") async (result (stream u8)) (canon lift (core func $cm "start-stream")))
    (func (export "write4") async (canon lift (core func $cm "write4")))
    (func (export "write4-dropped") async (canon lift (core func $cm "write4-dropped")))
    (func (export "write0") async (canon lift (core func $cm "write0")))
    (func (export "start-blocking-write") async (canon lift (core func $cm "start-blocking-write")))
    (func (export "check-write-event") async (canon lift (core func $cm "check-write-event")))
    (func (export "check-write-event4") async (canon lift (core func $cm "check-write-event4")))
    (func (export "check-write-dropped") async (canon lift (core func $cm "check-write-dropped")))
    (func (export "check-write-dropped4") async (canon lift (core func $cm "check-write-dropped4")))
    (func (export "drop-writable") async (canon lift (core func $cm "drop-writable")))
  )
  (component $D
    (import "c" (instance $c
      (export "start-stream" (func async (result (stream u8))))
      (export "write4" (func async))
      (export "write4-dropped" (func async))
      (export "write0" (func async))
      (export "start-blocking-write" (func async))
      (export "check-write-event" (func async))
      (export "check-write-event4" (func async))
      (export "check-write-dropped" (func async))
      (export "check-write-dropped4" (func async))
      (export "drop-writable" (func async))
    ))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Core
      (import "" "mem" (memory 1))
      (import "" "stream.new" (func $stream.new (result i64)))
      (import "" "stream.new-u16" (func $stream.new-u16 (result i64)))
      (import "" "stream.read" (func $stream.read (param i32 i32 i32) (result i32)))
      (import "" "stream.read-async" (func $stream.read-async (param i32 i32 i32) (result i32)))
      (import "" "stream.write-async" (func $stream.write-async (param i32 i32 i32) (result i32)))
      (import "" "stream.forward" (func $stream.forward (param i32 i32)))
      (import "" "stream.cancel-read" (func $stream.cancel-read (param i32) (result i32)))
      (import "" "stream.drop-readable" (func $stream.drop-readable (param i32)))
      (import "" "stream.drop-writable" (func $stream.drop-writable (param i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (import "" "start-stream" (func $start-stream (result i32)))
      (import "" "write4" (func $write4))
      (import "" "write4-dropped" (func $write4-dropped))
      (import "" "write0" (func $write0))
      (import "" "start-blocking-write" (func $start-blocking-write))
      (import "" "check-write-event" (func $check-write-event))
      (import "" "check-write-event4" (func $check-write-event4))
      (import "" "check-write-dropped" (func $check-write-dropped))
      (import "" "check-write-dropped4" (func $check-write-dropped4))
      (import "" "drop-writable" (func $drop-writable))

      (global $r.src (mut i32) (i32.const 0))
      (global $r.dst (mut i32) (i32.const 0))
      (global $w.dst (mut i32) (i32.const 0))

      (func $setup
        ;; get the source stream from $C and create the destination stream
        (local $ret64 i64)
        (global.set $r.src (call $start-stream))
        (if (i32.ne (i32.const 1) (global.get $r.src))
          (then unreachable))
        (local.set $ret64 (call $stream.new))
        (global.set $r.dst (i32.wrap_i64 (local.get $ret64)))
        (global.set $w.dst (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
        (if (i32.ne (i32.const 2) (global.get $r.dst))
          (then unreachable))
        (if (i32.ne (i32.const 3) (global.get $w.dst))
          (then unreachable))
      )
      (func $expect-event (param $waitable i32) (param $event i32) (param $payload i32)
        ;; wait for the given event on the given waitable with the given payload
        (local $ret i32) (local $seti i32)
        (local.set $seti (call $waitable-set.new))
        (call $waitable.join (local.get $waitable) (local.get $seti))
        (local.set $ret (call $waitable-set.wait (local.get $seti) (i32.const 0)))
        (if (i32.ne (local.get $event) (local.get $ret))
          (then unreachable))
        (if (i32.ne (local.get $waitable) (i32.load (i32.const 0)))
          (then unreachable))
        (if (i32.ne (local.get $payload) (i32.load (i32.const 4)))
          (then unreachable))
        (call $waitable.join (local.get $waitable) (i32.const 0))
      )
      (func $read4-dst (param $expected i32)
        ;; synchronously read 4 bytes out of the destination stream
        (local $ret i32)
        (local.set $ret (call $stream.read (global.get $r.dst) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 0x40 (; COMPLETED=0 | (4<<4) ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (local.get $expected) (i32.load (i32.const 8)))
          (then unreachable))
      )
      (func $read4-dst-async
        ;; start a read on the destination stream that will block
        (local $ret i32)
        (local.set $ret (call $stream.read-async (global.get $r.dst) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))
      )
      (func $expect-read4-dst
        (call $expect-event (global.get $r.dst) (i32.const 2 (; STREAM_READ ;)) (i32.const 0x40 (; COMPLETED=0 | (4<<4) ;)))
        (if (i32.ne (i32.const 0x12345678) (i32.load (i32.const 8)))
          (then unreachable))
      )
      (func $pump4
        ;; read, block, write 4 bytes on the source, confirm the read completes
        (call $read4-dst-async)
        (call $write4)
        (call $expect-read4-dst)
      )

      (func (export "forward-rendezvous")
        (local $ret i32)
        (call $setup)

        ;; forward the source into the destination; this returns immediately
        ;; and no event is ever delivered
        (call $stream.forward (global.get $r.src) (global.get $w.dst))

        ;; with no read pending on the destination, $C's 8-byte write blocks
        (call $start-blocking-write)

        ;; two reads drain $C's write buffer, completing its write
        (call $read4-dst (i32.const 0x89abcdef))
        (call $read4-dst (i32.const 0x01234567))
        (call $check-write-event)

        ;; a blocked read on the destination rendezvous with a later write
        (call $pump4)

        ;; the end of the source stream propagates to the destination's reader
        (call $drop-writable)
        (local.set $ret (call $stream.read (global.get $r.dst) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)) (local.get $ret))
          (then unreachable))
        (call $stream.drop-readable (global.get $r.dst))
      )

      (func (export "forward-pending-read")
        (local $ret i32)
        (call $setup)

        ;; a read blocked on the destination when the forward starts is
        ;; transferred to the source
        (call $read4-dst-async)
        (call $stream.forward (global.get $r.src) (global.get $w.dst))
        (call $write4)
        (call $expect-read4-dst)

        (call $drop-writable)
        (local.set $ret (call $stream.read (global.get $r.dst) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)) (local.get $ret))
          (then unreachable))
        (call $stream.drop-readable (global.get $r.dst))
      )

      (func (export "forward-pending-write")
        (local $ret i32)
        (call $setup)

        ;; a write blocked on the source when the forward starts rendezvous
        ;; with later destination reads
        (call $start-blocking-write)
        (call $stream.forward (global.get $r.src) (global.get $w.dst))
        (call $read4-dst (i32.const 0x89abcdef))
        (call $read4-dst (i32.const 0x01234567))
        (call $check-write-event)

        (call $drop-writable)
        (local.set $ret (call $stream.read (global.get $r.dst) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)) (local.get $ret))
          (then unreachable))
        (call $stream.drop-readable (global.get $r.dst))
      )

      (func (export "forward-eos-blocked-read")
        (call $setup)
        (call $stream.forward (global.get $r.src) (global.get $w.dst))

        ;; a read blocked on the destination observes the end of the source
        (call $read4-dst-async)
        (call $drop-writable)
        (call $expect-event (global.get $r.dst) (i32.const 2 (; STREAM_READ ;)) (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)))
        (call $stream.drop-readable (global.get $r.dst))
      )

      (func (export "forward-dst-dropped")
        (call $setup)
        (call $stream.forward (global.get $r.src) (global.get $w.dst))
        (call $start-blocking-write)

        ;; dropping the destination's readable end drops the source's
        ;; readable end, so $C's blocked write observes DROPPED
        (call $stream.drop-readable (global.get $r.dst))
        (call $check-write-dropped)
        (call $drop-writable)
      )

      (func (export "forward-dst-already-dropped")
        (call $setup)

        ;; forwarding into an already-dropped destination drops the source's
        ;; readable end right away
        (call $stream.drop-readable (global.get $r.dst))
        (call $stream.forward (global.get $r.src) (global.get $w.dst))
        (call $write4-dropped)
        (call $drop-writable)
      )

      (func (export "forward-chained")
        (local $ret i32) (local $ret64 i64) (local $r.mid i32) (local $w.mid i32)
        (call $setup)
        (local.set $ret64 (call $stream.new))
        (local.set $r.mid (i32.wrap_i64 (local.get $ret64)))
        (local.set $w.mid (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))

        ;; chain two forwards through an intermediate stream: reads and the
        ;; end of the source stream propagate through both
        (call $stream.forward (global.get $r.src) (local.get $w.mid))
        (call $stream.forward (local.get $r.mid) (global.get $w.dst))
        (call $pump4)
        (call $drop-writable)
        (local.set $ret (call $stream.read (global.get $r.dst) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)) (local.get $ret))
          (then unreachable))
        (call $stream.drop-readable (global.get $r.dst))
      )

      (func (export "forward-zero-length-read")
        (local $ret i32)
        (call $setup)

        ;; a blocked zero-length read is transferred to the source and
        ;; completes on the next write without consuming any elements
        (local.set $ret (call $stream.read-async (global.get $r.dst) (i32.const 8) (i32.const 0)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))
        (call $stream.forward (global.get $r.src) (global.get $w.dst))
        (call $start-blocking-write)
        (call $expect-event (global.get $r.dst) (i32.const 2 (; STREAM_READ ;)) (i32.const 0x00 (; COMPLETED=0 | (0<<4) ;)))

        ;; the write is still pending and is drained by ordinary reads
        (call $read4-dst (i32.const 0x89abcdef))
        (call $read4-dst (i32.const 0x01234567))
        (call $check-write-event)

        (call $drop-writable)
        (local.set $ret (call $stream.read (global.get $r.dst) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)) (local.get $ret))
          (then unreachable))
        (call $stream.drop-readable (global.get $r.dst))
      )

      (func (export "forward-zero-length-write")
        (local $ret i32)
        (call $setup)
        (call $stream.forward (global.get $r.src) (global.get $w.dst))

        ;; a zero-length write leaves the forwarded read pending
        (call $read4-dst-async)
        (call $write0)
        (call $write4)
        (call $expect-read4-dst)

        (call $drop-writable)
        (local.set $ret (call $stream.read (global.get $r.dst) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)) (local.get $ret))
          (then unreachable))
        (call $stream.drop-readable (global.get $r.dst))
      )

      (func (export "forward-partially-completed-read")
        (local $ret i32)
        (call $setup)

        ;; leave a read pending on the destination with 4 of its 8 requested
        ;; elements already written
        (local.set $ret (call $stream.read-async (global.get $r.dst) (i32.const 8) (i32.const 8)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))
        (i32.store (i32.const 16) (i32.const 0xdeadbeef))
        (local.set $ret (call $stream.write-async (global.get $w.dst) (i32.const 16) (i32.const 4)))
        (if (i32.ne (i32.const 0x40 (; COMPLETED=0 | (4<<4) ;)) (local.get $ret))
          (then unreachable))

        ;; a partially completed read is completed (rather than transferred)
        ;; by the forward
        (call $stream.forward (global.get $r.src) (global.get $w.dst))
        (call $expect-event (global.get $r.dst) (i32.const 2 (; STREAM_READ ;)) (i32.const 0x40 (; COMPLETED=0 | (4<<4) ;)))
        (if (i32.ne (i32.const 0xdeadbeef) (i32.load (i32.const 8)))
          (then unreachable))

        ;; a fresh read is routed to the source as usual
        (call $pump4)

        (call $drop-writable)
        (local.set $ret (call $stream.read (global.get $r.dst) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)) (local.get $ret))
          (then unreachable))
        (call $stream.drop-readable (global.get $r.dst))
      )

      (func (export "forward-partially-completed-write")
        (local $ret i32)
        (call $setup)

        ;; leave a write pending on the source with 4 of its 8 elements
        ;; already read
        (call $start-blocking-write)
        (local.set $ret (call $stream.read (global.get $r.src) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 0x40 (; COMPLETED=0 | (4<<4) ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (i32.const 0x89abcdef) (i32.load (i32.const 8)))
          (then unreachable))

        ;; a partially completed write is completed (rather than transferred)
        ;; by the forward
        (call $stream.forward (global.get $r.src) (global.get $w.dst))
        (call $check-write-event4)

        ;; a fresh write rendezvous with a read on the destination as usual
        (call $pump4)

        (call $drop-writable)
        (local.set $ret (call $stream.read (global.get $r.dst) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)) (local.get $ret))
          (then unreachable))
        (call $stream.drop-readable (global.get $r.dst))
      )

      (func (export "forward-partially-completed-read-dropped")
        (local $ret i32)
        (call $setup)

        ;; leave a read pending on the destination with 4 of its 8 requested
        ;; elements already written
        (local.set $ret (call $stream.read-async (global.get $r.dst) (i32.const 8) (i32.const 8)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))
        (i32.store (i32.const 16) (i32.const 0xdeadbeef))
        (local.set $ret (call $stream.write-async (global.get $w.dst) (i32.const 16) (i32.const 4)))
        (if (i32.ne (i32.const 0x40 (; COMPLETED=0 | (4<<4) ;)) (local.get $ret))
          (then unreachable))

        ;; the source's writer is already gone when the forward happens, so
        ;; the partially completed read observes its progress and the end of
        ;; the source stream as a single DROPPED(4) event
        (call $drop-writable)
        (call $stream.forward (global.get $r.src) (global.get $w.dst))
        (call $expect-event (global.get $r.dst) (i32.const 2 (; STREAM_READ ;)) (i32.const 0x41 (; DROPPED=1 | (4<<4) ;)))
        (if (i32.ne (i32.const 0xdeadbeef) (i32.load (i32.const 8)))
          (then unreachable))
        (call $stream.drop-readable (global.get $r.dst))
      )

      (func (export "forward-partially-completed-write-dropped")
        (local $ret i32)
        (call $setup)

        ;; leave a write pending on the source with 4 of its 8 elements
        ;; already read
        (call $start-blocking-write)
        (local.set $ret (call $stream.read (global.get $r.src) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 0x40 (; COMPLETED=0 | (4<<4) ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (i32.const 0x89abcdef) (i32.load (i32.const 8)))
          (then unreachable))

        ;; the destination's reader is already gone when the forward happens,
        ;; so $C's write observes its partial completion and the drop
        ;; notification as a single DROPPED(4) event
        (call $stream.drop-readable (global.get $r.dst))
        (call $stream.forward (global.get $r.src) (global.get $w.dst))
        (call $check-write-dropped4)
        (call $drop-writable)
      )

      (func (export "forward-cancel-read")
        (local $ret i32)
        (call $setup)

        ;; a read transferred to the source can still be cancelled through
        ;; the destination's readable end, after which the stream remains
        ;; usable
        (call $read4-dst-async)
        (call $stream.forward (global.get $r.src) (global.get $w.dst))
        (local.set $ret (call $stream.cancel-read (global.get $r.dst)))
        (if (i32.ne (i32.const 0x02 (; CANCELLED=2 | (0<<4) ;)) (local.get $ret))
          (then unreachable))
        (call $pump4)

        (call $drop-writable)
        (local.set $ret (call $stream.read (global.get $r.dst) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)) (local.get $ret))
          (then unreachable))
        (call $stream.drop-readable (global.get $r.dst))
      )

      (func (export "forward-src-writer-already-dropped")
        (local $ret i32)
        (call $setup)

        ;; a source whose writer is already gone when the forward starts is
        ;; observed as end-of-stream by the next read of the destination's
        ;; readable end, which completes synchronously
        (call $drop-writable)
        (call $stream.forward (global.get $r.src) (global.get $w.dst))
        (local.set $ret (call $stream.read (global.get $r.dst) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)) (local.get $ret))
          (then unreachable))
        (call $stream.drop-readable (global.get $r.dst))
      )

      (func (export "forward-after-eos")
        (local $ret i32)
        (call $setup)

        ;; a readable end that observed end-of-stream can no longer be
        ;; forwarded
        (call $drop-writable)
        (local.set $ret (call $stream.read (global.get $r.src) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)) (local.get $ret))
          (then unreachable))
        ;; boom
        (call $stream.forward (global.get $r.src) (global.get $w.dst))
      )

      (func (export "forward-after-write-dropped")
        (local $ret i32)
        (call $setup)

        ;; a writable end that observed DROPPED can no longer be the target
        ;; of a forward
        (call $stream.drop-readable (global.get $r.dst))
        (local.set $ret (call $stream.write-async (global.get $w.dst) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 0x01 (; DROPPED=1 | (0<<4) ;)) (local.get $ret))
          (then unreachable))
        ;; boom
        (call $stream.forward (global.get $r.src) (global.get $w.dst))
      )

      (func (export "forward-removes-readable")
        (call $setup)
        ;; stream.forward removes both ends from the table
        (call $stream.forward (global.get $r.src) (global.get $w.dst))
        ;; boom
        (call $stream.drop-readable (global.get $r.src))
      )

      (func (export "forward-removes-writable")
        (call $setup)
        (call $stream.forward (global.get $r.src) (global.get $w.dst))
        ;; boom
        (call $stream.drop-writable (global.get $w.dst))
      )

      (func (export "forward-while-reading")
        (local $ret i32)
        (call $setup)
        (local.set $ret (call $stream.read-async (global.get $r.src) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))
        ;; boom
        (call $stream.forward (global.get $r.src) (global.get $w.dst))
      )

      (func (export "forward-while-writing")
        (local $ret i32)
        (call $setup)
        (local.set $ret (call $stream.write-async (global.get $w.dst) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))
        ;; boom
        (call $stream.forward (global.get $r.src) (global.get $w.dst))
      )

      (func (export "forward-readable-in-waitable-set")
        (local $seti i32)
        (call $setup)
        ;; forwarding an end that is in a waitable set traps
        (local.set $seti (call $waitable-set.new))
        (call $waitable.join (global.get $r.src) (local.get $seti))
        ;; boom
        (call $stream.forward (global.get $r.src) (global.get $w.dst))
      )

      (func (export "forward-writable-in-waitable-set")
        (local $seti i32)
        (call $setup)
        (local.set $seti (call $waitable-set.new))
        (call $waitable.join (global.get $w.dst) (local.get $seti))
        ;; boom
        (call $stream.forward (global.get $r.src) (global.get $w.dst))
      )

      (func (export "forward-readable-as-writable")
        (call $setup)
        ;; boom
        (call $stream.forward (global.get $r.src) (global.get $r.dst))
      )

      (func (export "forward-writable-as-readable")
        (call $setup)
        ;; boom
        (call $stream.forward (global.get $w.dst) (global.get $w.dst))
      )

      (func (export "forward-readable-type-mismatch")
        (local $ret64 i64)
        (call $setup)
        ;; the element type of the readable end must match the type immediate
        (local.set $ret64 (call $stream.new-u16))
        ;; boom
        (call $stream.forward (i32.wrap_i64 (local.get $ret64)) (global.get $w.dst))
      )

      (func (export "forward-writable-type-mismatch")
        (local $ret64 i64)
        (call $setup)
        ;; the element type of the writable end must match the type immediate
        (local.set $ret64 (call $stream.new-u16))
        ;; boom
        (call $stream.forward (global.get $r.src) (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
      )

      (func (export "self-forward")
        (local $ret64 i64) (local $r.self i32) (local $w.self i32)
        ;; a stream cannot be forwarded into itself
        (local.set $ret64 (call $stream.new))
        (local.set $r.self (i32.wrap_i64 (local.get $ret64)))
        (local.set $w.self (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
        ;; boom
        (call $stream.forward (local.get $r.self) (local.get $w.self))
      )

      (func (export "forward-cycle")
        (local $ret64 i64) (local $r.a i32) (local $w.a i32) (local $r.b i32) (local $w.b i32)
        (local.set $ret64 (call $stream.new))
        (local.set $r.a (i32.wrap_i64 (local.get $ret64)))
        (local.set $w.a (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
        (local.set $ret64 (call $stream.new))
        (local.set $r.b (i32.wrap_i64 (local.get $ret64)))
        (local.set $w.b (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))

        (call $stream.forward (local.get $r.a) (local.get $w.b))
        ;; forwarding $b back into $a would close a cycle
        ;; boom
        (call $stream.forward (local.get $r.b) (local.get $w.a))
      )
    )
    (type $ST (stream u8))
    (canon stream.new $ST (core func $stream.new))
    (type $STU16 (stream u16))
    (canon stream.new $STU16 (core func $stream.new-u16))
    (canon stream.read $ST (memory (core memory $memory "mem")) (core func $stream.read))
    (canon stream.read $ST async (memory (core memory $memory "mem")) (core func $stream.read-async))
    (canon stream.write $ST async (memory (core memory $memory "mem")) (core func $stream.write-async))
    (canon stream.forward $ST (core func $stream.forward))
    (canon stream.cancel-read $ST (core func $stream.cancel-read))
    (canon stream.drop-readable $ST (core func $stream.drop-readable))
    (canon stream.drop-writable $ST (core func $stream.drop-writable))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (canon lower (func $c "start-stream") (core func $start-stream'))
    (canon lower (func $c "write4") (core func $write4'))
    (canon lower (func $c "write4-dropped") (core func $write4-dropped'))
    (canon lower (func $c "write0") (core func $write0'))
    (canon lower (func $c "start-blocking-write") (core func $start-blocking-write'))
    (canon lower (func $c "check-write-event") (core func $check-write-event'))
    (canon lower (func $c "check-write-event4") (core func $check-write-event4'))
    (canon lower (func $c "check-write-dropped") (core func $check-write-dropped'))
    (canon lower (func $c "check-write-dropped4") (core func $check-write-dropped4'))
    (canon lower (func $c "drop-writable") (core func $drop-writable'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "stream.new" (func $stream.new))
      (export "stream.new-u16" (func $stream.new-u16))
      (export "stream.read" (func $stream.read))
      (export "stream.read-async" (func $stream.read-async))
      (export "stream.write-async" (func $stream.write-async))
      (export "stream.forward" (func $stream.forward))
      (export "stream.cancel-read" (func $stream.cancel-read))
      (export "stream.drop-readable" (func $stream.drop-readable))
      (export "stream.drop-writable" (func $stream.drop-writable))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "start-stream" (func $start-stream'))
      (export "write4" (func $write4'))
      (export "write4-dropped" (func $write4-dropped'))
      (export "write0" (func $write0'))
      (export "start-blocking-write" (func $start-blocking-write'))
      (export "check-write-event" (func $check-write-event'))
      (export "check-write-event4" (func $check-write-event4'))
      (export "check-write-dropped" (func $check-write-dropped'))
      (export "check-write-dropped4" (func $check-write-dropped4'))
      (export "drop-writable" (func $drop-writable'))
    ))))
    (func (export "forward-rendezvous") async (canon lift (core func $core "forward-rendezvous")))
    (func (export "forward-pending-read") async (canon lift (core func $core "forward-pending-read")))
    (func (export "forward-pending-write") async (canon lift (core func $core "forward-pending-write")))
    (func (export "forward-eos-blocked-read") async (canon lift (core func $core "forward-eos-blocked-read")))
    (func (export "forward-dst-dropped") async (canon lift (core func $core "forward-dst-dropped")))
    (func (export "forward-dst-already-dropped") async (canon lift (core func $core "forward-dst-already-dropped")))
    (func (export "forward-chained") async (canon lift (core func $core "forward-chained")))
    (func (export "forward-zero-length-read") async (canon lift (core func $core "forward-zero-length-read")))
    (func (export "forward-zero-length-write") async (canon lift (core func $core "forward-zero-length-write")))
    (func (export "forward-partially-completed-read") async (canon lift (core func $core "forward-partially-completed-read")))
    (func (export "forward-partially-completed-write") async (canon lift (core func $core "forward-partially-completed-write")))
    (func (export "forward-partially-completed-read-dropped") async (canon lift (core func $core "forward-partially-completed-read-dropped")))
    (func (export "forward-partially-completed-write-dropped") async (canon lift (core func $core "forward-partially-completed-write-dropped")))
    (func (export "forward-cancel-read") async (canon lift (core func $core "forward-cancel-read")))
    (func (export "forward-src-writer-already-dropped") async (canon lift (core func $core "forward-src-writer-already-dropped")))
    (func (export "forward-after-eos") async (canon lift (core func $core "forward-after-eos")))
    (func (export "forward-after-write-dropped") async (canon lift (core func $core "forward-after-write-dropped")))
    (func (export "forward-removes-readable") async (canon lift (core func $core "forward-removes-readable")))
    (func (export "forward-removes-writable") async (canon lift (core func $core "forward-removes-writable")))
    (func (export "forward-while-reading") async (canon lift (core func $core "forward-while-reading")))
    (func (export "forward-while-writing") async (canon lift (core func $core "forward-while-writing")))
    (func (export "forward-readable-in-waitable-set") async (canon lift (core func $core "forward-readable-in-waitable-set")))
    (func (export "forward-writable-in-waitable-set") async (canon lift (core func $core "forward-writable-in-waitable-set")))
    (func (export "forward-readable-as-writable") async (canon lift (core func $core "forward-readable-as-writable")))
    (func (export "forward-writable-as-readable") async (canon lift (core func $core "forward-writable-as-readable")))
    (func (export "forward-readable-type-mismatch") async (canon lift (core func $core "forward-readable-type-mismatch")))
    (func (export "forward-writable-type-mismatch") async (canon lift (core func $core "forward-writable-type-mismatch")))
    (func (export "self-forward") async (canon lift (core func $core "self-forward")))
    (func (export "forward-cycle") async (canon lift (core func $core "forward-cycle")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "c" (instance $c))))
  (func (export "forward-rendezvous") (alias export $d "forward-rendezvous"))
  (func (export "forward-pending-read") (alias export $d "forward-pending-read"))
  (func (export "forward-pending-write") (alias export $d "forward-pending-write"))
  (func (export "forward-eos-blocked-read") (alias export $d "forward-eos-blocked-read"))
  (func (export "forward-dst-dropped") (alias export $d "forward-dst-dropped"))
  (func (export "forward-dst-already-dropped") (alias export $d "forward-dst-already-dropped"))
  (func (export "forward-chained") (alias export $d "forward-chained"))
  (func (export "forward-zero-length-read") (alias export $d "forward-zero-length-read"))
  (func (export "forward-zero-length-write") (alias export $d "forward-zero-length-write"))
  (func (export "forward-partially-completed-read") (alias export $d "forward-partially-completed-read"))
  (func (export "forward-partially-completed-write") (alias export $d "forward-partially-completed-write"))
  (func (export "forward-partially-completed-read-dropped") (alias export $d "forward-partially-completed-read-dropped"))
  (func (export "forward-partially-completed-write-dropped") (alias export $d "forward-partially-completed-write-dropped"))
  (func (export "forward-cancel-read") (alias export $d "forward-cancel-read"))
  (func (export "forward-src-writer-already-dropped") (alias export $d "forward-src-writer-already-dropped"))
  (func (export "forward-after-eos") (alias export $d "forward-after-eos"))
  (func (export "forward-after-write-dropped") (alias export $d "forward-after-write-dropped"))
  (func (export "forward-removes-readable") (alias export $d "forward-removes-readable"))
  (func (export "forward-removes-writable") (alias export $d "forward-removes-writable"))
  (func (export "forward-while-reading") (alias export $d "forward-while-reading"))
  (func (export "forward-while-writing") (alias export $d "forward-while-writing"))
  (func (export "forward-readable-in-waitable-set") (alias export $d "forward-readable-in-waitable-set"))
  (func (export "forward-writable-in-waitable-set") (alias export $d "forward-writable-in-waitable-set"))
  (func (export "forward-readable-as-writable") (alias export $d "forward-readable-as-writable"))
  (func (export "forward-writable-as-readable") (alias export $d "forward-writable-as-readable"))
  (func (export "forward-readable-type-mismatch") (alias export $d "forward-readable-type-mismatch"))
  (func (export "forward-writable-type-mismatch") (alias export $d "forward-writable-type-mismatch"))
  (func (export "self-forward") (alias export $d "self-forward"))
  (func (export "forward-cycle") (alias export $d "forward-cycle"))
)
(component instance $i $Tester)
(assert_return (invoke "forward-rendezvous"))
(component instance $i $Tester)
(assert_return (invoke "forward-pending-read"))
(component instance $i $Tester)
(assert_return (invoke "forward-pending-write"))
(component instance $i $Tester)
(assert_return (invoke "forward-eos-blocked-read"))
(component instance $i $Tester)
(assert_return (invoke "forward-dst-dropped"))
(component instance $i $Tester)
(assert_return (invoke "forward-dst-already-dropped"))
(component instance $i $Tester)
(assert_return (invoke "forward-chained"))
(component instance $i $Tester)
(assert_return (invoke "forward-zero-length-read"))
(component instance $i $Tester)
(assert_return (invoke "forward-zero-length-write"))
(component instance $i $Tester)
(assert_return (invoke "forward-partially-completed-read"))
(component instance $i $Tester)
(assert_return (invoke "forward-partially-completed-write"))
(component instance $i $Tester)
(assert_return (invoke "forward-partially-completed-read-dropped"))
(component instance $i $Tester)
(assert_return (invoke "forward-partially-completed-write-dropped"))
(component instance $i $Tester)
(assert_return (invoke "forward-cancel-read"))
(component instance $i $Tester)
(assert_return (invoke "forward-src-writer-already-dropped"))
(component instance $i $Tester)
(assert_trap (invoke "forward-after-eos") "cannot forward from stream after being notified that the writable end dropped")
(component instance $i $Tester)
(assert_trap (invoke "forward-after-write-dropped") "cannot forward to stream after being notified that the readable end dropped")
(component instance $i $Tester)
(assert_trap (invoke "forward-removes-readable") "unknown handle index 1")
(component instance $i $Tester)
(assert_trap (invoke "forward-removes-writable") "unknown handle index 3")
(component instance $i $Tester)
(assert_trap (invoke "forward-while-reading") "cannot have concurrent operations active on a future/stream")
(component instance $i $Tester)
(assert_trap (invoke "forward-while-writing") "cannot have concurrent operations active on a future/stream")
(component instance $i $Tester)
(assert_trap (invoke "forward-readable-in-waitable-set") "cannot forward while either end is in a waitable set")
(component instance $i $Tester)
(assert_trap (invoke "forward-writable-in-waitable-set") "cannot forward while either end is in a waitable set")
(component instance $i $Tester)
(assert_trap (invoke "forward-readable-as-writable") "cannot have concurrent operations active on a future/stream")
(component instance $i $Tester)
(assert_trap (invoke "forward-writable-as-readable") "cannot have concurrent operations active on a future/stream")
(component instance $i $Tester)
(assert_trap (invoke "forward-readable-type-mismatch") "handle is a stream of a different type")
(component instance $i $Tester)
(assert_trap (invoke "forward-writable-type-mismatch") "handle is a stream of a different type")
(component instance $i $Tester)
(assert_trap (invoke "self-forward") "cannot forward a stream or future into itself")
(component instance $i $Tester)
(assert_trap (invoke "forward-cycle") "cannot forward a stream or future into itself")
