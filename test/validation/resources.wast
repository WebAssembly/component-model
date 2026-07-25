;; Tests for the resource-type parts of Explainer.md#type-checking and
;; validation of Explainer.md#resource-built-ins.

;; `sub` bounds are fresh

(assert_invalid
  (component
    (import "T1" (type $T1 (sub resource)))
    (import "T2" (type $T2 (sub resource)))
    (component $eq
      (import "a" (type $a (sub resource)))
      (import "b" (type (eq $a))))
    (instance (instantiate $eq (with "a" (type $T1)) (with "b" (type $T2)))))
  "resource types are not the same")


;; `eq` bounds are equal

(component definition
  (import "T1" (type $T1 (sub resource)))
  (import "T2" (type $T2 (sub resource)))
  (import "T3" (type $T3 (eq $T2)))
  (component $eq
    (import "a" (type $a (sub resource)))
    (import "b" (type (eq $a))))
  (instance (instantiate $eq (with "a" (type $T2)) (with "b" (type $T3)))))

(assert_invalid
  (component
    (import "T1" (type $T1 (sub resource)))
    (import "T2" (type $T2 (sub resource)))
    (import "T3" (type $T3 (eq $T2)))
    (component $eq
      (import "a" (type $a (sub resource)))
      (import "b" (type (eq $a))))
    (instance (instantiate $eq (with "a" (type $T1)) (with "b" (type $T2)))))
  "resource types are not the same")

(component definition
  (import "T1" (type $T1 (sub resource)))
  (import "T2" (type $T2 (eq $T1)))
  (import "T3" (type $T3 (eq $T2)))
  (component $eq
    (import "a" (type $a (sub resource)))
    (import "b" (type (eq $a))))
  (instance (instantiate $eq (with "a" (type $T1)) (with "b" (type $T3)))))

(component definition
  (import "T1" (type $T1 (sub resource)))
  (import "T2" (type $T2 (eq $T1)))
  (import "T3" (type $T3 (eq $T2)))
  (import "T4" (type $T4 (eq $T3)))
  (import "T5" (type $T5 (eq $T4)))
  (import "T6" (type $T6 (eq $T5)))
  (import "T7" (type $T7 (eq $T6)))
  (import "T8" (type $T8 (eq $T7)))
  (component $eq
    (import "a" (type $a (sub resource)))
    (import "b" (type (eq $a))))
  (instance (instantiate $eq (with "a" (type $T1)) (with "b" (type $T8)))))

;; compound value types inherit freshness

(component definition
  (import "T" (type $T (sub resource)))
  (import "f" (func $f (param "x" (own $T))))
  (component $c
    (import "T" (type $T (sub resource)))
    (import "g" (func (param "x" (own $T)))))
  (instance (instantiate $c (with "T" (type $T)) (with "g" (func $f)))))

(assert_invalid
  (component
    (import "T" (type $T (sub resource)))
    (import "U" (type $U (sub resource)))
    (import "f" (func $f (param "x" (own $U))))
    (component $c
      (import "T" (type $T (sub resource)))
      (import "g" (func (param "x" (own $T)))))
    (instance (instantiate $c (with "T" (type $T)) (with "g" (func $f)))))
  "resource types are not the same")

(component definition
  (import "T" (type $T (sub resource)))
  (import "f" (func $f (param "x" (borrow $T))))
  (component $c
    (import "T" (type $T (sub resource)))
    (import "g" (func (param "x" (borrow $T)))))
  (instance (instantiate $c (with "T" (type $T)) (with "g" (func $f)))))

(assert_invalid
  (component
    (import "T" (type $T (sub resource)))
    (import "U" (type $U (sub resource)))
    (import "f" (func $f (param "x" (borrow $U))))
    (component $c
      (import "T" (type $T (sub resource)))
      (import "g" (func (param "x" (borrow $T)))))
    (instance (instantiate $c (with "T" (type $T)) (with "g" (func $f)))))
  "resource types are not the same")

(assert_invalid
  (component
    (import "T" (type $T (sub resource)))
    (import "f" (func $f (param "x" (borrow $T))))
    (component $c
      (import "T" (type $T (sub resource)))
      (import "g" (func (param "x" (own $T)))))
    (instance (instantiate $c (with "T" (type $T)) (with "g" (func $f)))))
  "expected own, found borrow")

