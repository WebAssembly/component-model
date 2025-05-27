;; This test contains two components $C and $D that test that a trap occurs
;; when closing the writable end of a future (in $C) before having written
;; a value while closing the readable end of a future (in $D) before reading
;; a value is fine.
(component
  (component $C
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $CM
      (import "" "mem" (memory 1))
      (import "" "future.new" (func $future.new (result i64)))
      (import "" "future.write" (func $future.write (param i32 i32) (result i32)))
      (import "" "future.close-writable" (func $future.close-writable (param i32)))

      (global $fw (mut i32) (i32.const 0))

      (func $start-future (export "start-future") (result i32)
        ;; create a new future, return the readable end to the caller
        (local $ret64 i64)
        (local.set $ret64 (call $future.new))
        (global.set $fw (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
        (i32.wrap_i64 (local.get $ret64))
      )
      (func $attempt-write (export "attempt-write") (result i32)
        ;; because the caller already closed the readable end, this write will eagerly
        ;; return CLOSED having written no values.
        (local $ret i32)
        (local.set $ret (call $future.write (global.get $fw) (i32.const 42)))
        (if (i32.ne (i32.const 0x01 (; CLOSED=1 | (0<<4) ;)) (local.get $ret))
          (then
            (i32.load (i32.add (local.get $ret) (i32.const 0x8000_0000)))
          unreachable))

        ;; return without trapping
        (i32.const 42)
      )
      (func $close-writable (export "close-writable")
        ;; maybe boom
        (call $future.close-writable (global.get $fw))
      )
    )
    (type $FT (future u8))
    (canon future.new $FT (core func $future.new))
    (canon future.write $FT async (memory $memory "mem") (core func $future.write))
    (canon future.close-writable $FT (core func $future.close-writable))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "future.new" (func $future.new))
      (export "future.write" (func $future.write))
      (export "future.close-writable" (func $future.close-writable))
    ))))
    (func (export "start-future") (result (future u8)) (canon lift (core func $cm "start-future")))
    (func (export "attempt-write") (result u32) (canon lift (core func $cm "attempt-write")))
    (func (export "close-writable") (canon lift (core func $cm "close-writable")))
  )
  (component $D
    (import "c" (instance $c
      (export "start-future" (func (result (future u8))))
      (export "attempt-write" (func (result u32)))
      (export "close-writable" (func))
    ))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Core
      (import "" "mem" (memory 1))
      (import "" "future.read" (func $future.read (param i32 i32) (result i32)))
      (import "" "future.close-readable" (func $future.close-readable (param i32)))
      (import "" "start-future" (func $start-future (result i32)))
      (import "" "attempt-write" (func $attempt-write (result i32)))
      (import "" "close-writable" (func $close-writable))

      (func $close-readable-future-before-read (export "close-readable-future-before-read") (result i32)
        ;; call 'start-future' to get the future we'll be working with
        (local $fr i32)
        (local.set $fr (call $start-future))
        (if (i32.ne (i32.const 1) (local.get $fr))
          (then unreachable))

        ;; ok to immediately close the readable end
        (call $future.close-readable (local.get $fr))

        ;; the callee will see that we closed the readable end when it tries to write
        (call $attempt-write)
      )
      (func $close-writable-future-before-write (export "close-writable-future-before-write")
        ;; call 'start-future' to get the future we'll be working with
        (local $fr i32)
        (local.set $fr (call $start-future))
        (if (i32.ne (i32.const 1) (local.get $fr))
          (then unreachable))

        ;; boom
        (call $close-writable)
      )
    )
    (type $FT (future u8))
    (canon future.new $FT (core func $future.new))
    (canon future.read $FT async (memory $memory "mem") (core func $future.read))
    (canon future.close-readable $FT (core func $future.close-readable))
    (canon lower (func $c "start-future") (core func $start-future'))
    (canon lower (func $c "attempt-write") (core func $attempt-write'))
    (canon lower (func $c "close-writable") (core func $close-writable'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "future.new" (func $future.new))
      (export "future.read" (func $future.read))
      (export "future.close-readable" (func $future.close-readable))
      (export "start-future" (func $start-future'))
      (export "attempt-write" (func $attempt-write'))
      (export "close-writable" (func $close-writable'))
    ))))
    (func (export "close-readable-future-before-read") (result u32) (canon lift (core func $core "close-readable-future-before-read")))
    (func (export "close-writable-future-before-write") (canon lift (core func $core "close-writable-future-before-write")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "c" (instance $c))))
  (func (export "close-writable-future-before-write") (alias export $d "close-writable-future-before-write"))
  (func (export "close-readable-future-before-read") (alias export $d "close-readable-future-before-read"))
)

(assert_return (invoke "close-readable-future-before-read") (u32.const 42))
(assert_trap (invoke "close-writable-future-before-write") "cannot close future write end without first writing a value")
