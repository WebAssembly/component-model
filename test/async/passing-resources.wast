;; This test contains two components, $Producer and $Consumer.
;; $Producer.run drives the test and calls $Producer.start-stream to create
;; a stream and attempt to write 2 owned handles. $Producer.run then reads
;; just 1 element. The test finishes by confirming that $Consumer owns the
;; first resource, $Producer (still) owns the second resource, and $Producer
;; traps if it attempts to access the index of the first resource.
(component
  (component $Producer
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Core
      (import "" "mem" (memory 1))
      (import "" "resource.new" (func $resource.new (param i32) (result i32)))
      (import "" "resource.rep" (func $resource.rep (param i32) (result i32)))
      (import "" "stream.new" (func $stream.new (result i64)))
      (import "" "stream.write" (func $stream.write (param i32 i32 i32) (result i32)))
      (import "" "stream.cancel-write" (func $stream.cancel-write (param i32) (result i32)))
      (import "" "stream.drop-writable" (func $stream.drop-writable (param i32)))

      (global $ws (mut i32) (i32.const 0))
      (global $res1 (mut i32) (i32.const 0))
      (global $res2 (mut i32) (i32.const 0))

      (func $start-stream (export "start-stream") (result i32)
        (local $ret i32) (local $ret64 i64)
        (local $rs i32)

        ;; create a new stream, return the readable end to the caller
        (local.set $ret64 (call $stream.new))
        (global.set $ws (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
        (local.set $rs (i32.wrap_i64 (local.get $ret64)))

        ;; create two resources and write them into a buffer to pass to stream.write
        (global.set $res1 (call $resource.new (i32.const 50)))
        (global.set $res2 (call $resource.new (i32.const 51)))
        (i32.store (i32.const 8) (global.get $res1))
        (i32.store (i32.const 12) (global.get $res2))

        ;; start a write which will block
        (local.set $ret (call $stream.write (global.get $ws) (i32.const 8) (i32.const 2)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))

        ;; check that this instance still owns both resources (ownership has not
        ;; yet been transferred).
        (if (i32.ne (i32.const 50) (call $resource.rep (global.get $res1)))
          (then unreachable))
        (if (i32.ne (i32.const 51) (call $resource.rep (global.get $res2)))
          (then unreachable))

        (local.get $rs)
      )
      (func $cancel-write (export "cancel-write")
        (local $ret i32)

        ;; cancel the write, confirming that the first element was transferred
        (local.set $ret (call $stream.cancel-write (global.get $ws)))
        (if (i32.ne (i32.const 0x11 (; DROPPED=1 | (1 << 4) ;)) (local.get $ret))
          (then unreachable))

        ;; we still own $res2
        (if (i32.ne (i32.const 51) (call $resource.rep (global.get $res2)))
          (then unreachable))

        (call $stream.drop-writable (global.get $ws))
      )
      (func $R.foo (export "R.foo") (param $rep i32) (result i32)
        (i32.add (local.get $rep) (i32.const 50))
      )
      (func $fail-accessing-res1 (export "fail-accessing-res1")
        ;; boom
        (call $resource.rep (global.get $res1))
        unreachable
      )
    )
    (type $R (resource (rep i32)))
    (type $ST (stream (own $R)))
    (canon resource.new $R (core func $resource.new))
    (canon resource.rep $R (core func $resource.rep))
    (canon stream.new $ST (core func $stream.new))
    (canon stream.write $ST async (memory $memory "mem") (core func $stream.write))
    (canon stream.cancel-write $ST (core func $stream.cancel-write))
    (canon stream.drop-writable $ST (core func $stream.drop-writable))
    (core instance $core (instantiate $Core (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "resource.new" (func $resource.new))
      (export "resource.rep" (func $resource.rep))
      (export "stream.new" (func $stream.new))
      (export "stream.write" (func $stream.write))
      (export "stream.cancel-write" (func $stream.cancel-write))
      (export "stream.drop-writable" (func $stream.drop-writable))
    ))))
    (export $R' "R" (type $R))
    (func (export "[method]R.foo") async (param "self" (borrow $R')) (result u32) (canon lift (core func $core "R.foo")))
    (func (export "start-stream") async (result (stream (own $R'))) (canon lift (core func $core "start-stream")))
    (func (export "cancel-write") async (canon lift (core func $core "cancel-write")))
    (func (export "fail-accessing-res1") async (canon lift (core func $core "fail-accessing-res1")))
  )

  (component $Consumer
    (import "producer" (instance $producer
      (export "R" (type $R (sub resource)))
      (export "[method]R.foo" (func async (param "self" (borrow $R)) (result u32)))
      (export "start-stream" (func async (result (stream (own $R)))))
      (export "cancel-write" (func async))
    ))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Core
      (import "" "mem" (memory 1))
      (import "" "stream.read" (func $stream.read (param i32 i32 i32) (result i32)))
      (import "" "stream.drop-readable" (func $stream.drop-readable (param i32)))
      (import "" "R.foo" (func $R.foo (param i32) (result i32)))
      (import "" "start-stream" (func $start-stream (result i32)))
      (import "" "cancel-write" (func $cancel-write))

      (func $run (export "run") (result i32)
        (local $ret i32) (local $rs i32)
        (local $res1 i32)

        ;; get the readable end of a stream which has a pending write
        (local.set $rs (call $start-stream))
        (if (i32.ne (local.get $rs) (i32.const 2))
          (then unreachable))

        ;; read only 1 (of the 2 pending) elements, which won't block
        (i64.store (i32.const 8) (i64.const 0xdeadbeefdeadbeef))
        (local.set $ret (call $stream.read (local.get $rs) (i32.const 8) (i32.const 1)))
        (if (i32.ne (i32.const 0x10) (local.get $ret))
          (then unreachable))

        ;; only 1 handle should have been transferred
        (local.set $res1 (i32.load (i32.const 8)))
        (if (i32.ne (i32.load (i32.const 12)) (i32.const 0xdeadbeef))
          (then unreachable))

        ;; check that we got the first resource and it works
        (local.set $ret (call $R.foo (local.get $res1)))
        (if (i32.ne (i32.const 100) (local.get $ret))
          (then unreachable))

        ;; drop the stream and then let $C run and assert stuff
        (call $stream.drop-readable (local.get $rs))
        (call $cancel-write)
        
        (i32.const 42)
      )
    )
    (alias export $producer "R" (type $R))
    (type $ST (stream (own $R)))
    (canon stream.read $ST async (memory $memory "mem") (core func $stream.read))
    (canon stream.drop-readable $ST (core func $stream.drop-readable))
    (canon lower (func $producer "[method]R.foo") (core func $R.foo'))
    (canon lower (func $producer "start-stream") (core func $start-stream'))
    (canon lower (func $producer "cancel-write") (core func $cancel-write'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "stream.read" (func $stream.read))
      (export "stream.drop-readable" (func $stream.drop-readable))
      (export "R.foo" (func $R.foo'))
      (export "start-stream" (func $start-stream'))
      (export "cancel-write" (func $cancel-write'))
    ))))
    (func (export "run") async (result u32) (canon lift
      (core func $core "run")
    ))
  )

  (instance $producer (instantiate $Producer))
  (instance $consumer (instantiate $Consumer (with "producer" (instance $producer))))
  (func (export "run") (alias export $consumer "run"))
  (func (export "fail-accessing-res1") (alias export $producer "fail-accessing-res1"))
)
(assert_return (invoke "run") (u32.const 42))
(assert_trap (invoke "fail-accessing-res1") "unknown handle index")
