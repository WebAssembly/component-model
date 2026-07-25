;; Well-formedness of defined (value) types: label rules, non-emptiness, the
;; 32-flag limit, where a defined type is (and is not) allowed, and the sort
;; checks applied when a type index is ascribed to an import or export.

;; all primitive and compound defined types are well-formed, referenced by
;; index or inline, including error-only and empty result types

(component
  (type bool)
  (type u8) (type s8) (type u16) (type s16)
  (type u32) (type s32) (type u64) (type s64)
  (type f32) (type f64)
  (type char) (type string)

  (type $r (record (field "x" (result)) (field "y" string)))
  (type $u (variant (case "r" $r) (case "s" string)))
  (type $e (result $u (error u32)))
  (type (result $u))
  (type (result (error $u)))
  (type (result))
  (type (func (param "a" $e) (result (option $r))))

  (type $errno (enum "a" "b" "e"))
  (type (list $errno))
  (type $oflags (flags "read" "write" "exclusive"))
  (type (tuple $oflags $errno $r))
)

;; labels must be non-empty

(assert_invalid
  (component (type (record (field "" s32))))
  "record field name cannot be empty")
(assert_invalid
  (component (type (variant (case "" s32))))
  "variant case name cannot be empty")
(assert_invalid
  (component (type (flags "")))
  "flag name cannot be empty")
(assert_invalid
  (component (type (enum "")))
  "enum tag name cannot be empty")
(assert_invalid
  (component (type (func (param "" string))))
  "function parameter name cannot be empty")

;; labels must be unique, compared case-insensitively

(assert_invalid
  (component (type (record (field "a-B-c-D" string) (field "A-b-C-d" u8))))
  "record field name `A-b-C-d` conflicts with previous field name `a-B-c-D`")
(assert_invalid
  (component (type (variant (case "x" s64) (case "x" s64))))
  "variant case name `x` conflicts with previous case name `x`")
(assert_invalid
  (component (type (variant (case "x" s64) (case "X" s64))))
  "variant case name `X` conflicts with previous case name `x`")
(assert_invalid
  (component (type (flags "x" "y" "X")))
  "flag name `X` conflicts with previous flag name `x`")
(assert_invalid
  (component (type (enum "x" "y" "X")))
  "enum tag name `X` conflicts with previous tag name `x`")
(assert_invalid
  (component (type (func (param "foo" string) (param "FOO" u32))))
  "function parameter name `FOO` conflicts with previous parameter name `foo`")

;; labels must be in kebab case

(assert_invalid
  (component (type (enum "NevEr")))
  "enum tag name `NevEr` is not in kebab case")
(assert_invalid
  (component (type (record (field "GoNnA" string))))
  "record field name `GoNnA` is not in kebab case")
(assert_invalid
  (component (type (variant (case "GIVe" string))))
  "variant case name `GIVe` is not in kebab case")
(assert_invalid
  (component (type (func (param "yOu" string))))
  "function parameter name `yOu` is not in kebab case")

;; variant, enum, record, flags and tuple must be non-empty

(assert_invalid
  (component (type (variant)))
  "variant type must have at least one case")
(assert_invalid
  (component (type (enum)))
  "enum type must have at least one variant")
(assert_invalid
  (component (type (record)))
  "record type must have at least one field")
(assert_invalid
  (component (type (flags)))
  "flags must have at least one entry")
(assert_invalid
  (component (type (tuple)))
  "tuple type must have at least one type")

;; at most 32 flags

(component
  (type (flags
    "f1" "f2" "f3" "f4" "f5" "f6" "f7" "f8"
    "f9" "f10" "f11" "f12" "f13" "f14" "f15" "f16"
    "f17" "f18" "f19" "f20" "f21" "f22" "f23" "f24"
    "f25" "f26" "f27" "f28" "f29" "f30" "f31" "f32"))
)
(assert_invalid
  (component
    (type (flags
      "f1" "f2" "f3" "f4" "f5" "f6" "f7" "f8"
      "f9" "f10" "f11" "f12" "f13" "f14" "f15" "f16"
      "f17" "f18" "f19" "f20" "f21" "f22" "f23" "f24"
      "f25" "f26" "f27" "f28" "f29" "f30" "f31" "f32" "f33")))
  "cannot have more than 32 flags")

;; func, instance and component types are not defined (value) types

(assert_invalid
  (component
    (type $t (func))
    (type (func (param "t" $t))))
  "type index 0 is not a defined type")
(assert_invalid
  (component
    (type $t (instance))
    (type (func (result $t))))
  "type index 0 is not a defined type")
(assert_invalid
  (component
    (type $t (component))
    (type (option $t)))
  "type index 0 is not a defined type")

;; type indices inside defined types must be in bounds

(assert_invalid
  (component (type (option 0)))
  "type index out of bounds")
(assert_invalid
  (component (type (list 0)))
  "type index out of bounds")
(assert_invalid
  (component (type (record (field "x" 0))))
  "type index out of bounds")
(assert_invalid
  (component (type (variant (case "x" 0))))
  "type index out of bounds")
(assert_invalid
  (component (type (result 0 (error 1))))
  "type index out of bounds")
(assert_invalid
  (component (type (tuple 0)))
  "type index out of bounds")

;; indices ascribed to imports and exports or used by canon lift must also be
;; in bounds

(assert_invalid
  (component (import "a" (func (type 100))))
  "type index out of bounds")
(assert_invalid
  (component
    (core module $m (func (export "f")))
    (core instance $i (instantiate $m))
    (func (type 100) (canon lift (core func $i "f"))))
  "type index out of bounds")
(assert_invalid
  (component (export "a" (core module 0)))
  "module index out of bounds")
(assert_invalid
  (component (export "a" (instance 0)))
  "instance index out of bounds")

;; a type ascribed to a func import/export must be a function type

(assert_invalid
  (component
    (type $t (instance))
    (import "a" (func (type $t))))
  "type index 0 is not a function type")
(assert_invalid
  (component
    (type $t (instance))
    (core module $m (func (export "f")))
    (core instance $i (instantiate $m))
    (func $f (canon lift (core func $i "f")))
    (export "a" (func $f) (func (type $t))))
  "type index 0 is not a function type")
(assert_invalid
  (component
    (type $t (instance))
    (type (component
      (import "a" (func (type $t))))))
  "type index 0 is not a function type")
(assert_invalid
  (component
    (type $t (record (field "x" u8)))
    (type (instance
      (export "a" (func (type $t))))))
  "type index 0 is not a function type")
(assert_invalid
  (component
    (type $t (instance))
    (type (instance
      (export "a" (instance
        (export "b" (func (type $t))))))))
  "type index 0 is not a function type")

;; ...an instance import/export must be an instance type

(assert_invalid
  (component
    (type $t (func))
    (import "a" (instance (type $t))))
  "type index 0 is not an instance type")
(assert_invalid
  (component
    (type $t (func))
    (type (component
      (import "a" (instance (type $t))))))
  "type index 0 is not an instance type")
(assert_invalid
  (component
    (type $t (func))
    (type (instance
      (export "a" (instance (type $t))))))
  "type index 0 is not an instance type")

;; ...a core module import/export must be a core module type

(assert_invalid
  (component
    (core type $t (func))
    (import "a" (core module (type $t))))
  "core type index 0 is not a module type")
(assert_invalid
  (component
    (core type $t (func))
    (type (component
      (import "a" (core module (type $t))))))
  "core type index 0 is not a module type")
(assert_invalid
  (component
    (core type $t (func))
    (type (instance
      (export "a" (core module (type $t))))))
  "core type index 0 is not a module type")
