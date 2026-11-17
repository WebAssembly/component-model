(assert_invalid
  (component
    (core module $cm
      (func (export "one") (param i32) (result i32) (i32.const 1)))
    (core instance $ci (instantiate $cm))
    (type $t (resource (rep i32)))
    (export $et "t" (type $t)))
  "Cannot export type containing bare resource type")

(assert_invalid
  (component
    (core module $cm
      (func (export "one") (param i32) (result i32) (i32.const 1)))
    (core instance $ci (instantiate $cm))
    (type $t (resource (rep i32)))
    (export $et "t" (type $t) (type (sub resource)))
    (alias core export $ci "one" (core func $cf1))
    (canon lift $cf1 (func $f1 (param (own $t)) (result (own $t))))
    (export "one" (func $f1)))
  "Cannot export type containing bare resource type")

(assert_invalid
  (component $C
    (type $t (resource (rep i32)))
    (component
      (alias outer $C $t (type))))
  "Cannot export type containing bare resource type")

(assert_invalid
  (component $C
    (type $t (resource (rep i32)))
    (export $et "t" (type $t) (type (sub resource)))
    (component
      (alias outer $C $et (type))))
  "Cannot export type containing bare resource type")

(assert_invalid
  (component $C
    (import "t" (type $it (sub resource)))
    (component
      (alias outer $C $it (type))))
  "Outer alias may not refer to type variable")

(component $dt
  (core module $cm
    (func (export "one") (param i32) (result i32) (local.get 0)))
  (core instance $ci (instantiate $cm))
  (type $t (resource (rep i32)))
  (export $et "t" (type $t) (type (sub resource)))
  (alias core export $ci "one" (core func $cf1))
  (canon lift $cf1 (func $f1 (param (own $t)) (result (own $t))))
  (export "one" (func $f1) (func (param (own $et)) (result (own $et)))))

(component $use1
  (import "deftype" (instance $deftype
    (export "t" (type $et (sub resource)))
    (export "one" (func (param (own $et)) (result (own $et))))))
  (alias export $deftype "t" (type $det))
  (alias export $deftype "one" (func $f1))
  (canon lower $f1 (core func $cf1))
  (core module $cm
    (import "dt" "one" (func $one (param i32) (result i32)))
    (func (export "two") (param i32) (result i32) (local.get 0) (call $one)))
  (core instance $ci (instantiate $cm
    (with "dt" (instance (export "one" (func $cf1))))))
  (alias core export $ci "two" (core func $cf2))
  (canon lift $cf2 (func $f2 (param (own $det)) (result (own $det))))
  (export "two" (func $f2)))

(component
  (instance $deftype (instantiate $dt))
  (instance (instantiate $use1 (with "deftype" (instance $deftype)))))

(component $use2i
  (import "deftype" (instance $deftype
    (export "t" (type $et (sub resource)))
    (export "one" (func (param (own $et)) (result (own $et))))))
  (alias export $deftype "t" (type $det))
  (import "two" (instance $itwo
    (alias outer $use2i $det (type $iet))
    (export "two" (func (param (own $iet)) (result (own $iet)))))))

(component
  (instance $deftype (instantiate $dt))
  (instance $itwo (instantiate $use1 (with "deftype" (instance $deftype))))
  (instance (instantiate $use2i
    (with "deftype" (instance $deftype))
    (with "two" (instance $itwo)))))

(component $use2c
  (import "deftype" (instance $deftype
    (export "t" (type $et (sub resource)))
    (export "one" (func (param (own $et)) (result (own $et))))))
  (import "two" (component $ctwo
    (import "deftype" (instance $deftype
      (export "t" (type $et (sub resource)))
      (export "one" (func (param (own $et)) (result (own $et))))))
    (alias export $deftype "t" (type $det))
    (export "two" (func (param (own $det)) (result (own $det))))))
  (alias export $deftype "t" (type $det))
  (alias export $deftype "one" (func $f1))
  (instance $itwo (instantiate $ctwo
    (with "deftype" (instance $deftype))))
  (alias export $itwo "two" (func $f2))
  (export "one" (func $f1))
  (export "two" (func $f2))
  )

(component
  (instance $deftype (instantiate $dt))
  (instance (instantiate $use2c
    (with "deftype" (instance $deftype))
    (with "two" (component $use1)))))

(component $dt2
  (type $t1 (resource (rep i32)))
  (type $t2 (resource (rep i32)))
  (export $et1 "t1" (type $t1) (type (sub resource)))
  (export $et2 "t2" (type $t2) (type (sub resource)))
  (core module $cm
    (func (export "id") (param i32) (result i32) (local.get 0)))
  (core instance $ci (instantiate $cm))
  (alias core export $ci "id" (core func $cfid))
  (canon lift $cfid (func $fid1 (param (own $et1)) (result (own $et1))))
  (canon lift $cfid (func $fid2 (param (own $et2)) (result (own $et2))))
  (export "one" (func $fid1))
  (export "two" (func $fid2)))

