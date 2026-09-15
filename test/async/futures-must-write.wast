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
      (import "" "future.drop-writable" (func $future.drop-writable (param i32)))

      (global $fw (mut i32) (i32.const 0))

      (func $start-future (export "start-future") (result i32)
        ;; create a new future, return the readable end to the caller
        (local $ret64 i64)
        (local.set $ret64 (call $future.new))
        (global.set $fw (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
        (i32.wrap_i64 (local.get $ret64))
      )
      (func $attempt-write (export "attempt-write") (result i32)
        ;; because the caller already dropped the readable end, this write will eagerly
        ;; return DROPPED having written no values.
        (local $ret i32)
        (local.set $ret (call $future.write (global.get $fw) (i32.const 42)))
        (if (i32.ne (i32.const 0x01 (; DROPPED ;)) (local.get $ret))
          (then unreachable))

        ;; return without trapping
        (i32.const 42)
      )
      (func $drop-writable (export "drop-writable")
        ;; maybe boom
        (call $future.drop-writable (global.get $fw))
      )
    )
    (type $FT (future u8))
    (canon future.new $FT (core func $future.new))
    (canon future.write $FT async (memory (core memory $memory "mem")) (core func $future.write))
    (canon future.drop-writable $FT (core func $future.drop-writable))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "future.new" (func $future.new))
      (export "future.write" (func $future.write))
      (export "future.drop-writable" (func $future.drop-writable))
    ))))
    (func (export "start-future") (result (future u8)) (canon lift (core func $cm "start-future")))
    (func (export "attempt-write") (result u32) (canon lift (core func $cm "attempt-write")))
    (func (export "drop-writable") (canon lift (core func $cm "drop-writable")))
  )
  (component $D
    (import "c" (instance $c
      (export "start-future" (func (result (future u8))))
      (export "attempt-write" (func (result u32)))
      (export "drop-writable" (func))
    ))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Core
      (import "" "mem" (memory 1))
      (import "" "future.drop-readable" (func $future.drop-readable (param i32)))
      (import "" "start-future" (func $start-future (result i32)))
      (import "" "attempt-write" (func $attempt-write (result i32)))
      (import "" "drop-writable" (func $drop-writable))

      (func $drop-readable-future-before-read (export "drop-readable-future-before-read") (result i32)
        ;; call 'start-future' to get the future we'll be working with
        (local $fr i32)
        (local.set $fr (call $start-future))
        (if (i32.ne (i32.const 1) (local.get $fr))
          (then unreachable))

        ;; ok to immediately drop the readable end
        (call $future.drop-readable (local.get $fr))

        ;; the callee will see that we dropped the readable end when it tries to write
        (call $attempt-write)
      )
      (func $drop-writable-future-before-write (export "drop-writable-future-before-write")
        ;; call 'start-future' to get the future we'll be working with
        (local $fr i32)
        (local.set $fr (call $start-future))
        (if (i32.ne (i32.const 1) (local.get $fr))
          (then unreachable))

        ;; boom
        (call $drop-writable)
      )
    )
    (type $FT (future u8))
    (canon future.new $FT (core func $future.new))
    (canon future.drop-readable $FT (core func $future.drop-readable))
    (canon lower (func $c "start-future") (core func $start-future'))
    (canon lower (func $c "attempt-write") (core func $attempt-write'))
    (canon lower (func $c "drop-writable") (core func $drop-writable'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "future.new" (func $future.new))
      (export "future.drop-readable" (func $future.drop-readable))
      (export "start-future" (func $start-future'))
      (export "attempt-write" (func $attempt-write'))
      (export "drop-writable" (func $drop-writable'))
    ))))
    (func (export "drop-readable-future-before-read") (result u32) (canon lift (core func $core "drop-readable-future-before-read")))
    (func (export "drop-writable-future-before-write") (canon lift (core func $core "drop-writable-future-before-write")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "c" (instance $c))))
  (func (export "drop-writable-future-before-write") (alias export $d "drop-writable-future-before-write"))
  (func (export "drop-readable-future-before-read") (alias export $d "drop-readable-future-before-read"))
)

(assert_return (invoke "drop-readable-future-before-read") (u32.const 42))
(assert_trap (invoke "drop-writable-future-before-write") "cannot drop future write end without first writing a value")

;; Test interactions with cancellation
(component definition $Tester
  (core module $Memory (memory (export "mem") 1))
  (core instance $memory (instantiate $Memory))
  (core module $M
    (import "" "mem" (memory 1))
    (import "" "future.new" (func $future.new (result i64)))
    (import "" "future.read" (func $future.read (param i32 i32) (result i32)))
    (import "" "future.write" (func $future.write (param i32 i32) (result i32)))
    (import "" "future.cancel-read" (func $future.cancel-read (param i32) (result i32)))
    (import "" "future.cancel-write" (func $future.cancel-write (param i32) (result i32)))
    (import "" "future.drop-readable" (func $future.drop-readable (param i32)))
    (import "" "future.drop-writable" (func $future.drop-writable (param i32)))

    (global $rx (mut i32) (i32.const 0))
    (global $tx (mut i32) (i32.const 0))
    (func $new-future
      (local $r i64)
      (local.set $r (call $future.new))
      (global.set $rx (i32.wrap_i64 (local.get $r)))
      (global.set $tx (i32.wrap_i64 (i64.shr_u (local.get $r) (i64.const 32)))))

    ;; The write blocked, then the read took the value. Cancelling afterwards
    ;; reports COMPLETED, not CANCELLED -- the value was delivered and cannot
    ;; be unsent -- so the writable end is done and may be dropped.
    (func (export "cancel-write-after-completion") (result i32)
      (call $new-future)
      (i32.store8 (i32.const 64) (i32.const 7))
      (if (i32.ne (call $future.write (global.get $tx) (i32.const 64))
                  (i32.const -1 (; BLOCKED ;)))
        (then unreachable))
      (if (i32.ne (call $future.read (global.get $rx) (i32.const 128))
                  (i32.const 0 (; COMPLETED ;)))
        (then unreachable))
      (if (i32.ne (call $future.cancel-write (global.get $tx))
                  (i32.const 0 (; COMPLETED ;)))
        (then unreachable))
      (if (i32.ne (i32.load8_u (i32.const 128)) (i32.const 7))
        (then unreachable))
      (call $future.drop-writable (global.get $tx))
      (call $future.drop-readable (global.get $rx))
      (i32.const 42)
    )
    ;; The converse case:
    (func (export "cancel-read-after-completion") (result i32)
      (call $new-future)
      (if (i32.ne (call $future.read (global.get $rx) (i32.const 128))
                  (i32.const -1 (; BLOCKED ;)))
        (then unreachable))
      (i32.store8 (i32.const 64) (i32.const 7))
      (if (i32.ne (call $future.write (global.get $tx) (i32.const 64))
                  (i32.const 0 (; COMPLETED ;)))
        (then unreachable))
      (if (i32.ne (call $future.cancel-read (global.get $rx))
                  (i32.const 0 (; COMPLETED ;)))
        (then unreachable))
      (if (i32.ne (i32.load8_u (i32.const 128)) (i32.const 7))
        (then unreachable))
      (call $future.drop-readable (global.get $rx))
      (call $future.drop-writable (global.get $tx))
      (i32.const 42)
    )

    ;; Nothing was ever copied, so the cancel really does cancel: CANCELLED,
    ;; and the end goes back to IDLE, still owing a value.
    (func (export "cancel-write-with-nothing-written") (result i32)
      (call $new-future)
      (if (i32.ne (call $future.write (global.get $tx) (i32.const 64))
                  (i32.const -1 (; BLOCKED ;)))
        (then unreachable))
      (if (i32.ne (call $future.cancel-write (global.get $tx))
                  (i32.const 2 (; CANCELLED ;)))
        (then unreachable))
      (i32.const 42)
    )
    ;; ... so dropping it still traps, exactly as if no write had been started.
    (func (export "drop-writable-after-cancelled-write")
      (call $new-future)
      (if (i32.ne (call $future.write (global.get $tx) (i32.const 64))
                  (i32.const -1 (; BLOCKED ;)))
        (then unreachable))
      (if (i32.ne (call $future.cancel-write (global.get $tx))
                  (i32.const 2 (; CANCELLED ;)))
        (then unreachable))
      ;; boom
      (call $future.drop-writable (global.get $tx))
    )

    ;; If the readable end is dropped while the write is in flight, the cancel
    ;; reports DROPPED rather than CANCELLED, and that does make the writable
    ;; end done: it may be dropped without ever having written a value.
    (func (export "cancel-write-after-readable-dropped") (result i32)
      (call $new-future)
      (if (i32.ne (call $future.write (global.get $tx) (i32.const 64))
                  (i32.const -1 (; BLOCKED ;)))
        (then unreachable))
      (call $future.drop-readable (global.get $rx))
      (if (i32.ne (call $future.cancel-write (global.get $tx))
                  (i32.const 1 (; DROPPED ;)))
        (then unreachable))
      (call $future.drop-writable (global.get $tx))
      (i32.const 42)
    )
  )
  (type $FT (future u8))
  (canon future.new $FT (core func $future.new))
  (canon future.read $FT async (memory (core memory $memory "mem")) (core func $future.read))
  (canon future.write $FT async (memory (core memory $memory "mem")) (core func $future.write))
  (canon future.cancel-read $FT async (core func $future.cancel-read))
  (canon future.cancel-write $FT async (core func $future.cancel-write))
  (canon future.drop-readable $FT (core func $future.drop-readable))
  (canon future.drop-writable $FT (core func $future.drop-writable))
  (core instance $m (instantiate $M (with "" (instance
    (export "mem" (memory $memory "mem"))
    (export "future.new" (func $future.new))
    (export "future.read" (func $future.read))
    (export "future.write" (func $future.write))
    (export "future.cancel-read" (func $future.cancel-read))
    (export "future.cancel-write" (func $future.cancel-write))
    (export "future.drop-readable" (func $future.drop-readable))
    (export "future.drop-writable" (func $future.drop-writable))
  ))))
  (func (export "cancel-write-after-completion") (result u32) (canon lift (core func $m "cancel-write-after-completion")))
  (func (export "cancel-read-after-completion") (result u32) (canon lift (core func $m "cancel-read-after-completion")))
  (func (export "cancel-write-with-nothing-written") (result u32) (canon lift (core func $m "cancel-write-with-nothing-written")))
  (func (export "drop-writable-after-cancelled-write") (canon lift (core func $m "drop-writable-after-cancelled-write")))
  (func (export "cancel-write-after-readable-dropped") (result u32) (canon lift (core func $m "cancel-write-after-readable-dropped")))
)
(component instance $i $Tester)
(assert_return (invoke "cancel-write-after-completion") (u32.const 42))
(component instance $i $Tester)
(assert_return (invoke "cancel-read-after-completion") (u32.const 42))
(component instance $i $Tester)
(assert_return (invoke "cancel-write-with-nothing-written") (u32.const 42))
(component instance $i $Tester)
(assert_trap (invoke "drop-writable-after-cancelled-write") "cannot drop future write end without first writing a value")
(component instance $i $Tester)
(assert_return (invoke "cancel-write-after-readable-dropped") (u32.const 42))