(component definition
  (import "T1" (type $T1 (sub resource)))
  (import "T2" (type $T2 (eq $T1)))
  (import "T3" (type $T3 (sub resource)))
  (import "T4" (type $T4 (eq $T3)))
  (import "T5" (type $T5 (sub resource)))
  (import "T6" (type $T6 (eq $T5)))
  (import "T7" (type $T7 (sub resource)))
  (import "T8" (type $T8 (eq $T7)))
  (import "f" (func $f (param "p1" (own $T1))
    (param "p2" (borrow $T2))
    (param "p3" (own $T3))
    (param "p4" (borrow $T4))
    (param "p5" (list (own $T5)))
    (param "p6" (option (borrow $T6)))
    (param "p7" (own $T7))
    (param "p8" (borrow $T8))))
  (component $c
    (import "T1" (type $T1 (sub resource)))
    (import "T2" (type $T2 (sub resource)))
    (import "T3" (type $T3 (sub resource)))
    (import "T4" (type $T4 (eq $T3)))
    (import "T5" (type $T5 (sub resource)))
    (import "T6" (type $T6 (sub resource)))
    (import "T7" (type $T7 (sub resource)))
    (import "T8" (type $T8 (eq $T7)))
    (import "g" (func (param "p1" (own $T1))
      (param "p2" (borrow $T2))
      (param "p3" (own $T3))
      (param "p4" (borrow $T4))
      (param "p5" (list (own $T5)))
      (param "p6" (option (borrow $T6)))
      (param "p7" (own $T7))
      (param "p8" (borrow $T8)))))
  (instance (instantiate $c
    (with "T1" (type $T1))
    (with "T2" (type $T2))
    (with "T3" (type $T3))
    (with "T4" (type $T4))
    (with "T5" (type $T5))
    (with "T6" (type $T6))
    (with "T7" (type $T7))
    (with "T8" (type $T8))
    (with "g" (func $f)))))

(component definition
  (import "T" (type $T (sub resource)))
  (type $LO1 (list (own $T)))
  (import "f" (func $f (param "x" $LO1)))
  (component $c
    (import "T" (type $T (sub resource)))
    (type $LO2 (list (own $T)))
    (import "g" (func (param "x" $LO2))))
  (instance (instantiate $c (with "T" (type $T)) (with "g" (func $f)))))

(assert_invalid
  (component
    (import "T" (type $T (sub resource)))
    (import "U" (type $U (sub resource)))
    (type $LO3 (list (own $U)))
    (import "f" (func $f (param "x" $LO3)))
    (component $c
      (import "T" (type $T (sub resource)))
      (type $LO1 (list (own $T)))
      (import "g" (func (param "x" $LO1))))
    (instance (instantiate $c (with "T" (type $T)) (with "g" (func $f)))))
  "resource types are not the same")

(assert_invalid
  (component
    (import "T" (type $T (sub resource)))
    (type $LB (list (borrow $T)))
    (import "f" (func $f (param "x" $LB)))
    (component $c
      (import "T" (type $T (sub resource)))
      (type $LO (list (own $T)))
      (import "g" (func (param "x" $LO))))
    (instance (instantiate $c (with "T" (type $T)) (with "g" (func $f)))))
  "expected own, found borrow")

(component definition
  (import "T" (type $T (sub resource)))
  (import "f" (func $f (param "x" (tuple (own $T) u32))))
  (component $c
    (import "T" (type $T (sub resource)))
    (import "g" (func (param "x" (tuple (own $T) u32)))))
  (instance (instantiate $c (with "T" (type $T)) (with "g" (func $f)))))

(assert_invalid
  (component
    (import "T" (type $T (sub resource)))
    (import "U" (type $U (sub resource)))
    (import "f" (func $f (param "x" (tuple (own $U) u32))))
    (component $c
      (import "T" (type $T (sub resource)))
      (import "g" (func (param "x" (tuple (own $T) u32)))))
    (instance (instantiate $c (with "T" (type $T)) (with "g" (func $f)))))
  "resource types are not the same")

