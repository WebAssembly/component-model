;; Instantiation-time type checking: matching `with` arguments against the
;; instantiated component's or core module's declared imports, and validating
;; synthesized (bag-of-exports) instances.

;; type arguments must structurally match `eq`-bounded type imports

(component
  (type $t (tuple u32 u32))
  (component $c
    (type $t (tuple u32 u32))
    (import "x" (type (eq $t))))
  (instance (instantiate $c (with "x" (type $t)))))

(assert_invalid
  (component
    (component $c
      (type $t (tuple u32 u32))
      (import "x" (type (eq $t))))
    (type $x (tuple string string))
    (instance (instantiate $c (with "x" (type $x)))))
  "expected primitive `u32` found primitive `string`")

(assert_invalid
  (component
    (component $c
      (type $t u32)
      (import "x" (type (eq $t))))
    (type $x (record (field "f" u32)))
    (instance (instantiate $c (with "x" (type $x)))))
  "expected primitive, found record")

(assert_invalid
  (component
    (component $c
      (type $t (record (field "f" u32)))
      (import "x" (type (eq $t))))
    (type $x u32)
    (instance (instantiate $c (with "x" (type $x)))))
  "expected record, found u32")

(assert_invalid
  (component
    (component $c
      (type $t (record (field "x" u32)))
      (import "x" (type (eq $t))))
    (type $f (tuple u8))
    (type $x (record (field "x" $f)))
    (instance (instantiate $c (with "x" (type $x)))))
  "expected u32, found tuple")

(assert_invalid
  (component
    (component $c
      (type $f (option s32))
      (type $t (record (field "x" $f)))
      (import "x" (type (eq $t))))
    (type $x (record (field "x" u32)))
    (instance (instantiate $c (with "x" (type $x)))))
  "type mismatch in record field `x`")

(assert_invalid
  (component
    (component $c
      (type $t (record (field "x" u32)))
      (import "x" (type (eq $t))))
    (type $x (record (field "y" u32) (field "z" u64)))
    (instance (instantiate $c (with "x" (type $x)))))
  "expected 1 fields, found 2")

(assert_invalid
  (component
    (component $c
      (type $t (record (field "a" u32)))
      (import "x" (type (eq $t))))
    (type $x (record (field "b" u32)))
    (instance (instantiate $c (with "x" (type $x)))))
  "expected field name `a`, found `b`")

(assert_invalid
  (component
    (component $c
      (type $t (variant (case "x" u32)))
      (import "x" (type (eq $t))))
    (type $x (variant (case "x" u32) (case "y" u32)))
    (instance (instantiate $c (with "x" (type $x)))))
  "expected 1 cases, found 2")

(assert_invalid
  (component
    (component $c
      (type $t (variant (case "x" u32)))
      (import "x" (type (eq $t))))
    (type $x (variant (case "y" u32)))
    (instance (instantiate $c (with "x" (type $x)))))
  "expected case named `x`, found `y`")

(assert_invalid
  (component
    (component $c
      (type $t (variant (case "x" u32)))
      (import "x" (type (eq $t))))
    (type $x (variant (case "x")))
    (instance (instantiate $c (with "x" (type $x)))))
  "expected case `x` to have a type, found none")

(assert_invalid
  (component
    (component $c
      (type $t (variant (case "x")))
      (import "x" (type (eq $t))))
    (type $x (variant (case "x" u32)))
    (instance (instantiate $c (with "x" (type $x)))))
  "expected case `x` to have no type")

(assert_invalid
  (component
    (component $c
      (type $t (variant (case "x" u32)))
      (import "x" (type (eq $t))))
    (type $x (variant (case "x" s32)))
    (instance (instantiate $c (with "x" (type $x)))))
  "type mismatch in variant case `x`")

(assert_invalid
  (component
    (component $c
      (type $t (tuple u8))
      (import "x" (type (eq $t))))
    (type $x (tuple u32 u32))
    (instance (instantiate $c (with "x" (type $x)))))
  "expected 1 types, found 2")

(assert_invalid
  (component
    (component $c
      (type $t (tuple u8))
      (import "x" (type (eq $t))))
    (type $x (tuple u16))
    (instance (instantiate $c (with "x" (type $x)))))
  "type mismatch in tuple field 0")

(assert_invalid
  (component
    (component $c
      (type $t (flags "a"))
      (import "x" (type (eq $t))))
    (type $x (flags "x"))
    (instance (instantiate $c (with "x" (type $x)))))
  "mismatch in flags elements")

(assert_invalid
  (component
    (component $c
      (type $t (enum "a"))
      (import "x" (type (eq $t))))
    (type $x (enum "x"))
    (instance (instantiate $c (with "x" (type $x)))))
  "mismatch in enum elements")

