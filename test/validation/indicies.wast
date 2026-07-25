;; Text-format index and name forms: inline aliases and sugar in each position,
;; and how definitions, imports, aliases and exports introduce new indices.

;; test component instantiate parsing
(component
  (component
    (component $C (import "x" (func)))
    (import "f" (func $f))
    (instance (instantiate $C (with "x" (func $f))))
    (instance (instantiate $C (with "x" (func 0))))
    (import "i" (instance $i (export "f" (func))))
    (instance (instantiate $C (with "x" (func $i "f"))))
    (import "j" (instance $j
      (export "a" (instance
        (export "b" (instance
          (export "f" (func))))))))
    (instance (instantiate $C (with "x" (func $j "a" "b" "f"))))
  )

  (component
    (component $C (import "x" (instance)))
    (import "i" (instance $i))
    (instance (instantiate $C (with "x" (instance $i))))
    (import "j" (instance $j (export "k" (instance))))
    (instance (instantiate $C (with "x" (instance $j "k"))))
  )

  (component
    (component $C (import "x" (component)))
    (import "c" (component $c))
    (instance (instantiate $C (with "x" (component $c))))
    (import "i" (instance $i (export "c" (component))))
    (instance (instantiate $C (with "x" (component $i "c"))))
  )

  (component
    (component $C (import "x" (type (sub resource))))
    (import "t" (type $t (sub resource)))
    (instance (instantiate $C (with "x" (type $t))))
    (instance (instantiate $C (with "x" (type 0))))
    (import "i" (instance $i (export "t" (type (sub resource)))))
    (instance (instantiate $C (with "x" (type $i "t"))))
  )

  (component
    (component $C (import "x" (core module)))
    (import "m" (core module $m))
    (instance (instantiate $C (with "x" (core module $m))))
    (instance (instantiate $C (with "x" (core module 0))))
    (import "i" (instance $i (export "m" (core module))))
    (instance (instantiate $C (with "x" (core module $i "m"))))
    (import "j" (instance $j
      (export "a" (instance
        (export "m" (core module))))))
    (instance (instantiate $C (with "x" (core module $j "a" "m"))))
  )
)

;; test core instantiate parsing
(component
  (component
    (core module $M (import "" "" (func)))
    (core module $E (func (export "")))
    (core instance $e (instantiate $E))
    (core instance (instantiate $M (with "" (instance $e))))
    (core instance (instantiate $M (with "" (instance 0))))
    (core instance (instantiate $M
      (with "" (instance (export "" (func $e ""))))))
  )
)

;; test alias sugar in instantiate target position
(component
  (component
    (import "a" (instance $i (export "x" (core module))))
    (core instance (instantiate (module $i "x")))
  )
  (component
    (import "a" (instance $i (export "x" (component))))
    (instance (instantiate (component $i "x")))
  )
)

;; test canon lower parsing
(component
  (component
    (import "f" (func $f))
    (import "i" (instance $i (export "f" (func))))
    (import "j" (instance $j
      (export "n" (instance
        (export "f" (func))))))
    (canon lower (func $f) (core func))
    (canon lower (func $i "f") (core func))
    (canon lower (func 0) (core func))
    (canon lower (func $j "n" "f") (core func))
    (core func (canon lower (func 0)))
    (core func (canon lower (func $f)))
    (core func (canon lower (func $i "f")))
    (core func (canon lower (func $j "n" "f")))
  )

  (component
    (import "f" (func $f (param "x" string)))
    (core module $L
      (memory (export "mem") 1)
      (func (export "realloc") (param i32 i32 i32 i32) (result i32) unreachable))
    (core instance $libc (instantiate $L))
    (alias core export $libc "mem" (core memory $mem))
    (alias core export $libc "realloc" (core func $realloc))
    (canon lower (func $f)
      (memory 0) (realloc 0)
      (core func))
    (canon lower (func $f)
      (memory $mem) (realloc $realloc)
      (core func))
    (canon lower (func 0)
      (memory (core memory 0)) (realloc 0)
      (core func))
    (canon lower (func 0)
      (memory 0) (realloc (core func 0))
      (core func))
    (canon lower (func 0)
      (memory (core memory 0)) (realloc (core func 0))
      (core func))
    (canon lower (func $f)
      (memory 0) (realloc (core func $realloc))
      (core func))
    (canon lower (func $f)
      (memory (core memory $mem)) (realloc 0)
      (core func))
    (canon lower (func $f)
      (memory (core memory $mem)) (realloc (core func $realloc))
      (core func))
    (canon lower (func $f)
      (memory (core memory $libc "mem")) (realloc (core func $libc "realloc"))
      (core func))
    (core func (canon lower (func $f)
      (memory 0) (realloc 0)))
    (core func (canon lower (func $f)
      (memory $mem) (realloc $realloc)))
    (core func (canon lower (func 0)
      (memory (core memory 0))
      (realloc (core func 0))))
    (core func (canon lower (func $f)
      (memory (core memory $mem)) (realloc (core func $realloc))))
    (core func (canon lower (func $f)
      (memory (core memory $libc "mem")) (realloc (core func $libc "realloc"))))
  )
)

