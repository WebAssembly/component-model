;; Validation of core modules and core module types embedded in components:
;; nested core code and module types are fully core-validated, and two-level
;; core import names must mangle to distinct single-level component names.

;; valid nested core module, core module type and module-typed import

(component definition
  (core module
    (func (export "add") (param i32 i32) (result i32)
      (i32.add (local.get 0) (local.get 1)))
  )
  (core type $MT (module
    (type $ft (func))
    (import "a" "b" (func (type $ft)))
    (import "a" "c" (func (type $ft)))
    (export "f" (func (type $ft)))
    (export "g" (func (type $ft)))
  ))
  (import "m" (core module (type $MT)))
)

;; the code of a core module nested in a component is core-validated

(assert_invalid
  (component
    (core module
      (func
        i32.add)
    )
  )
  "type mismatch")

;; module types are internally validated: index bounds, duplicate export
;; names and core limits

(assert_invalid
  (component
    (core type (module
      (export "a" (func (type 0)))
    ))
  )
  "type index out of bounds")
(assert_invalid
  (component
    (core type (module
      (export "a" (func))
      (export "a" (func))
    ))
  )
  "export name `a` already defined")
(assert_invalid
  (component
    (core type (module
      (import "" "" (memory 70000))
    ))
  )
  "memory size must be at most")

;; ...including when the module type is itself nested in a component or
;; instance type

(assert_invalid
  (component
    (type (component
      (core type (module
        (export "" (func))
        (export "" (func))
      ))
    ))
  )
  "name `` already defined")
(assert_invalid
  (component
    (type (instance
      (core type (module
        (export "" (func))
        (export "" (func))
      ))
    ))
  )
  "name `` already defined")

;; duplicate two-level core import names are forbidden (in both concrete
;; modules and module types) since they mangle to the same single-level name

(assert_invalid
  (component
    (core module
      (import "" "" (func))
      (import "" "" (func))
    )
  )
  "duplicate import name `:`")
(assert_invalid
  (component
    (core module
      (import "" "a" (func))
      (import "" "a" (func))
    )
  )
  "duplicate import name `:a`")
(assert_invalid
  (component
    (core type (module
      (import "" "" (func))
      (import "" "" (func))
    ))
  )
  "duplicate import name `:`")
(assert_invalid
  (component
    (core type (module
      (import "" "a" (func))
      (import "" "a" (func))
    ))
  )
  "duplicate import name `:a`")
