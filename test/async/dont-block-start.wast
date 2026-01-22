;; test a few cases where components trap during core module instantiation
;; due to blocking during the (implicitly sync) start function
(assert_trap
  (component
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $M
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (func $start
        (drop (call $waitable-set.wait (call $waitable-set.new) (i32.const 0)))
      )
      (start $start)
    )
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory $memory "mem") (core func $waitable-set.wait))
    (core instance $m (instantiate $M (with "" (instance
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
    ))))
  )
  "cannot block a synchronous task before returning"
)
(assert_trap
  (component
    (component $C
      (core module $M
        (func (export "f") (result i32) unreachable)
        (func (export "f_cb") (param i32 i32 i32) (result i32) unreachable)
      )
      (core instance $i (instantiate $M))
      (func (export "f") async (canon lift (core func $i "f") async (callback (func $i "f_cb"))))
    )
    (component $D
      (import "f" (func $f async))
      (core module $M
        (import "" "f" (func $f))
        (func $start (call $f))
        (start $start)
      )
      (canon lower (func $f) (core func $f'))
      (core instance $m (instantiate $M (with "" (instance
        (export "f" (func $f'))
      ))))
    )
    (instance $c (instantiate $C))
    (instance $d (instantiate $D (with "f" (func $c "f"))))
  )
  "cannot block a synchronous task before returning"
)