(component $needs_dt2i
  (import "deftype" (component
    (export "t1" (type $t1 (sub resource)))
    (export "t2" (type $t2 (sub resource)))
    (export "one" (func (param (own $t1)) (result (own $t1))))
    (export "two" (func (param (own $t2)) (result (own $t2)))))))

(component
  (instance (instantiate $needs_dt2i
    (with "deftype" (component $dt2)))))

(component $needs_dt2i_backwards
  (import "deftype" (component
    (export "t1" (type $t1 (sub resource)))
    (export "t2" (type $t2 (sub resource)))
    (export "one" (func (param (own $t2)) (result (own $t2))))
    (export "two" (func (param (own $t1)) (result (own $t1)))))))

(assert_invalid
  (component
    (instance (instantiate $needs_dt2i_backwards
      (with "deftype" (component $dt2)))))
  "Type variable u0.0 is not u0.1")


(component $needs_two_imports_same
  (import "uses_types" (component
    (import "t1" (type $t1 (sub resource)))
    (import "t2" (type (eq $t1))))))

(component $needs_two_imports_different
  (import "uses_types" (component
    (import "t1" (type (sub resource)))
    (import "t2" (type (sub resource))))))

(component $two_imports_same
  (import "t1" (type $t1 (sub resource)))
  (import "t2" (type (eq $t1))))

(component $two_imports_different
  (import "t1" (type (sub resource)))
  (import "t2" (type (sub resource))))

(component
  (instance (instantiate $needs_two_imports_different
    (with "uses_types" (component $two_imports_different)))))

(assert_invalid
  (component
    (instance (instantiate $needs_two_imports_different
      (with "uses_types" (component $two_imports_same)))))
  "Type variable u0.0 is not u0.1")

(component
  (instance (instantiate $needs_two_imports_same
    (with "uses_types" (component $two_imports_different)))))

(component
  (instance (instantiate $needs_two_imports_same
    (with "uses_types" (component $two_imports_same)))))

(component $needs_exports_shared
  (import "deftype" (component
    (export "t1" (type $t (sub resource)))
    (export "t2" (type (eq $t))))))

(component $exports_shared
  (type $t (resource (rep i32)))
  (export $t1 "t1" (type $t) (type (sub resource)))
  (export "t2" (type $t) (type (eq $t1))))

(component
  (instance (instantiate $needs_exports_shared
    (with "deftype" (component $exports_shared)))))

(component $exports_shared_reverse
  (type $t (resource (rep i32)))
  (export $t2 "t2" (type $t) (type (sub resource)))
  (export "t1" (type $t) (type (eq $t2))))

(component
  (instance (instantiate $needs_exports_shared
    (with "deftype" (component $exports_shared_reverse)))))

(component $exports_not_shared
  (type $t (resource (rep i32)))
  (export "t1" (type $t) (type (sub resource)))
  (export "t2" (type $t) (type (sub resource))))

(assert_invalid
  (component
    (instance (instantiate $needs_exports_shared
      (with "deftype" (component $exports_not_shared)))))
  "Type variable u0.0 is not u0.1")

(component
  (import "in" (component $in
    (export "t" (type (sub resource)))))
  (instance $ii (instantiate $in)))

(assert_invalid
  (component
    (import "in" (component $in
      (export "t" (type (sub resource)))))
    (instance $ii (instantiate $in))
    (alias export $ii "t" (type $t))
    (export "t" (type $t)))
  "Component type may not refer to non-imported uvar")

(assert_invalid
  (component
    (import "in" (component $in
      (export "t" (type $t (sub resource)))
      (export "f" (func (param (own $t)) (result (own $t))))))
    (instance $ii (instantiate $in))
    (alias export $ii "f" (func $f))
    (export "f" (func $f)))
  "Component type may not refer to non-imported uvar")

(assert_invalid
  (component
    (import "in" (component $in
      (export "i2" (instance
        (export "t" (type (sub resource)))))))
    (instance $ii (instantiate $in))
    (alias export $ii "i2" (instance $i2))
    (export "i2" (instance $i2)))
  "Component type may not refer to non-imported uvar")

(component
  (type $t (resource (rep i32)))
  (canon resource.new $t (core func $tnew))
  (canon resource.drop (own $t) (core func $tdrop))
  (canon resource.rep $t (core func $trep))
  (core module $cm
    (import "t" "new" (func (param i32) (result i32)))
    (import "t" "drop" (func (param i32)))
    (import "t" "rep" (func (param i32) (result i32))))
  (core instance (instantiate $cm
    (with "t" (instance
      (export "new" (func $tnew))
      (export "drop" (func $tdrop))
      (export "rep" (func $trep)))))))
