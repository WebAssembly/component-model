;; Invocation and failure semantics of the `realloc` canonopt: lowering a list
;; always calls realloc, even for zero-size allocations, and the returned
;; pointer is alignment- and bounds-checked.

;; lowering an empty list across components still calls realloc with (0, 0, align, 0)
(component
  (component $C
    (core module $CM
      (memory (export "mem") 1)
      (global $calls (mut i32) (i32.const 0))
      (func (export "realloc") (param $old i32) (param $old-size i32) (param $align i32) (param $new-size i32) (result i32)
        (if (i32.or
              (i32.or (local.get $old) (local.get $old-size))
              (i32.or (i32.ne (local.get $align) (i32.const 1)) (local.get $new-size)))
          (then unreachable))
        (global.set $calls (i32.add (global.get $calls) (i32.const 1)))
        (i32.const 16))
      (func (export "f") (param $ptr i32) (param $len i32) (result i32)
        (if (i32.ne (local.get $ptr) (i32.const 16)) (then unreachable))
        (if (local.get $len) (then unreachable))
        (i32.mul (global.get $calls) (i32.const 42))))
    (core instance $cm (instantiate $CM))
    (func (export "f") (param "a" (list u8)) (result u32)
      (canon lift (core func $cm "f") (memory (core memory $cm "mem")) (realloc (core func $cm "realloc")))))
  (component $D
    (import "f" (func $f (param "a" (list u8)) (result u32)))
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core func $f' (canon lower (func $f) (memory (core memory $memory "mem"))))
    (core module $DM
      (import "" "f" (func $f' (param i32 i32) (result i32)))
      (func (export "run") (result i32)
        (call $f' (i32.const 0) (i32.const 0))))
    (core instance $dm (instantiate $DM (with "" (instance (export "f" (func $f'))))))
    (func (export "run") (result u32) (canon lift (core func $dm "run"))))
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "f" (func $c "f"))))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 42))

;; realloc returning an out-of-bounds pointer traps, even for a zero-size allocation
(component definition $OobRealloc
  (component $C
    (core module $CM
      (memory (export "mem") 1)
      (func (export "realloc") (param i32 i32 i32 i32) (result i32) (i32.const -1))
      (func (export "f") (param i32 i32)))
    (core instance $cm (instantiate $CM))
    (func (export "f") (param "a" (list u8))
      (canon lift (core func $cm "f") (memory (core memory $cm "mem")) (realloc (core func $cm "realloc")))))
  (component $D
    (import "f" (func $f (param "a" (list u8))))
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core func $f' (canon lower (func $f) (memory (core memory $memory "mem"))))
    (core module $DM
      (import "" "f" (func $f' (param i32 i32)))
      (func (export "run") (call $f' (i32.const 0) (i32.const 0))))
    (core instance $dm (instantiate $DM (with "" (instance (export "f" (func $f'))))))
    (func (export "run") (canon lift (core func $dm "run"))))
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "f" (func $c "f"))))
  (func (export "run") (alias export $d "run"))
)
(component instance $i $OobRealloc)
(assert_trap (invoke "run") "wasm trap: list content out-of-bounds")

;; realloc returning a misaligned pointer for a (list u32) lowering traps
(component definition $MisalignedRealloc
  (component $C
    (core module $CM
      (memory (export "mem") 1)
      (func (export "realloc") (param i32 i32 i32 i32) (result i32) (i32.const 2))
      (func (export "f") (param i32 i32)))
    (core instance $cm (instantiate $CM))
    (func (export "f") (param "a" (list u32))
      (canon lift (core func $cm "f") (memory (core memory $cm "mem")) (realloc (core func $cm "realloc")))))
  (component $D
    (import "f" (func $f (param "a" (list u32))))
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core func $f' (canon lower (func $f) (memory (core memory $memory "mem"))))
    (core module $DM
      (import "" "f" (func $f' (param i32 i32)))
      (func (export "run") (call $f' (i32.const 8) (i32.const 1))))
    (core instance $dm (instantiate $DM (with "" (instance (export "f" (func $f'))))))
    (func (export "run") (canon lift (core func $dm "run"))))
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "f" (func $c "f"))))
  (func (export "run") (alias export $d "run"))
)
(component instance $i $MisalignedRealloc)
(assert_trap (invoke "run") "wasm trap: unaligned pointer")

;; realloc failure lowering a (list u32) argument of a directly-invoked export;
;; the returned pointer is bounds-checked even for a zero-size allocation
(component definition $HostOobRealloc
  (core module $M
    (memory (export "mem") 1)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32)
      (i32.const -4))  ;; 4-aligned, so the bounds check is what trips
    (func (export "f") (param i32 i32)))
  (core instance $m (instantiate $M))
  (func (export "f") (param "a" (list u32))
    (canon lift (core func $m "f") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
)
(component instance $i $HostOobRealloc)
(assert_trap (invoke "f" (list.const (u32.const 1) (u32.const 2))) "realloc return: beyond end of memory")
(component instance $i $HostOobRealloc)
(assert_trap (invoke "f" (list.const)) "realloc return: beyond end of memory")

;; realloc returning -1 for a (list u32) fails the alignment check before the bounds check
(component definition $HostMisalignedRealloc
  (core module $M
    (memory (export "mem") 1)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32) (i32.const -1))
    (func (export "f") (param i32 i32)))
  (core instance $m (instantiate $M))
  (func (export "f") (param "a" (list u32))
    (canon lift (core func $m "f") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
)
(component instance $i $HostMisalignedRealloc)
(assert_trap (invoke "f" (list.const (u32.const 1) (u32.const 2))) "realloc return: result not aligned")
