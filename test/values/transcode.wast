;; Test string transcoding between directly-linked components whose `canon
;; lower` (caller) and `canon lift` (callee) declare different string
;; encodings; each side checks the exact transcoded bytes in its own memory.

;; utf16 caller -> utf8 callee, plus an empty-string round trip. utf16 lengths
;; count 16-bit code units (not bytes) and code units are little-endian.
(component
  (component $C
    (core module $M
      (memory (export "mem") 1)
      (global $next (mut i32) (i32.const 1024))
      (func (export "realloc") (param $old i32) (param $osize i32) (param $align i32) (param $nsize i32) (result i32)
        (local $r i32)
        ;; shrinking realloc: keep the (8-aligned) allocation in place
        (if (i32.and (i32.ne (local.get $old) (i32.const 0))
                     (i32.le_u (local.get $nsize) (local.get $osize)))
          (then (return (local.get $old))))
        ;; fresh 8-aligned bump allocation
        (global.set $next (i32.and (i32.add (global.get $next) (i32.const 7)) (i32.const -8)))
        (local.set $r (global.get $next))
        (global.set $next (i32.add (global.get $next) (local.get $nsize)))
        ;; growing realloc must preserve the old contents
        (if (i32.ne (local.get $old) (i32.const 0))
          (then (memory.copy (local.get $r) (local.get $old) (local.get $osize))))
        (local.get $r))

      ;; response "ok☃🍰" utf8 = 6F 6B E2 98 83 F0 9F 8D B0 (9 bytes)
      (data (i32.const 64) "\6f\6b\e2\98\83\f0\9f\8d\b0")

      ;; expect "hö☃🍰" utf8 = 68 C3 B6 E2 98 83 F0 9F 8D B0 (10 bytes)
      (func (export "join") (param $ptr i32) (param $len i32) (result i32)
        (if (i32.ne (local.get $len) (i32.const 10)) (then unreachable))
        (if (i64.ne (i64.load (local.get $ptr)) (i64.const 0x9FF08398E2B6C368)) (then unreachable))
        (if (i32.ne (i32.load16_u offset=8 (local.get $ptr)) (i32.const 0xB08D)) (then unreachable))
        (i32.store (i32.const 0) (i32.const 64))
        (i32.store (i32.const 4) (i32.const 9))
        (i32.const 0))

      ;; expect "" (0 bytes); respond "" as (ptr=0, len=0)
      (func (export "empty") (param $ptr i32) (param $len i32) (result i32)
        (if (i32.ne (local.get $len) (i32.const 0)) (then unreachable))
        (i32.store (i32.const 0) (i32.const 0))
        (i32.store (i32.const 4) (i32.const 0))
        (i32.const 0))
    )
    (core instance $m (instantiate $M))
    (func (export "join") (param "s" string) (result string)
      (canon lift (core func $m "join") string-encoding=utf8
        (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
    (func (export "empty") (param "s" string) (result string)
      (canon lift (core func $m "empty") string-encoding=utf8
        (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  )

  (component $D
    (import "join" (func $join (param "s" string) (result string)))
    (import "empty" (func $empty (param "s" string) (result string)))
    (core module $Libc
      (memory (export "mem") 1)
      (global $next (mut i32) (i32.const 1024))
      (func (export "realloc") (param $old i32) (param $osize i32) (param $align i32) (param $nsize i32) (result i32)
        (local $r i32)
        (if (i32.and (i32.ne (local.get $old) (i32.const 0))
                     (i32.le_u (local.get $nsize) (local.get $osize)))
          (then (return (local.get $old))))
        (global.set $next (i32.and (i32.add (global.get $next) (i32.const 7)) (i32.const -8)))
        (local.set $r (global.get $next))
        (global.set $next (i32.add (global.get $next) (local.get $nsize)))
        (if (i32.ne (local.get $old) (i32.const 0))
          (then (memory.copy (local.get $r) (local.get $old) (local.get $osize))))
        (local.get $r))
    )
    (core instance $libc (instantiate $Libc))
    (core func $join' (canon lower (func $join) string-encoding=utf16
      (memory (core memory $libc "mem")) (realloc (core func $libc "realloc"))))
    (core func $empty' (canon lower (func $empty) string-encoding=utf16
      (memory (core memory $libc "mem")) (realloc (core func $libc "realloc"))))
    (core module $Main
      (import "" "mem" (memory 1))
      (import "" "join" (func $join (param i32 i32 i32)))
      (import "" "empty" (func $empty (param i32 i32 i32)))

      ;; argument "hö☃🍰" utf16 = 0068 00F6 2603 D83C DF70 (5 code units)
      (data (i32.const 16) "\68\00\f6\00\03\26\3c\d8\70\df")

      (func (export "run") (result i32)
        (local $p i32)
        (call $join (i32.const 16) (i32.const 5) (i32.const 8))
        ;; expect "ok☃🍰" utf16 = 006F 006B 2603 D83C DF70 (5 code units)
        (local.set $p (i32.load (i32.const 8)))
        (if (i32.ne (i32.load (i32.const 12)) (i32.const 5)) (then unreachable))
        (if (i64.ne (i64.load (local.get $p)) (i64.const 0xD83C2603006B006F)) (then unreachable))
        (if (i32.ne (i32.load16_u offset=8 (local.get $p)) (i32.const 0xDF70)) (then unreachable))
        (call $empty (i32.const 16) (i32.const 0) (i32.const 8))
        (if (i32.ne (i32.load (i32.const 12)) (i32.const 0)) (then unreachable))
        (i32.const 42))
    )
    (core instance $main (instantiate $Main (with "" (instance
      (export "mem" (memory $libc "mem"))
      (export "join" (func $join'))
      (export "empty" (func $empty'))
    ))))
    (func (export "run") (result u32) (canon lift (core func $main "run")))
  )

  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "join" (func $c "join"))
    (with "empty" (func $c "empty"))
  ))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 42))

;; utf8 caller -> utf16 callee; the caller's `canon lower` omits
;; string-encoding, exercising the utf8 default.
(component
  (component $C
    (core module $M
      (memory (export "mem") 1)
      (global $next (mut i32) (i32.const 1024))
      (func (export "realloc") (param $old i32) (param $osize i32) (param $align i32) (param $nsize i32) (result i32)
        (local $r i32)
        (if (i32.and (i32.ne (local.get $old) (i32.const 0))
                     (i32.le_u (local.get $nsize) (local.get $osize)))
          (then (return (local.get $old))))
        (global.set $next (i32.and (i32.add (global.get $next) (i32.const 7)) (i32.const -8)))
        (local.set $r (global.get $next))
        (global.set $next (i32.add (global.get $next) (local.get $nsize)))
        (if (i32.ne (local.get $old) (i32.const 0))
          (then (memory.copy (local.get $r) (local.get $old) (local.get $osize))))
        (local.get $r))

      ;; response "ök🍰" utf16 = 00F6 006B D83C DF70 (4 code units)
      (data (i32.const 64) "\f6\00\6b\00\3c\d8\70\df")

      ;; expect "hö☃🍰" utf16 = 0068 00F6 2603 D83C DF70 (5 code units)
      (func (export "join") (param $ptr i32) (param $units i32) (result i32)
        (if (i32.ne (local.get $units) (i32.const 5)) (then unreachable))
        (if (i64.ne (i64.load (local.get $ptr)) (i64.const 0xD83C260300F60068)) (then unreachable))
        (if (i32.ne (i32.load16_u offset=8 (local.get $ptr)) (i32.const 0xDF70)) (then unreachable))
        (i32.store (i32.const 0) (i32.const 64))
        (i32.store (i32.const 4) (i32.const 4))
        (i32.const 0))
    )
    (core instance $m (instantiate $M))
    (func (export "join") (param "s" string) (result string)
      (canon lift (core func $m "join") string-encoding=utf16
        (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  )

  (component $D
    (import "join" (func $join (param "s" string) (result string)))
    (core module $Libc
      (memory (export "mem") 1)
      (global $next (mut i32) (i32.const 1024))
      (func (export "realloc") (param $old i32) (param $osize i32) (param $align i32) (param $nsize i32) (result i32)
        (local $r i32)
        (if (i32.and (i32.ne (local.get $old) (i32.const 0))
                     (i32.le_u (local.get $nsize) (local.get $osize)))
          (then (return (local.get $old))))
        (global.set $next (i32.and (i32.add (global.get $next) (i32.const 7)) (i32.const -8)))
        (local.set $r (global.get $next))
        (global.set $next (i32.add (global.get $next) (local.get $nsize)))
        (if (i32.ne (local.get $old) (i32.const 0))
          (then (memory.copy (local.get $r) (local.get $old) (local.get $osize))))
        (local.get $r))
    )
    (core instance $libc (instantiate $Libc))
    (core func $join' (canon lower (func $join)
      (memory (core memory $libc "mem")) (realloc (core func $libc "realloc"))))
    (core module $Main
      (import "" "mem" (memory 1))
      (import "" "join" (func $join (param i32 i32 i32)))

      ;; argument "hö☃🍰" utf8 = 68 C3 B6 E2 98 83 F0 9F 8D B0 (10 bytes)
      (data (i32.const 16) "\68\c3\b6\e2\98\83\f0\9f\8d\b0")

      (func (export "run") (result i32)
        (local $p i32)
        (call $join (i32.const 16) (i32.const 10) (i32.const 8))
        ;; expect "ök🍰" utf8 = C3 B6 6B F0 9F 8D B0 (7 bytes)
        (local.set $p (i32.load (i32.const 8)))
        (if (i32.ne (i32.load (i32.const 12)) (i32.const 7)) (then unreachable))
        (if (i32.ne (i32.load (local.get $p)) (i32.const 0xF06BB6C3)) (then unreachable))
        (if (i32.ne (i32.load16_u offset=4 (local.get $p)) (i32.const 0x8D9F)) (then unreachable))
        (if (i32.ne (i32.load8_u offset=6 (local.get $p)) (i32.const 0xB0)) (then unreachable))
        (i32.const 43))
    )
    (core instance $main (instantiate $Main (with "" (instance
      (export "mem" (memory $libc "mem"))
      (export "join" (func $join'))
    ))))
    (func (export "run") (result u32) (canon lift (core func $main "run")))
  )

  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "join" (func $c "join"))))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 43))

;; latin1+utf16 caller -> utf8 callee: the length's high bit tags a utf16 (vs
;; latin1) argument; the adapter picks the result representation by content.
(component
  (component $C
    (core module $M
      (memory (export "mem") 1)
      (global $next (mut i32) (i32.const 1024))
      (func (export "realloc") (param $old i32) (param $osize i32) (param $align i32) (param $nsize i32) (result i32)
        (local $r i32)
        (if (i32.and (i32.ne (local.get $old) (i32.const 0))
                     (i32.le_u (local.get $nsize) (local.get $osize)))
          (then (return (local.get $old))))
        (global.set $next (i32.and (i32.add (global.get $next) (i32.const 7)) (i32.const -8)))
        (local.set $r (global.get $next))
        (global.set $next (i32.add (global.get $next) (local.get $nsize)))
        (if (i32.ne (local.get $old) (i32.const 0))
          (then (memory.copy (local.get $r) (local.get $old) (local.get $osize))))
        (local.get $r))

      ;; response "grün" utf8 = 67 72 C3 BC 6E (5 bytes)
      (data (i32.const 64) "\67\72\c3\bc\6e")
      ;; response "sn☃" utf8 = 73 6E E2 98 83 (5 bytes)
      (data (i32.const 80) "\73\6e\e2\98\83")

      ;; expect "höla" utf8 = 68 C3 B6 6C 61 (5 bytes)
      (func (export "compact") (param $ptr i32) (param $len i32) (result i32)
        (if (i32.ne (local.get $len) (i32.const 5)) (then unreachable))
        (if (i32.ne (i32.load (local.get $ptr)) (i32.const 0x6CB6C368)) (then unreachable))
        (if (i32.ne (i32.load8_u offset=4 (local.get $ptr)) (i32.const 0x61)) (then unreachable))
        (i32.store (i32.const 0) (i32.const 64))
        (i32.store (i32.const 4) (i32.const 5))
        (i32.const 0))

      ;; expect "☃🍰" utf8 = E2 98 83 F0 9F 8D B0 (7 bytes)
      (func (export "unicode") (param $ptr i32) (param $len i32) (result i32)
        (if (i32.ne (local.get $len) (i32.const 7)) (then unreachable))
        (if (i32.ne (i32.load (local.get $ptr)) (i32.const 0xF08398E2)) (then unreachable))
        (if (i32.ne (i32.load16_u offset=4 (local.get $ptr)) (i32.const 0x8D9F)) (then unreachable))
        (if (i32.ne (i32.load8_u offset=6 (local.get $ptr)) (i32.const 0xB0)) (then unreachable))
        (i32.store (i32.const 0) (i32.const 80))
        (i32.store (i32.const 4) (i32.const 5))
        (i32.const 0))
    )
    (core instance $m (instantiate $M))
    (func (export "compact") (param "s" string) (result string)
      (canon lift (core func $m "compact") string-encoding=utf8
        (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
    (func (export "unicode") (param "s" string) (result string)
      (canon lift (core func $m "unicode") string-encoding=utf8
        (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  )

  (component $D
    (import "compact" (func $compact (param "s" string) (result string)))
    (import "unicode" (func $unicode (param "s" string) (result string)))
    (core module $Libc
      (memory (export "mem") 1)
      (global $next (mut i32) (i32.const 1024))
      (func (export "realloc") (param $old i32) (param $osize i32) (param $align i32) (param $nsize i32) (result i32)
        (local $r i32)
        (if (i32.and (i32.ne (local.get $old) (i32.const 0))
                     (i32.le_u (local.get $nsize) (local.get $osize)))
          (then (return (local.get $old))))
        (global.set $next (i32.and (i32.add (global.get $next) (i32.const 7)) (i32.const -8)))
        (local.set $r (global.get $next))
        (global.set $next (i32.add (global.get $next) (local.get $nsize)))
        (if (i32.ne (local.get $old) (i32.const 0))
          (then (memory.copy (local.get $r) (local.get $old) (local.get $osize))))
        (local.get $r))
    )
    (core instance $libc (instantiate $Libc))
    (core func $compact' (canon lower (func $compact) string-encoding=latin1+utf16
      (memory (core memory $libc "mem")) (realloc (core func $libc "realloc"))))
    (core func $unicode' (canon lower (func $unicode) string-encoding=latin1+utf16
      (memory (core memory $libc "mem")) (realloc (core func $libc "realloc"))))
    (core module $Main
      (import "" "mem" (memory 1))
      (import "" "compact" (func $compact (param i32 i32 i32)))
      (import "" "unicode" (func $unicode (param i32 i32 i32)))

      ;; argument "höla" latin1 = 68 F6 6C 61 (4 code units, untagged)
      (data (i32.const 16) "\68\f6\6c\61")
      ;; argument "☃🍰" utf16 = 2603 D83C DF70 (3 code units, tagged)
      (data (i32.const 24) "\03\26\3c\d8\70\df")

      (func (export "run") (result i32)
        (local $p i32)
        (call $compact (i32.const 16) (i32.const 4) (i32.const 8))
        ;; expect "grün" latin1 = 67 72 FC 6E (4 code units, untagged)
        (local.set $p (i32.load (i32.const 8)))
        (if (i32.ne (i32.load (i32.const 12)) (i32.const 4)) (then unreachable))
        (if (i32.ne (i32.load (local.get $p)) (i32.const 0x6EFC7267)) (then unreachable))
        ;; tagged length 0x80000003 = high bit (utf16 tag) | 3 code units
        (call $unicode (i32.const 24) (i32.const 0x80000003) (i32.const 8))
        ;; expect "sn☃" utf16 = 0073 006E 2603 (3 code units, tagged)
        (local.set $p (i32.load (i32.const 8)))
        (if (i32.ne (i32.load (i32.const 12)) (i32.const 0x80000003)) (then unreachable))
        (if (i32.ne (i32.load (local.get $p)) (i32.const 0x006E0073)) (then unreachable))
        (if (i32.ne (i32.load16_u offset=4 (local.get $p)) (i32.const 0x2603)) (then unreachable))
        (i32.const 44))
    )
    (core instance $main (instantiate $Main (with "" (instance
      (export "mem" (memory $libc "mem"))
      (export "compact" (func $compact'))
      (export "unicode" (func $unicode'))
    ))))
    (func (export "run") (result u32) (canon lift (core func $main "run")))
  )

  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "compact" (func $c "compact"))
    (with "unicode" (func $c "unicode"))
  ))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 44))

;; latin1+utf16 on both sides: utf16-tagged input whose code points all fit in
;; latin1 must arrive deflated to latin1; wide content stays utf16.
(component
  (component $C
    (core module $M
      (memory (export "mem") 1)
      (global $next (mut i32) (i32.const 1024))
      (func (export "realloc") (param $old i32) (param $osize i32) (param $align i32) (param $nsize i32) (result i32)
        (local $r i32)
        (if (i32.and (i32.ne (local.get $old) (i32.const 0))
                     (i32.le_u (local.get $nsize) (local.get $osize)))
          (then (return (local.get $old))))
        (global.set $next (i32.and (i32.add (global.get $next) (i32.const 7)) (i32.const -8)))
        (local.set $r (global.get $next))
        (global.set $next (i32.add (global.get $next) (local.get $nsize)))
        (if (i32.ne (local.get $old) (i32.const 0))
          (then (memory.copy (local.get $r) (local.get $old) (local.get $osize))))
        (local.get $r))

      ;; response "øk" latin1 = F8 6B (2 code units, untagged)
      (data (i32.const 64) "\f8\6b")
      ;; response "n☃" utf16 = 006E 2603 (2 code units, tagged)
      (data (i32.const 68) "\6e\00\03\26")

      ;; expect "AB" deflated to latin1 = 41 42 (2 code units, untagged)
      (func (export "deflate") (param $ptr i32) (param $tagged i32) (result i32)
        (if (i32.ne (local.get $tagged) (i32.const 2)) (then unreachable))
        (if (i32.ne (i32.load16_u (local.get $ptr)) (i32.const 0x4241)) (then unreachable))
        (i32.store (i32.const 0) (i32.const 64))
        (i32.store (i32.const 4) (i32.const 2))
        (i32.const 0))

      ;; expect "☃" kept as utf16 = 2603 (1 code unit, tagged)
      (func (export "keep-wide") (param $ptr i32) (param $tagged i32) (result i32)
        (if (i32.ne (local.get $tagged) (i32.const 0x80000001)) (then unreachable))
        (if (i32.ne (i32.load16_u (local.get $ptr)) (i32.const 0x2603)) (then unreachable))
        (i32.store (i32.const 0) (i32.const 68))
        (i32.store (i32.const 4) (i32.const 0x80000002))
        (i32.const 0))
    )
    (core instance $m (instantiate $M))
    (func (export "deflate") (param "s" string) (result string)
      (canon lift (core func $m "deflate") string-encoding=latin1+utf16
        (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
    (func (export "keep-wide") (param "s" string) (result string)
      (canon lift (core func $m "keep-wide") string-encoding=latin1+utf16
        (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  )

  (component $D
    (import "deflate" (func $deflate (param "s" string) (result string)))
    (import "keep-wide" (func $keep-wide (param "s" string) (result string)))
    (core module $Libc
      (memory (export "mem") 1)
      (global $next (mut i32) (i32.const 1024))
      (func (export "realloc") (param $old i32) (param $osize i32) (param $align i32) (param $nsize i32) (result i32)
        (local $r i32)
        (if (i32.and (i32.ne (local.get $old) (i32.const 0))
                     (i32.le_u (local.get $nsize) (local.get $osize)))
          (then (return (local.get $old))))
        (global.set $next (i32.and (i32.add (global.get $next) (i32.const 7)) (i32.const -8)))
        (local.set $r (global.get $next))
        (global.set $next (i32.add (global.get $next) (local.get $nsize)))
        (if (i32.ne (local.get $old) (i32.const 0))
          (then (memory.copy (local.get $r) (local.get $old) (local.get $osize))))
        (local.get $r))
    )
    (core instance $libc (instantiate $Libc))
    (core func $deflate' (canon lower (func $deflate) string-encoding=latin1+utf16
      (memory (core memory $libc "mem")) (realloc (core func $libc "realloc"))))
    (core func $keep-wide' (canon lower (func $keep-wide) string-encoding=latin1+utf16
      (memory (core memory $libc "mem")) (realloc (core func $libc "realloc"))))
    (core module $Main
      (import "" "mem" (memory 1))
      (import "" "deflate" (func $deflate (param i32 i32 i32)))
      (import "" "keep-wide" (func $keep-wide (param i32 i32 i32)))

      ;; argument "AB" over-encoded as utf16 = 0041 0042 (2 code units, tagged)
      (data (i32.const 16) "\41\00\42\00")
      ;; argument "☃" utf16 = 2603 (1 code unit, tagged)
      (data (i32.const 24) "\03\26")

      (func (export "run") (result i32)
        (local $p i32)
        (call $deflate (i32.const 16) (i32.const 0x80000002) (i32.const 8))
        ;; expect "øk" latin1 = F8 6B (2 code units, untagged)
        (local.set $p (i32.load (i32.const 8)))
        (if (i32.ne (i32.load (i32.const 12)) (i32.const 2)) (then unreachable))
        (if (i32.ne (i32.load16_u (local.get $p)) (i32.const 0x6BF8)) (then unreachable))
        (call $keep-wide (i32.const 24) (i32.const 0x80000001) (i32.const 8))
        ;; expect "n☃" utf16 = 006E 2603 (2 code units, tagged)
        (local.set $p (i32.load (i32.const 8)))
        (if (i32.ne (i32.load (i32.const 12)) (i32.const 0x80000002)) (then unreachable))
        (if (i32.ne (i32.load (local.get $p)) (i32.const 0x2603006E)) (then unreachable))
        (i32.const 45))
    )
    (core instance $main (instantiate $Main (with "" (instance
      (export "mem" (memory $libc "mem"))
      (export "deflate" (func $deflate'))
      (export "keep-wide" (func $keep-wide'))
    ))))
    (func (export "run") (result u32) (canon lift (core func $main "run")))
  )

  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "deflate" (func $c "deflate"))
    (with "keep-wide" (func $c "keep-wide"))
  ))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 45))

;; list<string> across a utf16 caller -> utf8 callee boundary: each element is
;; transcoded individually and its (ptr, length) pair rebuilt in the callee's
;; memory.
(component
  (component $C
    (core module $M
      (memory (export "mem") 1)
      (global $next (mut i32) (i32.const 1024))
      (func (export "realloc") (param $old i32) (param $osize i32) (param $align i32) (param $nsize i32) (result i32)
        (local $r i32)
        (if (i32.and (i32.ne (local.get $old) (i32.const 0))
                     (i32.le_u (local.get $nsize) (local.get $osize)))
          (then (return (local.get $old))))
        (global.set $next (i32.and (i32.add (global.get $next) (i32.const 7)) (i32.const -8)))
        (local.set $r (global.get $next))
        (global.set $next (i32.add (global.get $next) (local.get $nsize)))
        (if (i32.ne (local.get $old) (i32.const 0))
          (then (memory.copy (local.get $r) (local.get $old) (local.get $osize))))
        (local.get $r))

      ;; response "ok" utf8 = 6F 6B (2 bytes)
      (data (i32.const 64) "\6f\6b")

      ;; expect ["hi", "", "☃🍰"] as three (ptr, byte-length) pairs of utf8
      (func (export "concat") (param $ptr i32) (param $len i32) (result i32)
        (local $p i32)
        (if (i32.ne (local.get $len) (i32.const 3)) (then unreachable))
        ;; element 0: "hi" utf8 = 68 69 (2 bytes)
        (local.set $p (i32.load (local.get $ptr)))
        (if (i32.ne (i32.load offset=4 (local.get $ptr)) (i32.const 2)) (then unreachable))
        (if (i32.ne (i32.load16_u (local.get $p)) (i32.const 0x6968)) (then unreachable))
        ;; element 1: "" (0 bytes)
        (if (i32.ne (i32.load offset=12 (local.get $ptr)) (i32.const 0)) (then unreachable))
        ;; element 2: "☃🍰" utf8 = E2 98 83 F0 9F 8D B0 (7 bytes)
        (local.set $p (i32.load offset=16 (local.get $ptr)))
        (if (i32.ne (i32.load offset=20 (local.get $ptr)) (i32.const 7)) (then unreachable))
        (if (i32.ne (i32.load (local.get $p)) (i32.const 0xF08398E2)) (then unreachable))
        (if (i32.ne (i32.load16_u offset=4 (local.get $p)) (i32.const 0x8D9F)) (then unreachable))
        (if (i32.ne (i32.load8_u offset=6 (local.get $p)) (i32.const 0xB0)) (then unreachable))
        (i32.store (i32.const 0) (i32.const 64))
        (i32.store (i32.const 4) (i32.const 2))
        (i32.const 0))
    )
    (core instance $m (instantiate $M))
    (func (export "concat") (param "l" (list string)) (result string)
      (canon lift (core func $m "concat") string-encoding=utf8
        (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  )

  (component $D
    (import "concat" (func $concat (param "l" (list string)) (result string)))
    (core module $Libc
      (memory (export "mem") 1)
      (global $next (mut i32) (i32.const 1024))
      (func (export "realloc") (param $old i32) (param $osize i32) (param $align i32) (param $nsize i32) (result i32)
        (local $r i32)
        (if (i32.and (i32.ne (local.get $old) (i32.const 0))
                     (i32.le_u (local.get $nsize) (local.get $osize)))
          (then (return (local.get $old))))
        (global.set $next (i32.and (i32.add (global.get $next) (i32.const 7)) (i32.const -8)))
        (local.set $r (global.get $next))
        (global.set $next (i32.add (global.get $next) (local.get $nsize)))
        (if (i32.ne (local.get $old) (i32.const 0))
          (then (memory.copy (local.get $r) (local.get $old) (local.get $osize))))
        (local.get $r))
    )
    (core instance $libc (instantiate $Libc))
    (core func $concat' (canon lower (func $concat) string-encoding=utf16
      (memory (core memory $libc "mem")) (realloc (core func $libc "realloc"))))
    (core module $Main
      (import "" "mem" (memory 1))
      (import "" "concat" (func $concat (param i32 i32 i32)))

      ;; element 0: "hi" utf16 = 0068 0069 (2 code units)
      (data (i32.const 32) "\68\00\69\00")
      ;; element 2: "☃🍰" utf16 = 2603 D83C DF70 (3 code units)
      (data (i32.const 40) "\03\26\3c\d8\70\df")
      ;; argument ["hi", "", "☃🍰"] as (ptr, code-units) pairs: (32, 2) (0, 0) (40, 3)
      (data (i32.const 64) "\20\00\00\00\02\00\00\00\00\00\00\00\00\00\00\00\28\00\00\00\03\00\00\00")

      (func (export "run") (result i32)
        (local $p i32)
        (call $concat (i32.const 64) (i32.const 3) (i32.const 8))
        ;; expect "ok" utf16 = 006F 006B (2 code units)
        (local.set $p (i32.load (i32.const 8)))
        (if (i32.ne (i32.load (i32.const 12)) (i32.const 2)) (then unreachable))
        (if (i32.ne (i32.load (local.get $p)) (i32.const 0x006B006F)) (then unreachable))
        (i32.const 46))
    )
    (core instance $main (instantiate $Main (with "" (instance
      (export "mem" (memory $libc "mem"))
      (export "concat" (func $concat'))
    ))))
    (func (export "run") (result u32) (canon lift (core func $main "run")))
  )

  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "concat" (func $c "concat"))))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 46))
