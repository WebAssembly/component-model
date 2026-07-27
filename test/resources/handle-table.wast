;; Runtime semantics of the per-component-instance handle table: sequential
;; index allocation and reuse, bounds- and type-checking of every handle
;; access, and isolation between component instances.

;; Indices allocate sequentially from 1 and freed indices are reused LIFO
;; (the free-list order is spec-normative, so exact indices can be asserted).
(component
  (type $R (resource (rep i32)))
  (canon resource.new $R (core func $R.resource.new))
  (canon resource.drop $R (core func $R.resource.drop))
  (canon resource.rep $R (core func $R.resource.rep))
  (core module $M
    (import "" "new" (func $new (param i32) (result i32)))
    (import "" "drop" (func $drop (param i32)))
    (import "" "rep" (func $rep (param i32) (result i32)))
    (func (export "run") (result i32)
      (if (i32.ne (i32.const 1) (call $new (i32.const 100))) (then unreachable))
      (if (i32.ne (i32.const 2) (call $new (i32.const 200))) (then unreachable))
      (if (i32.ne (i32.const 3) (call $new (i32.const 300))) (then unreachable))

      (call $drop (i32.const 2))
      (if (i32.ne (i32.const 2) (call $new (i32.const 400))) (then unreachable))
      (if (i32.ne (i32.const 100) (call $rep (i32.const 1))) (then unreachable))
      (if (i32.ne (i32.const 400) (call $rep (i32.const 2))) (then unreachable))
      (if (i32.ne (i32.const 300) (call $rep (i32.const 3))) (then unreachable))

      (call $drop (i32.const 1))
      (call $drop (i32.const 2))
      (call $drop (i32.const 3))
      (if (i32.ne (i32.const 3) (call $new (i32.const 500))) (then unreachable))
      (if (i32.ne (i32.const 2) (call $new (i32.const 600))) (then unreachable))
      (if (i32.ne (i32.const 1) (call $new (i32.const 700))) (then unreachable))
      (if (i32.ne (i32.const 500) (call $rep (i32.const 3))) (then unreachable))
      (if (i32.ne (i32.const 600) (call $rep (i32.const 2))) (then unreachable))
      (if (i32.ne (i32.const 700) (call $rep (i32.const 1))) (then unreachable))

      (if (i32.ne (i32.const 4) (call $new (i32.const 800))) (then unreachable))

      (i32.const 42)
    )
  )
  (core instance $m (instantiate $M (with "" (instance
    (export "new" (func $R.resource.new))
    (export "drop" (func $R.resource.drop))
    (export "rep" (func $R.resource.rep))
  ))))
  (func (export "run") (result u32) (canon lift (core func $m "run")))
)
(assert_return (invoke "run") (u32.const 42))

