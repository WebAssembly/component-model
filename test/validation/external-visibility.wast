;; Tests Explainer.md#external-visibility-of-types

;; resources

(component definition
  (core module $m (func (export "f") (result i32) unreachable))
  (core instance $i (instantiate $m))
  (type $R (resource (rep i32)))
  (func $f (result (own $R)) (canon lift (core func $i "f")))
  (export $R' "r" (type $R))
  (export "f" (func $f) (func (result (own $R'))))
  (func $f2 (result (own $R')) (canon lift (core func $i "f")))
  (export "f2" (func $f2))
  (import "r2" (type $R2 (sub resource)))
  (import "f3" (func $f3 (result (own $R2))))
  (func $f4 (result (own $R2)) (canon lift (core func $i "f")))
  (export "f4" (func $f4)))

(assert_invalid
  (component
    (core module $m (func (export "f") (result i32) unreachable))
    (core instance $i (instantiate $m))
    (type $R (resource (rep i32)))
    (func $f (result (own $R)) (canon lift (core func $i "f")))
    (export "f" (func $f)))
  "func not valid to be used as export")

(assert_invalid
  (component
    (core module $m (func (export "f") (result i32) unreachable))
    (core instance $i (instantiate $m))
    (type $R (resource (rep i32)))
    (func $f (result (own $R)) (canon lift (core func $i "f")))
    (export $R' "r" (type $R))
    (export "f" (func $f)))
  "func not valid to be used as export")

(assert_invalid
  (component
    (type $R (resource (rep i32)))
    (export $R' "r" (type $R))
    (import "f" (func (result (own $R')))))
  "func not valid to be used as import")

(assert_invalid
  (component
    (type $R (resource (rep i32)))
    (import "f" (func (result (own $R)))))
  "func not valid to be used as import")

;; records

(component definition
  (core module $m (func (export "f") (result i32) unreachable))
  (core instance $i (instantiate $m))
  (type $Rec (record (field "x" u32)))
  (func $f (result $Rec) (canon lift (core func $i "f")))
  (export $Rec' "rec" (type $Rec))
  (export "f" (func $f) (func (result $Rec'))))

(assert_invalid
  (component
    (core module $m (func (export "f") (result i32) unreachable))
    (core instance $i (instantiate $m))
    (type $Rec (record (field "x" u32)))
    (func $f (result $Rec) (canon lift (core func $i "f")))
    (export "f" (func $f)))
  "func not valid to be used as export")

(assert_invalid
  (component
    (core module $m (func (export "f") (result i32) unreachable))
    (core instance $i (instantiate $m))
    (type $Rec (record (field "x" u32)))
    (func $f (result $Rec) (canon lift (core func $i "f")))
    (export $Rec' "rec" (type $Rec))
    (export "f" (func $f)))
  "func not valid to be used as export")

(component definition
  (core module $m (func (export "f") (result i32) unreachable))
  (core instance $i (instantiate $m))
  (type $R (resource (rep i32)))
  (export $R' "r" (type $R))
  (type $Rec (record (field "r" (own $R'))))
  (export $Rec' "rec" (type $Rec))
  (func $f (result $Rec') (canon lift (core func $i "f")))
  (export "f" (func $f)))

(assert_invalid
  (component
    (core module $m (func (export "f") (result i32) unreachable))
    (core instance $i (instantiate $m))
    (type $R (resource (rep i32)))
    (type $Rec (record (field "r" (own $R))))
    (export $Rec' "rec" (type $Rec))
    (func $f (result $Rec') (canon lift (core func $i "f")))
    (export "f" (func $f)))
  "type not valid to be used as export")

;; enums

(component definition
  (core module $m (func (export "f") (result i32) unreachable))
  (core instance $i (instantiate $m))
  (type $E (enum "a" "b"))
  (func $f (result $E) (canon lift (core func $i "f")))
  (export $E' "e" (type $E))
  (export "f" (func $f) (func (result $E'))))

(assert_invalid
  (component
    (core module $m (func (export "f") (result i32) unreachable))
    (core instance $i (instantiate $m))
    (type $E (enum "a" "b"))
    (func $f (result $E) (canon lift (core func $i "f")))
    (export "f" (func $f)))
  "func not valid to be used as export")

;; flags

(component definition
  (core module $m (func (export "f") (result i32) unreachable))
  (core instance $i (instantiate $m))
  (type $Fl (flags "a" "b"))
  (func $f (result $Fl) (canon lift (core func $i "f")))
  (export $Fl' "fl" (type $Fl))
  (export "f" (func $f) (func (result $Fl'))))

(assert_invalid
  (component
    (core module $m (func (export "f") (result i32) unreachable))
    (core instance $i (instantiate $m))
    (type $Fl (flags "a" "b"))
    (func $f (result $Fl) (canon lift (core func $i "f")))
    (export "f" (func $f)))
  "func not valid to be used as export")

;; variants

(component definition
  (core module $m (func (export "f") (result i32) unreachable))
  (core instance $i (instantiate $m))
  (type $V (variant (case "a") (case "b")))
  (func $f (result $V) (canon lift (core func $i "f")))
  (export $V' "v" (type $V))
  (export "f" (func $f) (func (result $V'))))

(assert_invalid
  (component
    (core module $m (func (export "f") (result i32) unreachable))
    (core instance $i (instantiate $m))
    (type $V (variant (case "a") (case "b")))
    (func $f (result $V) (canon lift (core func $i "f")))
    (export "f" (func $f)))
  "func not valid to be used as export")

;; tuples/options

(component definition
  (core module $m (func (export "f") (param i32 i32 i32 i32)))
  (core instance $i (instantiate $m))
  (func $f (param "a" (tuple u32 u32)) (param "b" (option u32))
    (canon lift (core func $i "f")))
  (export "f" (func $f)))

(assert_invalid
  (component
    (core module $m (func (export "f") (result i32) unreachable))
    (core instance $i (instantiate $m))
    (type $R (resource (rep i32)))
    (func $f (result (tuple (own $R))) (canon lift (core func $i "f")))
    (export "f" (func $f)))
  "func not valid to be used as export")

(component definition
  (core module $m (func (export "f") (result i32) unreachable))
  (core instance $i (instantiate $m))
  (type $R (resource (rep i32)))
  (export $R' "r" (type $R))
  (func $f (result (tuple (own $R'))) (canon lift (core func $i "f")))
  (export "f" (func $f)))

(assert_invalid
  (component
    (core module $m
      (memory (export "mem") 1)
      (func (export "f") (result i32) unreachable))
    (core instance $i (instantiate $m))
    (type $R (resource (rep i32)))
    (func $f (result (option (own $R))) (canon lift (core func $i "f") (memory $i "mem")))
    (export "f" (func $f)))
  "func not valid to be used as export")

(assert_invalid
  (component
    (core module $m
      (memory (export "mem") 1)
      (func (export "f") (result i32) unreachable))
    (core instance $i (instantiate $m))
    (type $Rec (record (field "x" u32)))
    (func $f (result (tuple $Rec u32)) (canon lift (core func $i "f") (memory $i "mem")))
    (export "f" (func $f)))
  "func not valid to be used as export")

;; bag-of-exports:

(assert_invalid
  (component
    (core module $m (func (export "f") (result i32) unreachable))
    (core instance $i (instantiate $m))
    (type $R (resource (rep i32)))
    (func $f (result (own $R)) (canon lift (core func $i "f")))
    (instance $bag (export "f" (func $f)))
    (export "bag" (instance $bag)))
  "instance not valid to be used as export")