;; test canon lift parsing
(component
  (component
    (core module $M (func (export "f")))
    (core instance $m (instantiate $M))
    (alias core export $m "f" (core func $f))
    (canon lift (core func $f) (func))
    (canon lift (core func 0) (func))
    (canon lift (core func $m "f") (func))
    (func (canon lift (core func $f)))
    (func (canon lift (core func 0)))
    (func (canon lift (core func $m "f")))
  )

  (component
    (core module $M
      (memory (export "mem") 1)
      (func (export "realloc") (param i32 i32 i32 i32) (result i32) unreachable)
      (func (export "run") (param i32 i32) (result i32) unreachable)
      (func (export "post") (param i32))
    )
    (core instance $m (instantiate $M))
    (alias core export $m "mem" (core memory $mem))
    (alias core export $m "realloc" (core func $realloc))
    (alias core export $m "post" (core func $post))
    (canon lift (core func $m "run")
      (memory 0)
      (realloc 0)
      (post-return 1)
      (func (param "s" string) (result string)))
    (canon lift (core func $m "run")
      (memory $mem)
      (realloc $realloc)
      (post-return $post)
      (func (param "s" string) (result string)))
    (canon lift (core func $m "run")
      (memory (core memory $m "mem"))
      (realloc $realloc)
      (post-return $post)
      (func (param "s" string) (result string)))
    (canon lift (core func $m "run")
      (memory $mem)
      (realloc (core func $m "realloc"))
      (post-return $post)
      (func (param "s" string) (result string)))
    (canon lift (core func $m "run")
      (memory $mem)
      (realloc $realloc)
      (post-return (core func $m "post"))
      (func (param "s" string) (result string)))
    (canon lift (core func $m "run")
      (memory (core memory $m "mem"))
      (realloc (core func $m "realloc"))
      (post-return (core func $m "post"))
      (func (param "s" string) (result string)))
  )
)

;; test resource type parsing
(component
  (component
    (core module $M (func (export "dtor") (param i32)))
    (core instance $m (instantiate $M))
    (alias core export $m "dtor" (core func $dtor))
    (type $R1 (resource (rep i32) (dtor $dtor)))
    (type $R2 (resource (rep i32) (dtor 0)))
    (type $R3 (resource (rep i32) (dtor (core func $dtor))))
    (type $R4 (resource (rep i32) (dtor (core func $m "dtor"))))
  )
)

;; test inverted and anonymous canon resource built-in forms
(component
  (component
    (type $r (resource (rep i32)))
    (core func (canon resource.new $r))
    (canon resource.new $r (core func))
    (core func (canon resource.drop $r))
    (canon resource.drop $r (core func))
    (core func (canon resource.rep $r))
    (canon resource.rep $r (core func))
  )
)

;; test waitable-set.wait/poll parsing
(component
  (component
    (core module $M (memory (export "mem") 1))
    (core instance $m (instantiate $M))
    (alias core export $m "mem" (core memory $mem))
    (canon waitable-set.wait (memory $mem) (core func))
    (canon waitable-set.wait (memory 0) (core func))
    (canon waitable-set.wait (memory (core memory $mem)) (core func))
    (canon waitable-set.wait (memory (core memory $m "mem")) (core func))
    (canon waitable-set.poll (memory (core memory $mem)) (core func))
    (canon waitable-set.poll (memory (core memory $m "mem")) (core func))
  )
)