(assert_invalid
  (component
    (import "T" (type $T (sub resource)))
    (import "U" (type $U (sub resource)))
    (import "f" (func $f (param "x" (option (own $U)))))
    (component $c
      (import "T" (type $T (sub resource)))
      (import "g" (func (param "x" (option (own $T))))))
    (instance (instantiate $c (with "T" (type $T)) (with "g" (func $f)))))
  "resource types are not the same")

(assert_invalid
  (component
    (import "T" (type $T (sub resource)))
    (import "U" (type $U (sub resource)))
    (import "f" (func $f (param "x" (result (own $U)))))
    (component $c
      (import "T" (type $T (sub resource)))
      (import "g" (func (param "x" (result (own $T))))))
    (instance (instantiate $c (with "T" (type $T)) (with "g" (func $f)))))
  "resource types are not the same")

(component definition
  (import "T" (type $T (sub resource)))
  (import "f" (func $f (param "x" (list (list (own $T))))))
  (component $c
    (import "T" (type $T (sub resource)))
    (import "g" (func (param "x" (list (list (own $T)))))))
  (instance (instantiate $c (with "T" (type $T)) (with "g" (func $f)))))

(assert_invalid
  (component
    (import "T" (type $T (sub resource)))
    (import "U" (type $U (sub resource)))
    (import "f" (func $f (param "x" (list (list (own $U))))))
    (component $c
      (import "T" (type $T (sub resource)))
      (import "g" (func (param "x" (list (list (own $T)))))))
    (instance (instantiate $c (with "T" (type $T)) (with "g" (func $f)))))
  "resource types are not the same")

(component definition
  (import "T" (type $T (sub resource)))
  (import "f" (func $f (param "x" (list (option (result (list (option (result (list (option (own $T))))))))))))
  (component $c
    (import "T" (type $T (sub resource)))
    (import "g" (func (param "x" (list (option (result (list (option (result (list (option (own $T)))))))))))))
  (instance (instantiate $c (with "T" (type $T)) (with "g" (func $f)))))

(assert_invalid
  (component
    (import "T" (type $T (sub resource)))
    (import "U" (type $U (sub resource)))
    (import "f" (func $f (param "x" (list (option (result (list (option (result (list (option (own $U))))))))))))
    (component $c
      (import "T" (type $T (sub resource)))
      (import "g" (func (param "x" (list (option (result (list (option (result (list (option (own $T)))))))))))))
    (instance (instantiate $c (with "T" (type $T)) (with "g" (func $f)))))
  "resource types are not the same")

(component
  (type $R (resource (rep i32)))
  (type $Rec (record (field "h" (own $R))))
  (component $c
    (import "T" (type $t (sub resource)))
    (type $expected (record (field "h" (own $t))))
    (import "a" (type (eq $expected))))
  (instance (instantiate $c (with "T" (type $R)) (with "a" (type $Rec)))))

(assert_invalid
  (component
    (type $R1 (resource (rep i32)))
    (type $R2 (resource (rep i32)))
    (type $RecU (record (field "h" (own $R2))))
    (component $c
      (import "T" (type $t (sub resource)))
      (type $expected (record (field "h" (own $t))))
      (import "a" (type (eq $expected))))
    (instance (instantiate $c (with "T" (type $R1)) (with "a" (type $RecU)))))
  "resource types are not the same")

(component
  (type $R (resource (rep i32)))
  (type $Var (variant (case "c" (own $R))))
  (component $c
    (import "T" (type $t (sub resource)))
    (type $expected (variant (case "c" (own $t))))
    (import "a" (type (eq $expected))))
  (instance (instantiate $c (with "T" (type $R)) (with "a" (type $Var)))))

(assert_invalid
  (component
    (type $R1 (resource (rep i32)))
    (type $R2 (resource (rep i32)))
    (type $VarU (variant (case "c" (own $R2))))
    (component $c
      (import "T" (type $t (sub resource)))
      (type $expected (variant (case "c" (own $t))))
      (import "a" (type (eq $expected))))
    (instance (instantiate $c (with "T" (type $R1)) (with "a" (type $VarU)))))
  "resource types are not the same")

