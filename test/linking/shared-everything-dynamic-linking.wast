;; Shared-everything dynamic linking, mirroring
;; design/mvp/examples/SharedEverythingDynamicLinking.md

(component
  (core module $Libc
    (memory (export "memory") 1)
    (global $next (mut i32) (i32.const 8192))
    (func (export "malloc") (param $n i32) (result i32)
      (local $p i32)
      (local.set $p (global.get $next))
      (global.set $next (i32.add (global.get $next) (local.get $n)))
      (local.get $p))
    (func (export "poke") (param $addr i32) (param $val i32) (result i32)
      (local $old i32)
      (local.set $old (i32.load (local.get $addr)))
      (i32.store (local.get $addr) (local.get $val))
      (local.get $old)
    )
  )

  (core module $Libzip
    (import "libc" "memory" (memory 1))
    (import "libc" "malloc" (func $malloc (param i32) (result i32)))
    ;; fake zip(x) = 2*x
    (func (export "zip") (param $x i32) (result i32)
      (local $p i32)
      (local.set $p (call $malloc (i32.const 4)))
      (i32.store (local.get $p) (local.get $x))
      (i32.mul (i32.load (local.get $p)) (i32.const 2)))
  )

  (core module $Libimg
    (import "libc" "memory" (memory 1))
    (import "libc" "malloc" (func (param i32) (result i32)))
    (import "libzip" "zip" (func $zip (param i32) (result i32)))
    ;; fake compress(x) = zip(x)+100
    (func (export "compress") (param $x i32) (result i32)
      (i32.add (call $zip (local.get $x)) (i32.const 100)))
  )

  (component $Zipper
    (import "libc" (core module $Libc
      (export "memory" (memory 1))
      (export "malloc" (func (param i32) (result i32)))
      (export "poke" (func (param i32 i32) (result i32)))))
    (import "libzip" (core module $Libzip
      (import "libc" "memory" (memory 1))
      (import "libc" "malloc" (func (param i32) (result i32)))
      (export "zip" (func (param i32) (result i32)))))
    (core module $Main
      (import "libzip" "zip" (func $zip (param i32) (result i32)))
      (func (export "zip") (param $x i32) (result i32) (call $zip (local.get $x)))
    )
    (core instance $libc (instantiate $Libc))
    (core instance $libzip (instantiate $Libzip (with "libc" (instance $libc))))
    (core instance $main (instantiate $Main (with "libzip" (instance $libzip))))
    (func (export "zip") (param "x" u32) (result u32) (canon lift (core func $main "zip")))
    (func (export "poke") (param "addr" u32) (param "val" u32) (result u32)
      (canon lift (core func $libc "poke")))
  )

  (component $Imgmgk
    (import "libc" (core module $Libc
      (export "memory" (memory 1))
      (export "malloc" (func (param i32) (result i32)))
      (export "poke" (func (param i32 i32) (result i32)))))
    (import "libzip" (core module $Libzip
      (import "libc" "memory" (memory 1))
      (import "libc" "malloc" (func (param i32) (result i32)))
      (export "zip" (func (param i32) (result i32)))))
    (import "libimg" (core module $Libimg
      (import "libc" "memory" (memory 1))
      (import "libc" "malloc" (func (param i32) (result i32)))
      (import "libzip" "zip" (func (param i32) (result i32)))
      (export "compress" (func (param i32) (result i32)))))
    (core module $Main
      (import "libimg" "compress" (func $compress (param i32) (result i32)))
      ;; fake transform(x) = compress(x) + 42
      (func (export "transform") (param $x i32) (result i32)
        (i32.add (call $compress (local.get $x)) (i32.const 42)))
    )
    (core instance $libc (instantiate $Libc))
    (core instance $libzip (instantiate $Libzip (with "libc" (instance $libc))))
    (core instance $libimg (instantiate $Libimg
      (with "libc" (instance $libc))
      (with "libzip" (instance $libzip))))
    (core instance $main (instantiate $Main (with "libimg" (instance $libimg))))
    (func (export "transform") (param "x" u32) (result u32) (canon lift (core func $main "transform")))
    (func (export "poke") (param "addr" u32) (param "val" u32) (result u32)
      (canon lift (core func $libc "poke"))))

  (component $App
    (import "libc" (core module $Libc
      (export "memory" (memory 1))
      (export "malloc" (func (param i32) (result i32)))
      (export "poke" (func (param i32 i32) (result i32)))))
    (import "zipper" (instance $zipper
      (export "zip" (func (param "x" u32) (result u32)))))
    (import "imgmgk" (instance $imgmgk
      (export "transform" (func (param "x" u32) (result u32)))))
    (core instance $libc (instantiate $Libc))
    (core func $zip (canon lower (func $zipper "zip")))
    (core func $transform (canon lower (func $imgmgk "transform")))
    (core module $Main
      (import "dep" "zip" (func $zip (param i32) (result i32)))
      (import "dep" "transform" (func $transform (param i32) (result i32)))
      ;; fake run(x) = zip(x) + transform(x)
      (func (export "run") (param $x i32) (result i32)
        (i32.add (call $zip (local.get $x)) (call $transform (local.get $x))))
    )
    (core instance $main (instantiate $Main
      (with "dep" (instance (export "zip" (func $zip)) (export "transform" (func $transform))))))
    (func (export "run") (param "x" u32) (result u32) (canon lift (core func $main "run")))
    (func (export "poke") (param "addr" u32) (param "val" u32) (result u32)
      (canon lift (core func $libc "poke")))
  )

  (instance $zipper (instantiate $Zipper
    (with "libc" (core module $Libc))
    (with "libzip" (core module $Libzip))))
  (instance $imgmgk (instantiate $Imgmgk
    (with "libc" (core module $Libc))
    (with "libzip" (core module $Libzip))
    (with "libimg" (core module $Libimg))))
  (instance $app (instantiate $App
    (with "libc" (core module $Libc))
    (with "zipper" (instance $zipper))
    (with "imgmgk" (instance $imgmgk))))

  (func (export "run") (alias export $app "run"))
  (func (export "zip") (alias export $zipper "zip"))
  (func (export "transform") (alias export $imgmgk "transform"))
  (func (export "poke-zipper") (alias export $zipper "poke"))
  (func (export "poke-imgmgk") (alias export $imgmgk "poke"))
  (func (export "poke-app") (alias export $app "poke"))
)

