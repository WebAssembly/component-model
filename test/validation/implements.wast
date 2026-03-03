;; Valid: basic [implements=<...>] on instance import
(component
  (import "[implements=<a:b/c>]name" (instance))
)

;; Valid: [implements=<...>] on instance export
(component
  (instance $i)
  (export "[implements=<a:b/c>]name" (instance $i))
)

;; Valid: two imports with the same interface, different labels
(component
  (import "[implements=<a:b/c>]one" (instance))
  (import "[implements=<a:b/c>]two" (instance))
)

;; Valid: [implements=<...>] with version in interface name
(component
  (import "[implements=<a:b/c@1.2.3>]name" (instance))
)

;; Valid: [implements=<...>] alongside a bare interface import of the same interface
(component
  (import "a:b/c" (instance))
  (import "[implements=<a:b/c>]alt" (instance))
)

;; Valid: in a component type
(component
  (type (component
    (import "[implements=<a:b/c>]one" (instance
      (export "get" (func (param "key" string) (result (option string))))
    ))
    (import "[implements=<a:b/c>]two" (instance
      (export "get" (func (param "key" string) (result (option string))))
    ))
  ))
)

;; Invalid: [implements=<...>] on func (must be instance)
(assert_invalid
  (component
    (import "[implements=<a:b/c>]name" (func))
  )
  "`[implements=<a:b/c>]` must be on an instance import or export")

;; Invalid: [implements=<...>] on component (must be instance)
(assert_invalid
  (component
    (import "[implements=<a:b/c>]name" (component))
  )
  "`[implements=<a:b/c>]` must be on an instance import or export")

;; Invalid: [implements=<...>] on value type import
(assert_invalid
  (component
    (import "[implements=<a:b/c>]name" (value string))
  )
  "`[implements=<a:b/c>]` must be on an instance import or export")

;; Invalid: [implements=<...>] on type (resource) import
(assert_invalid
  (component
    (import "[implements=<a:b/c>]name" (type (sub resource)))
  )
  "`[implements=<a:b/c>]` must be on an instance import or export")

;; Invalid: [implements=<...>] on func export
(assert_invalid
  (component
    (core module $m (func (export "")))
    (core instance $i (instantiate $m))
    (func $f (canon lift (core func $i "")))
    (export "[implements=<a:b/c>]name" (func $f))
  )
  "`[implements=<a:b/c>]` must be on an instance import or export")

;; Invalid: [implements=<...>] on value type export
(assert_invalid
  (component
    (import "v" (value $v string))
    (export "[implements=<a:b/c>]name" (value $v))
  )
  "`[implements=<a:b/c>]` must be on an instance import or export")

;; Invalid: [implements=<...>] on type (resource) export
(assert_invalid
  (component
    (type $r (resource (rep i32)))
    (export "[implements=<a:b/c>]name" (type $r))
  )
  "`[implements=<a:b/c>]` must be on an instance import or export")

;; Invalid: duplicate labels after stripping annotation
(assert_invalid
  (component
    (import "[implements=<a:b/c>]name" (instance))
    (import "[implements=<x:y/z>]name" (instance))
  )
  "conflicts with previous name")

;; Invalid: duplicate label between annotated and bare plain name
(assert_invalid
  (component
    (import "name" (func))
    (import "[implements=<a:b/c>]name" (instance))
  )
  "conflicts with previous name")

;; Invalid: malformed interface name inside annotation
(assert_invalid
  (component
    (import "[implements=<NotValid>]name" (instance))
  )
  "not a valid extern name")

;; Invalid: empty label
(assert_invalid
  (component
    (import "[implements=<a:b/c>]" (instance))
  )
  "not a valid extern name")

;; Invalid: empty interface name
(assert_invalid
  (component
    (import "[implements=<>]name" (instance))
  )
  "not a valid extern name")

;; ---- interfacename validation (must be instance-typed) ----

;; Valid: interfacename on instance import
(component
  (import "a:b/c" (instance))
)

;; Valid: interfacename on instance export
(component
  (instance $i)
  (export "a:b/c" (instance $i))
)

;; Invalid: interfacename on func import (must be instance)
(assert_invalid
  (component
    (import "a:b/c" (func))
  )
  "interfacename must be on an instance import or export")

;; Invalid: interfacename on component import (must be instance)
(assert_invalid
  (component
    (import "a:b/c" (component))
  )
  "interfacename must be on an instance import or export")

;; Invalid: interfacename on value type import (must be instance)
(assert_invalid
  (component
    (import "a:b/c" (value string))
  )
  "interfacename must be on an instance import or export")

;; Invalid: interfacename on type (resource) import (must be instance)
(assert_invalid
  (component
    (import "a:b/c" (type (sub resource)))
  )
  "interfacename must be on an instance import or export")

;; Invalid: interfacename on func export (must be instance)
(assert_invalid
  (component
    (core module $m (func (export "")))
    (core instance $i (instantiate $m))
    (func $f (canon lift (core func $i "")))
    (export "a:b/c" (func $f))
  )
  "interfacename must be on an instance import or export")

;; Invalid: interfacename on value type export (must be instance)
(assert_invalid
  (component
    (import "v" (value $v string))
    (export "a:b/c" (value $v))
  )
  "interfacename must be on an instance import or export")

;; Invalid: interfacename on type (resource) export (must be instance)
(assert_invalid
  (component
    (type $r (resource (rep i32)))
    (export "a:b/c" (type $r))
  )
  "interfacename must be on an instance import or export")
