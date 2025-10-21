;; This test contains two components $C and $D that test that if the writable side
;; of a stream is dropped, the other side registers a STREAM DROPPED status
;; when attempting to read from the stream.
(component definition $Tester
  ;; Creates a stream and keeps a handle to the writable end of it.
  (component $C
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $CM
      (import "" "mem" (memory 1))
      (import "" "stream.new" (func $stream.new (result i64)))
      (import "" "stream.write" (func $stream.write (param i32 i32 i32) (result i32)))
      (import "" "stream.drop-writable" (func $stream.drop-writable (param i32)))

      ;; Store the writable end of a stream
      (global $sw (mut i32) (i32.const 0))

      ;; Create a new stream, return the readable end to the caller
      (func $start-stream (export "start-stream") (result i32)
        (local $ret64 i64)
        (local.set $ret64 (call $stream.new))
        (global.set $sw (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
        (i32.wrap_i64 (local.get $ret64))
      )

      ;; Drop the writable end of a stream
      (func $drop-writable (export "drop-writable")
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
    (func (export "drop-writable") (canon lift (core func $cm "drop-writable")))
  )

  ;; Gets a readable stream from component $C and calls operations on it.
  (component $D
    (import "c" (instance $c
      (export "start-stream" (func (result (stream u8))))
      (export "drop-writable" (func))
    ))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Core
      (import "" "mem" (memory 1))
      (import "" "stream.new" (func $stream.new (result i64)))
      (import "" "stream.read" (func $stream.read (param i32 i32 i32) (result i32)))
      (import "" "stream.write" (func $stream.write (param i32 i32 i32) (result i32)))
      (import "" "stream.drop-writable" (func $stream.drop-writable (param i32)))
      (import "" "start-stream" (func $start-stream (result i32)))
      (import "" "drop-writable" (func $drop-writable))

      (func (export "read-from-closed-stream")
        (local $ret i32) (local $sr i32)

        ;; call 'start-stream' to get the stream we'll be working with
        (local.set $sr (call $start-stream))
        (if (i32.ne (i32.const 1) (local.get $sr))
          (then unreachable))

        ;; drop the writable end and then attempt to read from it
        (call $drop-writable)
        (local.set $ret (call $stream.read (local.get $sr) (i32.const 8) (i32.const 4)))
        (if (i32.ne (i32.const 1 (; DROPPED ;)) (local.get $ret))
          (then unreachable))
      )
    )
    (type $ST (stream u8))
    (canon stream.new $ST (core func $stream.new))
    (canon stream.read $ST async (memory $memory "mem") (core func $stream.read))
    (canon stream.write $ST async (memory $memory "mem") (core func $stream.write))
    (canon stream.drop-writable $ST (core func $stream.drop-writable))
    (canon lower (func $c "start-stream") (core func $start-stream'))
    (canon lower (func $c "drop-writable") (core func $drop-writable'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "stream.new" (func $stream.new))
      (export "stream.read" (func $stream.read))
      (export "stream.write" (func $stream.write))
      (export "stream.drop-writable" (func $stream.drop-writable))
      (export "start-stream" (func $start-stream'))
      (export "drop-writable" (func $drop-writable'))
    ))))
    (func (export "read-from-closed-stream") (canon lift (core func $core "read-from-closed-stream")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "c" (instance $c))))
  (func (export "read-from-closed-stream") (alias export $d "read-from-closed-stream"))
)

(component instance $new-tester-instance $Tester)
(invoke "read-from-closed-stream")
