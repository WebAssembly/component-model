(assert_invalid
  (component
    (import "foo" (func $foo (result (tuple u64 u64 u64 u64 u64 u64 u64 u64))))
    (canon lower (func $foo) (core func $foo'))
  )
  "canonical option `memory` is required"
)
(assert_invalid
  (component
    (import "foo" (func $foo (result (tuple u64 u64 u64 u64 u64 u64 u64 u64))))
    (core module $M
      (func (export "realloc") (param i32 i32 i32 i32) (result i32) unreachable)
    )
    (core instance $i (instantiate $M))
    (canon lower (func $foo) (realloc (core func $i "realloc")) (core func $foo'))
  )
  "canonical option `realloc` requires `memory` to also be specified"
)
(component
  (component
    (import "foo" (func $foo (result (tuple u64 u64 u64 u64 u64 u64 u64 u64))))
    (core module $M
      (memory (export "mem") 1)
      (func (export "realloc") (param i32 i32 i32 i32) (result i32) unreachable)
    )
    (core instance $i (instantiate $M))
    (canon lower (func $foo) (memory (core memory $i "mem")) (core func $foo1))
    ;; realloc superfluous but allowed:
    (canon lower (func $foo) (memory (core memory $i "mem")) (realloc (core func $i "realloc")) (core func $foo2))
  )
)
