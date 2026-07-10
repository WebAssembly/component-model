;; Link-time virtualization, mirroring design/mvp/examples/LinkTimeVirtualization.md
(component
  ;; $RealFs mocks the "real" filesystem as an array of bytes in memory
  (component $RealFs
    (core module $M
      (memory (export "mem") 1)
      (func (export "read") (param $addr i32) (result i32)
        (i32.load8_u (local.get $addr)))
      (func (export "write") (param $addr i32) (param $val i32)
        (i32.store8 (local.get $addr) (local.get $val))))
    (core instance $m (instantiate $M))
    (func (export "read") (param "addr" u32) (result u32)
      (canon lift (core func $m "read")))
    (func (export "write") (param "addr" u32) (param "val" u32)
      (canon lift (core func $m "write")))
  )

  ;; $Virtualize imports an fs {read,write} and re-exports a wrapped fs
  ;; that transparently shifts every address into a private window, so a
  ;; consumer of the virtual fs can only ever touch [base, base+255] of the
  ;; underlying store. It also counts calls in its own private memory to
  ;; show it can carry state of its own.
  (component $Virtualize
    (import "fs" (instance $fs
      (export "read" (func (param "addr" u32) (result u32)))
      (export "write" (func (param "addr" u32) (param "val" u32)))))
    (import "base" (core module $Base
      (export "base" (global i32))))
    (core func $read (canon lower (func $fs "read")))
    (core func $write (canon lower (func $fs "write")))
    (core module $M
      (import "fs" "read" (func $read (param i32) (result i32)))
      (import "fs" "write" (func $write (param i32 i32)))
      (import "cfg" "base" (global $base i32))
      (global $calls (mut i32) (i32.const 0))
      (func (export "read") (param $addr i32) (result i32)
        (global.set $calls (i32.add (global.get $calls) (i32.const 1)))
        (call $read (i32.add (local.get $addr) (global.get $base))))
      (func (export "write") (param $addr i32) (param $val i32)
        (global.set $calls (i32.add (global.get $calls) (i32.const 1)))
        (call $write (i32.add (local.get $addr) (global.get $base)) (local.get $val)))
      (func (export "calls") (result i32) (global.get $calls)))
    (core instance $base (instantiate $Base))
    (core instance $m (instantiate $M
      (with "fs" (instance (export "read" (func $read)) (export "write" (func $write))))
      (with "cfg" (instance $base))))
    (func (export "read") (param "addr" u32) (result u32) (canon lift (core func $m "read")))
    (func (export "write") (param "addr" u32) (param "val" u32) (canon lift (core func $m "write")))
    (func (export "calls") (result u32) (canon lift (core func $m "calls")))
  )

  ;; Two "base" configs, giving each virtualize instance a distinct window.
  (core module $Base256 (global (export "base") i32 (i32.const 256)))
  (core module $Base512 (global (export "base") i32 (i32.const 512)))

  ;; $Child consumes an fs and does app-level work. It stores a value at
  ;; a low address and reads it back, doubling the result.
  (component $Child
    (import "fs" (instance $fs
      (export "read" (func (param "addr" u32) (result u32)))
      (export "write" (func (param "addr" u32) (param "val" u32)))))
    (core func $read (canon lower (func $fs "read")))
    (core func $write (canon lower (func $fs "write")))
    (core module $M
      (import "fs" "read" (func $read (param i32) (result i32)))
      (import "fs" "write" (func $write (param i32 i32)))
      (func (export "run") (param $v i32) (result i32)
        (call $write (i32.const 10) (local.get $v))
        (i32.mul (call $read (i32.const 10)) (i32.const 2))))
    (core instance $m (instantiate $M
      (with "fs" (instance (export "read" (func $read)) (export "write" (func $write))))))
    (func (export "run") (param "v" u32) (result u32) (canon lift (core func $m "run")))
  )

  ;; Parent wires single real fs shared by two virtualize instances (windows
  ;; 256 and 512), each feeding its own child. The parent also re-exports
  ;; the real fs's raw read so the harness can prove isolation.
  (instance $real (instantiate $RealFs))
  (instance $virtA (instantiate $Virtualize
    (with "fs" (instance $real)) (with "base" (core module $Base256))))
  (instance $virtB (instantiate $Virtualize
    (with "fs" (instance $real)) (with "base" (core module $Base512))))
  (instance $childA (instantiate $Child (with "fs" (instance $virtA))))
  (instance $childB (instantiate $Child (with "fs" (instance $virtB))))

  (func (export "run-a") (alias export $childA "run"))
  (func (export "run-b") (alias export $childB "run"))
  (func (export "calls-a") (alias export $virtA "calls"))
  (func (export "calls-b") (alias export $virtB "calls"))
  (func (export "real-read") (alias export $real "read"))
)

(assert_return (invoke "run-a" (u32.const 42)) (u32.const 84))
(assert_return (invoke "real-read" (u32.const 266)) (u32.const 42))
(assert_return (invoke "run-b" (u32.const 7)) (u32.const 14))
(assert_return (invoke "real-read" (u32.const 522)) (u32.const 7))
(assert_return (invoke "real-read" (u32.const 10)) (u32.const 0))
(assert_return (invoke "calls-a") (u32.const 2))
(assert_return (invoke "calls-b") (u32.const 2))
