;; This test contains two components $C and $D where $C writes into a future
;; it created (the "source", ends $r.src/$w.src) and $D forwards that future
;; into a second future (the "destination", ends $r.dst/$w.dst) using the
;; future.forward built-in, reading the forwarded value back out of the
;; destination future itself.
;;
;; $D exports one function per scenario. Since traps take out their containing
;; instance, a fresh instance of $Tester is created for each invoke.
(component definition $Tester
  (component $C
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $CM
      (import "" "mem" (memory 1))
      (import "" "future.new" (func $future.new (result i64)))
      (import "" "future.write" (func $future.write (param i32 i32) (result i32)))
      (import "" "future.drop-writable" (func $future.drop-writable (param i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))

      (global $w.src (mut i32) (i32.const 0))

      (func $start-future (export "start-future") (result i32)
        ;; create a new future, return the readable end to the caller
        (local $ret64 i64)
        (local.set $ret64 (call $future.new))
        (global.set $w.src (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
        (i32.wrap_i64 (local.get $ret64))
      )
      (func $write1 (export "write1")
        ;; write the value, expecting to rendezvous with a read
        (local $ret i32)
        (i32.store8 (i32.const 8) (i32.const 0xab))
        (local.set $ret (call $future.write (global.get $w.src) (i32.const 8)))
        (if (i32.ne (i32.const 0 (; COMPLETED ;)) (local.get $ret))
          (then unreachable))
        (call $future.drop-writable (global.get $w.src))
      )
      (func $write1-dropped (export "write1-dropped")
        ;; write expecting to observe DROPPED synchronously
        (local $ret i32)
        (local.set $ret (call $future.write (global.get $w.src) (i32.const 8)))
        (if (i32.ne (i32.const 1 (; DROPPED ;)) (local.get $ret))
          (then unreachable))
        (call $future.drop-writable (global.get $w.src))
      )
      (func $start-blocking-write (export "start-blocking-write")
        (local $ret i32)

        ;; prepare the write buffer
        (i32.store8 (i32.const 8) (i32.const 0xab))

        ;; start a blocking write
        (local.set $ret (call $future.write (global.get $w.src) (i32.const 8)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))
      )
      (func $check-write-event (export "check-write-event")
        ;; confirm the blocking write completed
        (local $ret i32) (local $seti i32)
        (local.set $seti (call $waitable-set.new))
        (call $waitable.join (global.get $w.src) (local.get $seti))
        (local.set $ret (call $waitable-set.wait (local.get $seti) (i32.const 0)))
        (if (i32.ne (i32.const 5 (; FUTURE_WRITE ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (global.get $w.src) (i32.load (i32.const 0)))
          (then unreachable))
        (if (i32.ne (i32.const 0 (; COMPLETED ;)) (i32.load (i32.const 4)))
          (then unreachable))
        (call $waitable.join (global.get $w.src) (i32.const 0))
        (call $future.drop-writable (global.get $w.src))
      )
      (func $check-write-dropped (export "check-write-dropped")
        ;; confirm the blocking write observed DROPPED with nothing written
        (local $ret i32) (local $seti i32)
        (local.set $seti (call $waitable-set.new))
        (call $waitable.join (global.get $w.src) (local.get $seti))
        (local.set $ret (call $waitable-set.wait (local.get $seti) (i32.const 0)))
        (if (i32.ne (i32.const 5 (; FUTURE_WRITE ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (global.get $w.src) (i32.load (i32.const 0)))
          (then unreachable))
        (if (i32.ne (i32.const 1 (; DROPPED ;)) (i32.load (i32.const 4)))
          (then unreachable))
        (call $waitable.join (global.get $w.src) (i32.const 0))
        (call $future.drop-writable (global.get $w.src))
      )
    )
    (type $FT (future u8))
    (canon future.new $FT (core func $future.new))
    (canon future.write $FT async (memory (core memory $memory "mem")) (core func $future.write))
    (canon future.drop-writable $FT (core func $future.drop-writable))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "future.new" (func $future.new))
      (export "future.write" (func $future.write))
      (export "future.drop-writable" (func $future.drop-writable))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
    ))))
    (func (export "start-future") async (result (future u8)) (canon lift (core func $cm "start-future")))
    (func (export "write1") async (canon lift (core func $cm "write1")))
    (func (export "write1-dropped") async (canon lift (core func $cm "write1-dropped")))
    (func (export "start-blocking-write") async (canon lift (core func $cm "start-blocking-write")))
    (func (export "check-write-event") async (canon lift (core func $cm "check-write-event")))
    (func (export "check-write-dropped") async (canon lift (core func $cm "check-write-dropped")))
  )
  (component $D
    (import "c" (instance $c
      (export "start-future" (func async (result (future u8))))
      (export "write1" (func async))
      (export "write1-dropped" (func async))
      (export "start-blocking-write" (func async))
      (export "check-write-event" (func async))
      (export "check-write-dropped" (func async))
    ))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Core
      (import "" "mem" (memory 1))
      (import "" "future.new" (func $future.new (result i64)))
      (import "" "future.new-u16" (func $future.new-u16 (result i64)))
      (import "" "future.read" (func $future.read (param i32 i32) (result i32)))
      (import "" "future.read-async" (func $future.read-async (param i32 i32) (result i32)))
      (import "" "future.write-async" (func $future.write-async (param i32 i32) (result i32)))
      (import "" "future.forward" (func $future.forward (param i32 i32)))
      (import "" "future.cancel-read" (func $future.cancel-read (param i32) (result i32)))
      (import "" "future.drop-readable" (func $future.drop-readable (param i32)))
      (import "" "future.drop-writable" (func $future.drop-writable (param i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (import "" "start-future" (func $start-future (result i32)))
      (import "" "write1" (func $write1))
      (import "" "write1-dropped" (func $write1-dropped))
      (import "" "start-blocking-write" (func $start-blocking-write))
      (import "" "check-write-event" (func $check-write-event))
      (import "" "check-write-dropped" (func $check-write-dropped))

      (global $r.src (mut i32) (i32.const 0))
      (global $r.dst (mut i32) (i32.const 0))
      (global $w.dst (mut i32) (i32.const 0))

      (func $setup
        ;; get the source future from $C and create the destination future
        (local $ret64 i64)
        (global.set $r.src (call $start-future))
        (if (i32.ne (i32.const 1) (global.get $r.src))
          (then unreachable))
        (local.set $ret64 (call $future.new))
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
      (func $read1-dst
        ;; synchronously read the value out of the destination future
        (local $ret i32)
        (local.set $ret (call $future.read (global.get $r.dst) (i32.const 8)))
        (if (i32.ne (i32.const 0 (; COMPLETED ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (i32.const 0xab) (i32.load8_u (i32.const 8)))
          (then unreachable))
        (call $future.drop-readable (global.get $r.dst))
      )
      (func $read1-dst-async
        ;; start a read on the destination future that will block
        (local $ret i32)
        (local.set $ret (call $future.read-async (global.get $r.dst) (i32.const 8)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))
      )
      (func $expect-read1-dst
        (call $expect-event (global.get $r.dst) (i32.const 4 (; FUTURE_READ ;)) (i32.const 0 (; COMPLETED ;)))
        (if (i32.ne (i32.const 0xab) (i32.load8_u (i32.const 8)))
          (then unreachable))
        (call $future.drop-readable (global.get $r.dst))
      )

      (func (export "forward-rendezvous")
        (call $setup)

        ;; forward the source into the destination; this returns immediately
        ;; and no event is ever delivered
        (call $future.forward (global.get $r.src) (global.get $w.dst))

        ;; with no read pending on the destination, $C's write blocks
        (call $start-blocking-write)

        ;; the read is satisfied out of $C's write buffer, completing its write
        (call $read1-dst)
        (call $check-write-event)
      )

      (func (export "forward-pending-read")
        (call $setup)

        ;; a read blocked on the destination when the forward starts is
        ;; transferred to the source
        (call $read1-dst-async)
        (call $future.forward (global.get $r.src) (global.get $w.dst))
        (call $write1)
        (call $expect-read1-dst)
      )

      (func (export "forward-pending-write")
        (call $setup)

        ;; a write blocked on the source when the forward starts rendezvous
        ;; with a later destination read
        (call $start-blocking-write)
        (call $future.forward (global.get $r.src) (global.get $w.dst))
        (call $read1-dst)
        (call $check-write-event)
      )

      (func (export "forward-dst-dropped")
        (call $setup)
        (call $future.forward (global.get $r.src) (global.get $w.dst))
        (call $start-blocking-write)

        ;; dropping the destination's readable end drops the source's
        ;; readable end, so $C's blocked write observes DROPPED
        (call $future.drop-readable (global.get $r.dst))
        (call $check-write-dropped)
      )

      (func (export "forward-dst-already-dropped")
        (call $setup)

        ;; forwarding into an already-dropped destination drops the source's
        ;; readable end right away
        (call $future.drop-readable (global.get $r.dst))
        (call $future.forward (global.get $r.src) (global.get $w.dst))
        (call $write1-dropped)
      )

      (func (export "forward-chained")
        (local $ret64 i64) (local $r.mid i32) (local $w.mid i32)
        (call $setup)
        (local.set $ret64 (call $future.new))
        (local.set $r.mid (i32.wrap_i64 (local.get $ret64)))
        (local.set $w.mid (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))

        ;; chain two forwards through an intermediate future: a read at the
        ;; end of the chain is satisfied directly out of $C's write
        (call $future.forward (global.get $r.src) (local.get $w.mid))
        (call $future.forward (local.get $r.mid) (global.get $w.dst))
        (call $start-blocking-write)
        (call $read1-dst)
        (call $check-write-event)
      )

      (func (export "forward-cancel-read")
        (local $ret i32)
        (call $setup)

        ;; a read transferred to the source can still be cancelled through
        ;; the destination's readable end, after which the future remains
        ;; usable
        (call $read1-dst-async)
        (call $future.forward (global.get $r.src) (global.get $w.dst))
        (local.set $ret (call $future.cancel-read (global.get $r.dst)))
        (if (i32.ne (i32.const 0x02 (; CANCELLED ;)) (local.get $ret))
          (then unreachable))
        (call $read1-dst-async)
        (call $write1)
        (call $expect-read1-dst)
      )

      (func (export "forward-after-value-read")
        (local $ret i32)
        (call $setup)

        ;; once the future's value has been read it can no longer be forwarded
        (call $start-blocking-write)
        (local.set $ret (call $future.read (global.get $r.src) (i32.const 8)))
        (if (i32.ne (i32.const 0 (; COMPLETED ;)) (local.get $ret))
          (then unreachable))
        ;; boom
        (call $future.forward (global.get $r.src) (global.get $w.dst))
      )

      (func (export "forward-after-value-written")
        (local $ret i32)
        (call $setup)

        ;; once a value has been written into the destination it can no longer
        ;; be the target of a forward
        (call $read1-dst-async)
        (i32.store8 (i32.const 16) (i32.const 0xcd))
        (local.set $ret (call $future.write-async (global.get $w.dst) (i32.const 16)))
        (if (i32.ne (i32.const 0 (; COMPLETED ;)) (local.get $ret))
          (then unreachable))
        ;; boom
        (call $future.forward (global.get $r.src) (global.get $w.dst))
      )

      (func (export "forward-after-write-dropped")
        (local $ret i32)
        (call $setup)

        ;; a writable end that observed DROPPED can no longer be the target
        ;; of a forward
        (call $future.drop-readable (global.get $r.dst))
        (local.set $ret (call $future.write-async (global.get $w.dst) (i32.const 8)))
        (if (i32.ne (i32.const 1 (; DROPPED ;)) (local.get $ret))
          (then unreachable))
        ;; boom
        (call $future.forward (global.get $r.src) (global.get $w.dst))
      )

      (func (export "forward-removes-readable")
        (call $setup)
        ;; future.forward removes both ends from the table
        (call $future.forward (global.get $r.src) (global.get $w.dst))
        ;; boom
        (call $future.drop-readable (global.get $r.src))
      )

      (func (export "forward-removes-writable")
        (call $setup)
        (call $future.forward (global.get $r.src) (global.get $w.dst))
        ;; boom
        (call $future.drop-writable (global.get $w.dst))
      )

      (func (export "forward-while-reading")
        (local $ret i32)
        (call $setup)
        (local.set $ret (call $future.read-async (global.get $r.src) (i32.const 8)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))
        ;; boom
        (call $future.forward (global.get $r.src) (global.get $w.dst))
      )

      (func (export "forward-while-writing")
        (local $ret i32)
        (call $setup)
        (local.set $ret (call $future.write-async (global.get $w.dst) (i32.const 8)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))
        ;; boom
        (call $future.forward (global.get $r.src) (global.get $w.dst))
      )

      (func (export "forward-readable-in-waitable-set")
        (local $seti i32)
        (call $setup)
        ;; forwarding an end that is in a waitable set traps
        (local.set $seti (call $waitable-set.new))
        (call $waitable.join (global.get $r.src) (local.get $seti))
        ;; boom
        (call $future.forward (global.get $r.src) (global.get $w.dst))
      )

      (func (export "forward-writable-in-waitable-set")
        (local $seti i32)
        (call $setup)
        (local.set $seti (call $waitable-set.new))
        (call $waitable.join (global.get $w.dst) (local.get $seti))
        ;; boom
        (call $future.forward (global.get $r.src) (global.get $w.dst))
      )

      (func (export "forward-readable-as-writable")
        (call $setup)
        ;; boom
        (call $future.forward (global.get $r.src) (global.get $r.dst))
      )

      (func (export "forward-writable-as-readable")
        (call $setup)
        ;; boom
        (call $future.forward (global.get $w.dst) (global.get $w.dst))
      )

      (func (export "forward-readable-type-mismatch")
        (local $ret64 i64)
        (call $setup)
        ;; the element type of the readable end must match the type immediate
        (local.set $ret64 (call $future.new-u16))
        ;; boom
        (call $future.forward (i32.wrap_i64 (local.get $ret64)) (global.get $w.dst))
      )

      (func (export "forward-writable-type-mismatch")
        (local $ret64 i64)
        (call $setup)
        ;; the element type of the writable end must match the type immediate
        (local.set $ret64 (call $future.new-u16))
        ;; boom
        (call $future.forward (global.get $r.src) (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
      )

      (func (export "self-forward")
        (local $ret64 i64) (local $r.self i32) (local $w.self i32)
        ;; a future cannot be forwarded into itself
        (local.set $ret64 (call $future.new))
        (local.set $r.self (i32.wrap_i64 (local.get $ret64)))
        (local.set $w.self (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
        ;; boom
        (call $future.forward (local.get $r.self) (local.get $w.self))
      )

      (func (export "forward-cycle")
        (local $ret64 i64) (local $r.a i32) (local $w.a i32) (local $r.b i32) (local $w.b i32)
        (local.set $ret64 (call $future.new))
        (local.set $r.a (i32.wrap_i64 (local.get $ret64)))
        (local.set $w.a (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
        (local.set $ret64 (call $future.new))
        (local.set $r.b (i32.wrap_i64 (local.get $ret64)))
        (local.set $w.b (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))

        (call $future.forward (local.get $r.a) (local.get $w.b))
        ;; forwarding $b back into $a would close a cycle
        ;; boom
        (call $future.forward (local.get $r.b) (local.get $w.a))
      )
    )
    (type $FT (future u8))
    (canon future.new $FT (core func $future.new))
    (type $FTU16 (future u16))
    (canon future.new $FTU16 (core func $future.new-u16))
    (canon future.read $FT (memory (core memory $memory "mem")) (core func $future.read))
    (canon future.read $FT async (memory (core memory $memory "mem")) (core func $future.read-async))
    (canon future.write $FT async (memory (core memory $memory "mem")) (core func $future.write-async))
    (canon future.forward $FT (core func $future.forward))
    (canon future.cancel-read $FT (core func $future.cancel-read))
    (canon future.drop-readable $FT (core func $future.drop-readable))
    (canon future.drop-writable $FT (core func $future.drop-writable))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (canon lower (func $c "start-future") (core func $start-future'))
    (canon lower (func $c "write1") (core func $write1'))
    (canon lower (func $c "write1-dropped") (core func $write1-dropped'))
    (canon lower (func $c "start-blocking-write") (core func $start-blocking-write'))
    (canon lower (func $c "check-write-event") (core func $check-write-event'))
    (canon lower (func $c "check-write-dropped") (core func $check-write-dropped'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "future.new" (func $future.new))
      (export "future.new-u16" (func $future.new-u16))
      (export "future.read" (func $future.read))
      (export "future.read-async" (func $future.read-async))
      (export "future.write-async" (func $future.write-async))
      (export "future.forward" (func $future.forward))
      (export "future.cancel-read" (func $future.cancel-read))
      (export "future.drop-readable" (func $future.drop-readable))
      (export "future.drop-writable" (func $future.drop-writable))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "start-future" (func $start-future'))
      (export "write1" (func $write1'))
      (export "write1-dropped" (func $write1-dropped'))
      (export "start-blocking-write" (func $start-blocking-write'))
      (export "check-write-event" (func $check-write-event'))
      (export "check-write-dropped" (func $check-write-dropped'))
    ))))
    (func (export "forward-rendezvous") async (canon lift (core func $core "forward-rendezvous")))
    (func (export "forward-pending-read") async (canon lift (core func $core "forward-pending-read")))
    (func (export "forward-pending-write") async (canon lift (core func $core "forward-pending-write")))
    (func (export "forward-dst-dropped") async (canon lift (core func $core "forward-dst-dropped")))
    (func (export "forward-dst-already-dropped") async (canon lift (core func $core "forward-dst-already-dropped")))
    (func (export "forward-chained") async (canon lift (core func $core "forward-chained")))
    (func (export "forward-cancel-read") async (canon lift (core func $core "forward-cancel-read")))
    (func (export "forward-after-value-read") async (canon lift (core func $core "forward-after-value-read")))
    (func (export "forward-after-value-written") async (canon lift (core func $core "forward-after-value-written")))
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
  (func (export "forward-dst-dropped") (alias export $d "forward-dst-dropped"))
  (func (export "forward-dst-already-dropped") (alias export $d "forward-dst-already-dropped"))
  (func (export "forward-chained") (alias export $d "forward-chained"))
  (func (export "forward-cancel-read") (alias export $d "forward-cancel-read"))
  (func (export "forward-after-value-read") (alias export $d "forward-after-value-read"))
  (func (export "forward-after-value-written") (alias export $d "forward-after-value-written"))
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
(assert_return (invoke "forward-dst-dropped"))
(component instance $i $Tester)
(assert_return (invoke "forward-dst-already-dropped"))
(component instance $i $Tester)
(assert_return (invoke "forward-chained"))
(component instance $i $Tester)
(assert_return (invoke "forward-cancel-read"))
(component instance $i $Tester)
(assert_trap (invoke "forward-after-value-read") "cannot forward from future after previous read succeeded")
(component instance $i $Tester)
(assert_trap (invoke "forward-after-value-written") "cannot forward to future after previous write succeeded")
(component instance $i $Tester)
(assert_trap (invoke "forward-after-write-dropped") "cannot forward to future after being notified that the readable end dropped")
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
(assert_trap (invoke "forward-readable-type-mismatch") "handle is a future of a different type")
(component instance $i $Tester)
(assert_trap (invoke "forward-writable-type-mismatch") "handle is a future of a different type")
(component instance $i $Tester)
(assert_trap (invoke "self-forward") "cannot forward a stream or future into itself")
(component instance $i $Tester)
(assert_trap (invoke "forward-cycle") "cannot forward a stream or future into itself")
