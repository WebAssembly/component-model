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
    (func $f (result (option (own $R))) (canon lift (core func $i "f") (memory (core memory $i "mem"))))
    (export "f" (func $f)))
  "func not valid to be used as export")

(assert_invalid
  (component
    (core module $m
      (memory (export "mem") 1)
      (func (export "f") (result i32) unreachable))
    (core instance $i (instantiate $m))
    (type $Rec (record (field "x" u32)))
    (func $f (result (tuple $Rec u32)) (canon lift (core func $i "f") (memory (core memory $i "mem"))))
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

;; direct type exports: anonymous structural types need no name

(component definition
  (type $T1 (tuple (tuple u32)))
  (export "t1" (type $T1))
  (type $T2 (option (tuple (list u8) (result (list u32) (error (option string))))))
  (export "t2" (type $T2))
  (type $T3 u32)
  (export "t3" (type $T3)))

;; ...but a named type referenced by an exported type must itself be
;; exported first, whatever position it's referenced from

(assert_invalid
  (component
    (type $Rec (record (field "x" u32)))
    (type $Rec2 (record (field "r" $Rec)))
    (export "t" (type $Rec2)))
  "type not valid to be used as export")

(assert_invalid
  (component
    (type $Rec (record (field "x" u32)))
    (type $L (list $Rec))
    (export "t" (type $L)))
  "type not valid to be used as export")

(assert_invalid
  (component
    (type $Rec (record (field "x" u32)))
    (type $T (tuple $Rec))
    (export "t" (type $T)))
  "type not valid to be used as export")

(assert_invalid
  (component
    (type $Rec (record (field "x" u32)))
    (type $V (variant (case "c" $Rec)))
    (export "t" (type $V)))
  "type not valid to be used as export")

(assert_invalid
  (component
    (type $Rec (record (field "x" u32)))
    (type $O (option $Rec))
    (export "t" (type $O)))
  "type not valid to be used as export")

(assert_invalid
  (component
    (type $Rec (record (field "x" u32)))
    (type $Res (result $Rec))
    (export "t" (type $Res)))
  "type not valid to be used as export")

;; every nameable kind (not just records) needs a name

(assert_invalid
  (component
    (type $E (enum "a"))
    (type $L (list $E))
    (export "t" (type $L)))
  "type not valid to be used as export")

(assert_invalid
  (component
    (type $Fl (flags "a"))
    (type $L (list $Fl))
    (export "t" (type $L)))
  "type not valid to be used as export")

(assert_invalid
  (component
    (type $V (variant (case "a")))
    (type $L (list $V))
    (export "t" (type $L)))
  "type not valid to be used as export")

(assert_invalid
  (component
    (type $R (resource (rep i32)))
    (type $L (list (own $R)))
    (export "t" (type $L)))
  "type not valid to be used as export")

;; type imports enforce the same restrictions; importing the inner type first
;; makes it valid

(component definition
  (type $Rec (record (field "x" u32)))
  (import "rec" (type $Rec' (eq $Rec)))
  (type $Rec2 (record (field "r" $Rec')))
  (import "t" (type (eq $Rec2))))

(assert_invalid
  (component
    (type $Rec (record (field "x" u32)))
    (type $Rec2 (record (field "r" $Rec)))
    (import "t" (type (eq $Rec2))))
  "type not valid to be used as import")

;; an instance type containing an unexportable type export is definable, but
;; not usable as a type import or export; same for func types

(component definition
  (type (instance
    (type $Rec (record (field "x" u32)))
    (type $Rec2 (record (field "r" $Rec)))
    (export "t" (type (eq $Rec2))))))

(assert_invalid
  (component
    (type $I (instance
      (type $Rec (record (field "x" u32)))
      (type $Rec2 (record (field "r" $Rec)))
      (export "t" (type (eq $Rec2)))))
    (import "i" (type (eq $I))))
  "type not valid to be used as import")

(assert_invalid
  (component
    (type $I (instance
      (type $Rec (record (field "x" u32)))
      (type $Rec2 (record (field "r" $Rec)))
      (export "t" (type (eq $Rec2)))))
    (export "i" (type $I)))
  "type not valid to be used as export")

(assert_invalid
  (component
    (type $Rec (record (field "x" u32)))
    (type $F (func (result $Rec)))
    (import "f" (type (eq $F))))
  "type not valid to be used as import")

(assert_invalid
  (component
    (type $Rec (record (field "x" u32)))
    (type $F (func (result $Rec)))
    (export "f" (type $F)))
  "type not valid to be used as export")

;; instance types defer visibility validation until attached to a concrete
;; import or export; component types validate eagerly

(component definition
  (type (instance
    (type $Rec (record (field "x" u32)))
    (export "f" (func (param "x" $Rec))))))

(assert_invalid
  (component
    (type $I (instance
      (type $Rec (record (field "x" u32)))
      (type $Rec2 (record (field "r" $Rec)))
      (export "t" (type (eq $Rec2)))))
    (import "i" (instance (type $I))))
  "instance not valid to be used as import")

(assert_invalid
  (component
    (type (component
      (type $Rec (record (field "x" u32)))
      (export "f" (func (param "x" $Rec))))))
  "func not valid to be used as export")

(assert_invalid
  (component
    (type (component
      (type $Rec (record (field "x" u32)))
      (type $Rec2 (record (field "r" $Rec)))
      (export "t" (type (eq $Rec2))))))
  "type not valid to be used as export")

;; within a component type, an import may not reference a preceding export's
;; resource
(assert_invalid
  (component
    (type (component
      (export "r" (type $R (sub resource)))
      (import "f" (func (result (own $R)))))))
  "func not valid to be used as import")

;; a local unexported synthesized instance may export unexportable types
(component definition
  (type $Rec (record (field "x" u32)))
  (type $Rec2 (record (field "r" $Rec)))
  (instance (export "t" (type $Rec2))))

;; aliasing a type through an exported instance confers a name; aliasing out
;; of an unexported synthesized instance or an instantiated child does not

(component definition
  (core module $m (func (export "f") (param i32)))
  (core instance $i (instantiate $m))
  (type $Rec (record (field "x" u32)))
  (instance $bag (export "t" (type $Rec)))
  (export $bag' "i" (instance $bag))
  (alias export $bag' "t" (type $Rec'))
  (func $f (param "r" $Rec') (canon lift (core func $i "f")))
  (export "f" (func $f)))

(component definition
  (core module $m (func (export "f") (param i32)))
  (core instance $i (instantiate $m))
  (component $C
    (type $Rec (record (field "x" u32)))
    (export "t" (type $Rec)))
  (instance $c (instantiate $C))
  (export $c' "i" (instance $c))
  (alias export $c' "t" (type $Rec))
  (func $f (param "r" $Rec) (canon lift (core func $i "f")))
  (export "f" (func $f)))

(assert_invalid
  (component
    (core module $m (func (export "f") (param i32)))
    (core instance $i (instantiate $m))
    (type $Rec (record (field "x" u32)))
    (instance $bag (export "t" (type $Rec)))
    (alias export $bag "t" (type $Rec'))
    (func $f (param "r" $Rec') (canon lift (core func $i "f")))
    (export "f" (func $f)))
  "func not valid to be used as export")

(assert_invalid
  (component
    (core module $m (func (export "f") (param i32)))
    (core instance $i (instantiate $m))
    (component $C
      (type $Rec (record (field "x" u32)))
      (export "t" (type $Rec)))
    (instance $c (instantiate $C))
    (alias export $c "t" (type $Rec))
    (func $f (param "r" $Rec) (canon lift (core func $i "f")))
    (export "f" (func $f)))
  "func not valid to be used as export")

;; re-exporting an instance aliased from a child does not confer visibility on
;; the types referenced by the instance's exports
(assert_invalid
  (component
    (component $A
      (core module $m (func (export "f") (result i32) unreachable))
      (core instance $i (instantiate $m))
      (type $Rec (record (field "x" u32)))
      (export $Rec' "t" (type $Rec))
      (func $f (result $Rec') (canon lift (core func $i "f")))
      (instance $bag (export "f" (func $f)))
      (export "i" (instance $bag)))
    (instance $a (instantiate $A))
    ;; only "i" is re-exported here, not the record type "t" behind it
    (export "i2" (instance $a "i")))
  "instance not valid to be used as export")

;; visibility threads through instantiation plus re-export of the child's
;; exported type
(component definition
  (type $Rec (record (field "x" u32)))
  (import "t" (type $Rec' (eq $Rec)))
  (component $C
    (type $Rec (record (field "x" u32)))
    (import "t" (type $Rec' (eq $Rec)))
    (type $Rec2 (record (field "r" $Rec')))
    (export "t2" (type $Rec2)))
  (instance $c (instantiate $C (with "t" (type $Rec'))))
  (export "t2" (type $c "t2")))

;; outer-aliased types imported/exported only in the parent confer no
;; visibility in the child

(assert_invalid
  (component
    (type $Rec (record (field "x" u32)))
    (import "t" (type $Rec' (eq $Rec)))
    (component
      (import "f" (func (result $Rec')))))
  "func not valid to be used as import")

(assert_invalid
  (component
    (type $Rec (record (field "x" u32)))
    (export $Rec' "t" (type $Rec))
    (component
      (core module $m (func (export "f") (result i32) unreachable))
      (core instance $i (instantiate $m))
      (func $f (result $Rec') (canon lift (core func $i "f")))
      (export "f" (func $f))))
  "func not valid to be used as export")

;; bags-of-exports count as "explicit in" for resources: synthesized,
;; transitive, instantiated, or threaded through nested instance-typed imports

(component definition
  (type $R (resource (rep i32)))
  (instance $bag (export "r" (type $R)))
  (export $bag' "i" (instance $bag))
  (alias export $bag' "r" (type $R'))
  (core func $drop (canon resource.drop $R'))
  (func $f (param "x" (own $R')) (canon lift (core func $drop)))
  (export "f" (func $f)))

(component definition
  (type $R (resource (rep i32)))
  (instance $bag (export "r" (type $R)))
  (instance $bag2 (export "i" (instance $bag)))
  (export $bag2' "i2" (instance $bag2))
  (alias export $bag2' "i" (instance $i))
  (alias export $i "r" (type $R'))
  (core func $drop (canon resource.drop $R'))
  (func $f (param "x" (own $R')) (canon lift (core func $drop)))
  (export "f" (func $f)))

(component definition
  (type $R (resource (rep i32)))
  (component $C
    (import "x" (type $X (sub resource)))
    (export "y" (type $X)))
  (instance $c (instantiate $C (with "x" (type $R))))
  (export $c' "c" (instance $c))
  (alias export $c' "y" (type $R'))
  (core func $drop (canon resource.drop $R'))
  (func $f (param "x" (own $R')) (canon lift (core func $drop)))
  (export "f" (func $f)))

(component definition
  (type $R (resource (rep i32)))
  (component $C
    (import "x" (type $X (sub resource)))
    (export "y" (type $X)))
  (instance $c (instantiate $C (with "x" (type $R))))
  (instance $ix (export "x" (type $c "y")))
  (component $C2
    (import "x" (instance $i
      (export "i1" (instance
        (export "i2" (type (sub resource)))))))
    (export "y" (type $i "i1" "i2")))
  (instance $i2 (export "i2" (type $ix "x")))
  (instance $i1 (export "i1" (instance $i2)))
  (instance $c2 (instantiate $C2 (with "x" (instance $i1))))
  (export $R' "r" (type $c2 "y"))
  (core func $drop (canon resource.drop $R'))
  (func $f (param "x" (own $R')) (canon lift (core func $drop)))
  (export "f" (func $f)))

(component definition
  (type $R (resource (rep i32)))
  (component $C
    (import "x" (instance $x (export "t" (type (sub resource)))))
    (export "y" (instance $x)))
  (instance $c (instantiate $C
    (with "x" (instance (export "t" (type $R))))))
  (export $c' "c" (instance $c))
  (alias export $c' "y" (instance $y))
  (alias export $y "t" (type $R'))
  (core func $drop (canon resource.drop $R'))
  (func $f (param "x" (own $R')) (canon lift (core func $drop)))
  (export "f" (func $f)))

;; export ascription is a one-directional subtype check: forgetting exports is
;; an allowed up-cast, adding them is not

(component definition
  (core module $m (func (export "f")))
  (core instance $i (instantiate $m))
  (func $f (canon lift (core func $i "f")))
  (instance $inst (export "f" (func $f)))
  (export "f2" (instance $inst) (instance)))

(assert_invalid
  (component
    (import "f" (instance $i))
    (export "f2" (instance $i) (instance (export "f" (func)))))
  "ascribed type of export is not compatible")

;; ascription replaces the visible type: the export ascribed to an empty
;; instance no longer satisfies a consumer requiring "f"
(assert_invalid
  (component
    (import "f" (func $f))
    (component $C
      (import "f" (instance $i (export "f" (func))))
      (export "f2" (instance $i) (instance)))
    (instance $c (instantiate $C (with "f" (instance (export "f" (func $f))))))
    (component $Consume
      (import "arg" (instance (export "f" (func)))))
    (instance (instantiate $Consume (with "arg" (instance $c "f2")))))
  "missing expected export `f`")