(component
  (type $R1 (resource (rep i32)))
  (type $R2 (resource (rep i32)))
  (type $Rec (record (field "f1" (own $R1))
    (field "f2" (borrow $R2))
    (field "f3" (own $R1))
    (field "f4" (borrow $R2))
    (field "f5" (list (own $R1)))
    (field "f6" (option (borrow $R2)))
    (field "f7" (own $R1))
    (field "f8" (borrow $R2))))
  (component $c
    (import "T1" (type $t1 (sub resource)))
    (import "T2" (type $t2 (sub resource)))
    (import "T3" (type $t3 (sub resource)))
    (import "T4" (type $t4 (sub resource)))
    (import "T5" (type $t5 (eq $t1)))
    (import "T6" (type $t6 (eq $t2)))
    (import "T7" (type $t7 (eq $t1)))
    (import "T8" (type $t8 (eq $t4)))
    (type $expected (record (field "f1" (own $t1))
      (field "f2" (borrow $t2))
      (field "f3" (own $t3))
      (field "f4" (borrow $t4))
      (field "f5" (list (own $t5)))
      (field "f6" (option (borrow $t6)))
      (field "f7" (own $t7))
      (field "f8" (borrow $t8))))
    (import "a" (type (eq $expected))))
  (instance (instantiate $c
    (with "T1" (type $R1))
    (with "T2" (type $R2))
    (with "T3" (type $R1))
    (with "T4" (type $R2))
    (with "T5" (type $R1))
    (with "T6" (type $R2))
    (with "T7" (type $R1))
    (with "T8" (type $R2))
    (with "a" (type $Rec)))))

;; each instance-typed import generates fresh resources

(component definition
  (type $I (instance
    (export "r" (type $r (sub resource)))
    (export "f" (func (result (own $r))))))
  (import "i1" (instance $i1 (type $I)))
  (import "i2" (instance $i2 (type $I)))
  (component $C
    (import "r" (type $r (sub resource)))
    (import "f" (func (result (own $r)))))
  (instance (instantiate $C
    (with "r" (type $i1 "r"))
    (with "f" (func $i1 "f"))))
  (instance (instantiate $C
    (with "r" (type $i2 "r"))
    (with "f" (func $i2 "f")))))

(assert_invalid
  (component
    (type $I (instance
      (export "r" (type $r (sub resource)))
      (export "f" (func (result (own $r))))))
    (import "i1" (instance $i1 (type $I)))
    (import "i2" (instance $i2 (type $I)))
    (component $C
      (import "r" (type $r (sub resource)))
      (import "f" (func (result (own $r)))))
    (instance (instantiate $C
      (with "r" (type $i1 "r"))
      (with "f" (func $i2 "f")))))
  "resource types are not the same")

;; ...including instance-typed exports of a single imported instance
(assert_invalid
  (component
    (import "x" (instance $i
      (type $I (instance
        (export "r" (type (sub resource)))))
      (export "a" (instance (type $I)))
      (export "b" (instance (type $I)))))
    (component $eq
      (import "a" (type $a (sub resource)))
      (import "b" (type (eq $a))))
    (instance (instantiate $eq
      (with "a" (type $i "a" "r"))
      (with "b" (type $i "b" "r")))))
  "resource types are not the same")

;; within one component type, an instance-typed export's resource can be
;; aliased and eq-referenced by later exports
(component
  (type $X (component
    (type $T (instance
      (export "r" (type (sub resource)))))
    (export "t" (instance $t (type $T)))
    (alias export $t "r" (type $r))
    (type $T2 (instance
      (export "r2" (type (eq $r)))
      (export "r" (type (sub resource)))))
    (export "t2" (instance (type $T2))))))

;; resource type definitions are generative

(assert_invalid
  (component
    (type $R1 (resource (rep i32)))
    (type $R2 (resource (rep i32)))
    (component $eq
      (import "a" (type $a (sub resource)))
      (import "b" (type (eq $a))))
    (instance (instantiate $eq (with "a" (type $R1)) (with "b" (type $R2)))))
  "resource types are not the same")

(component
  (type $R (resource (rep i32)))
  (component $eq
    (import "a" (type $a (sub resource)))
    (import "b" (type (eq $a))))
  (instance (instantiate $eq (with "a" (type $R)) (with "b" (type $R)))))

(assert_invalid
  (component
    (import "T" (type $T (sub resource)))
    (type $R (resource (rep i32)))
    (component $eq
      (import "a" (type $a (sub resource)))
      (import "b" (type (eq $a))))
    (instance (instantiate $eq (with "a" (type $R)) (with "b" (type $T)))))
  "resource types are not the same")

