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
      (import "" "stream.close-writable" (func $stream.close-writable (param i32)))

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
      (func $close-writable (export "close-writable")
        ;; boom
        (call $stream.close-writable (global.get $sw))
      )
    )
    (type $ST (stream u8))
    (canon stream.new $ST (core func $stream.new))
    (canon stream.write $ST async (memory $memory "mem") (core func $stream.write))
    (canon stream.close-writable $ST (core func $stream.close-writable))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "stream.new" (func $stream.new))
      (export "stream.write" (func $stream.write))
      (export "stream.close-writable" (func $stream.close-writable))
    ))))
    (func (export "start-stream") (result (stream u8)) (canon lift (core func $cm "start-stream")))
    (func (export "write4") (canon lift (core func $cm "write4")))
    (func (export "start-blocking-write") (canon lift (core func $cm "start-blocking-write")))
    (func (export "close-writable") (canon lift (core func $cm "close-writable")))
  )
  (component $D
    (import "c" (instance $c
      (export "start-stream" (func (result (stream u8))))
      (export "write4" (func))
      (export "start-blocking-write" (func))
      (export "close-writable" (func))
    ))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Core
      (import "" "mem" (memory 1))
      (import "" "stream.new" (func $stream.new (result i64)))
      (import "" "stream.read" (func $stream.read (param i32 i32 i32) (result i32)))
      (import "" "stream.write" (func $stream.write (param i32 i32 i32) (result i32)))
      (import "" "stream.close-readable" (func $stream.close-readable (param i32)))
      (import "" "stream.close-writable" (func $stream.close-writable (param i32)))
      (import "" "start-stream" (func $start-stream (result i32)))
      (import "" "write4" (func $write4))
      (import "" "start-blocking-write" (func $start-blocking-write))
      (import "" "close-writable" (func $close-writable))

      (func (export "close-while-reading")
        (local $ret i32) (local $sr i32)

        ;; call 'start-stream' to get the stream we'll be working with
        (local.set $sr (call $start-stream))
        (if (i32.ne (i32.const 1) (local.get $sr))
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
        (call $stream.close-readable (local.get $sr))
      )
      (func (export "close-while-writing")
        (local $ret i32) (local $sr i32)

        ;; call 'start-stream' to get the stream we'll be working with
        (local.set $sr (call $start-stream))
        (if (i32.ne (i32.const 1) (local.get $sr))
          (then unreachable))

        ;; start a blocking write and partially read from it
        (call $start-blocking-write)
        (local.set $ret (call $stream.read (local.get $sr) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 0x40 (; COMPLETED=0 | (4<<4) ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (i32.const 0x89abcdef) (i32.load (i32.const 8)))
          (then unreachable))
        (call $close-writable)
      )
    )
    (type $ST (stream u8))
    (canon stream.new $ST (core func $stream.new))
    (canon stream.read $ST async (memory $memory "mem") (core func $stream.read))
    (canon stream.write $ST async (memory $memory "mem") (core func $stream.write))
    (canon stream.close-readable $ST (core func $stream.close-readable))
    (canon stream.close-writable $ST (core func $stream.close-writable))
    (canon lower (func $c "start-stream") (core func $start-stream'))
    (canon lower (func $c "write4") (core func $write4'))
    (canon lower (func $c "start-blocking-write") (core func $start-blocking-write'))
    (canon lower (func $c "close-writable") (core func $close-writable'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "stream.new" (func $stream.new))
      (export "stream.read" (func $stream.read))
      (export "stream.write" (func $stream.write))
      (export "stream.close-readable" (func $stream.close-readable))
      (export "stream.close-writable" (func $stream.close-writable))
      (export "start-stream" (func $start-stream'))
      (export "write4" (func $write4'))
      (export "start-blocking-write" (func $start-blocking-write'))
      (export "close-writable" (func $close-writable'))
    ))))
    (func (export "close-while-reading") (canon lift (core func $core "close-while-reading")))
    (func (export "close-while-writing") (canon lift (core func $core "close-while-writing")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "c" (instance $c))))
  (func (export "close-while-reading") (alias export $d "close-while-reading"))
  (func (export "close-while-writing") (alias export $d "close-while-writing"))
)
(component instance $new-tester-instance $Tester)
(assert_trap (invoke "close-while-reading") "cannot drop busy stream or future")
(component instance $new-tester-instance $Tester)
(assert_trap (invoke "close-while-writing") "cannot drop busy stream or future")
