;; Validation of `canon lift`/`canon lower` ABI options: string-encoding,
;; memory, realloc and post-return, and the lifted core function's signature.

(assert_invalid
  (component
    (import "foo" (func $foo (result (tuple u64 u64 u64 u64 u64 u64 u64 u64))))
    (canon lower (func $foo) (core func $foo'))
  )
  "canonical option `memory` is required"
)
(assert_invalid
  (component
    (import "foo" (func $foo (result (tuple u64 u64 u64 u64 u64 u64 u64 u64))))
    (core module $M
      (func (export "realloc") (param i32 i32 i32 i32) (result i32) unreachable)
    )
    (core instance $i (instantiate $M))
    (canon lower (func $foo) (realloc (core func $i "realloc")) (core func $foo'))
  )
  "canonical option `realloc` requires `memory` to also be specified"
)
(component
  (component
    (import "foo" (func $foo (result (tuple u64 u64 u64 u64 u64 u64 u64 u64))))
    (core module $M
      (memory (export "mem") 1)
      (func (export "realloc") (param i32 i32 i32 i32) (result i32) unreachable)
    )
    (core instance $i (instantiate $M))
    (canon lower (func $foo) (memory (core memory $i "mem")) (core func $foo1))
    ;; realloc superfluous but allowed:
    (canon lower (func $foo) (memory (core memory $i "mem")) (realloc (core func $i "realloc")) (core func $foo2))
  )
)

;; the memory option must refer to a defined core memory

(assert_invalid
  (component
    (import "f" (func $f))
    (core func $f' (canon lower (func $f) (memory 0)))
  )
  "memory index out of bounds")

;; memory is required when lifting a list param, lifting >1 flat results or
;; lowering a list param (lowering a large result is covered above)

(assert_invalid
  (component
    (core module $M (func (export "f") (param i32 i32)))
    (core instance $i (instantiate $M))
    (func $f (param "p" (list u8)) (canon lift (core func $i "f")))
  )
  "canonical option `memory` is required")
(assert_invalid
  (component
    (core module $M (func (export "f") (result i32) unreachable))
    (core instance $i (instantiate $M))
    (func $f (result (tuple s8 u8)) (canon lift (core func $i "f")))
  )
  "canonical option `memory` is required")
(assert_invalid
  (component
    (import "f" (func $f (param "p" (list u8))))
    (core func $f' (canon lower (func $f)))
  )
  "canonical option `memory` is required")

;; realloc is required when lifting a list param, lifting >16 flat params or
;; lowering a string result

(assert_invalid
  (component
    (core module $M
      (memory (export "mem") 1)
      (func (export "f") (param i32 i32))
    )
    (core instance $i (instantiate $M))
    (func $f (param "p" (list u8))
      (canon lift (core func $i "f") (memory (core memory $i "mem"))))
  )
  "canonical option `realloc` is required")
(assert_invalid
  (component
    (core module $M
      (memory (export "mem") 1)
      (func (export "f") (param i32))
    )
    (core instance $i (instantiate $M))
    (func $f
      (param "p1" u32) (param "p2" u32) (param "p3" u32) (param "p4" u32) (param "p5" u32)
      (param "p6" u32) (param "p7" u32) (param "p8" u32) (param "p9" u32) (param "p10" u32)
      (param "p11" u32) (param "p12" u32) (param "p13" u32) (param "p14" u32) (param "p15" u32)
      (param "p16" u32) (param "p17" u32) (param "p18" u32) (param "p19" u32) (param "p20" u32)
      (canon lift (core func $i "f") (memory (core memory $i "mem"))))
  )
  "canonical option `realloc` is required")
(assert_invalid
  (component
    (import "f" (func $f (result string)))
    (core module $M (memory (export "mem") 1))
    (core instance $i (instantiate $M))
    (core func $f' (canon lower (func $f) (memory (core memory $i "mem"))))
  )
  "canonical option `realloc` is required")

;; string-encoding: lift and lower each accept utf8, utf16 and latin1+utf16

(component definition
  (import "log" (func $log (param "msg" string)))
  (core module $Libc
    (memory (export "mem") 1)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32) unreachable)
  )
  (core instance $libc (instantiate $Libc))
  (alias core export $libc "mem" (core memory $mem))
  (alias core export $libc "realloc" (core func $realloc))
  (canon lower (func $log) string-encoding=utf8 (memory $mem) (realloc $realloc) (core func $log1'))
  (canon lower (func $log) string-encoding=utf16 (memory $mem) (realloc $realloc) (core func $log2'))
  (canon lower (func $log) string-encoding=latin1+utf16 (memory $mem) (realloc $realloc) (core func $log3'))
  (core module $M (func (export "log") (param i32 i32)))
  (core instance $m (instantiate $M))
  (func (export "log1") (param "msg" string)
    (canon lift (core func $m "log") string-encoding=utf8 (memory $mem) (realloc $realloc)))
  (func (export "log2") (param "msg" string)
    (canon lift (core func $m "log") string-encoding=utf16 (memory $mem) (realloc $realloc)))
  (func (export "log3") (param "msg" string)
    (canon lift (core func $m "log") string-encoding=latin1+utf16 (memory $mem) (realloc $realloc)))
)

;; at most one string-encoding option may be specified

(assert_invalid
  (component
    (import "f" (func $f))
    (core func $f' (canon lower (func $f) string-encoding=utf8 string-encoding=utf16))
  )
  "canonical encoding option `utf8` conflicts with option `utf16`")
(assert_invalid
  (component
    (import "f" (func $f))
    (core func $f' (canon lower (func $f) string-encoding=utf8 string-encoding=latin1+utf16))
  )
  "canonical encoding option `utf8` conflicts with option `latin1-utf16`")
(assert_invalid
  (component
    (import "f" (func $f))
    (core func $f' (canon lower (func $f) string-encoding=utf16 string-encoding=latin1+utf16))
  )
  "canonical encoding option `utf16` conflicts with option `latin1-utf16`")

;; the memory, realloc and post-return options may be specified at most once

(assert_invalid
  (component
    (import "f" (func $f))
    (core module $M (memory (export "mem") 1))
    (core instance $i (instantiate $M))
    (core func $f' (canon lower (func $f)
      (memory (core memory $i "mem"))
      (memory (core memory $i "mem"))))
  )
  "`memory` is specified more than once")
(assert_invalid
  (component
    (core module $M
      (memory (export "mem") 1)
      (func (export "f") (param i32 i32))
      (func (export "realloc") (param i32 i32 i32 i32) (result i32) unreachable)
    )
    (core instance $i (instantiate $M))
    (func $f (param "p" (list u8))
      (canon lift (core func $i "f")
        (memory (core memory $i "mem"))
        (realloc (core func $i "realloc"))
        (realloc (core func $i "realloc"))))
  )
  "canonical option `realloc` is specified more than once")
(assert_invalid
  (component
    (core module $M
      (memory (export "mem") 1)
      (func (export "f") (result i32) unreachable)
      (func (export "realloc") (param i32 i32 i32 i32) (result i32) unreachable)
      (func (export "post") (param i32))
    )
    (core instance $i (instantiate $M))
    (func $f (result string)
      (canon lift (core func $i "f")
        (memory (core memory $i "mem"))
        (realloc (core func $i "realloc"))
        (post-return (core func $i "post"))
        (post-return (core func $i "post"))))
  )
  "canonical option `post-return` is specified more than once")

;; the realloc and post-return options must have the correct core signatures
;; and post-return is only valid when lifting

(assert_invalid
  (component
    (core module $M
      (memory (export "mem") 1)
      (func (export "f") (param i32 i32))
      (func (export "realloc"))
    )
    (core instance $i (instantiate $M))
    (func $f (param "p" (list u8))
      (canon lift (core func $i "f")
        (memory (core memory $i "mem"))
        (realloc (core func $i "realloc"))))
  )
  "canonical option `realloc` uses a core function with an incorrect signature")
(assert_invalid
  (component
    (core module $M
      (memory (export "mem") 1)
      (func (export "f") (result i32) unreachable)
      (func (export "realloc") (param i32 i32 i32 i32) (result i32) unreachable)
      ;; post-return must take the lifted core func's results as params, here (param i32)
      (func (export "post"))
    )
    (core instance $i (instantiate $M))
    (func $f (result string)
      (canon lift (core func $i "f")
        (memory (core memory $i "mem"))
        (realloc (core func $i "realloc"))
        (post-return (core func $i "post"))))
  )
  "canonical option `post-return` uses a core function with an incorrect signature")
(assert_invalid
  (component
    (import "f" (func $f (param "p" string)))
    (core module $M
      (memory (export "mem") 1)
      (func (export "realloc") (param i32 i32 i32 i32) (result i32) unreachable)
      (func (export "post") (param i32))
    )
    (core instance $i (instantiate $M))
    (core func $f' (canon lower (func $f)
      (memory (core memory $i "mem"))
      (realloc (core func $i "realloc"))
      (post-return (core func $i "post"))))
  )
  "canonical option `post-return` cannot be specified for lowerings")

;; the lifted core func's signature must match the flattening of the
;; component-level function type, on both the param and result side

(assert_invalid
  (component
    (core module $M (func (export "f") (param i32)))
    (core instance $i (instantiate $M))
    (func $f (canon lift (core func $i "f")))
  )
  "lowered parameter types `[]` do not match parameter types `[I32]`")
(assert_invalid
  (component
    (core module $M (func (export "f") (result i32) unreachable))
    (core instance $i (instantiate $M))
    (func $f (canon lift (core func $i "f")))
  )
  "lowered result types `[]` do not match result types `[I32]`")

;; a type ascription on canon lift must be a function type

(assert_invalid
  (component
    (type $t string)
    (core module $M (func (export "f")))
    (core instance $i (instantiate $M))
    (func $f (type $t) (canon lift (core func $i "f")))
  )
  "not a function type")