(assert_return (invoke "zip" (u32.const 5)) (u32.const 10))
(assert_return (invoke "transform" (u32.const 5)) (u32.const 152))
(assert_return (invoke "run" (u32.const 5)) (u32.const 162))

(assert_return (invoke "poke-zipper" (u32.const 1000) (u32.const 111)) (u32.const 0))
(assert_return (invoke "poke-imgmgk" (u32.const 1000) (u32.const 222)) (u32.const 0))
(assert_return (invoke "poke-app"    (u32.const 1000) (u32.const 333)) (u32.const 0))
(assert_return (invoke "poke-zipper" (u32.const 1000) (u32.const 0)) (u32.const 111))
(assert_return (invoke "poke-imgmgk" (u32.const 1000) (u32.const 0)) (u32.const 222))
(assert_return (invoke "poke-app"    (u32.const 1000) (u32.const 0)) (u32.const 333))

;; breaking a cyclic module dependency with a shared funcref table +
;; a mutable `bar-index` global, per the example's "Cyclic Dependencies" section:

(component
  (core module $A
    (import "linkage" "table" (table $ftbl 1 funcref))
    (import "linkage" "bar-index" (global $bar-index (mut i32)))
    (type $BarT (func (result i32)))
    (func (export "foo") (result i32) (i32.const 10))
    (func (export "call-bar") (result i32)
      (call_indirect (type $BarT) (global.get $bar-index)))
  )

  (core module $B
    (import "a" "foo" (func $a-foo (result i32)))
    (import "linkage" "table" (table $ftbl 1 funcref))
    (import "linkage" "bar-index" (global $bar-index (mut i32)))
    (func $bar (result i32) (i32.add (i32.const 20) (call $a-foo)))
    (func (export "bar") (result i32) (call $bar))
    (elem (table $ftbl) (offset (i32.const 0)) func $bar)
    (func $start (global.set $bar-index (i32.const 0)))
    (start $start)
  )

  (core module $Linkage
    (global (export "bar-index") (mut i32) (i32.const 0))
    (table (export "table") 1 funcref)
  )

  (core instance $linkage (instantiate $Linkage))
  (core instance $a (instantiate $A (with "linkage" (instance $linkage))))
  (core instance $b (instantiate $B
    (with "a" (instance $a))
    (with "linkage" (instance $linkage))))

  (func (export "foo") (result u32) (canon lift (core func $a "foo")))
  (func (export "bar") (result u32) (canon lift (core func $b "bar")))
  (func (export "call-bar") (result u32) (canon lift (core func $a "call-bar")))
)

(assert_return (invoke "foo") (u32.const 10))
(assert_return (invoke "bar") (u32.const 30))
(assert_return (invoke "call-bar") (u32.const 30))
