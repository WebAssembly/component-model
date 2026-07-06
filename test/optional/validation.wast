;; Validation of `optional` imports and exports.

;; `optional.present` requires an `optional` definition (which may be a lifted
;; function) and produces an immutable `i32` global

(component definition
  (core module $M (func (export "f")))
  (core instance $m (instantiate $M))
  (func $f optional (canon lift (core func $m "f")))
  (canon optional.present (func $f) (core global)))

(assert_invalid
  (component
    (import "f" (func $f))
    (canon optional.present (func $f) (core global)))
  "is not optional")
(assert_invalid
  (component
    (import "i" (instance $i))
    (canon optional.present (instance $i) (core global)))
  "is not optional")
(assert_invalid
  (component
    (import "t" (type $t (sub resource)))
    (canon optional.present (type $t) (core global)))
  "is not optional")
(assert_invalid
  (component
    (component $c)
    (canon optional.present (component $c) (core global)))
  "is not optional")
(assert_invalid
  (component
    (core module $m)
    (canon optional.present (core module $m) (core global)))
  "is not optional")
(assert_invalid
  (component
    (core module $M)
    (core instance $i (instantiate $M))
    (canon optional.present (core instance $i) (core global)))
  "is not optional")
(assert_invalid
  (component
    (core type $ft (func))
    (canon optional.present (core type $ft) (core global)))
  "is not optional")
(assert_invalid
  (component
    (core module $M (func (export "f")))
    (core instance $i (instantiate $M))
    (alias core export $i "f" (core func $f))
    (canon optional.present (core func $f) (core global)))
  "is not optional")
(assert_invalid
  (component
    (core module $M (table (export "t") 1 funcref))
    (core instance $i (instantiate $M))
    (alias core export $i "t" (core table $t))
    (canon optional.present (core table $t) (core global)))
  "is not optional")
(assert_invalid
  (component
    (core module $M (memory (export "m") 1))
    (core instance $i (instantiate $M))
    (alias core export $i "m" (core memory $m))
    (canon optional.present (core memory $m) (core global)))
  "is not optional")
(assert_invalid
  (component
    (core module $M (global (export "g") i32 (i32.const 0)))
    (core instance $i (instantiate $M))
    (alias core export $i "g" (core global $g))
    (canon optional.present (core global $g) (core global)))
  "is not optional")
(assert_invalid
  (component
    (import "f" (func $f optional))
    (canon optional.present (func $f) (core global $has-f))
    (core module $M (import "" "has-f" (global (mut i32))))
    (core instance (instantiate $M (with "" (instance (export "has-f" (global $has-f)))))))
  "global types differ in mutability")

;; a function type that transitively uses an `optional` resource type must be
;; `optional`, even when it's only defined and not imported or exported (as
;; must a `[static]` function of an `optional` resource, even when it doesn't
;; use the resource); other types need not be, and a resource type exported by
;; an `optional` instance isn't `optional` inside the instance type

(component definition
  (import "t" (type $t (sub optional resource)))
  (type $l (list (option (own $t))))
  (import "f" (func optional (param "l" $l)))
  (import "[static]t.g" (func optional))
  (type $ft (func optional (param "l" $l)))
  (import "i" (instance optional
    (export "u" (type $u (sub resource)))
    (export "h" (func (result (own $u))))))
  (canon resource.drop $t (core func)))

(assert_invalid
  (component
    (import "t" (type $t (sub optional resource)))
    (import "f" (func (result (own $t)))))
  "must be optional")
(assert_invalid
  (component
    (import "t" (type $t (sub optional resource)))
    (type (func (result (own $t)))))
  "must be optional")
(assert_invalid
  (component
    (import "t" (type $t (sub optional resource)))
    (type $l (list (option (borrow $t))))
    (type (func (param "l" $l))))
  "must be optional")
(assert_invalid
  (component
    (import "t" (type $t (sub optional resource)))
    (core module $M (func (export "f") (result i32) unreachable))
    (core instance $m (instantiate $M))
    (func (result (own $t)) (canon lift (core func $m "f"))))
  "must be optional")
(assert_invalid
  (component
    (import "t" (type $t (sub optional resource)))
    (type $l (list (option (borrow $t))))
    (import "f" (func (param "l" $l))))
  "must be optional")
(assert_invalid
  (component
    (import "t" (type $t (sub optional resource)))
    (import "[static]t.g" (func)))
  "must be optional")
(assert_invalid
  (component
    (type (instance
      (export "t" (type $t (sub optional resource)))
      (export "f" (func (result (own $t)))))))
  "must be optional")
