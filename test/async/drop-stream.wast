;; This test contains two components $C and $D that test that traps occur
;; when closing the readable or writable end of stream while a read or write
;; is pending. In particular, even if a partial copy has happened into the
;; buffer such that waiting/polling for an event *would* produce a STREAM
;; READ/WRITE event, if the event has not been delivered, the operation is
;; still considered pending.
(component definition $Tester
  (component $C
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $CM
      (import "" "mem" (memory 1))
      (import "" "stream.new" (func $stream.new (result i64)))
      (import "" "stream.write" (func $stream.write (param i32 i32 i32) (result i32)))
      (import "" "stream.drop-writable" (func $stream.drop-writable (param i32)))

      (global $sw (mut i32) (i32.const 0))

      (func $start-stream (export "start-stream") (result i32)
        ;; create a new stream, return the readable end to the caller
        (local $ret64 i64)
        (local.set $ret64 (call $stream.new))
        (global.set $sw (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
        (i32.wrap_i64 (local.get $ret64))
      )
      (func $write4 (export "write4")
        ;; write 6 bytes into the stream, expecting to rendezvous with a stream.read
        (local $ret i32)
        (i32.store (i32.const 8) (i32.const 0x12345678))
        (local.set $ret (call $stream.write (global.get $sw) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 0x40 (; COMPLETED=0 | (4<<4) ;)) (local.get $ret))
          (then unreachable))
      )
      (func $start-blocking-write (export "start-blocking-write")
        (local $ret i32)

        ;; prepare the write buffer
        (i64.store (i32.const 8) (i64.const 0x123456789abcdef))

        ;; start a blocking write
        (local.set $ret (call $stream.write (global.get $sw) (i32.const 8) (i32.const 8)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))
      )
      (func $drop-writable (export "drop-writable")
        ;; boom
        (call $stream.drop-writable (global.get $sw))
      )
    )
    (type $ST (stream u8))
    (canon stream.new $ST (core func $stream.new))
    (canon stream.write $ST async (memory $memory "mem") (core func $stream.write))
    (canon stream.drop-writable $ST (core func $stream.drop-writable))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "stream.new" (func $stream.new))
      (export "stream.write" (func $stream.write))
      (export "stream.drop-writable" (func $stream.drop-writable))
    ))))
    (func (export "start-stream") (result (stream u8)) (canon lift (core func $cm "start-stream")))
    (func (export "write4") (canon lift (core func $cm "write4")))
    (func (export "start-blocking-write") (canon lift (core func $cm "start-blocking-write")))
    (func (export "drop-writable") (canon lift (core func $cm "drop-writable")))
  )
  (component $D
    (import "c" (instance $c
      (export "start-stream" (func (result (stream u8))))
      (export "write4" (func))
      (export "start-blocking-write" (func))
      (export "drop-writable" (func))
    ))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Core
      (import "" "mem" (memory 1))
      (import "" "stream.new" (func $stream.new (result i64)))
      (import "" "stream.read" (func $stream.read (param i32 i32 i32) (result i32)))
      (import "" "stream.write" (func $stream.write (param i32 i32 i32) (result i32)))
      (import "" "stream.drop-readable" (func $stream.drop-readable (param i32)))
      (import "" "stream.drop-writable" (func $stream.drop-writable (param i32)))
      (import "" "start-stream" (func $start-stream (result i32)))
      (import "" "write4" (func $write4))
      (import "" "start-blocking-write" (func $start-blocking-write))
      (import "" "drop-writable" (func $drop-writable))

      (func (export "drop-while-reading")
        (local $ret i32) (local $sr i32)

        ;; call 'start-stream' to get the stream we'll be working with
        (local.set $sr (call $start-stream))
        (if (i32.ne (i32.const 2) (local.get $sr))
          (then unreachable))

        ;; start a blocking read
        (local.set $ret (call $stream.read (local.get $sr) (i32.const 8) (i32.const 100)))
        (if (i32.ne (i32.const -1 (; BLOCKED;)) (local.get $ret))
          (then unreachable))

        ;; write into the buffer, but the read is still in progress since we
        ;; haven't received notification yet.
        (call $write4)
        (if (i32.ne (i32.const 0x12345678) (i32.load (i32.const 8)))
          (then unreachable))

        ;; boom
        (call $stream.drop-readable (local.get $sr))
      )
      (func (export "drop-while-writing")
        (local $ret i32) (local $sr i32)

        ;; call 'start-stream' to get the stream we'll be working with
        (local.set $sr (call $start-stream))
        (if (i32.ne (i32.const 2) (local.get $sr))
          (then unreachable))

        ;; start a blocking write and partially read from it
        (call $start-blocking-write)
        (local.set $ret (call $stream.read (local.get $sr) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 0x40 (; COMPLETED=0 | (4<<4) ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (i32.const 0x89abcdef) (i32.load (i32.const 8)))
          (then unreachable))
        (call $drop-writable)
      )
    )
    (type $ST (stream u8))
    (canon stream.new $ST (core func $stream.new))
    (canon stream.read $ST async (memory $memory "mem") (core func $stream.read))
    (canon stream.write $ST async (memory $memory "mem") (core func $stream.write))
    (canon stream.drop-readable $ST (core func $stream.drop-readable))
    (canon stream.drop-writable $ST (core func $stream.drop-writable))
    (canon lower (func $c "start-stream") (core func $start-stream'))
    (canon lower (func $c "write4") (core func $write4'))
    (canon lower (func $c "start-blocking-write") (core func $start-blocking-write'))
    (canon lower (func $c "drop-writable") (core func $drop-writable'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "stream.new" (func $stream.new))
      (export "stream.read" (func $stream.read))
      (export "stream.write" (func $stream.write))
      (export "stream.drop-readable" (func $stream.drop-readable))
      (export "stream.drop-writable" (func $stream.drop-writable))
      (export "start-stream" (func $start-stream'))
      (export "write4" (func $write4'))
      (export "start-blocking-write" (func $start-blocking-write'))
      (export "drop-writable" (func $drop-writable'))
    ))))
    (func (export "drop-while-reading") (canon lift (core func $core "drop-while-reading")))
    (func (export "drop-while-writing") (canon lift (core func $core "drop-while-writing")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "c" (instance $c))))
  (func (export "drop-while-reading") (alias export $d "drop-while-reading"))
  (func (export "drop-while-writing") (alias export $d "drop-while-writing"))
)
(component instance $new-tester-instance $Tester)
(assert_trap (invoke "drop-while-reading") "cannot remove busy stream")
(component instance $new-tester-instance $Tester)
(assert_trap (invoke "drop-while-writing") "cannot drop busy stream")
