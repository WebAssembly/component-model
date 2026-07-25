;; Pointer alignment and bounds checks in the canonical ABI at a
;; cross-component boundary.

;; callee returns a misaligned retptr for a spilled (>1 flat) result
(component definition $CalleeRetptr
  (component $C
    (core module $M
      (memory (export "mem") 1)
      (func (export "f") (result i32) (i32.const 1)))
    (core instance $m (instantiate $M))
    (func (export "f") (result (tuple u32 u32))
      (canon lift (core func $m "f") (memory (core memory $m "mem")))))
  (component $D
    (import "f" (func $f (result (tuple u32 u32))))
    (core module $Libc (memory (export "mem") 1))
    (core instance $libc (instantiate $Libc))
    (core func $f' (canon lower (func $f) (memory (core memory $libc "mem"))))
    (core module $Main
      (import "" "f" (func $f (param i32)))
      (func (export "run") (call $f (i32.const 8))))
    (core instance $main (instantiate $Main (with "" (instance (export "f" (func $f'))))))
    (func (export "run") (canon lift (core func $main "run"))))
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "f" (func $c "f"))))
  (func (export "run") (alias export $d "run")))
(component instance $i $CalleeRetptr)
(assert_trap (invoke "run") "unaligned pointer")

;; caller passes a misaligned retptr to the lowered import
(component definition $CallerRetptr
  (component $C
    (core module $M
      (memory (export "mem") 1)
      (func (export "f") (result i32) (i32.const 0)))
    (core instance $m (instantiate $M))
    (func (export "f") (result (tuple u32 u32))
      (canon lift (core func $m "f") (memory (core memory $m "mem")))))
  (component $D
    (import "f" (func $f (result (tuple u32 u32))))
    (core module $Libc (memory (export "mem") 1))
    (core instance $libc (instantiate $Libc))
    (core func $f' (canon lower (func $f) (memory (core memory $libc "mem"))))
    (core module $Main
      (import "" "f" (func $f (param i32)))
      (func (export "run") (call $f (i32.const 1))))
    (core instance $main (instantiate $Main (with "" (instance (export "f" (func $f'))))))
    (func (export "run") (canon lift (core func $main "run"))))
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "f" (func $c "f"))))
  (func (export "run") (alias export $d "run")))
(component instance $i $CallerRetptr)
(assert_trap (invoke "run") "unaligned pointer")

;; >16 flat params spill through the callee's realloc, which returns a
;; misaligned pointer
(component definition $CalleeArgptr
  (component $C
    (type $big (tuple u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32))
    (core module $M
      (memory (export "mem") 1)
      (func (export "f") (param i32))
      (func (export "realloc") (param i32 i32 i32 i32) (result i32) (i32.const 1)))
    (core instance $m (instantiate $M))
    (func (export "f") (param "a" $big)
      (canon lift (core func $m "f")
        (memory (core memory $m "mem")) (realloc (core func $m "realloc")))))
  (component $D
    (type $big (tuple u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32))
    (import "f" (func $f (param "a" $big)))
    (core module $Libc (memory (export "mem") 1))
    (core instance $libc (instantiate $Libc))
    (core func $f' (canon lower (func $f) (memory (core memory $libc "mem"))))
    (core module $Main
      (import "" "f" (func $f (param i32)))
      (func (export "run") (call $f (i32.const 8))))
    (core instance $main (instantiate $Main (with "" (instance (export "f" (func $f'))))))
    (func (export "run") (canon lift (core func $main "run"))))
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "f" (func $c "f"))))
  (func (export "run") (alias export $d "run")))
(component instance $i $CalleeArgptr)
(assert_trap (invoke "run") "unaligned pointer")

;; caller passes a misaligned argptr for the spilled params
(component definition $CallerArgptr
  (component $C
    (type $big (tuple u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32))
    (core module $M
      (memory (export "mem") 1)
      (func (export "f") (param i32))
      (func (export "realloc") (param i32 i32 i32 i32) (result i32) (i32.const 8)))
    (core instance $m (instantiate $M))
    (func (export "f") (param "a" $big)
      (canon lift (core func $m "f")
        (memory (core memory $m "mem")) (realloc (core func $m "realloc")))))
  (component $D
    (type $big (tuple u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32 u32))
    (import "f" (func $f (param "a" $big)))
    (core module $Libc (memory (export "mem") 1))
    (core instance $libc (instantiate $Libc))
    (core func $f' (canon lower (func $f) (memory (core memory $libc "mem"))))
    (core module $Main
      (import "" "f" (func $f (param i32)))
      (func (export "run") (call $f (i32.const 1))))
    (core instance $main (instantiate $Main (with "" (instance (export "f" (func $f'))))))
    (func (export "run") (canon lift (core func $main "run"))))
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "f" (func $c "f"))))
  (func (export "run") (alias export $d "run")))
(component instance $i $CallerArgptr)
(assert_trap (invoke "run") "unaligned pointer")

;; a utf16 caller-side string pointer must be 2-aligned, even when len=0
(component definition $Utf16Src
  (component $C
    (core module $M
      (memory (export "mem") 1)
      (func (export "f") (param i32 i32))
      (func (export "realloc") (param i32 i32 i32 i32) (result i32) (i32.const 8)))
    (core instance $m (instantiate $M))
    (func (export "f") (param "s" string)
      (canon lift (core func $m "f") string-encoding=utf8
        (memory (core memory $m "mem")) (realloc (core func $m "realloc")))))
  (component $D
    (import "f" (func $f (param "s" string)))
    (core module $Libc (memory (export "mem") 1))
    (core instance $libc (instantiate $Libc))
    (core func $f' (canon lower (func $f) string-encoding=utf16
      (memory (core memory $libc "mem"))))
    (core module $Main
      (import "" "f" (func $f (param i32 i32)))
      (func (export "run") (call $f (i32.const 1) (i32.const 0))))
    (core instance $main (instantiate $Main (with "" (instance (export "f" (func $f'))))))
    (func (export "run") (canon lift (core func $main "run"))))
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "f" (func $c "f"))))
  (func (export "run") (alias export $d "run")))
(component instance $i $Utf16Src)
(assert_trap (invoke "run") "unaligned pointer")

;; a latin1+utf16 caller-side string pointer must be 2-aligned for both
;; dynamic representations: untagged (latin1) and tagged (utf16) lengths
(component definition $Latin1Utf16Src
  (component $C
    (core module $M
      (memory (export "mem") 1)
      (func (export "f") (param i32 i32))
      (func (export "realloc") (param i32 i32 i32 i32) (result i32) (i32.const 8)))
    (core instance $m (instantiate $M))
    (func (export "f") (param "s" string)
      (canon lift (core func $m "f") string-encoding=utf8
        (memory (core memory $m "mem")) (realloc (core func $m "realloc")))))
  (component $D
    (import "f" (func $f (param "s" string)))
    (core module $Libc (memory (export "mem") 1))
    (core instance $libc (instantiate $Libc))
    (core func $f' (canon lower (func $f) string-encoding=latin1+utf16
      (memory (core memory $libc "mem"))))
    (core module $Main
      (import "" "f" (func $f (param i32 i32)))
      (func (export "run-latin1") (call $f (i32.const 1) (i32.const 0)))
      (func (export "run-utf16") (call $f (i32.const 1) (i32.const 0x80000000))))
    (core instance $main (instantiate $Main (with "" (instance (export "f" (func $f'))))))
    (func (export "run-latin1") (canon lift (core func $main "run-latin1")))
    (func (export "run-utf16") (canon lift (core func $main "run-utf16"))))
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "f" (func $c "f"))))
  (func (export "run-latin1") (alias export $d "run-latin1"))
  (func (export "run-utf16") (alias export $d "run-utf16")))
(component instance $i $Latin1Utf16Src)
(assert_trap (invoke "run-latin1") "unaligned pointer")
(component instance $i $Latin1Utf16Src)
(assert_trap (invoke "run-utf16") "unaligned pointer")

;; caller-side string ptr/len out of bounds of the caller's own memory, both
;; with the pointer itself out of bounds and with only ptr+len out of bounds
(component definition $StringOOB
  (component $C
    (core module $M
      (memory (export "mem") 1)
      (func (export "f") (param i32 i32))
      (func (export "realloc") (param i32 i32 i32 i32) (result i32) (i32.const 8)))
    (core instance $m (instantiate $M))
    (func (export "f") (param "s" string)
      (canon lift (core func $m "f") string-encoding=utf8
        (memory (core memory $m "mem")) (realloc (core func $m "realloc")))))
  (component $D
    (import "f" (func $f (param "s" string)))
    (core module $Libc (memory (export "mem") 1))
    (core instance $libc (instantiate $Libc))
    (core func $f' (canon lower (func $f) string-encoding=utf8
      (memory (core memory $libc "mem"))))
    (core module $Main
      (import "" "f" (func $f (param i32 i32)))
      (func (export "run-ptr-oob") (call $f (i32.const 0x80000000) (i32.const 1)))
      (func (export "run-len-oob") (call $f (i32.const 65535) (i32.const 2))))
    (core instance $main (instantiate $Main (with "" (instance (export "f" (func $f'))))))
    (func (export "run-ptr-oob") (canon lift (core func $main "run-ptr-oob")))
    (func (export "run-len-oob") (canon lift (core func $main "run-len-oob"))))
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "f" (func $c "f"))))
  (func (export "run-ptr-oob") (alias export $d "run-ptr-oob"))
  (func (export "run-len-oob") (alias export $d "run-len-oob")))
(component instance $i $StringOOB)
(assert_trap (invoke "run-ptr-oob") "string content out-of-bounds")
(component instance $i $StringOOB)
(assert_trap (invoke "run-len-oob") "string content out-of-bounds")
