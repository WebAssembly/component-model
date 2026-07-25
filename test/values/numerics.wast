;; Scalar-value canonicalization semantics of the canonical ABI: small-int
;; truncation, bool normalization, char validation, and flags masking.

;; Out-of-range core i32s passed as u8/s8/u16/s16 params are truncated to the
;; type's width (and sign-extended for signed types) before reaching the callee.
(component
  (component $C
    (core module $M
      (func (export "expect-zero") (param i32)
        (if (i32.ne (local.get 0) (i32.const 0)) (then unreachable)))
      (func (export "expect-neg1") (param i32)
        (if (i32.ne (local.get 0) (i32.const -1)) (then unreachable)))
    )
    (core instance $m (instantiate $M))
    (func (export "u8") (param "x" u8) (canon lift (core func $m "expect-zero")))
    (func (export "u16") (param "x" u16) (canon lift (core func $m "expect-zero")))
    (func (export "s8") (param "x" s8) (canon lift (core func $m "expect-neg1")))
    (func (export "s16") (param "x" s16) (canon lift (core func $m "expect-neg1")))
  )
  (component $D
    (import "u8" (func $u8 (param "x" u8)))
    (import "s8" (func $s8 (param "x" s8)))
    (import "u16" (func $u16 (param "x" u16)))
    (import "s16" (func $s16 (param "x" s16)))
    (core func $u8' (canon lower (func $u8)))
    (core func $s8' (canon lower (func $s8)))
    (core func $u16' (canon lower (func $u16)))
    (core func $s16' (canon lower (func $s16)))
    (core module $M
      (import "" "u8" (func $u8 (param i32)))
      (import "" "s8" (func $s8 (param i32)))
      (import "" "u16" (func $u16 (param i32)))
      (import "" "s16" (func $s16 (param i32)))
      (func (export "run") (result i32)
        (call $u8 (i32.const 0))
        (call $u8 (i32.const 0xff00))     ;; low byte is 0
        (call $s8 (i32.const -1))
        (call $s8 (i32.const 0xff))       ;; low byte sign-extends to -1
        (call $s8 (i32.const 0xffff))
        (call $u16 (i32.const 0))
        (call $u16 (i32.const 0xff0000))
        (call $s16 (i32.const -1))
        (call $s16 (i32.const 0xffff))
        (call $s16 (i32.const 0xffffff))
        (i32.const 42)
      )
    )
    (core instance $m (instantiate $M (with "" (instance
      (export "u8" (func $u8'))
      (export "s8" (func $s8'))
      (export "u16" (func $u16'))
      (export "s16" (func $s16'))
    ))))
    (func (export "run") (result u32) (canon lift (core func $m "run")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "u8" (func $c "u8"))
    (with "s8" (func $c "s8"))
    (with "u16" (func $c "u16"))
    (with "s16" (func $c "s16"))
  ))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 42))

;; An out-of-range core result is truncated when lifted to a narrower type at
;; the host boundary.
(component
  (core module $M (func (export "id") (param i32) (result i32) (local.get 0)))
  (core instance $m (instantiate $M))
  (func (export "i-to-b") (param "x" u32) (result bool) (canon lift (core func $m "id")))
  (func (export "i-to-u8") (param "x" u32) (result u8) (canon lift (core func $m "id")))
  (func (export "i-to-s8") (param "x" u32) (result s8) (canon lift (core func $m "id")))
  (func (export "i-to-u16") (param "x" u32) (result u16) (canon lift (core func $m "id")))
  (func (export "i-to-s16") (param "x" u32) (result s16) (canon lift (core func $m "id")))
)
(assert_return (invoke "i-to-b" (u32.const 0)) (bool.const false))
(assert_return (invoke "i-to-b" (u32.const 2)) (bool.const true))
(assert_return (invoke "i-to-u8" (u32.const 0xf01)) (u8.const 1))
(assert_return (invoke "i-to-s8" (u32.const 0xffffffff)) (s8.const -1))
(assert_return (invoke "i-to-u16" (u32.const 0xffffffff)) (u16.const 0xffff))
(assert_return (invoke "i-to-s16" (u32.const 0xffffffff)) (s16.const -1))

;; Any nonzero core i32 passed as a bool param reaches the callee as exactly 1;
;; 0 stays 0.
(component
  (component $C
    (core module $M
      (func (export "expect-one") (param i32)
        (if (i32.ne (local.get 0) (i32.const 1)) (then unreachable)))
      (func (export "expect-zero") (param i32)
        (if (i32.ne (local.get 0) (i32.const 0)) (then unreachable)))
    )
    (core instance $m (instantiate $M))
    (func (export "assert-true") (param "x" bool) (canon lift (core func $m "expect-one")))
    (func (export "assert-false") (param "x" bool) (canon lift (core func $m "expect-zero")))
  )
  (component $D
    (import "assert-true" (func $assert-true (param "x" bool)))
    (import "assert-false" (func $assert-false (param "x" bool)))
    (core func $assert-true' (canon lower (func $assert-true)))
    (core func $assert-false' (canon lower (func $assert-false)))
    (core module $M
      (import "" "assert-true" (func $assert-true (param i32)))
      (import "" "assert-false" (func $assert-false (param i32)))
      (func (export "run") (result i32)
        (call $assert-true (i32.const 1))
        (call $assert-true (i32.const 2))
        (call $assert-true (i32.const -1))
        (call $assert-false (i32.const 0))
        (i32.const 43)
      )
    )
    (core instance $m (instantiate $M (with "" (instance
      (export "assert-true" (func $assert-true'))
      (export "assert-false" (func $assert-false'))
    ))))
    (func (export "run") (result u32) (canon lift (core func $m "run")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "assert-true" (func $c "assert-true"))
    (with "assert-false" (func $c "assert-false"))
  ))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 43))

;; Valid chars round-trip across components and the host boundary, including
;; the surrogate-range boundaries 0xd7ff/0xe000 and the max scalar 0x10ffff.
(component
  (component $C
    (core module $M (func (export "id") (param i32) (result i32) (local.get 0)))
    (core instance $m (instantiate $M))
    (func (export "id") (param "x" char) (result char) (canon lift (core func $m "id")))
  )
  (component $D
    (import "id" (func $id (param "x" char) (result char)))
    (core func $id' (canon lower (func $id)))
    (core module $M
      (import "" "id" (func $id (param i32) (result i32)))
      (func $check (param i32)
        (if (i32.ne (call $id (local.get 0)) (local.get 0)) (then unreachable)))
      (func (export "run") (result i32)
        (call $check (i32.const 0))
        (call $check (i32.const 0xd7ff))
        (call $check (i32.const 0xe000))
        (call $check (i32.const 0x10ffff))
        (i32.const 44)
      )
    )
    (core instance $m (instantiate $M (with "" (instance (export "id" (func $id'))))))
    (func (export "run") (result u32) (canon lift (core func $m "run")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "id" (func $c "id"))))
  (func (export "run") (alias export $d "run"))
  (func (export "roundtrip") (alias export $c "id"))
)
(assert_return (invoke "run") (u32.const 44))
(assert_return (invoke "roundtrip" (char.const "⛳")) (char.const "⛳"))
(assert_return (invoke "roundtrip" (char.const "🍰")) (char.const "🍰"))

;; Surrogates and values above 0x10ffff are invalid char bit patterns and trap
;; when passed from core code.
(component definition $CharTraps
  (component $C
    (core module $M (func (export "take") (param i32)))
    (core instance $m (instantiate $M))
    (func (export "take") (param "x" char) (canon lift (core func $m "take")))
  )
  (component $D
    (import "take" (func $take (param "x" char)))
    (core func $take' (canon lower (func $take)))
    (core module $M
      (import "" "take" (func $take (param i32)))
      (func (export "run-d800") (call $take (i32.const 0xd800)))
      (func (export "run-dfff") (call $take (i32.const 0xdfff)))
      (func (export "run-too-big") (call $take (i32.const 0x110000)))
    )
    (core instance $m (instantiate $M (with "" (instance (export "take" (func $take'))))))
    (func (export "run-d800") (canon lift (core func $m "run-d800")))
    (func (export "run-dfff") (canon lift (core func $m "run-dfff")))
    (func (export "run-too-big") (canon lift (core func $m "run-too-big")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "take" (func $c "take"))))
  (func (export "run-d800") (alias export $d "run-d800"))
  (func (export "run-dfff") (alias export $d "run-dfff"))
  (func (export "run-too-big") (alias export $d "run-too-big"))
)
(component instance $ct $CharTraps)
(assert_trap (invoke "run-d800") "invalid `char` bit pattern")
(component instance $ct $CharTraps)
(assert_trap (invoke "run-dfff") "invalid `char` bit pattern")
(component instance $ct $CharTraps)
(assert_trap (invoke "run-too-big") "invalid `char` bit pattern")

;; Undefined upper flag bits are masked off crossing components; a 32-flag type
;; has no undefined bits so all pass through.
(component
  (type $f1' (flags "f1"))
  (type $f8' (flags "f1" "f2" "f3" "f4" "f5" "f6" "f7" "f8"))
  (type $f9' (flags "f1" "f2" "f3" "f4" "f5" "f6" "f7" "f8" "f9"))
  (type $f16' (flags
    "f1" "f2" "f3" "f4" "f5" "f6" "f7" "f8"
    "g1" "g2" "g3" "g4" "g5" "g6" "g7" "g8"
  ))
  (type $f17' (flags
    "f1" "f2" "f3" "f4" "f5" "f6" "f7" "f8"
    "g1" "g2" "g3" "g4" "g5" "g6" "g7" "g8"
    "g9"
  ))
  (type $f32' (flags
    "f1" "f2" "f3" "f4" "f5" "f6" "f7" "f8"
    "g1" "g2" "g3" "g4" "g5" "g6" "g7" "g8"
    "h1" "h2" "h3" "h4" "h5" "h6" "h7" "h8"
    "i1" "i2" "i3" "i4" "i5" "i6" "i7" "i8"
  ))
  (component $C
    (export $f1 "t-f1" (type $f1'))
    (export $f8 "t-f8" (type $f8'))
    (export $f9 "t-f9" (type $f9'))
    (export $f16 "t-f16" (type $f16'))
    (export $f17 "t-f17" (type $f17'))
    (export $f32 "t-f32" (type $f32'))
    (core module $M
      (func (export "f1") (param i32)
        (if (i32.ne (local.get 0) (i32.const 0x1)) (then unreachable)))
      (func (export "f8") (param i32)
        (if (i32.ne (local.get 0) (i32.const 0x11)) (then unreachable)))
      (func (export "f9") (param i32)
        (if (i32.ne (local.get 0) (i32.const 0x111)) (then unreachable)))
      (func (export "f16") (param i32)
        (if (i32.ne (local.get 0) (i32.const 0x1111)) (then unreachable)))
      (func (export "f17") (param i32)
        (if (i32.ne (local.get 0) (i32.const 0x11111)) (then unreachable)))
      (func (export "f32") (param i32)
        (if (i32.ne (local.get 0) (i32.const 0xffffffff)) (then unreachable)))
    )
    (core instance $m (instantiate $M))
    (func (export "f1") (param "x" $f1) (canon lift (core func $m "f1")))
    (func (export "f8") (param "x" $f8) (canon lift (core func $m "f8")))
    (func (export "f9") (param "x" $f9) (canon lift (core func $m "f9")))
    (func (export "f16") (param "x" $f16) (canon lift (core func $m "f16")))
    (func (export "f17") (param "x" $f17) (canon lift (core func $m "f17")))
    (func (export "f32") (param "x" $f32) (canon lift (core func $m "f32")))
  )
  (component $D
    (import "c" (instance $i
      (export "t-f1" (type $f1 (eq $f1')))
      (export "t-f8" (type $f8 (eq $f8')))
      (export "t-f9" (type $f9 (eq $f9')))
      (export "t-f16" (type $f16 (eq $f16')))
      (export "t-f17" (type $f17 (eq $f17')))
      (export "t-f32" (type $f32 (eq $f32')))
      (export "f1" (func (param "x" $f1)))
      (export "f8" (func (param "x" $f8)))
      (export "f9" (func (param "x" $f9)))
      (export "f16" (func (param "x" $f16)))
      (export "f17" (func (param "x" $f17)))
      (export "f32" (func (param "x" $f32)))
    ))
    (core func $f1' (canon lower (func $i "f1")))
    (core func $f8' (canon lower (func $i "f8")))
    (core func $f9' (canon lower (func $i "f9")))
    (core func $f16' (canon lower (func $i "f16")))
    (core func $f17' (canon lower (func $i "f17")))
    (core func $f32' (canon lower (func $i "f32")))
    (core module $M
      (import "" "f1" (func $f1 (param i32)))
      (import "" "f8" (func $f8 (param i32)))
      (import "" "f9" (func $f9 (param i32)))
      (import "" "f16" (func $f16 (param i32)))
      (import "" "f17" (func $f17 (param i32)))
      (import "" "f32" (func $f32 (param i32)))
      (func (export "run") (result i32)
        (call $f1 (i32.const 0xffffff01))
        (call $f8 (i32.const 0xffffff11))
        (call $f9 (i32.const 0xffffff11))
        (call $f16 (i32.const 0xffff1111))
        (call $f17 (i32.const 0xffff1111))
        (call $f32 (i32.const 0xffffffff))
        (i32.const 45)
      )
    )
    (core instance $m (instantiate $M (with "" (instance
      (export "f1" (func $f1'))
      (export "f8" (func $f8'))
      (export "f9" (func $f9'))
      (export "f16" (func $f16'))
      (export "f17" (func $f17'))
      (export "f32" (func $f32'))
    ))))
    (func (export "run") (result u32) (canon lift (core func $m "run")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "c" (instance $c))))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 45))

;; Undefined upper bits in a core flags result are also dropped when lifted to
;; the host.
(component
  (type $f9 (flags "f1" "f2" "f3" "f4" "f5" "f6" "f7" "f8" "f9"))
  (export $f9' "f9" (type $f9))
  (core module $M (func (export "junk") (result i32) (i32.const 0xffffff11)))
  (core instance $m (instantiate $M))
  (func (export "junk-to-f9") (result $f9') (canon lift (core func $m "junk")))
)
(assert_return (invoke "junk-to-f9") (flags.const "f1" "f5" "f9"))
