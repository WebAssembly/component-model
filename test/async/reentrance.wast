;; Test various case of reentrance

;; Child-to-parent reentrance
(component
  (core module $M1
    (global $entered (export "entered") (mut i32) (i32.const 0))
    (func (export "back") (result i32)
      (global.set $entered (i32.add (global.get $entered) (i32.const 1)))
      (i32.const 5))
  )
  (core instance $m1 (instantiate $M1))
  (func $back (export "back") (result u32) (canon lift (core func $m1 "back")))

  (component $C
    (import "back" (func $back (result u32)))
    (canon lower (func $back) (core func $back'))
    (core module $MC
      (import "" "back" (func $back (result i32)))
      (func (export "go") (result i32) (i32.add (call $back) (i32.const 1)))
    )
    (core instance $mc (instantiate $MC (with "" (instance (export "back" (func $back'))))))
    (func (export "go") (result u32) (canon lift (core func $mc "go")))
  )
  (instance $c (instantiate $C (with "back" (func $back))))
  (canon lower (func $c "go") (core func $go'))

  (core module $M2
    (import "" "go" (func $go (result i32)))
    (import "" "entered" (global $entered (mut i32)))
    (func (export "run") (result i32)
      (local $r i32)
      (local.set $r (call $go))
      (if (i32.ne (global.get $entered) (i32.const 1))
        (then unreachable))
      (local.get $r))
  )
  (core instance $m2 (instantiate $M2 (with "" (instance
    (export "go" (func $go'))
    (export "entered" (global $m1 "entered"))))))
  (func (export "run") (result u32) (canon lift (core func $m2 "run")))
)
(assert_return (invoke "run") (u32.const 6))

;; Parent-to-child
(component
  (component $Child
    (core module $CoreChild (func (export "f") (result i32) (i32.const 11)))
    (core instance $core_child (instantiate $CoreChild))
    (func (export "f") (result u32) (canon lift (core func $core_child "f")))
  )
  (instance $child (instantiate $Child))
  (canon lower (func $child "f") (core func $f'))
  (core module $CoreOuter
    (import "" "f" (func $f (result i32)))
    (func (export "g") (result i32) (i32.add (call $f) (i32.const 1)))
  )
  (core instance $core_outer (instantiate $CoreOuter (with "" (instance (export "f" (func $f'))))))
  (func (export "g") (result u32) (canon lift (core func $core_outer "g")))
)
(assert_return (invoke "g") (u32.const 12))

;; Mutual recursion between a parent and its child via donut wrapping
(component
  (core module $M1
    (type $ft (func (param i32) (result i32)))
    (table (export "tbl") 1 1 funcref)
    (func (export "f") (param i32) (result i32)
      (if (result i32) (i32.eqz (local.get 0))
        (then (i32.const 100))
        (else (i32.add
                (call_indirect (type $ft) (i32.sub (local.get 0) (i32.const 1)) (i32.const 0))
                (i32.const 1)))))
  )
  (core instance $m1 (instantiate $M1))
  (func $f (export "f") (param "n" u32) (result u32) (canon lift (core func $m1 "f")))

  (component $B
    (import "f" (func $f (param "n" u32) (result u32)))
    (canon lower (func $f) (core func $f'))
    (core module $MB
      (import "" "f" (func $f (param i32) (result i32)))
      (func (export "g") (param i32) (result i32) (call $f (local.get 0)))
    )
    (core instance $mb (instantiate $MB (with "" (instance (export "f" (func $f'))))))
    (func (export "g") (param "n" u32) (result u32) (canon lift (core func $mb "g")))
  )
  (instance $b (instantiate $B (with "f" (func $f))))
  (canon lower (func $b "g") (core func $g'))
  (core module $M2
    (import "" "tbl" (table 1 1 funcref))
    (import "" "g" (func $g (param i32) (result i32)))
    (elem (i32.const 0) func $g)
  )
  (core instance $m2 (instantiate $M2 (with "" (instance
    (export "tbl" (table $m1 "tbl"))
    (export "g" (func $g'))))))
)
;; f(3) -> g(2) -> f(2) -> g(1) -> f(1) -> g(0) -> f(0) = 100, +1 per level
(assert_return (invoke "f" (u32.const 3)) (u32.const 103))
(assert_return (invoke "f" (u32.const 0)) (u32.const 100))

;; Reentrance through a sibling instance
(component
  (core module $M1
    (type $ft (func (param i32) (result i32)))
    (table (export "tbl") 1 1 funcref)
    (func (export "fwd") (param i32) (result i32)
      (call_indirect (type $ft) (local.get 0) (i32.const 0)))
  )
  (core instance $m1 (instantiate $M1))
  (func $fwd (export "fwd") (param "n" u32) (result u32) (canon lift (core func $m1 "fwd")))

  (component $C2
    (import "fwd" (func $fwd (param "n" u32) (result u32)))
    (canon lower (func $fwd) (core func $fwd'))
    (core module $M
      (import "" "fwd" (func $fwd (param i32) (result i32)))
      (func (export "g") (param i32) (result i32) (call $fwd (local.get 0)))
    )
    (core instance $m (instantiate $M (with "" (instance (export "fwd" (func $fwd'))))))
    (func (export "g") (param "n" u32) (result u32) (canon lift (core func $m "g")))
  )
  (instance $c2 (instantiate $C2 (with "fwd" (func $fwd))))

  (component $C1
    (import "g" (func $g (param "n" u32) (result u32)))
    (canon lower (func $g) (core func $g'))
    (core module $M
      (import "" "g" (func $g (param i32) (result i32)))
      (func (export "f") (param i32) (result i32)
        (if (result i32) (i32.eqz (local.get 0))
          (then (i32.const 100))
          (else (i32.add (call $g (i32.sub (local.get 0) (i32.const 1))) (i32.const 1))))))
    (core instance $m (instantiate $M (with "" (instance (export "g" (func $g'))))))
    (func (export "f") (param "n" u32) (result u32) (canon lift (core func $m "f")))
  )
  (instance $c1 (instantiate $C1 (with "g" (func $c2 "g"))))
  (canon lower (func $c1 "f") (core func $f'))

  (core module $M2
    (import "" "tbl" (table 1 1 funcref))
    (import "" "f" (func $f (param i32) (result i32)))
    (elem (i32.const 0) func $f)
    (func (export "run") (param i32) (result i32) (call $f (local.get 0)))
  )
  (core instance $m2 (instantiate $M2 (with "" (instance
    (export "tbl" (table $m1 "tbl"))
    (export "f" (func $f'))))))
  (func (export "run") (param "n" u32) (result u32) (canon lift (core func $m2 "run")))
)
(assert_return (invoke "run" (u32.const 2)) (u32.const 102))

;; A destructor is called reentrantly
(component
  (core module $Indirect
    (table (export "ftbl") 1 funcref)
    (type $FT (func (param i32)))
    (func (export "R-dtor") (param i32)
      (call_indirect (type $FT) (local.get 0) (i32.const 0)))
  )
  (core instance $indirect (instantiate $Indirect))
  (type $R (resource (rep i32) (dtor (core func $indirect "R-dtor"))))
  (canon resource.new $R (core func $resource.new))

  (component $D
    (import "r" (type $R (sub resource)))
    (canon resource.drop $R (core func $resource.drop))
    (core module $DM
      (import "" "resource.drop" (func $resource.drop (param i32)))
      (func (export "drop-it") (param i32) (call $resource.drop (local.get 0)))
    )
    (core instance $dm (instantiate $DM (with "" (instance
      (export "resource.drop" (func $resource.drop))))))
    (func (export "drop-it") (param "r" (own $R)) (canon lift (core func $dm "drop-it")))
  )
  (instance $d (instantiate $D (with "r" (type $R))))
  (canon lower (func $d "drop-it") (core func $drop-it'))

  (core module $CM
    (import "" "ftbl" (table 1 funcref))
    (import "" "resource.new" (func $resource.new (param i32) (result i32)))
    (import "" "drop-it" (func $drop-it (param i32)))
    (global $dropped (mut i32) (i32.const 0))
    (func $dtor (param $rep i32)
      (if (i32.ne (local.get $rep) (i32.const 7)) (then unreachable))
      (global.set $dropped (i32.add (global.get $dropped) (i32.const 1))))
    (elem (i32.const 0) $dtor)
    (func (export "run") (result i32)
      (call $drop-it (call $resource.new (i32.const 7)))
      (global.get $dropped))
  )
  (core instance $cm (instantiate $CM (with "" (instance
    (export "ftbl" (table $indirect "ftbl"))
    (export "resource.new" (func $resource.new))
    (export "drop-it" (func $drop-it'))))))
  (func (export "run") (result u32) (canon lift (core func $cm "run")))
)
(assert_return (invoke "run") (u32.const 1))

;; A non-async-typed export can be reentered even while the instance's
;; exclusive lock is held
(component
  (canon task.return (result u32) (core func $task.return))
  (core module $M1
    (func (export "s") (result i32) (i32.const 7))
  )
  (core instance $m1 (instantiate $M1))
  (func $s (export "s") (result u32) (canon lift (core func $m1 "s")))

  (component $C
    (import "s" (func $s (result u32)))
    (canon lower (func $s) (core func $s'))
    (core module $MC
      (import "" "s" (func $s (result i32)))
      (func (export "mid") (result i32) (i32.add (call $s) (i32.const 1)))
    )
    (core instance $mc (instantiate $MC (with "" (instance (export "s" (func $s'))))))
    (func (export "mid") (result u32) (canon lift (core func $mc "mid")))
  )
  (instance $c (instantiate $C (with "s" (func $s))))
  (canon lower (func $c "mid") (core func $mid'))

  (core module $M2
    (import "" "mid" (func $mid (result i32)))
    (import "" "task.return" (func $task.return (param i32)))
    (func (export "a") (result i32)
      (call $task.return (call $mid))
      (i32.const 0 (; EXIT ;)))
    (func (export "a-cb") (param i32 i32 i32) (result i32) unreachable)
  )
  (core instance $m2 (instantiate $M2 (with "" (instance
    (export "mid" (func $mid'))
    (export "task.return" (func $task.return))))))
  (func (export "a") async (result u32)
    (canon lift (core func $m2 "a") async (callback (core func $m2 "a-cb"))))
)
(assert_return (invoke "a") (u32.const 8))

;; Reentering an async-typed export lifted with the callback ABI blocks on
;; automatic backpressure instead of trapping, and completes once the
;; outstanding task releases the instance's exclusive lock
(component
  (core module $Memory (memory (export "mem") 1))
  (core instance $memory (instantiate $Memory))
  (canon task.return (result u32) (core func $task.return))
  (canon waitable-set.new (core func $waitable-set.new))
  (canon waitable.join (core func $waitable.join))
  (canon subtask.drop (core func $subtask.drop))

  (core module $M1
    (import "" "task.return" (func $task.return (param i32)))
    (func (export "b") (result i32)
      (call $task.return (i32.const 42))
      (i32.const 0 (; EXIT ;)))
    (func (export "b-cb") (param i32 i32 i32) (result i32) unreachable)
  )
  (core instance $m1 (instantiate $M1 (with "" (instance
    (export "task.return" (func $task.return))))))
  (func $b (export "b") async (result u32)
    (canon lift (core func $m1 "b") async (callback (core func $m1 "b-cb"))))

  (component $C
    (import "b" (func $b async (result u32)))
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (canon lower (func $b) async (memory (core memory $memory "mem")) (core func $b'))
    (canon task.return (result u32) (core func $task.return))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable.join (core func $waitable.join))
    (canon subtask.drop (core func $subtask.drop))
    (core module $MC
      (import "" "mem" (memory 1))
      (import "" "b" (func $b (param i32) (result i32)))
      (import "" "task.return" (func $task.return (param i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "subtask.drop" (func $subtask.drop (param i32)))
      (global $ws (mut i32) (i32.const 0))
      (global $sub (mut i32) (i32.const 0))
      (func (export "c") (result i32)
        (local $packed i32)
        (global.set $ws (call $waitable-set.new))
        (local.set $packed (call $b (i32.const 0)))
        (if (i32.ne (i32.and (local.get $packed) (i32.const 0xf)) (i32.const 0 (; STARTING ;)))
          (then unreachable))
        (global.set $sub (i32.shr_u (local.get $packed) (i32.const 4)))
        (call $waitable.join (global.get $sub) (global.get $ws))
        (i32.or (i32.const 2 (; WAIT ;)) (i32.shl (global.get $ws) (i32.const 4))))
      (func (export "c-cb") (param i32 i32 i32) (result i32)
        (if (i32.ne (local.get 0) (i32.const 1 (; SUBTASK ;))) (then unreachable))
        (if (i32.ne (local.get 1) (global.get $sub)) (then unreachable))
        (if (i32.ne (local.get 2) (i32.const 2 (; RETURNED ;))) (then unreachable))
        (call $subtask.drop (global.get $sub))
        (call $task.return (i32.load (i32.const 0)))
        (i32.const 0 (; EXIT ;)))
    )
    (core instance $mc (instantiate $MC (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "b" (func $b'))
      (export "task.return" (func $task.return))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable.join" (func $waitable.join))
      (export "subtask.drop" (func $subtask.drop))))))
    (func (export "c") async (result u32)
      (canon lift (core func $mc "c") async (callback (core func $mc "c-cb"))))
  )
  (instance $c (instantiate $C (with "b" (func $b))))
  (canon lower (func $c "c") async (memory (core memory $memory "mem")) (core func $c'))

  (core module $M2
    (import "" "mem" (memory 1))
    (import "" "c" (func $c (param i32) (result i32)))
    (import "" "task.return" (func $task.return (param i32)))
    (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
    (import "" "waitable.join" (func $waitable.join (param i32 i32)))
    (import "" "subtask.drop" (func $subtask.drop (param i32)))
    (global $ws (mut i32) (i32.const 0))
    (global $sub (mut i32) (i32.const 0))
    (func (export "a") (result i32)
      (local $packed i32)
      (global.set $ws (call $waitable-set.new))
      (local.set $packed (call $c (i32.const 0)))
      (if (i32.ne (i32.and (local.get $packed) (i32.const 0xf)) (i32.const 1 (; STARTED ;)))
        (then unreachable))
      (global.set $sub (i32.shr_u (local.get $packed) (i32.const 4)))
      (call $waitable.join (global.get $sub) (global.get $ws))
      (i32.or (i32.const 2 (; WAIT ;)) (i32.shl (global.get $ws) (i32.const 4))))
    (func (export "a-cb") (param i32 i32 i32) (result i32)
      (if (i32.ne (local.get 0) (i32.const 1 (; SUBTASK ;))) (then unreachable))
      (if (i32.ne (local.get 1) (global.get $sub)) (then unreachable))
      (if (i32.ne (local.get 2) (i32.const 2 (; RETURNED ;))) (then unreachable))
      (call $subtask.drop (global.get $sub))
      (call $task.return (i32.load (i32.const 0)))
      (i32.const 0 (; EXIT ;)))
  )
  (core instance $m2 (instantiate $M2 (with "" (instance
    (export "mem" (memory $memory "mem"))
    (export "c" (func $c'))
    (export "task.return" (func $task.return))
    (export "waitable-set.new" (func $waitable-set.new))
    (export "waitable.join" (func $waitable.join))
    (export "subtask.drop" (func $subtask.drop))))))
  (func (export "a") async (result u32)
    (canon lift (core func $m2 "a") async (callback (core func $m2 "a-cb"))))
)
(assert_return (invoke "a") (u32.const 42))

;; The same shape as test 7, but with "a" lifted using the sync ABI, which
;; holds the exclusive lock for the whole call instead of releasing it at
;; each event-loop turn. Reentrance still doesn't trap, but "b" can now
;; never acquire the lock, so the cycle deadlocks.
(component
  (core module $Memory (memory (export "mem") 1))
  (core instance $memory (instantiate $Memory))
  (canon task.return (result u32) (core func $task.return))
  (canon waitable-set.new (core func $waitable-set.new))
  (canon waitable.join (core func $waitable.join))
  (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))

  (core module $M1
    (import "" "task.return" (func $task.return (param i32)))
    (func (export "b") (result i32)
      (call $task.return (i32.const 42))
      (i32.const 0 (; EXIT ;)))
    (func (export "b-cb") (param i32 i32 i32) (result i32) unreachable)
  )
  (core instance $m1 (instantiate $M1 (with "" (instance
    (export "task.return" (func $task.return))))))
  (func $b (export "b") async (result u32)
    (canon lift (core func $m1 "b") async (callback (core func $m1 "b-cb"))))

  (component $C
    (import "b" (func $b async (result u32)))
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (canon lower (func $b) async (memory (core memory $memory "mem")) (core func $b'))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable.join (core func $waitable.join))
    (core module $MC
      (import "" "b" (func $b (param i32) (result i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (global $ws (mut i32) (i32.const 0))
      (global $sub (mut i32) (i32.const 0))
      (func (export "c") (result i32)
        (local $packed i32)
        (global.set $ws (call $waitable-set.new))
        (local.set $packed (call $b (i32.const 0)))
        (global.set $sub (i32.shr_u (local.get $packed) (i32.const 4)))
        (call $waitable.join (global.get $sub) (global.get $ws))
        (i32.or (i32.const 2 (; WAIT ;)) (i32.shl (global.get $ws) (i32.const 4))))
      (func (export "c-cb") (param i32 i32 i32) (result i32) unreachable)
    )
    (core instance $mc (instantiate $MC (with "" (instance
      (export "b" (func $b'))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable.join" (func $waitable.join))))))
    (func (export "c") async (result u32)
      (canon lift (core func $mc "c") async (callback (core func $mc "c-cb"))))
  )
  (instance $c (instantiate $C (with "b" (func $b))))
  (canon lower (func $c "c") async (memory (core memory $memory "mem")) (core func $c'))

  (core module $M2
    (import "" "mem" (memory 1))
    (import "" "c" (func $c (param i32) (result i32)))
    (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
    (import "" "waitable.join" (func $waitable.join (param i32 i32)))
    (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
    (func (export "a") (result i32)
      (local $packed i32) (local $ws i32) (local $sub i32)
      (local.set $ws (call $waitable-set.new))
      (local.set $packed (call $c (i32.const 0)))
      (local.set $sub (i32.shr_u (local.get $packed) (i32.const 4)))
      (call $waitable.join (local.get $sub) (local.get $ws))
      ;; "c" is waiting on "b", "b" is waiting for this task to release the
      ;; exclusive lock, and a sync-ABI lift only releases it once it returns
      (drop (call $waitable-set.wait (local.get $ws) (i32.const 8)))
      unreachable)
  )
  (core instance $m2 (instantiate $M2 (with "" (instance
    (export "mem" (memory $memory "mem"))
    (export "c" (func $c'))
    (export "waitable-set.new" (func $waitable-set.new))
    (export "waitable.join" (func $waitable.join))
    (export "waitable-set.wait" (func $waitable-set.wait))))))
  (func (export "a") async (result u32) (canon lift (core func $m2 "a")))
)
(assert_trap (invoke "a") "deadlock detected: event loop cannot make further progress")

;; 'subtask.cancel' delivers cancellation immediately even when the callee's
;; component instance is on the stack.
(component
  (canon subtask.cancel (core func $subtask.cancel))
  (canon subtask.cancel async (core func $subtask.cancel-async))
  (canon subtask.drop (core func $subtask.drop))
  (core module $M1
    (import "" "subtask.cancel" (func $subtask.cancel (param i32) (result i32)))
    (import "" "subtask.cancel-async" (func $subtask.cancel-async (param i32) (result i32)))
    (import "" "subtask.drop" (func $subtask.drop (param i32)))
    (global $s1 (export "s1") (mut i32) (i32.const 0))
    (global $s2 (export "s2") (mut i32) (i32.const 0))
    (func (export "h") (result i32)
      (local $r1 i32) (local $r2 i32)
      (local.set $r1 (call $subtask.cancel (global.get $s1)))
      (local.set $r2 (call $subtask.cancel-async (global.get $s2)))
      (call $subtask.drop (global.get $s1))
      (call $subtask.drop (global.get $s2))
      (i32.or (local.get $r1) (i32.shl (local.get $r2) (i32.const 8))))
  )
  (core instance $m1 (instantiate $M1 (with "" (instance
    (export "subtask.cancel" (func $subtask.cancel))
    (export "subtask.cancel-async" (func $subtask.cancel-async))
    (export "subtask.drop" (func $subtask.drop))))))
  (func $h (result u32) (canon lift (core func $m1 "h")))

  (component $B
    (import "h" (func $h (result u32)))
    (canon lower (func $h) (core func $h'))
    (canon task.cancel (core func $task.cancel))
    (canon waitable-set.new (core func $waitable-set.new))
    (core module $BM
      (import "" "h" (func $h (result i32)))
      (import "" "task.cancel" (func $task.cancel))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (global $ws (mut i32) (i32.const 0))
      (func $start (global.set $ws (call $waitable-set.new)))
      (start $start)
      ;; parks cancellably in its event loop on a set that never gets an event
      (func (export "f") (result i32)
        (i32.or (i32.const 2 (; WAIT ;)) (i32.shl (global.get $ws) (i32.const 4))))
      (func (export "f-cb") (param i32 i32 i32) (result i32)
        (if (i32.ne (local.get 0) (i32.const 6 (; TASK_CANCELLED ;))) (then unreachable))
        (call $task.cancel)
        (i32.const 0 (; EXIT ;)))
      ;; non-async-typed, so it doesn't take $B's exclusive lock
      (func (export "g") (result i32) (call $h))
    )
    (core instance $bm (instantiate $BM (with "" (instance
      (export "h" (func $h'))
      (export "task.cancel" (func $task.cancel))
      (export "waitable-set.new" (func $waitable-set.new))))))
    (func (export "f") async
      (canon lift (core func $bm "f") async (callback (core func $bm "f-cb"))))
    (func (export "g") (result u32) (canon lift (core func $bm "g")))
  )
  (instance $b (instantiate $B (with "h" (func $h))))
  (canon lower (func $b "f") async (core func $f'))
  (canon lower (func $b "g") (core func $g'))

  (core module $M2
    (import "" "f" (func $f (result i32)))
    (import "" "g" (func $g (result i32)))
    (import "" "s1" (global $s1 (mut i32)))
    (import "" "s2" (global $s2 (mut i32)))
    (func (export "run") (result i32)
      (local $p i32)
      (local.set $p (call $f))
      (if (i32.ne (i32.and (local.get $p) (i32.const 0xf)) (i32.const 1 (; STARTED ;)))
        (then unreachable))
      (global.set $s1 (i32.shr_u (local.get $p) (i32.const 4)))
      (local.set $p (call $f))
      (if (i32.ne (i32.and (local.get $p) (i32.const 0xf)) (i32.const 1 (; STARTED ;)))
        (then unreachable))
      (global.set $s2 (i32.shr_u (local.get $p) (i32.const 4)))
      ;; both cancels report CANCELLED_BEFORE_RETURNED (4), neither blocks
      (if (i32.ne (call $g) (i32.const 0x404)) (then unreachable))
      (i32.const 42))
  )
  (core instance $m2 (instantiate $M2 (with "" (instance
    (export "f" (func $f'))
    (export "g" (func $g'))
    (export "s1" (global $m1 "s1"))
    (export "s2" (global $m1 "s2"))))))
  (func (export "run") (result u32) (canon lift (core func $m2 "run")))
)
(assert_return (invoke "run") (u32.const 42))