(assert_invalid
  (component
    (import "i" (instance optional
      (export "t" (type $t (sub optional resource)))
      (export "f" (func (result (own $t)))))))
  "must be optional")

;; `alias export` of an `optional` instance's exports adds `optional`, so
;; `component` and `core module` exports (which can't be `optional`) can't be
;; aliased, but `eq`-bound non-resource types, and resource types defined
;; outside the instance, keep their type

(component definition
  (import "i" (instance $i optional
    (export "t" (type $t (sub resource)))
    (export "u" (type (eq $t)))
    (export "f" (func))
    (export "j" (instance (export "g" (func))))))
  (alias export $i "t" (type $t))
  (alias export $i "u" (type $u))
  (alias export $i "f" (func $f))
  (alias export $i "j" (instance $j))
  (alias export $j "g" (func $g))
  (canon optional.present (type $t) (core global))
  (canon optional.present (type $u) (core global))
  (canon optional.present (func $f) (core global))
  (canon optional.present (instance $j) (core global))
  (canon optional.present (func $g) (core global)))

(assert_invalid
  (component
    (import "i" (instance $i optional (export "f" (func))))
    (component $Child (import "f" (func)))
    (instance (instantiate $Child (with "f" (func $i "f")))))
  "expected non-optional")
(assert_invalid
  (component
    (import "i" (instance $i optional (export "t" (type (sub resource)))))
    (alias export $i "t" (type $t))
    (import "f" (func (param "x" (own $t)))))
  "must be optional")
(assert_invalid
  (component
    (import "i" (instance $i optional (export "c" (component))))
    (alias export $i "c" (component $c)))
  "from an optional instance")
(assert_invalid
  (component
    (import "i" (instance $i optional (export "m" (core module))))
    (alias export $i "m" (core module $m)))
  "from an optional instance")

(component definition $C
  (import "r" (type $r (sub resource)))
  (import "i" (instance $i optional
    (type $l (list u8))
    (export "l" (type (eq $l)))
    (alias outer $C $r (type $r'))
    (export "r" (type (eq $r')))))
  (alias export $i "l" (type $l))
  (alias export $i "r" (type $ir))
  (import "f" (func (param "l" $l) (param "r" (own $ir)))))

;; `alias outer` out of an `optional` instance type strips `optional`, but not
;; out of a non-`optional` one

(component definition $C
  (import "i" (instance $i optional (export "t" (type (sub resource)))))
  (alias export $i "t" (type $t))
  (import "j" (instance optional
    (alias outer $C $t (type $t'))
    (export "g" (func (result (own $t')))))))

(assert_invalid
  (component $C
    (import "i" (instance $i optional (export "t" (type (sub resource)))))
    (alias export $i "t" (type $t))
    (import "j" (instance
      (alias outer $C $t (type $t'))
      (export "g" (func (result (own $t')))))))
  "must be optional")

;; ... whichever of the instance types crossed is `optional`, and also from
;; resource types the target only refers to; a func type target keeps its own
;; `optional`

(component definition $C
  (import "i" (instance $i optional (export "t" (type (sub resource)))))
  (alias export $i "t" (type $t))
  (type $l (list (own $t)))
  (import "j" (instance optional
    (alias outer $C $l (type $l'))
    (export "g" (func (param "l" $l')))
    (export "k" (instance
      (alias outer $C $t (type $t'))
      (export "h" (func (result (own $t'))))))))
  (import "m" (instance
    (export "n" (instance optional
      (alias outer $C $t (type $t'))
      (export "h" (func (result (own $t')))))))))

(component definition $C
  (type $ft (func optional))
  (type $J (instance optional
    (alias outer $C $ft (type $ft'))
    (export "h" (func (type $ft')))))
  (instance (type $J)))

;; an `instance` of inline exports may be ascribed an instance type, which the
;; exports must match, except that the type's own `optional` exports (but not
;; those inside a nested instance type) may be omitted; `optional` definitions
;; may be given for non-`optional` exports only if the instance type is
;; `optional`

(component definition
  (import "f" (func $f (result u32)))
  (import "g" (func $g optional))
  (type $T (instance
    (export "f" (func (result u32)))
    (export "g" (func optional))
    (export "h" (func optional (result u32)))
    (export "k" (func optional))))
  (instance (type $T)
    (export "f" (func $f))
    (export "g" (func $g))
    (export "h" (func $f))))

(assert_invalid
  (component
    (type $T (func))
    (instance (type $T)))
  "is not an instance type")
(assert_invalid
  (component
    (type $T (instance (export "f" (func))))
    (instance (type $T)))
  "missing expected export `f`")
(assert_invalid
  (component
    (import "f" (func $f))
    (type $T (instance (export "f" (func (result u32)))))
    (instance (type $T) (export "f" (func $f))))
  "type mismatch in instance export `f`")
(assert_invalid
  (component
    (instance $k)
    (type $T (instance (export "k" (instance (export "f" (func optional))))))
    (instance (type $T) (export "k" (instance $k))))
  "type mismatch in instance export `k`")
(assert_invalid
  (component
    (import "f" (func $f optional))
    (type $T (instance (export "f" (func))))
    (instance (type $T) (export "f" (func $f))))
  "expected non-optional")

;; the instance's type is the ascribed type, not the inferred one, so
;; superfluous inline exports are ignored and a `sub`-bound type export is fresh
(assert_invalid
  (component
    (import "f" (func $f))
    (type $T (instance optional (export "f" (func))))
    (instance $i (type $T) (export "f" (func $f)))
    (component $Child (import "i" (instance (export "f" (func)))))
    (instance (instantiate $Child (with "i" (instance $i)))))
  "expected non-optional")
(assert_invalid
  (component
    (import "f" (func $f))
    (type $T (instance (export "f" (func))))
    (instance $i (type $T) (export "f" (func $f)) (export "extra" (func $f)))
    (alias export $i "extra" (func $g)))
  "no export named `extra`")

(component definition $C
  (type $R (resource (rep i32)))
  (type $IT (instance
    (alias outer $C $R (type $R))
    (export "T1" (type (eq $R)))
    (export "T2" (type (sub resource)))
    (export "T3" (type $T3 (sub optional resource)))
    (export "f" (func optional (result (own $T3))))))
  (instance $i (type $IT)
    (export "T1" (type $R))
    (export "T2" (type $R))
    (export "T3" (type $R))
    (export "extra" (type $R)))
  (component $Child
    (import "a" (type $a (sub resource)))
    (import "b" (type (eq $a))))
  (instance (instantiate $Child (with "a" (type $R)) (with "b" (type $i "T1")))))

(assert_invalid
  (component $C
    (type $R (resource (rep i32)))
    (type $IT (instance (export "T2" (type (sub resource)))))
    (instance $i (type $IT) (export "T2" (type $R)))
    (component $Child
      (import "a" (type $a (sub resource)))
      (import "b" (type (eq $a))))
    (instance (instantiate $Child (with "a" (type $R)) (with "b" (type $i "T2")))))
  "resource types are not the same")

;; `instantiate` may omit only `optional` imports (an instance argument can't
;; omit the `optional` exports of an instance import), and may supply a
;; non-`optional` definition for an `optional` import but not vice versa

(component definition
  (import "f" (func $f))
  (import "i" (instance $i (export "f" (func))))
  (import "t" (type $t (sub resource)))
  (component $Child
    (import "f" (func optional))
    (import "i" (instance optional (export "f" (func))))
    (import "t" (type (sub optional resource)))
    (import "g" (func optional)))
  (instance (instantiate $Child
    (with "f" (func $f))
    (with "i" (instance $i))
    (with "t" (type $t)))))

(assert_invalid
  (component
    (component $Child
      (import "f" (func optional))
      (import "g" (func)))
    (instance (instantiate $Child)))
  "missing import named `g`")
(assert_invalid
  (component
    (instance $i)
    (component $Child (import "i" (instance (export "f" (func optional)))))
    (instance (instantiate $Child (with "i" (instance $i)))))
  "missing expected export `f`")
(assert_invalid
  (component
    (import "f" (func $f optional))
    (component $Child (import "f" (func)))
    (instance (instantiate $Child (with "f" (func $f)))))
  "expected non-optional")
(assert_invalid
  (component
    (import "i" (instance $i optional))
    (component $Child (import "i" (instance)))
    (instance (instantiate $Child (with "i" (instance $i)))))
  "expected non-optional")
(assert_invalid
  (component
    (import "t" (type $t (sub optional resource)))
    (component $Child (import "t" (type (sub resource))))
    (instance (instantiate $Child (with "t" (type $t)))))
  "expected non-optional")

;; nor can a component argument omit the `optional` exports, or have
;; `optional` imports beyond those, of a component import; an `optional`
;; import of a component import can't be given a non-`optional` one

(component definition
  (component $A (import "f" (func $f optional)) (export "g" (func $f)))
  (component $User
    (import "c" (component (import "f" (func optional)) (export "g" (func optional)))))
  (instance (instantiate $User (with "c" (component $A)))))

(assert_invalid
  (component
    (component $A (import "f" (func optional)))
    (component $User
      (import "c" (component (import "f" (func optional)) (export "g" (func optional)))))
    (instance (instantiate $User (with "c" (component $A)))))
  "missing export named `g`")
(assert_invalid
  (component
    (component $A (import "f" (func optional)))
    (component $User (import "c" (component)))
    (instance (instantiate $User (with "c" (component $A)))))
  "missing import named `f`")
(assert_invalid
  (component
    (component $A (import "f" (func)))
    (component $User (import "c" (component (import "f" (func optional)))))
    (instance (instantiate $User (with "c" (component $A)))))
  "expected non-optional")

;; `instantiate` substitutes a type argument that isn't present like any other,
;; so the child's `bar` matches `foo` only if `u` is given `t`, and the type
;; that isn't present can be re-exported before the functions that use it

(component definition
  (import "t" (type $t (sub optional resource)))
  (import "foo" (func $foo optional (result (own $t))))
  (component $Child
    (import "u" (type $u (sub optional resource)))
    (import "bar" (func optional (result (own $u))))
    (export $v "v" (type $u))
    (core module $M (func (export "baz") (result i32) unreachable))
    (core instance $m (instantiate $M))
    (func (export "baz") optional (result (own $v)) (canon lift (core func $m "baz"))))
  (instance (instantiate $Child (with "u" (type $t)) (with "bar" (func $foo))))
  (instance $child (instantiate $Child))
  (alias export $child "v" (type $v))
  (alias export $child "baz" (func $baz))
  (export $V "v" (type $v))
  (export "baz" (func $baz) (func optional (result (own $V)))))

(assert_invalid
  (component
    (import "t" (type $t (sub optional resource)))
    (import "foo" (func $foo optional (result (own $t))))
    (component $Child
      (import "u" (type $u (sub optional resource)))
      (import "bar" (func optional (result (own $u)))))
    (instance (instantiate $Child (with "bar" (func $foo)))))
  "resource types are not the same")
(assert_invalid
  (component
    (component $Child
      (import "u" (type $u (sub optional resource)))
      (export $v "v" (type $u))
      (core module $M (func (export "baz") (result i32) unreachable))
      (core instance $m (instantiate $M))
      (func (export "baz") optional (result (own $v)) (canon lift (core func $m "baz"))))
    (instance $child (instantiate $Child))
    (export "v" (type $child "v"))
    (export "baz" (func $child "baz")))
  "func not valid to be used as export")

;; substitution erases the import's `optional` bound, leaving the argument's;
;; an omitted type argument is a singleton `optional` type

(component definition
  (type $R (resource (rep i32)))
  (component $Child1
    (import "t" (type $t (sub optional resource)))
    (export "t" (type $t)))
  (component $Child2 (import "u" (type (sub resource))))
  (instance $child1 (instantiate $Child1 (with "t" (type $R))))
  (instance (instantiate $Child2 (with "u" (type $child1 "t"))))
  (instance $a (instantiate $Child1))
  (instance $b (instantiate $Child1))
  (component $Child3
    (import "x" (type $x (sub optional resource)))
    (import "y" (type (eq $x))))
  (instance (instantiate $Child3 (with "x" (type $a "t")) (with "y" (type $b "t")))))

(assert_invalid
  (component
    (component $Child1
      (import "t" (type $t (sub optional resource)))
      (export "t" (type $t)))
    (component $Child2 (import "u" (type (sub resource))))
    (instance $a (instantiate $Child1))
    (instance (instantiate $Child2 (with "u" (type $a "t")))))
  "expected non-optional")

;; an export's type is inferred to be `optional` from its definition, and an
;; ascription may add `optional` but not remove it

(component definition
  (core module $M (func (export "f")))
  (core instance $m (instantiate $M))
  (func $f optional (canon lift (core func $m "f")))
  (func $g (canon lift (core func $m "f")))
  (type $r (resource (rep i32)))
  (export "f" (func $f))
  (export "g" (func $g) (func optional))
  (export "r" (type $r) (type (sub optional resource))))

(assert_invalid
  (component
    (core module $M (func (export "f")))
    (core instance $m (instantiate $M))
    (func $f optional (canon lift (core func $m "f")))
    (export "f" (func $f) (func)))
  "expected non-optional")
(assert_invalid
  (component
    (import "t" (type $t (sub optional resource)))
    (export "u" (type $t) (type (sub resource))))
  "expected non-optional")
