(component
  (core module $M
    (memory (export "mem") 1)
    (func (export "f1") (result i32)
      (i32.store (i32.const 0) (i32.const 8))
      (i32.store (i32.const 4) (i32.const 1))
      (i32.store8 (i32.const 8) (i32.const 97))
      (i32.const 0)
    )
    (func (export "f2") (result i32)
      (i32.store (i32.const 0) (i32.const 8))
      (i32.store (i32.const 4) (i32.const 14))
      (i64.store (i32.const 8) (i64.const 0xb8_ef_ba_98_e2_83_98_e2))
      (i32.store (i32.const 16) (i32.const 0xe3_b6_c3_8f))
      (i32.store16 (i32.const 20) (i32.const 0x84_83))
      (i32.const 0)
    )
    ;; TODO: so many cases left to test, everyone feel free to fill in...
  )
  (core instance $m (instantiate $M))
  (func (export "f1") (result string) (canon lift (core func $m "f1") (memory $m "mem")))
  (func (export "f2") (result string) (canon lift (core func $m "f2") (memory $m "mem")))
)
(assert_return (invoke "f1") (str.const "a"))
(assert_return (invoke "f2") (str.const "☃☺️öツ"))

;; empty string with ptr=0, len=0
(component
  (core module $M
    (memory (export "mem") 1)
    (func (export "f") (result i32)
      (i32.store (i32.const 0) (i32.const 0))
      (i32.store (i32.const 4) (i32.const 0))
      (i32.const 0)
    )
  )
  (core instance $m (instantiate $M))
  (func (export "f") (result string) (canon lift (core func $m "f") (memory $m "mem")))
)
(assert_return (invoke "f") (str.const ""))

;; empty string with non-zero in-bounds ptr, len=0
(component
  (core module $M
    (memory (export "mem") 1)
    (func (export "f") (result i32)
      (i32.store (i32.const 0) (i32.const 100))
      (i32.store (i32.const 4) (i32.const 0))
      (i32.const 0)
    )
  )
  (core instance $m (instantiate $M))
  (func (export "f") (result string) (canon lift (core func $m "f") (memory $m "mem")))
)
(assert_return (invoke "f") (str.const ""))

;; out-of-bounds pointer traps even with len=0
(component
  (core module $M
    (memory (export "mem") 1)
    (func (export "f") (result i32)
      (i32.store (i32.const 0) (i32.const 0xdeadbeef))
      (i32.store (i32.const 4) (i32.const 0))
      (i32.const 0)
    )
  )
  (core instance $m (instantiate $M))
  (func (export "f") (result string) (canon lift (core func $m "f") (memory $m "mem")))
)
(assert_trap (invoke "f") "string pointer/length out of bounds of memory")

;; invalid UTF-8: 0xFF is never valid
(component
  (core module $M
    (memory (export "mem") 1)
    (func (export "f") (result i32)
      (i32.store (i32.const 0) (i32.const 8))
      (i32.store (i32.const 4) (i32.const 1))
      (i32.store8 (i32.const 8) (i32.const 0xff))
      (i32.const 0)
    )
  )
  (core instance $m (instantiate $M))
  (func (export "f") (result string) (canon lift (core func $m "f") (memory $m "mem")))
)
(assert_trap (invoke "f") "invalid utf-8")

;; truncated multibyte UTF-8: leading byte 0xC3 expects a continuation byte
(component
  (core module $M
    (memory (export "mem") 1)
    (func (export "f") (result i32)
      (i32.store (i32.const 0) (i32.const 8))
      (i32.store (i32.const 4) (i32.const 1))
      (i32.store8 (i32.const 8) (i32.const 0xc3))
      (i32.const 0)
    )
  )
  (core instance $m (instantiate $M))
  (func (export "f") (result string) (canon lift (core func $m "f") (memory $m "mem")))
)
(assert_trap (invoke "f") "incomplete utf-8 byte sequence")

;; string at end of memory page boundary
(component
  (core module $M
    (memory (export "mem") 1)
    (func (export "f") (result i32)
      ;; place "ok" at the very end of the first page (65536 - 2 = 65534)
      (i32.store (i32.const 0) (i32.const 65534))
      (i32.store (i32.const 4) (i32.const 2))
      (i32.store8 (i32.const 65534) (i32.const 111)) ;; 'o'
      (i32.store8 (i32.const 65535) (i32.const 107)) ;; 'k'
      (i32.const 0)
    )
  )
  (core instance $m (instantiate $M))
  (func (export "f") (result string) (canon lift (core func $m "f") (memory $m "mem")))
)
(assert_return (invoke "f") (str.const "ok"))

;; string one byte past end of memory traps
(component
  (core module $M
    (memory (export "mem") 1)
    (func (export "f") (result i32)
      (i32.store (i32.const 0) (i32.const 65535))
      (i32.store (i32.const 4) (i32.const 2))
      (i32.store8 (i32.const 65535) (i32.const 111))
      (i32.const 0)
    )
  )
  (core instance $m (instantiate $M))
  (func (export "f") (result string) (canon lift (core func $m "f") (memory $m "mem")))
)
(assert_trap (invoke "f") "string pointer/length out of bounds of memory")