;; Both dropping a handle and transferring ownership out remove the entry:
;; once the table is drained, a fresh handle gets index 1 again.
(component
  (component $C
    (type $R' (resource (rep i32)))
    (export $R "R" (type $R'))
    (canon resource.new $R' (core func $R.resource.new))
    (canon resource.drop $R' (core func $R.resource.drop))
    (core module $CM
      (import "" "new" (func $new (param i32) (result i32)))
      (import "" "drop" (func $drop (param i32)))
      (func (export "make") (param $rep i32) (result i32) (call $new (local.get $rep)))
      (func (export "take") (param $h i32) (call $drop (local.get $h)))
    )
    (core instance $cm (instantiate $CM (with "" (instance
      (export "new" (func $R.resource.new))
      (export "drop" (func $R.resource.drop))
    ))))
    (func (export "make") (param "rep" u32) (result (own $R)) (canon lift (core func $cm "make")))
    (func (export "take") (param "r" (own $R)) (canon lift (core func $cm "take")))
  )
  (component $D
    (import "c" (instance $c
      (export "R" (type $R (sub resource)))
      (export "make" (func (param "rep" u32) (result (own $R))))
      (export "take" (func (param "r" (own $R))))
    ))
    (alias export $c "R" (type $R))
    (canon resource.drop $R (core func $R.resource.drop))
    (canon lower (func $c "make") (core func $make'))
    (canon lower (func $c "take") (core func $take'))
    (core module $DM
      (import "" "make" (func $make (param i32) (result i32)))
      (import "" "take" (func $take (param i32)))
      (import "" "drop" (func $drop (param i32)))
      (func (export "run") (result i32)
        (if (i32.ne (i32.const 1) (call $make (i32.const 100))) (then unreachable))
        (if (i32.ne (i32.const 2) (call $make (i32.const 200))) (then unreachable))
        (call $drop (i32.const 2))
        (call $take (i32.const 1))
        (if (i32.ne (i32.const 1) (call $make (i32.const 300))) (then unreachable))
        (i32.const 43)
      )
    )
    (core instance $dm (instantiate $DM (with "" (instance
      (export "make" (func $make'))
      (export "take" (func $take'))
      (export "drop" (func $R.resource.drop))
    ))))
    (func (export "run") (result u32) (canon lift (core func $dm "run")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "c" (instance $c))))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 43))

;; Unknown handle indices trap: never-allocated, already-dropped, 0, and
;; 0xffffffff, both for resource built-ins and when lifting handles at a call.
(component definition $Traps
  (type $R (resource (rep i32)))
  (canon resource.new $R (core func $R.resource.new))
  (canon resource.drop $R (core func $R.resource.drop))
  (canon resource.rep $R (core func $R.resource.rep))
  (core module $M
    (import "" "new" (func $new (param i32) (result i32)))
    (import "" "drop" (func $drop (param i32)))
    (import "" "rep" (func $rep (param i32) (result i32)))
    (func (export "drop-never-allocated") (call $drop (i32.const 5)))
    (func (export "rep-never-allocated") (drop (call $rep (i32.const 5))))
    (func (export "double-drop")
      (if (i32.ne (i32.const 1) (call $new (i32.const 100))) (then unreachable))
      (call $drop (i32.const 1))
      (call $drop (i32.const 1))
    )
    (func (export "drop-zero") (call $drop (i32.const 0)))
    (func (export "drop-max") (call $drop (i32.const 0xffffffff)))
  )
  (core instance $m (instantiate $M (with "" (instance
    (export "new" (func $R.resource.new))
    (export "drop" (func $R.resource.drop))
    (export "rep" (func $R.resource.rep))
  ))))
  (func (export "drop-never-allocated") (canon lift (core func $m "drop-never-allocated")))
  (func (export "rep-never-allocated") (canon lift (core func $m "rep-never-allocated")))
  (func (export "double-drop") (canon lift (core func $m "double-drop")))
  (func (export "drop-zero") (canon lift (core func $m "drop-zero")))
  (func (export "drop-max") (canon lift (core func $m "drop-max")))

  (component $C
    (type $R' (resource (rep i32)))
    (export $R "R" (type $R'))
    (canon resource.new $R' (core func $R.resource.new))
    (canon resource.drop $R' (core func $R.resource.drop))
    (core module $CM
      (import "" "new" (func $new (param i32) (result i32)))
      (import "" "drop" (func $drop (param i32)))
      (func (export "make") (result i32) (call $new (i32.const 100)))
      (func (export "consume") (param $h i32) (call $drop (local.get $h)))
      (func (export "use") (param $rep i32))
    )
    (core instance $cm (instantiate $CM (with "" (instance
      (export "new" (func $R.resource.new))
      (export "drop" (func $R.resource.drop))
    ))))
    (func (export "make") (result (own $R)) (canon lift (core func $cm "make")))
    (func (export "consume") (param "r" (own $R)) (canon lift (core func $cm "consume")))
    (func (export "use") (param "r" (borrow $R)) (canon lift (core func $cm "use")))
  )
  (component $D
    (import "c" (instance $c
      (export "R" (type $R (sub resource)))
      (export "make" (func (result (own $R))))
      (export "consume" (func (param "r" (own $R))))
      (export "use" (func (param "r" (borrow $R))))
    ))
    (alias export $c "R" (type $R))
    (canon resource.drop $R (core func $R.resource.drop))
    (canon lower (func $c "make") (core func $make'))
    (canon lower (func $c "consume") (core func $consume'))
    (canon lower (func $c "use") (core func $use'))
    (core module $DM
      (import "" "make" (func $make (result i32)))
      (import "" "consume" (func $consume (param i32)))
      (import "" "use" (func $use (param i32)))
      (import "" "drop" (func $drop (param i32)))
      (func (export "own-use-after-drop")
        (if (i32.ne (i32.const 1) (call $make)) (then unreachable))
        (call $drop (i32.const 1))
        (call $consume (i32.const 1))
      )
      (func (export "borrow-never-valid")
        (call $use (i32.const 3))
      )
    )
    (core instance $dm (instantiate $DM (with "" (instance
      (export "make" (func $make'))
      (export "consume" (func $consume'))
      (export "use" (func $use'))
      (export "drop" (func $R.resource.drop))
    ))))
    (func (export "own-use-after-drop") (canon lift (core func $dm "own-use-after-drop")))
    (func (export "borrow-never-valid") (canon lift (core func $dm "borrow-never-valid")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "c" (instance $c))))
  (func (export "own-use-after-drop") (alias export $d "own-use-after-drop"))
  (func (export "borrow-never-valid") (alias export $d "borrow-never-valid"))
)
(component instance $i $Traps)
(assert_trap (invoke "drop-never-allocated") "unknown handle index 5")
(component instance $i $Traps)
(assert_trap (invoke "rep-never-allocated") "unknown handle index 5")
(component instance $i $Traps)
(assert_trap (invoke "double-drop") "unknown handle index 1")
(component instance $i $Traps)
(assert_trap (invoke "drop-zero") "unknown handle index 0")
(component instance $i $Traps)
(assert_trap (invoke "drop-max") "unknown handle index 4294967295")
(component instance $i $Traps)
(assert_trap (invoke "own-use-after-drop") "unknown handle index 1")
(component instance $i $Traps)
(assert_trap (invoke "borrow-never-valid") "unknown handle index 3")

;; Handle tables are per component instance: an index allocated in one
;; instance of $User is unknown in a sibling instance of the same definition.
(component
  (component $Def
    (type $R' (resource (rep i32)))
    (export $R "R" (type $R'))
    (canon resource.new $R' (core func $R.resource.new))
    (core module $M
      (import "" "new" (func $new (param i32) (result i32)))
      (func (export "make") (result i32) (call $new (i32.const 100)))
    )
    (core instance $m (instantiate $M (with "" (instance
      (export "new" (func $R.resource.new))
    ))))
    (func (export "make") (result (own $R)) (canon lift (core func $m "make")))
  )
  (component $User
    (import "c" (instance $c
      (export "R" (type $R (sub resource)))
      (export "make" (func (result (own $R))))
    ))
    (alias export $c "R" (type $R))
    (canon resource.drop $R (core func $R.resource.drop))
    (canon lower (func $c "make") (core func $make'))
    (core module $UM
      (import "" "make" (func $make (result i32)))
      (import "" "drop" (func $drop (param i32)))
      (func (export "alloc")
        (if (i32.ne (i32.const 1) (call $make)) (then unreachable))
      )
      (func (export "dealloc") (call $drop (i32.const 1)))
    )
    (core instance $um (instantiate $UM (with "" (instance
      (export "make" (func $make'))
      (export "drop" (func $R.resource.drop))
    ))))
    (func (export "alloc") (canon lift (core func $um "alloc")))
    (func (export "dealloc") (canon lift (core func $um "dealloc")))
  )
  (instance $def (instantiate $Def))
  (instance $u1 (instantiate $User (with "c" (instance $def))))
  (instance $u2 (instantiate $User (with "c" (instance $def))))
  (func (export "alloc-in1") (alias export $u1 "alloc"))
  (func (export "dealloc-in2") (alias export $u2 "dealloc"))
)
(assert_return (invoke "alloc-in1"))
(assert_trap (invoke "dealloc-in2") "unknown handle index 1")

;; A parent aliasing a child's exported resource type still has its own empty
;; table: index 1 allocated by the child is unknown in the parent.
(component
  (component $Child
    (type $R' (resource (rep i32)))
    (canon resource.new $R' (core func $R.resource.new))
    (core module $M
      (import "" "new" (func $new (param i32) (result i32)))
      (func $start
        (if (i32.ne (i32.const 1) (call $new (i32.const 100))) (then unreachable))
      )
      (start $start)
    )
    (core instance (instantiate $M (with "" (instance
      (export "new" (func $R.resource.new))
    ))))
    (export "R" (type $R'))
  )
  (instance $child (instantiate $Child))
  (alias export $child "R" (type $R))
  (canon resource.drop $R (core func $R.resource.drop))
  (core module $PM
    (import "" "drop" (func $drop (param i32)))
    (func (export "drop-childs-index") (call $drop (i32.const 1)))
  )
  (core instance $pm (instantiate $PM (with "" (instance
    (export "drop" (func $R.resource.drop))
  ))))
  (func (export "drop-childs-index") (canon lift (core func $pm "drop-childs-index")))
)
(assert_trap (invoke "drop-childs-index") "unknown handle index 1")

;; Two resource types share one per-instance table, but each entry remembers
;; its type: using an $R1 handle as an $R2 handle traps.
(component definition $WrongType
  (type $R1 (resource (rep i32)))
  (type $R2 (resource (rep i32)))
  (canon resource.new $R1 (core func $R1.resource.new))
  (canon resource.drop $R2 (core func $R2.resource.drop))
  (core module $M
    (import "" "R1.new" (func $R1.new (param i32) (result i32)))
    (import "" "R2.drop" (func $R2.drop (param i32)))
    (func (export "drop-R1-as-R2")
      (if (i32.ne (i32.const 1) (call $R1.new (i32.const 100))) (then unreachable))
      (call $R2.drop (i32.const 1))
    )
    (func (export "return-R1-as-R2") (result i32)
      (call $R1.new (i32.const 100))
    )
  )
  (core instance $m (instantiate $M (with "" (instance
    (export "R1.new" (func $R1.resource.new))
    (export "R2.drop" (func $R2.resource.drop))
  ))))
  (export $R2' "R2" (type $R2))
  (func (export "drop-R1-as-R2") (canon lift (core func $m "drop-R1-as-R2")))
  (func (export "return-R1-as-R2") (result (own $R2')) (canon lift (core func $m "return-R1-as-R2")))
)
(component instance $i $WrongType)
(assert_trap (invoke "drop-R1-as-R2") "handle index 1 used with the wrong type, expected guest-defined resource but found a different guest-defined resource")
(component instance $i $WrongType)
(assert_trap (invoke "return-R1-as-R2") "handle index 1 used with the wrong type, expected guest-defined resource but found a different guest-defined resource")
