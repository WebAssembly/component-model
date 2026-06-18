(assert_invalid
  (component
    (core module $M
      (func (export "f"))
    )
    (core instance $i (instantiate $M))
    (func (export "f") (canon lift (core func $i "f") async))
  )
  "the `async` canonical option requires an async function type")

(assert_invalid
  (component
    (core module $M
      (func (export "f") (param i32) (result i32) unreachable)
      (func (export "f_cb") (param i32 i32 i32) (result i32) unreachable)
    )
    (core instance $i (instantiate $M))
    (func (export "f") (canon lift (core func $i "f") async (callback (func $i "f_cb"))))
  )
  "the `async` canonical option requires an async function type")

(assert_invalid
  (component
    (import "f" (func $f))
    (core func $f' (canon lower (func $f) async))
  )
  "the `async` canonical option requires an async function type")
