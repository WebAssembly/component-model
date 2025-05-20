;; This test creates an asynchronous recursive call stack:
;;  $Parent --> $Child --> $Parent
;; That should trap when $Child tries to call $Parent.
(component $Parent
  (core module $CoreInner
    (memory (export "mem") 1)
    (func (export "a") (result i32)
      unreachable
    )
    (func (export "a-cb") (param i32 i32 i32) (result i32)
      unreachable
    )
  )
  (core instance $core_inner (instantiate $CoreInner))
  (func $a (canon lift
    (core func $core_inner "a")
    async (callback (func $core_inner "a-cb"))
  ))

  (component $Child
    (import "a" (func $a))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))

    (core module $CoreChild
      (import "" "a" (func $a (result i32)))
      (func (export "b") (result i32)
        (i32.const 1 (; YIELD ;))
      )
      (func (export "b-cb") (param i32 i32 i32) (result i32)
        (call $a)
        unreachable
      )
    )
    (canon lower (func $a) async (memory $memory "mem") (core func $a'))
    (core instance $core_child (instantiate $CoreChild (with "" (instance
      (export "a" (func $a'))
    ))))
    (func (export "b") (canon lift
      (core func $core_child "b")
      async (callback (func $core_child "b-cb"))
    ))
  )
  (instance $child (instantiate $Child (with "a" (func $a))))

  (core module $CoreOuter
    (import "" "b" (func $b (result i32)))
    (func $c (export "c") (result i32)
      (i32.const 1 (; YIELD ;))
    )
    (func $c-cb (export "c-cb") (param i32 i32 i32) (result i32)
      (call $b)
    )
  )
  (canon lower (func $child "b") async (memory $core_inner "mem") (core func $b))
  (core instance $core_outer (instantiate $CoreOuter (with "" (instance
    (export "b" (func $b))
  ))))
  (func $c (export "c") (canon lift
    (core func $core_outer "c")
    async (callback (func $core_outer "c-cb"))
  ))
)
(assert_trap (invoke "c") "wasm trap: cannot enter component instance")
