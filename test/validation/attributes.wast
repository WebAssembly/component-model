;; valid uses of `implements`:
(component definition
  ;; can only be attached to instances with plain names:
  (import "a" (implements "a:b/c") (instance))
  (import "b" (implements "a:b/c") (instance))
  (import "c" (implements "a:b/c@1.0.0") (instance))
  (import "my-label" (implements "ns:pkg/iface") (instance))

  (instance $a)

  (export "a" (implements "a:b/c") (instance $a))
  (export "b" (implements "a:b/c") (instance $a))
  (export "c" (implements "a:b/c@1.0.0") (instance $a))
  (export "my-label" (implements "ns:pkg/iface") (instance $a))

  (type (instance
    (export "a" (implements "a:b/c") (instance))
  ))
  (type (component
    (import "a" (implements "a:b/c") (instance))
    (export "a" (implements "a:b/c") (instance))
  ))

  (instance
    (export "a" (implements "a:b/c") (instance $a))
  )
)

;; valid uses of `external-id`:
(component definition
  ;; can be attached to imports of any type:
  (import "a" (external-id "id") (func))
  (import "b" (external-id "id") (func (param "text" string) (result string)))
  (import "c" (external-id "id") (type (sub resource)))
  (import "d" (external-id "id") (instance))
  (component
    (import "e" (external-id "id") (component))
  )

  ;; can be attached to a plain name or an interface name (unlike `implements`):
  (import "a:b/c" (external-id "id") (instance))

  ;; the external-id may be any Unicode string using Core WebAssembly string literal:
  (import "uni" (external-id "☃︎") (func))
  (import "esc" (external-id "\u{7fff}") (func))
  (import "empty" (external-id "") (func))

  ;; `implements` and `external-id` compose on instances:
  (import "store1" (implements "w:kv/s") (external-id "!@#") (instance))
  (import "store2" (implements "w:kv/s") (external-id ")*&") (instance))

  ;; the same external-id value may be reused:
  (import "dup1" (external-id "same") (func))
  (import "dup2" (external-id "same") (func))

  (instance $a)

  (export "a" (external-id "id") (instance $a))
  (export "a:b/c" (external-id "☃︎") (instance $a))
  (export "c" (implements "w:kv/s") (external-id "\u{7fff}") (instance $a))

  (type (instance
    (export "a" (external-id "x") (func))
    (export "b" (external-id "y") (instance))
  ))
  (type (component
    (import "a" (external-id "x") (instance))
    (export "b" (implements "a:b/c") (external-id "y") (instance))
  ))

  (instance
    (export "a" (external-id "bag-id") (instance $a))
  )
)

;; both attribute values must be well-formed WebAssembly string literals:
(assert_malformed
  (component quote
    "(import \"a\" (implements \"\\zz\") (instance))")
  "invalid string escape")
(assert_malformed
  (component quote
    "(import \"a\" (external-id \"\\zz\") (func))")
  "invalid string escape")

;; at most one of each attribute:
(assert_malformed
  (component quote
    "(import \"a\" (implements \"a:b/c\") (implements \"a:b/c\") (instance))")
  "unexpected token")
(assert_malformed
  (component quote
    "(import \"a\" (external-id \"x\") (external-id \"y\") (func))")
  "unexpected token")

;; an `implements` value must be an interface name (`external-id` has no such
;; restriction):
(assert_invalid
  (component (import "a" (implements "not-valid") (instance)))
  "must be an interface")
(assert_invalid
  (component (import "a" (implements "") (instance)))
  "not a valid name")

;; neither attribute relaxes name uniqueness:
(assert_invalid
  (component
    (import "a" (implements "a:b/c") (instance))
    (import "a" (implements "a:b/c") (instance))
  )
  "conflicts with previous name")
(assert_invalid
  (component
    (import "a" (implements "a1:b/c") (instance))
    (import "a" (implements "a2:b/c") (instance))
  )
  "conflicts with previous name")
(assert_invalid
  (component
    (import "a" (instance))
    (import "a" (implements "a:b/c") (instance))
  )
  "conflicts with previous name")
(assert_invalid
  (component
    (import "a" (external-id "same") (func))
    (import "a" (external-id "same") (func))
  )
  "conflicts with previous name")
(assert_invalid
  (component
    (import "a" (external-id "x") (func))
    (import "a" (external-id "y") (func))
  )
  "conflicts with previous name")
(assert_invalid
  (component
    (import "a" (func))
    (import "a" (external-id "id") (func))
  )
  "conflicts with previous name")

;; `implements` can only be attached to instances with plain names:
(assert_invalid
  (component
    (import "a" (implements "a:b/c") (func))
  )
  "only instances can have an `implements`")
(assert_invalid
  (component
    (import "a1:b/c" (implements "a2:b/c") (instance))
  )
  "name `a1:b/c` is not valid with `implements`")

;; the same rules apply to `implements` in other locations, such as
;; component/instance types and bag-of-exports:
(assert_invalid
  (component (type (component (import "a" (implements "not-valid") (instance)))))
  "must be an interface")
(assert_invalid
  (component (type (component (export "a" (implements "") (instance)))))
  "not a valid name")
(assert_invalid
  (component (type (instance (export "a" (implements "a:b/c") (func)))))
  "only instances")
(assert_invalid
  (component
    (instance)
    (instance (export "x" (implements "a") (instance 0)))
  )
  "must be an interface")

;; an accompanying `external-id` doesn't relax any of the `implements` rules:
(assert_invalid
  (component
    (import "a" (implements "a:b/c") (external-id "id") (func))
  )
  "only instances can have an `implements`")
(assert_invalid
  (component
    (import "a1:b/c" (implements "a2:b/c") (external-id "id") (instance))
  )
  "name `a1:b/c` is not valid with `implements`")
(assert_invalid
  (component (type (component
    (import "a" (implements "a:b/c") (external-id "id") (func)))))
  "only instances can have an `implements`")
(assert_invalid
  (component (type (instance
    (export "a" (implements "a:b/c") (external-id "id") (func)))))
  "only instances can have an `implements`")
(assert_invalid
  (component
    (instance)
    (instance (export "x" (implements "a") (external-id "id") (instance 0)))
  )
  "must be an interface")

;; neither attribute participates in type checking: when instantiating a child
;; component, attributes on both the child's imports and the supplied instance
;; (including nested) are ignored by subtyping.
(component definition
  (import "s" (instance $s
    (export "e" (implements "a:b/c") (instance))
  ))
  (component $c
    (import "i" (implements "x:y/z") (instance
      (export "e" (implements "p:q/r") (instance))
    ))
  )
  (instance (instantiate $c (with "i" (instance $s))))
)
(component definition
  (import "s" (instance $s
    (export "e" (external-id "supplied-id") (instance))
  ))
  (component $c
    (import "i" (external-id "child-id") (instance
      (export "e" (external-id "inner-id") (instance))
    ))
  )
  (instance (instantiate $c (with "i" (instance $s))))
)

;; a `with` argument names an import's externname, not its attribute value:
(assert_invalid
  (component
    (import "s" (instance $s))
    (component $c
      (import "primary" (implements "w:kv/s") (instance))
    )
    (instance (instantiate $c (with "w:kv/s" (instance $s))))
  )
  "missing import named `primary`")
(assert_invalid
  (component
    (import "s" (instance $s))
    (component $c
      (import "primary" (external-id "the-id") (instance))
    )
    (instance (instantiate $c (with "the-id" (instance $s))))
  )
  "missing import named `primary`")
