;; RUN: wast --assert default --snapshot tests/snapshots %

(component definition
  (func (import "a"))
  (component)
  (instance (instantiate 0 (with "NotKebab-Case" (func 0))))
)

(assert_invalid
  (component
    (import "f" (func))
    (instance (export "1" (func 0)))
  )
  "`1` is not in kebab case"
)

(assert_invalid
  (component
    (instance)
    (alias export 0 "Xml" (func))
  )
  "instance 0 has no export named `Xml`"
)

(component definition
  (type (flags "a-1-c"))
)

(assert_invalid
  (component
    (type (enum "NevEr"))
  )
  "enum tag name `NevEr` is not in kebab case"
)

(assert_invalid
  (component
    (type (record (field "GoNnA" string)))
  )
  "record field name `GoNnA` is not in kebab case"
)

(assert_invalid
  (component
    (type (variant (case "GIVe" string)))
  )
  "variant case name `GIVe` is not in kebab case"
)


(assert_invalid
  (component
    (type (func (param "yOu" string)))
  )
  "function parameter name `yOu` is not in kebab case"
)

(assert_invalid
  (component
    (type (component (export "NevEr" (func))))
  )
  "`NevEr` is not in kebab case"
)

(assert_invalid
  (component
    (type (component (import "GonnA" (func))))
  )
  "`GonnA` is not in kebab case"
)

(assert_invalid
  (component
    (type (instance (export "lET" (func))))
  )
  "`lET` is not in kebab case"
)

(assert_invalid
  (component
    (instance (export "YoU"))
  )
  "`YoU` is not in kebab case"
)

(assert_invalid
  (component
    (instance (import "DOWn"))
  )
  "`DOWn` is not in kebab case"
)

(assert_invalid
  (component
    (instance (import "A:b/c"))
  )
  "character `A` is not lowercase in package name/namespace"
)
(assert_invalid
  (component
    (instance (import "a:B/c"))
  )
  "character `B` is not lowercase in package name/namespace"
)
(component
  (instance (import "a:b/c"))
  (instance (import "a1:b1/c"))
)

(component definition
  (import "a" (type $a (sub resource)))
  (import "[constructor]a" (func (result (own $a))))
)

(assert_invalid
  (component
    (import "a" (type $a (sub resource)))
    (import "[method]a.a" (func (param "self" (borrow $a))))
  )
  "import name `[method]a.a` conflicts with previous name `a`")

(assert_invalid
  (component
    (import "a" (type $a (sub resource)))
    (import "[static]a.a" (func))
  )
  "import name `[static]a.a` conflicts with previous name `a`")

;; [implements=<...>] strong-uniqueness tests

;; Valid: two [implements=<...>] with different labels are strongly-unique
(component definition
  (import "[implements=<a:b/c>]one" (instance))
  (import "[implements=<a:b/c>]two" (instance))
)

;; Valid: [implements=<...>] and a bare interface name are strongly-unique
;; (different name kinds: plainname vs interfacename)
(component definition
  (import "a:b/c" (instance))
  (import "[implements=<a:b/c>]alt" (instance))
)

;; Invalid: two [implements=<...>] with the same label conflict
(assert_invalid
  (component
    (import "[implements=<a:b/c>]name" (instance))
    (import "[implements=<x:y/z>]name" (instance))
  )
  "conflicts with previous name")

;; Invalid: [implements=<...>] label conflicts with a bare plain name
(assert_invalid
  (component
    (import "name" (func))
    (import "[implements=<a:b/c>]name" (instance))
  )
  "conflicts with previous name")
