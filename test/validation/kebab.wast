;; Validation of kebab-case plain names and `ns:pkg/iface` extern names, and
;; case-insensitive uniqueness of import/export names.

(component (component
  (import "a" (func))
  (import "a1" (func))
  (import "a-1" (func))
  (import "a-1-b-2-c-3" (func))
  (import "B" (func))
  (import "B1" (func))
  (import "B-1" (func))
  (import "B-1-C-2-D-3" (func))
  (import "a11-B11-123-ABC-abc" (func))
  (import "ns-1-a:b-1-c/D-2" (func))
))
(assert_invalid
  (component
    (import "1" (func)))
  "is not in kebab case")
(assert_invalid
  (component
    (import "1-a" (func)))
  "is not in kebab case")
(assert_invalid
  (component
    (import "" (func)))
  "is not in kebab case")
(assert_invalid
  (component
    (import "a-" (func)))
  "is not in kebab case")
(assert_invalid
  (component
    (import "a--" (func)))
  "is not in kebab case")
(assert_invalid
  (component
    (import "aBc" (func)))
  "`aBc` is not in kebab case")
(assert_invalid
  (component
    (import "1:a/b" (func)))
  "is not in kebab case")
(assert_invalid
  (component
    (import "wasi:http/TyPeS" (func)))
  "`TyPeS` is not in kebab case")
(assert_invalid
  (component
    (import "WaSi:http/types" (func)))
  "`WaSi` is not in kebab case")
(assert_invalid
  (component
    (import "wasi:HtTp/types" (func)))
  "`HtTp` is not in kebab case")
(assert_invalid
  (component
    (import "wasi/http" (func)))
  "`wasi/http` is not in kebab case")
(assert_invalid
  (component
    (import "wasi:" (func)))
  "`` is not in kebab case")
(assert_invalid
  (component
    (import "wasi:/" (func)))
  "`` is not in kebab case")
(assert_invalid
  (component
    (import ":/" (func)))
  "`` is not in kebab case")
(assert_invalid
  (component
    (import "A:b/c" (func)))
  "is not a valid extern name")
(assert_invalid
  (component
    (import "1:b/c" (func)))
  "is not a valid extern name")
(assert_invalid
  (component
    (import "ns-A:b/c" (func)))
  "is not a valid extern name")
(assert_invalid
  (component
    (import "ns:A/b" (func)))
  "is not a valid extern name")
(assert_invalid
  (component
    (import "ns:1/a" (func)))
  "is not a valid extern name")
(assert_invalid
  (component
    (import "ns:pkg-A/b" (func)))
  "is not a valid extern name")

;; names are validated in non-import positions too
(assert_invalid
  (component
    (import "f" (func $f))
    (instance (export "1" (func $f))))
  "`1` is not in kebab case")
(assert_invalid
  (component
    (type (component (import "GonnA" (func)))))
  "`GonnA` is not in kebab case")
(assert_invalid
  (component
    (type (component (export "NevEr" (func)))))
  "`NevEr` is not in kebab case")
(assert_invalid
  (component
    (type (instance (export "lET" (func)))))
  "`lET` is not in kebab case")
(assert_invalid
  (component
    (import "DOWn" (instance)))
  "`DOWn` is not in kebab case")

;; import/export names must be unique, compared case-insensitively
(assert_invalid
  (component
    (import "f" (func $f))
    (export "a" (func $f))
    (export "a" (func $f)))
  "export name `a` conflicts with previous name `a`")
(assert_invalid
  (component
    (import "f" (func $f))
    (export "a" (func $f))
    (export "A" (func $f)))
  "export name `A` conflicts with previous name `a`")
(assert_invalid
  (component
    (type (component
      (import "A" (func))
      (import "a" (func)))))
  "import name `a` conflicts with previous name `A`")
(assert_invalid
  (component
    (type (component
      (export "a" (func))
      (export "A" (func)))))
  "export name `A` conflicts with previous name `a`")
(assert_invalid
  (component
    (type (instance
      (export "foo-BAR-baz" (func))
      (export "FOO-bar-BAZ" (func)))))
  "export name `FOO-bar-BAZ` conflicts with previous name `foo-BAR-baz`")