(assert_invalid
  (component
    (component $c
      (type $t (result s32))
      (import "x" (type (eq $t))))
    (type $x (result u32))
    (instance (instantiate $c (with "x" (type $x)))))
  "type mismatch in ok variant")

(assert_invalid
  (component
    (component $c
      (type $t (result (error s32)))
      (import "x" (type (eq $t))))
    (type $x (result (error u32)))
    (instance (instantiate $c (with "x" (type $x)))))
  "type mismatch in err variant")

(assert_invalid
  (component
    (component $c
      (type $t (result))
      (import "x" (type (eq $t))))
    (type $x (result u32))
    (instance (instantiate $c (with "x" (type $x)))))
  "expected ok type to not be present")

(assert_invalid
  (component
    (component $c
      (type $t (result u32))
      (import "x" (type (eq $t))))
    (type $x (result))
    (instance (instantiate $c (with "x" (type $x)))))
  "expected ok type, but found none")

(assert_invalid
  (component
    (component $c
      (type $t (result))
      (import "x" (type (eq $t))))
    (type $x (result (error u32)))
    (instance (instantiate $c (with "x" (type $x)))))
  "expected err type to not be present")

(assert_invalid
  (component
    (component $c
      (type $t (result (error u32)))
      (import "x" (type (eq $t))))
    (type $x (result))
    (instance (instantiate $c (with "x" (type $x)))))
  "expected err type, but found none")


;; function arguments must match the imported function type exactly,
;; including parameter names

(component definition
  (import "f" (func $f (param "x" u32) (result u32)))
  (component $c (import "f" (func (param "x" u32) (result u32))))
  (instance (instantiate $c (with "f" (func $f)))))

(assert_invalid
  (component
    (import "f" (func $f (result string)))
    (component $c (import "f" (func)))
    (instance (instantiate $c (with "f" (func $f)))))
  "expected a result, found none")

(assert_invalid
  (component
    (import "f" (func $f (param "x" string)))
    (component $c (import "f" (func)))
    (instance (instantiate $c (with "f" (func $f)))))
  "expected 0 parameters, found 1")

(assert_invalid
  (component
    (import "f" (func $f (param "x" u32)))
    (component $c (import "f" (func (param "y" u32))))
    (instance (instantiate $c (with "f" (func $f)))))
  "expected parameter named `y`, found `x`")

(assert_invalid
  (component
    (import "f" (func $f (param "x" u32)))
    (component $c (import "f" (func (param "x" s32))))
    (instance (instantiate $c (with "f" (func $f)))))
  "type mismatch in function parameter `x`")

(assert_invalid
  (component
    (import "f" (func $f (result u32)))
    (component $c (import "f" (func (result s32))))
    (instance (instantiate $c (with "f" (func $f)))))
  "type mismatch with result type")


;; instance arguments are checked export-by-export, including the sort; extra
;; exports beyond the imported instance type are allowed

(component definition
  (import "i" (instance $i
    (export "a" (func))
    (export "b" (func))))
  (component $c (import "i" (instance (export "a" (func)))))
  (instance (instantiate $c (with "i" (instance $i)))))

(assert_invalid
  (component
    (import "i" (instance $i (export "a" (func))))
    (component $c (import "i" (instance (export "a" (component)))))
    (instance (instantiate $c (with "i" (instance $i)))))
  "type mismatch in instance export `a`")


;; core module arguments are checked by core subtyping: imports
;; contravariantly (the supplied module may import less) and exports
;; covariantly (it may export more)

(component
  (core module $m (import "" "g" (global i32)))
  (component $c
    (import "m" (core module
      (import "" "g" (global i32))
      (import "" "f" (func)))))
  (instance (instantiate $c (with "m" (core module $m)))))

(component
  (core module $m
    (func (export "f"))
    (global (export "g") i32 (i32.const 0)))
  (component $c
    (import "m" (core module (export "f" (func)))))
  (instance (instantiate $c (with "m" (core module $m)))))

(assert_invalid
  (component
    (core module $m (import "" "f" (global i32)))
    (component $c
      (import "m" (core module (import "" "f" (func)))))
    (instance (instantiate $c (with "m" (core module $m)))))
  "type mismatch in import `::f`")

(assert_invalid
  (component
    (core module $m (import "" "extra" (global i32)))
    (component $c
      (import "m" (core module)))
    (instance (instantiate $c (with "m" (core module $m)))))
  "missing expected import `::extra`")

(assert_invalid
  (component
    (core module $m)
    (component $c
      (import "m" (core module (export "x" (func)))))
    (instance (instantiate $c (with "m" (core module $m)))))
  "missing expected export `x`")