;; aliasing exported types

(component
  (component $Outer
    (import "C" (component $C
      (export "T1" (type (sub resource)))
      (export "T2" (type $T2 (sub resource)))
      (export "T3" (type (eq $T2)))))
    (instance $c (instantiate $C))
    (alias export $c "T1" (type $T1))
    (alias export $c "T2" (type $T2))
    (alias export $c "T3" (type $T3))
    (component $eq
      (import "a" (type $a (sub resource)))
      (import "b" (type (eq $a))))
    (instance (instantiate $eq (with "a" (type $T2)) (with "b" (type $T3))))))

(assert_invalid
  (component
    (component $Outer
      (import "C" (component $C
        (export "T1" (type (sub resource)))
        (export "T2" (type $T2 (sub resource)))
        (export "T3" (type (eq $T2)))))
      (instance $c (instantiate $C))
      (alias export $c "T1" (type $T1))
      (alias export $c "T2" (type $T2))
      (component $eq
        (import "a" (type $a (sub resource)))
        (import "b" (type (eq $a))))
      (instance (instantiate $eq (with "a" (type $T1)) (with "b" (type $T2))))))
  "resource types are not the same")

;; generativity across component instances

(assert_invalid
  (component
    (component $C
      (type $r1 (export "r1") (resource (rep i32)))
      (type $r2 (export "r2") (resource (rep i32))))
    (instance $c1 (instantiate $C))
    (instance $c2 (instantiate $C))
    (alias export $c1 "r1" (type $c1r1))
    (alias export $c2 "r1" (type $c2r1))
    (component $eq
      (import "a" (type $a (sub resource)))
      (import "b" (type (eq $a))))
    (instance (instantiate $eq (with "a" (type $c1r1)) (with "b" (type $c2r1)))))
  "resource types are not the same")

(assert_invalid
  (component
    (component $C
      (type $r1 (export "r1") (resource (rep i32)))
      (type $r2 (export "r2") (resource (rep i32))))
    (instance $c1 (instantiate $C))
    (alias export $c1 "r1" (type $c1r1))
    (alias export $c1 "r2" (type $c1r2))
    (component $eq
      (import "a" (type $a (sub resource)))
      (import "b" (type (eq $a))))
    (instance (instantiate $eq (with "a" (type $c1r1)) (with "b" (type $c1r2)))))
  "resource types are not the same")

(assert_invalid
  (component
    (component $C
      (type $r1 (export "r1") (resource (rep i32)))
      (type $r2 (export "r2") (resource (rep i32)))
      (type $r3 (export "r3") (resource (rep i32)))
      (type $r4 (export "r4") (resource (rep i32))))
    (instance $c1 (instantiate $C))
    (instance $c2 (instantiate $C))
    (instance $c3 (instantiate $C))
    (instance $c4 (instantiate $C))
    (alias export $c1 "r1" (type $first))
    (alias export $c4 "r1" (type $last))
    (component $eq
      (import "a" (type $a (sub resource)))
      (import "b" (type (eq $a))))
    (instance (instantiate $eq (with "a" (type $first)) (with "b" (type $last)))))
  "resource types are not the same")


;; per-instantiation generativity is also enforced through functions using the
;; resource, not just type imports

