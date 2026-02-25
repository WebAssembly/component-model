;; RUN: wast --assert default --snapshot tests/snapshots %

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