(assert_invalid
  (component
    (core module $m (func (export "g")))
    (component $c
      (import "m" (core module (export "g" (global i32)))))
    (instance (instantiate $c (with "m" (core module $m)))))
  "type mismatch in export `g`")

;; table/memory limits are covariant on the export side and contravariant on
;; the import side

(component
  (core module $m
    (import "" "t" (table 1 funcref))
    (table (export "x") 2 funcref))
  (component $c
    (import "m" (core module
      (import "" "t" (table 2 funcref))
      (export "x" (table 1 funcref)))))
  (instance (instantiate $c (with "m" (core module $m)))))

(component
  (core module $m
    (import "" "m" (memory 1))
    (memory (export "x") 2))
  (component $c
    (import "m" (core module
      (import "" "m" (memory 2))
      (export "x" (memory 1)))))
  (instance (instantiate $c (with "m" (core module $m)))))


;; core instance arguments: each two-level import is looked up in the instance
;; supplied for its module name and checked by core subtyping, including sort

(assert_invalid
  (component
    (core module $m1 (import "" "f" (func)))
    (core module $m2 (func (export "f") (param i32)))
    (core instance $i (instantiate $m2))
    (core instance (instantiate $m1 (with "" (instance $i)))))
  "expected: (func)")

(assert_invalid
  (component
    (core module $m1 (import "" "f" (func)))
    (core module $m2 (func (export "f") (result i32) (i32.const 0)))
    (core instance $i (instantiate $m2))
    (core instance (instantiate $m1 (with "" (instance $i)))))
  "expected: (func)")

(assert_invalid
  (component
    (core module $m1 (import "" "f" (func)))
    (core module $m2 (func (export "g") (param i32)))
    (core instance $i (instantiate $m2))
    (core instance (instantiate $m1
      (with "" (instance (export "f" (func $i "g")))))))
  "expected: (func)")

(assert_invalid
  (component
    (core module $m1 (import "" "g" (global i32)))
    (core module $m2 (global (export "g") i64 (i64.const 0)))
    (core instance $i (instantiate $m2))
    (core instance (instantiate $m1 (with "" (instance $i)))))
  "expected global type i32, found i64")

(assert_invalid
  (component
    (core module $m1 (import "" "t" (table 1 funcref)))
    (core module $m2 (table (export "t") 2 externref))
    (core instance $i (instantiate $m2))
    (core instance (instantiate $m1 (with "" (instance $i)))))
  "expected table element type funcref, found externref")

(assert_invalid
  (component
    (core module $m1 (import "" "t" (table 2 2 funcref)))
    (core module $m2 (table (export "t") 1 funcref))
    (core instance $i (instantiate $m2))
    (core instance (instantiate $m1 (with "" (instance $i)))))
  "mismatch in table limits")

(assert_invalid
  (component
    (core module $m1 (import "" "t" (table 1 2 funcref)))
    (core module $m2 (table (export "t") 2 funcref))
    (core instance $i (instantiate $m2))
    (core instance (instantiate $m1 (with "" (instance $i)))))
  "mismatch in table limits")

(assert_invalid
  (component
    (core module $m1 (import "" "t" (table 2 2 funcref)))
    (core module $m2 (table (export "t") 2 3 funcref))
    (core instance $i (instantiate $m2))
    (core instance (instantiate $m1 (with "" (instance $i)))))
  "mismatch in table limits")

(assert_invalid
  (component
    (core module $m1 (import "" "m" (memory 1 2 shared)))
    (core module $m2 (memory (export "m") 1))
    (core instance $i (instantiate $m2))
    (core instance (instantiate $m1 (with "" (instance $i)))))
  "mismatch in the shared flag for memories")

(assert_invalid
  (component
    (core module $m1 (import "" "m" (memory 1)))
    (core module $m2 (memory (export "m") 0))
    (core instance $i (instantiate $m2))
    (core instance (instantiate $m1 (with "" (instance $i)))))
  "mismatch in memory limits")

(assert_invalid
  (component
    (core module $m1 (import "a" "b" (global i32)))
    (core module $m2 (func (export "b")))
    (core instance $i (instantiate $m2))
    (core instance (instantiate $m1 (with "a" (instance $i)))))
  "expected global, found func")

;; every imported module name needs an argument, and the supplied instance
;; must cover every field imported from that name

(assert_invalid
  (component
    (core module $m (import "" "f" (func)))
    (core instance (instantiate $m)))
  "missing module instantiation argument")

(assert_invalid
  (component
    (core module $libc
      (memory (export "memory") 1)
      (table (export "table") 0 funcref))
    (core instance $libc (instantiate $libc))
    (core module $needs
      (import "" "memory" (memory 1))
      (import "" "table" (table 0 funcref)))
    (core instance (instantiate $needs
      (with "" (instance (export "memory" (memory $libc "memory")))))))
  "does not export an item named `table`")


