;; Validation of `outer` aliases: the allowed sorts, the cross-`component`
;; no-resource-types rule, de Bruijn counting, and `alias` declarator restrictions.

;; aliasing from the current component (ct=0):

(component definition $C
  (core module $M (func (export "f")))
  (core type $CT (module))
  (component $D)
  (type $T (record (field "x" u32)))
  (alias outer 0 0 (core module $cm))
  (alias outer 0 0 (core type $ct))
  (alias outer 0 0 (component $comp))
  (alias outer 0 0 (type $ty))
  (alias outer $C $M (core module $cm2))
  (alias outer $C $CT (core type $ct2))
  (alias outer $C $D (component $comp2))
  (alias outer $C $T (type $ty2))
)

;; across a `component` boundary only substitutable definitions may be aliased
;; (core modules, core types, components, and resource-free types); generative
;; `resource`s may not.

(component definition $C
  (core module $M (func (export "f")))
  (core type $CT (module))
  (component $D (import "r" (type (sub resource))))
  (type $Pure (record (field "x" u32)))
  (component
    (alias outer $C $M (core module $cm))
    (alias outer $C $CT (core type $ct))
    (alias outer $C $D (component $comp))
    (alias outer $C $Pure (type $pure))
  )
)

(assert_invalid
  (component $C
    (type $R (resource (rep i32)))
    (component (alias outer $C $R (type $a)))
  )
  "transitively refers to resources")

(assert_invalid
  (component $C
    (type $R (resource (rep i32)))
    (type $B (borrow $R))
    (component (alias outer $C $B (type $a)))
  )
  "transitively refers to resources")

(assert_invalid
  (component $C
    (type $R (resource (rep i32)))
    (type $Rec (record (field "h" (own $R))))
    (component (alias outer $C $Rec (type $a)))
  )
  "transitively refers to resources")

(assert_invalid
  (component $C
    (type $R (resource (rep i32)))
    (component (component (alias outer 2 0 (type $a))))
  )
  "transitively refers to resources")

(assert_invalid
  (component $C
    (type $R (resource (rep i32)))
    (component (type (component
      (alias outer 2 0 (type $a))
    )))
  )
  "transitively refers to resources")

;; ct=0 (no boundary)
(component definition $C
  (type $R (resource (rep i32)))
  (type $B (borrow $R))
  (alias outer 0 0 (type $r))
  (alias outer 0 1 (type $b))
)

;; only a `type` boundary (component-type declarator)
(component definition $C
  (type $R (resource (rep i32)))
  (type $B (borrow $R))
  (type $L (list (own $R)))
  (type (component
    (alias outer $C $R (type $r))
    (alias outer $C $B (type $b))
    (alias outer $C $L (type $l))
  ))
  (type (instance
    (alias outer $C $R (type $r))
  ))
)

;; mix of valid
(component definition $C
  (type $Pure (record (field "x" u32)))
  (component
    (alias outer $C $Pure (type $pure))
    (type $R (resource (rep i32)))
    (alias outer 0 1 (type $localR))
  )
)

;; de Bruijn counting: both a real `component` and a `(type (component ...))`
;; declarator count as one enclosing scope.
(component definition $C
  (type $T (record (field "x" u32)))
  (type (component
    (alias outer 1 0 (type $parent))
    (type (component
      (alias outer 2 0 (type $grandparent))
    ))
  ))
  (component
    (alias outer 1 0 (type $parent))
  )
  (component $D
    (alias outer $C $T (type $aD))
    (component
      (alias outer $D $aD (type $aE))
      (type $use (tuple $aE $aE))
    )
  )
)

;; inside a `component`/`instance` type, `alias export` may only target
;; `instance`/`type` and `alias outer` may only target `core type`/`type` (a
;; subset of the sorts allowed for `alias` definitions).

(component definition $C
  (type (component
    (import "i" (instance $i
      (export "t" (type (sub resource)))
      (export "j" (instance))
    ))
    (alias export $i "t" (type $t))
    (alias export $i "j" (instance $j))
  ))
  (core type $FT (func (param i32) (result i32)))
  (type $T (record (field "x" u32)))
  (type (component
    (alias outer $C $FT (core type $ct))
    (alias outer $C $T (type $t))
  ))
)

(assert_invalid
  (component
    (type (component
      (import "i" (instance $i (export "f" (func))))
      (alias export $i "f" (func $a))
    ))
  )
  "may only refer to types or instances")

(assert_invalid
  (component $C
    (component $D)
    (type (component (alias outer $C $D (component $a))))
  )
  "may only refer to types or instances")

(assert_invalid
  (component $C
    (core module $M)
    (type (component (alias outer $C $M (core module $a))))
  )
  "may only refer to types or instances")

(assert_invalid
  (component $C
    (component $D)
    (type (instance (alias outer $C $D (component $a))))
  )
  "may only refer to types or instances")

;; acyclicity and index bounds

(assert_invalid
  (component $C
    (alias outer 0 0 (type $a))
    (type $T (record (field "x" u32)))
  )
  "index out of bounds")

(assert_invalid
  (component $C
    (component (alias outer 1 0 (type $a)))
    (type $T (record (field "x" u32)))
  )
  "index out of bounds")

(assert_invalid
  (component $C
    (type $T (record (field "x" u32)))
    (component (alias outer 5 0 (type $a)))
  )
  "invalid outer alias count")

(assert_invalid
  (component (alias outer 1 0 (type $a)))
  "invalid outer alias count")

(assert_invalid
  (component $C
    (type $T (record (field "x" u32)))
    (component (alias outer 1 9 (type $a)))
  )
  "index out of bounds")

;; core:alias

(component definition $C
  (core type $FT (func (param i32) (result i32)))
  (core type $MT (module
    (alias outer $C $FT (type $a))
    (export "f" (func (type $a)))
  ))
  (core type $MT2 (module
    (alias outer $C $FT (type))
    (import "a" "b" (func (type 0)))
    (export "c" (func (type 0)))
  ))
)