;; test thread.new-indirect
(component
  (component
    (core type $ft (func (param i32)))
    (core module $M (table (export "tbl") 1 funcref))
    (core instance $m (instantiate $M))
    (alias core export $m "tbl" (core table $tbl))
    (canon thread.new-indirect 0 0 (core func))
    (canon thread.new-indirect $ft $tbl (core func))
    (canon thread.new-indirect $ft (core table $tbl) (core func))
    (canon thread.new-indirect (core type $ft) $tbl (core func))
    (canon thread.new-indirect (core type $ft) (core table $tbl) (core func))
    (canon thread.new-indirect (core type $ft) (core table $m "tbl") (core func))
  )
)

;; test component-level typeidx in canon built-ins
(component
  (component
    (type $T (future u32))
    (import "i" (instance $i (export "T" (type (eq $T)))))
    (canon future.new $T (core func))
    (canon future.new 0 (core func))
    (canon future.new (type $T) (core func))
    (canon future.new (type 0) (core func))
    (canon future.new (type $i "T") (core func))
  )
)

;; test alias sugar in export position
(component
  (component
    (import "a" (instance $foo
      (export "v" (component))
      (export "m" (core module))))
    (export "v" (component $foo "v"))
    (export "w" (core module $foo "m"))
  )
)

;; test inline export sugar on definitions
(component
  (component
    (type (export "foo") u8)
    (core module (export "x"))
  )
)

;; test inline import sugar on instance declarations
(component
  (component
    (type $empty (instance))
    (instance $d (import "g") (type $empty))
    (instance (import "h"))
    (instance (import "i")
      (export "x" (func)))
    (instance (export "j") (export "k") (import "x"))
  )
)

;; test standalone core module type declarators
(component
  (component
    (core type (module))
    (core type (module
      (type $f (func (param i32) (result i32)))
      (import "a" "b" (func (type $f)))
      (export "c" (func (type $f)))
    ))
  )
  (component
    ;; module imports and core module types live in distinct index spaces
    (import "a" (core module))
    (core type (module))
  )
)

;; test module definitions interleaved with module imports and aliases
(component
  (component
    (core module
      (func (export "")))
    (import "a" (core module))
    (core module
      (func (export "") (result i32) i32.const 5))
    (import "b" (instance (export "a" (core module))))
    (alias export 0 "a" (core module))
  )
)

;; test that exports introduce new indices
(component
  (component
    (component
      (component
        (component)
        (instance (instantiate 0))
        (export "a" (instance 0))
      )
      (instance (instantiate 0))
      (export "a" (instance 0))
    )
    (instance (instantiate 0))       ;; instance 0
    (alias export 0 "a" (instance))  ;; instance 1
    (export "a" (instance 1))        ;; instance 2
    (alias export 2 "a" (instance))  ;; instance 3
    (export "inner-a" (instance 3))  ;; instance 4
  )
  (component
    (component
      (core module)
      (export "a" (core module 0))
    )
    (instance (instantiate 0))
    (alias export 0 "a" (core module))  ;; core module 0
    (export "a" (core module 0))        ;; core module 1
    (core instance (instantiate 1))
  )
)

;; test core global alias parsing
(component
  (component
    (core module $M
      (global (export "g") i32 (i32.const 0))
      (global (export "gm") (mut i64) (i64.const 0)))
    (core instance $m (instantiate $M))
    (alias core export $m "g" (core global $g))
    (alias core export $m "gm" (core global $gm))
    (core module $N
      (import "" "g" (global i32))
      (import "" "gm" (global (mut i64))))
    (core instance (instantiate $N (with "" (instance
      (export "g" (global $g))
      (export "gm" (global $gm))))))
    (core instance (instantiate $N (with "" (instance
      (export "g" (global $m "g"))
      (export "gm" (global $m "gm"))))))
  )
)