;; superfluous arguments are ignored, and argument names are uninterpreted
;; (in particular, not validated as kebab-case)

(component
  (component $c)
  (instance $i (instantiate $c))
  (instance (instantiate $c (with "extra" (instance $i)))))

(component
  (component $c)
  (instance $i (instantiate $c))
  (instance (instantiate $c (with "NotKebab-Case" (instance $i)))))

;; `with` arguments: the argument's sort must match the import's sort

(assert_invalid
  (component
    (component $c (import "a" (func)))
    (component $d)
    (instance (instantiate $c (with "a" (component $d)))))
  "expected func, found component")

(assert_invalid
  (component
    (component $x)
    (instance $i (instantiate $x))
    (component $c (import "x" (component)))
    (instance (instantiate $c (with "x" (instance $i)))))
  "expected component, found instance")

;; duplicate argument names are disallowed

(assert_invalid
  (component
    (core module $m)
    (core instance $i (instantiate $m))
    (core instance (instantiate $m
      (with "a" (instance $i))
      (with "a" (instance $i)))))
  "duplicate module instantiation argument named `a`")

(assert_invalid
  (component
    (component $c)
    (instance $i (instantiate $c))
    (instance (instantiate $c
      (with "a" (instance $i))
      (with "a" (instance $i)))))
  "instantiation argument `a` conflicts with previous argument `a`")


;; synthesized instances reject duplicate export names

(assert_invalid
  (component
    (component $c)
    (instance
      (export "a" (component $c))
      (export "a" (component $c))))
  "export name `a` conflicts with previous name `a`")

(assert_invalid
  (component
    (core module $m (func (export "f")))
    (core instance $i (instantiate $m))
    (core instance
      (export "a" (func $i "f"))
      (export "a" (func $i "f"))))
  "export name `a` already defined")


;; instantiating an index that was never defined

(assert_invalid
  (component
    (core instance (instantiate 0)))
  "unknown module")

(assert_invalid
  (component
    (instance (instantiate 0)))
  "unknown component")

(assert_invalid
  (component
    (import "a" (core module))
    (core instance (instantiate 1)))
  "unknown module")

;; out-of-bounds sort indices in synthesized instance exports

(assert_invalid
  (component (instance (export "a" (func 0))))
  "index out of bounds")

(assert_invalid
  (component (instance (export "a" (instance 0))))
  "index out of bounds")

(assert_invalid
  (component (instance (export "a" (component 0))))
  "index out of bounds")

(assert_invalid
  (component (instance (export "a" (core module 0))))
  "index out of bounds")

(assert_invalid
  (component (core instance (export "a" (func 0))))
  "index out of bounds")

(assert_invalid
  (component (core instance (export "a" (table 0))))
  "index out of bounds")

(assert_invalid
  (component (core instance (export "a" (global 0))))
  "index out of bounds")

(assert_invalid
  (component (core instance (export "a" (memory 0))))
  "index out of bounds")

;; out-of-bounds `with` argument indices

(assert_invalid
  (component
    (component $c)
    (instance (instantiate $c (with "a" (core module 0)))))
  "index out of bounds")

(assert_invalid
  (component
    (component $c)
    (instance (instantiate $c (with "a" (instance 0)))))
  "index out of bounds")

(assert_invalid
  (component
    (component $c)
    (instance (instantiate $c (with "a" (func 0)))))
  "index out of bounds")

(assert_invalid
  (component
    (component $c)
    (instance (instantiate $c (with "a" (component 100)))))
  "index out of bounds")

;; projecting a nonexistent export out of an instance

(assert_invalid
  (component
    (component $c)
    (instance $i (instantiate $c))
    (export "a" (instance $i "a")))
  "no export named `a`")

(assert_invalid
  (component
    (export "a" (instance 100 "a")))
  "index out of bounds")

(assert_invalid
  (component
    (instance)
    (alias export 0 "Xml" (func)))
  "instance 0 has no export named `Xml`")

(assert_invalid
  (component
    (core module $m)
    (core instance $i (instantiate $m))
    (alias core export $i "a" (core func)))
  "core instance 0 has no export named `a`")

(assert_invalid
  (component
    (import "a" (component $c))
    (instance $i (instantiate $c))
    (alias export $i "a" (func)))
  "instance 0 has no export named `a`")

;; projecting an export that exists but has the wrong sort

(assert_invalid
  (component
    (import "a" (instance (export "a" (func))))
    (export "a" (core module 0 "a")))
  "is not a module")

(assert_invalid
  (component
    (component $c
      (component $inner)
      (export "a" (component $inner)))
    (instance $i (instantiate $c))
    (export "a" (core module $i "a")))
  "is not a module")