(component
  (component $C
    (type $R (resource (rep i32)))
    (export $R' "r" (type $R))
    (core func $drop (canon resource.drop $R))
    (func (export "f") (param "x" (own $R')) (canon lift (core func $drop))))
  (instance $c1 (instantiate $C))
  (component $D
    (import "r" (type $R (sub resource)))
    (import "f" (func (param "x" (own $R)))))
  (instance (instantiate $D
    (with "r" (type $c1 "r"))
    (with "f" (func $c1 "f")))))

(assert_invalid
  (component
    (component $C
      (type $R (resource (rep i32)))
      (export $R' "r" (type $R))
      (core func $drop (canon resource.drop $R))
      (func (export "f") (param "x" (own $R')) (canon lift (core func $drop))))
    (instance $c1 (instantiate $C))
    (instance $c2 (instantiate $C))
    (component $D
      (import "r" (type $R (sub resource)))
      (import "f" (func (param "x" (own $R)))))
    (instance (instantiate $D
      (with "r" (type $c1 "r"))
      (with "f" (func $c2 "f")))))
  "resource types are not the same")

;; multiple exports of one resource with export ascription

(component
  (component $C
    (type $r (resource (rep i32)))
    (export "r1" (type $r))
    (export "r2" (type $r)))
  (instance $c (instantiate $C))
  (alias export $c "r1" (type $r1))
  (alias export $c "r2" (type $r2))
  (component $eq
    (import "a" (type $a (sub resource)))
    (import "b" (type (eq $a))))
  (instance (instantiate $eq (with "a" (type $r1)) (with "b" (type $r2)))))

(assert_invalid
  (component
    (component $C
      (type $r (resource (rep i32)))
      (export "r1" (type $r))
      (export "r2" (type $r) (type (sub resource))))
    (instance $c (instantiate $C))
    (alias export $c "r1" (type $r1))
    (alias export $c "r2" (type $r2))
    (component $eq
      (import "a" (type $a (sub resource)))
      (import "b" (type (eq $a))))
    (instance (instantiate $eq (with "a" (type $r1)) (with "b" (type $r2)))))
  "resource types are not the same")

;; type substitution by `instantiate`

(component
  (component $P
    (import "C1" (component $C1
      (import "T" (type $T (sub resource)))
      (export "foo" (func (param "t" (own $T))))))
    (import "C2" (component $C2
      (import "T" (type $T (sub resource)))
      (import "foo" (func (param "t" (own $T))))))
    (type $R (resource (rep i32)))
    (instance $c1 (instantiate $C1 (with "T" (type $R))))
    (alias export $c1 "foo" (func $foo))
    (instance $c2 (instantiate $C2 (with "T" (type $R)) (with "foo" (func $foo))))))

(component
  (type $t (resource (rep i32)))
  (component $c
    (import "x" (type $t (sub resource)))
    (export "y" (type $t)))
  (instance $c1 (instantiate $c (with "x" (type $t))))
  (instance $c2 (instantiate $c (with "x" (type $t))))
  (component $c2
    (import "x1" (type $t (sub resource)))
    (import "x2" (type (eq $t)))
    (import "x3" (type (eq $t))))
  (instance (instantiate $c2
    (with "x1" (type $t))
    (with "x2" (type $c1 "y"))
    (with "x3" (type $c2 "y")))))

(component
  (component $C
    (import "in" (type $r (sub resource)))
    (export "out" (type $r)))
  (type $r (resource (rep i32)))
  (instance $c1 (instantiate $C (with "in" (type $r))))
  (instance $c2 (instantiate $C (with "in" (type $c1 "out"))))
  (instance $c3 (instantiate $C (with "in" (type $c2 "out"))))
  (instance $c4 (instantiate $C (with "in" (type $c3 "out"))))
  (instance $c5 (instantiate $C (with "in" (type $c4 "out"))))
  (instance $c6 (instantiate $C (with "in" (type $c5 "out"))))
  (component $Check
    (import "in1" (type $r (sub resource)))
    (import "in2" (type (eq $r)))
    (import "in3" (type (eq $r)))
    (import "in4" (type (eq $r)))
    (import "in5" (type (eq $r)))
    (import "in6" (type (eq $r))))
  (instance (instantiate $Check
    (with "in1" (type $r))
    (with "in2" (type $c1 "out"))
    (with "in3" (type $c2 "out"))
    (with "in4" (type $c3 "out"))
    (with "in5" (type $c4 "out"))
    (with "in6" (type $c5 "out")))))

;; kind and arity checks at type imports

(assert_invalid
  (component
    (component $c
      (import "x" (type (sub resource))))
    (type $x u32)
    (instance (instantiate $c (with "x" (type $x)))))
  "expected resource, found defined type")

(assert_invalid
  (component
    (component $c
      (type $t u32)
      (import "x" (type (eq $t))))
    (type $x (resource (rep i32)))
    (instance (instantiate $c (with "x" (type $x)))))
  "expected defined type, found resource")

(assert_invalid
  (component
    (component $c
      (import "x" (type (sub resource))))
    (instance (instantiate $c)))
  "missing import named `x`")

;; `own` and `borrow` require a resource type

(assert_invalid
  (component
    (type $x (own 100)))
  "type index out of bounds")

(assert_invalid
  (component
    (type $x (borrow 100)))
  "type index out of bounds")

(assert_invalid
  (component
    (type $t u8)
    (type $x (own $t)))
  "not a resource type")

(assert_invalid
  (component
    (type $t u8)
    (type $x (borrow $t)))
  "not a resource type")

;; `borrow` cannot appear in function results

(assert_invalid
  (component
    (type $R (resource (rep i32)))
    (type $F (func (result (borrow $R)))))
  "function result cannot contain a `borrow` type")

(assert_invalid
  (component
    (type $R (resource (rep i32)))
    (type $F (func (result (list (borrow $R))))))
  "function result cannot contain a `borrow` type")

(assert_invalid
  (component
    (type $R (resource (rep i32)))
    (type $F (func (result (option (borrow $R))))))
  "function result cannot contain a `borrow` type")

(assert_invalid
  (component
    (type $R (resource (rep i32)))
    (type $Rec (record (field "f" (borrow $R))))
    (type $F (func (result (option (list $Rec))))))
  "function result cannot contain a `borrow` type")

;; resources can only be defined in concrete components, not in component or
;; instance types

(assert_invalid
  (component
    (type $C (component
      (type $R (resource (rep i32))))))
  "resources can only be defined within a concrete component")

(assert_invalid
  (component
    (type $I (instance
      (type $R (resource (rep i32))))))
  "resources can only be defined within a concrete component")

;; destructors must be core functions of type [i32] -> []

(component
  (core module $M
    (func (export "dtor") (param i32)))
  (core instance $m (instantiate $M))
  (type $R (resource (rep i32) (dtor (core func $m "dtor"))))
  (core func (canon resource.new $R)))

(assert_invalid
  (component
    (core module $M
      (func (export "dtor")))
    (core instance $m (instantiate $M))
    (type $R (resource (rep i32) (dtor (core func $m "dtor")))))
  "wrong signature for a destructor")

(assert_invalid
  (component
    (type $R (resource (rep i32) (dtor (core func 100)))))
  "function index out of bounds")

;; canon resource built-ins require a resource type

(assert_invalid
  (component
    (type $T (tuple u32))
    (core func (canon resource.drop $T)))
  "not a resource type")

(assert_invalid
  (component
    (type $C (component))
    (core func (canon resource.new $C)))
  "not a resource type")

(assert_invalid
  (component
    (type $C (component))
    (core func (canon resource.drop $C)))
  "not a resource type")

(assert_invalid
  (component
    (core func (canon resource.drop 100)))
  "type index out of bounds")

;; canon resource.new/resource.rep additionally require a *local* resource type

(assert_invalid
  (component
    (import "T" (type $T (sub resource)))
    (core func (canon resource.new $T)))
  "not a local resource")

(assert_invalid
  (component
    (import "T" (type $T (sub resource)))
    (core func (canon resource.rep $T)))
  "not a local resource")

;; a resource aliased from a child instance's export is not local...
(assert_invalid
  (component
    (component $C
      (type $R (resource (rep i32)))
      (export "r" (type $R)))
    (instance $c (instantiate $C))
    (alias export $c "r" (type $R))
    (core func (canon resource.rep $R)))
  "not a local resource")

;; ...though it can still be dropped
(component
  (component $C
    (type $R (resource (rep i32)))
    (export "r" (type $R)))
  (instance $c (instantiate $C))
  (alias export $c "r" (type $R))
  (core func (canon resource.drop $R)))

;; ...and it stays local if the child's export is this component's own resource
;; threaded back through `with`
(component
  (type $R (resource (rep i32)))
  (component $C
    (import "x" (type $x (sub resource)))
    (export "y" (type $x)))
  (instance $c (instantiate $C (with "x" (type $R))))
  (alias export $c "y" (type $R2))
  (core func (canon resource.rep $R2)))

;; component-typed imports can use abstract resources in their imports and
;; exports

(component
  (component $C1
    (import "X" (type $X (sub resource)))
    (import "f" (func $f (result (own $X))))
    (export "g" (func $f)))
  (component $C2
    (import "C1" (component
      (import "X" (type $X (sub resource)))
      (import "f" (func (result (own $X))))
      (export "g" (func (result (own $X)))))))
  (instance $c (instantiate $C2 (with "C1" (component $C1)))))
