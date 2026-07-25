;; Tests for `[constructor]`/`[method]`/`[static]` annotated plainnames
;; (Explainer.md#import-and-export-definitions and the import/export
;; validation rules of Binary.md).

;; `[constructor]a` requires a single `(own $a)` or `(result (own $a) (error E)?)`
;; result of the resource imported/exported as "a"

(component definition
  (import "a" (type $a (sub resource)))
  (import "[constructor]a" (func (result (own $a))))
  (import "b" (type $b (sub resource)))
  (import "[constructor]b" (func (result (result (own $b)))))
  (import "c" (type $c (sub resource)))
  (import "[constructor]c" (func (result (result (own $c) (error string)))))
  (import "d" (type $d (sub resource)))
  (import "[constructor]d" (func (param "x" u32) (result (own $d)))))
(assert_invalid
  (component
    (import "[constructor]" (func)))
  "not in kebab case")
(assert_invalid
  (component
    (import "[constructor]a" (func)))
  "should return one value")
(assert_invalid
  (component
    (import "[constructor]a" (func (result u32))))
  "should return `(own $T)`")
(assert_invalid
  (component
    (import "b" (type $a (sub resource)))
    (import "[constructor]a" (func (result (own $a)))))
  "function does not match expected resource name `b`")
(assert_invalid
  (component
    (import "a" (type $a (sub resource)))
    (import "[constructor]a" (func (result string))))
  "function should return `(own $T)` or `(result (own $T))`")
(assert_invalid
  (component
    (import "a" (type $a (sub resource)))
    (import "[constructor]a" (func (result (result string)))))
  "function should return `(own $T)` or `(result (own $T))`")
(assert_invalid
  (component
    (import "a" (type $a (sub resource)))
    (import "[constructor]a" (func (result (result (result (own $a)))))))
  "function should return `(own $T)` or `(result (own $T))`")

;; `[method]a.b` requires two `.`-separated labels and a first
;; `(param "self" (borrow $a))`

(component definition
  (import "a" (type $T (sub resource)))
  (import "[method]a.b" (func (param "self" (borrow $T)))))
(assert_invalid
  (component
    (import "[method]" (func)))
  "failed to find `.` character")
(assert_invalid
  (component
    (import "[method]a" (func)))
  "failed to find `.` character")
(assert_invalid
  (component
    (import "[method]a." (func)))
  "not in kebab case")
(assert_invalid
  (component
    (import "[method].a" (func)))
  "not in kebab case")
(assert_invalid
  (component
    (import "[method]a.b.c" (func)))
  "not in kebab case")
(assert_invalid
  (component
    (import "[method]a.b" (instance)))
  "is not a func")
(assert_invalid
  (component
    (import "[method]a.b" (func)))
  "should have at least one argument")
(assert_invalid
  (component
    (import "[method]a.b" (func (param "x" u32))))
  "should have a first argument called `self`")
(assert_invalid
  (component
    (import "[method]a.b" (func (param "self" u32))))
  "should take a first argument of `(borrow $T)`")
(assert_invalid
  (component
    (import "b" (type $T (sub resource)))
    (import "[method]a.b" (func (param "self" (borrow $T)))))
  "does not match expected resource name")

;; `[static]a.b` requires two `.`-separated labels and a resource named "a"
;; in scope, but constrains the function type no further

(component definition
  (import "a" (type (sub resource)))
  (import "[static]a.b" (func (param "x" u32) (result string))))
(assert_invalid
  (component
    (import "[static]" (func)))
  "failed to find `.` character")
(assert_invalid
  (component
    (import "[static]a" (func)))
  "failed to find `.` character")
(assert_invalid
  (component
    (import "[static]a." (func)))
  "not in kebab case")
(assert_invalid
  (component
    (import "[static].a" (func)))
  "not in kebab case")
(assert_invalid
  (component
    (import "[static]a.b.c" (func)))
  "not in kebab case")
(assert_invalid
  (component
    (import "[static]a.b" (instance)))
  "is not a func")
(assert_invalid
  (component
    (import "[static]a.b" (func)))
  "static resource name is not known in this context")

;; the resource name resolves in the same namespace as the annotated name, so
;; since import and export namespaces are disjoint, an exported `[method]`
;; requires the resource to itself be (re-)exported

(component
  (component
    (import "b" (type $T (sub resource)))
    (import "f" (func $f (param "self" (borrow $T))))
    (export $c "c" (type $T))
    (export "[method]c.foo" (func $f) (func (param "self" (borrow $c))))))
(assert_invalid
  (component
    (import "b" (type $T (sub resource)))
    (import "f" (func $f (param "self" (borrow $T))))
    (export "[method]b.foo" (func $f)))
  "resource used in function does not have a name in this context")

;; imports aren't transitive: a resource inside an imported instance confers
;; no root-level name

(assert_invalid
  (component
    (import "i" (instance $i
      (export "t" (type (sub resource)))))
    (alias export $i "t" (type $t))
    (import "[method]t.foo" (func (param "self" (borrow $t)))))
  "resource used in function does not have a name in this context")

;; validation applies inside type declarators and in synthesized
;; bag-of-exports instance types

(component
  (type (component
    (type $it (instance
      (export "bar" (type (sub resource)))
      (export "[static]bar.a" (func))))
    (export "x" (instance (type $it))))))
(assert_invalid
  (component
    (type (component
      (import "b" (type $T (sub resource)))
      (import "[constructor]a" (func (result (own $T)))))))
  "function does not match expected resource name `b`")
(assert_invalid
  (component
    (type $T (resource (rep i32)))
    (core module $m (func (export "a") (result i32) unreachable))
    (core instance $i (instantiate $m))
    (func $f (result (own $T)) (canon lift (core func $i "a")))
    (instance
      (export "a" (type $T))
      (export "[constructor]a" (func $f))))
  "resource used in function does not have a name in this context")

;; strong-uniqueness is computed on the post-`.` label, so `[method]a.a` and
;; `[static]a.a` conflict with a plain `a` while `[constructor]a` does not

(component definition
  (import "a" (type $a (sub resource)))
  (import "[constructor]a" (func (result (own $a)))))
(assert_invalid
  (component
    (import "a" (type $a (sub resource)))
    (import "[method]a.a" (func (param "self" (borrow $a)))))
  "import name `[method]a.a` conflicts with previous name `a`")
(assert_invalid
  (component
    (import "a" (type $a (sub resource)))
    (import "[static]a.a" (func)))
  "import name `[static]a.a` conflicts with previous name `a`")
