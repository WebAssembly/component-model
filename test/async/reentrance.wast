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

;; 'subtask.cancel' may be called reentrantly, while the subtask's own
;; component instance is on the stack. Here "run" starts $Callee's "park",
;; which blocks in $Callee's event loop, and then calls back into $Callee via
;; "reenter", which reenters the root instance to cancel the parked subtask.
;; "reenter" is not async-typed, so it doesn't take $Callee's exclusive lock
;; and thus doesn't keep "park" from being resumed to receive the
;; cancellation. Whether "park" is resumed before 'subtask.cancel async'
;; returns is nondeterministic, though, so the cancellation is either already
;; delivered when the built-in returns or the built-in reports BLOCKED and
;; "run" waits for the resolution on a waitable set. Either way the subtask
;; ends up CANCELLED_BEFORE_RETURNED.
(component
  (core module $Memory (memory (export "mem") 1))
  (core instance $memory (instantiate $Memory))
  (canon subtask.cancel async (core func $subtask.cancel-async))
  (canon subtask.drop (core func $subtask.drop))
  (canon waitable.join (core func $waitable.join))
  (canon waitable-set.new (core func $waitable-set.new))
  (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))

  ;; Called by $Callee.reenter, and thus reached while $Callee is on the
  ;; stack, to cancel the subtask of $Callee.park started by "run" below.
  (core module $Canceller
    (import "" "subtask.cancel-async" (func $subtask.cancel-async (param i32) (result i32)))
    (global $parked-subtask (export "parked-subtask") (mut i32) (i32.const 0))
    (func (export "cancel-parked") (result i32)
      (call $subtask.cancel-async (global.get $parked-subtask)))
  )
  (core instance $canceller (instantiate $Canceller (with "" (instance
    (export "subtask.cancel-async" (func $subtask.cancel-async))))))
  (func $cancel-parked (result u32) (canon lift (core func $canceller "cancel-parked")))

  (component $Callee
    (import "cancel-parked" (func $cancel-parked (result u32)))
    (canon lower (func $cancel-parked) (core func $cancel-parked'))
    (canon task.cancel (core func $task.cancel))
    (canon waitable-set.new (core func $waitable-set.new))
    (core module $CalleeModule
      (import "" "cancel-parked" (func $cancel-parked (result i32)))
      (import "" "task.cancel" (func $task.cancel))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (global $never-signalled (mut i32) (i32.const 0))
      (func $start (global.set $never-signalled (call $waitable-set.new)))
      (start $start)
      ;; Parks in the event loop on a waitable set that never gets an event,
      ;; so only the delivery of a pending cancellation can wake this task.
      (func (export "park") (result i32)
        (i32.or (i32.const 2 (; WAIT ;))
                (i32.shl (global.get $never-signalled) (i32.const 4))))
      (func (export "park-cb") (param $event i32) (param i32 i32) (result i32)
        (if (i32.ne (local.get $event) (i32.const 6 (; TASK_CANCELLED ;)))
          (then unreachable))
        (call $task.cancel)
        (i32.const 0 (; EXIT ;)))
      ;; Not async-typed, so it doesn't take this instance's exclusive lock
      ;; and "park" above stays resumable while this call is on the stack.
      (func (export "reenter") (result i32) (call $cancel-parked))
    )
    (core instance $callee (instantiate $CalleeModule (with "" (instance
      (export "cancel-parked" (func $cancel-parked'))
      (export "task.cancel" (func $task.cancel))
      (export "waitable-set.new" (func $waitable-set.new))))))
    (func (export "park") async
      (canon lift (core func $callee "park") async (callback (core func $callee "park-cb"))))
    (func (export "reenter") (result u32) (canon lift (core func $callee "reenter")))
  )
  (instance $c (instantiate $Callee (with "cancel-parked" (func $cancel-parked))))
  (canon lower (func $c "park") async (core func $park'))
  (canon lower (func $c "reenter") (core func $reenter'))

  (core module $Main
    (import "" "mem" (memory 1))
    (import "" "park" (func $park (result i32)))
    (import "" "reenter" (func $reenter (result i32)))
    (import "" "parked-subtask" (global $parked-subtask (mut i32)))
    (import "" "subtask.drop" (func $subtask.drop (param i32)))
    (import "" "waitable.join" (func $waitable.join (param i32 i32)))
    (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
    (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
    (func (export "run") (result i32)
      (local $packed i32) (local $state i32) (local $waiters i32)
      (local.set $packed (call $park))
      (if (i32.ne (i32.and (local.get $packed) (i32.const 0xf)) (i32.const 1 (; STARTED ;)))
        (then unreachable))
      (global.set $parked-subtask (i32.shr_u (local.get $packed) (i32.const 4)))
      ;; reentrantly cancel the parked subtask from inside $Callee
      (local.set $state (call $reenter))
      (if (i32.eq (local.get $state) (i32.const -1 (; BLOCKED ;)))
        (then
          ;; the request was only recorded; wait for $Callee's event loop to
          ;; deliver it and resolve the subtask
          (local.set $waiters (call $waitable-set.new))
          (call $waitable.join (global.get $parked-subtask) (local.get $waiters))
          (if (i32.ne (call $waitable-set.wait (local.get $waiters) (i32.const 0))
                      (i32.const 1 (; SUBTASK ;)))
            (then unreachable))
          (if (i32.ne (i32.load (i32.const 0)) (global.get $parked-subtask))
            (then unreachable))
          (local.set $state (i32.load (i32.const 4)))
          (call $waitable.join (global.get $parked-subtask) (i32.const 0))))
      (if (i32.ne (local.get $state) (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)))
        (then unreachable))
      (call $subtask.drop (global.get $parked-subtask))
      (i32.const 42))
  )
  (core instance $main (instantiate $Main (with "" (instance
    (export "mem" (memory $memory "mem"))
    (export "park" (func $park'))
    (export "reenter" (func $reenter'))
    (export "parked-subtask" (global $canceller "parked-subtask"))
    (export "subtask.drop" (func $subtask.drop))
    (export "waitable.join" (func $waitable.join))
    (export "waitable-set.new" (func $waitable-set.new))
    (export "waitable-set.wait" (func $waitable-set.wait))))))
  ;; async-typed (but sync-ABI-lifted) so that "run" may block
  (func (export "run") async (result u32) (canon lift (core func $main "run")))
)
(assert_return (invoke "run") (u32.const 42))

;; Reentrance between two sibling instances, where there is an outer sync
;; call and an inner async call that blocks:
;;   $A.run -> $B.mid -> $A.inner (blocks) -> run yield-then-resumes inner then returns 42
;; "inner" parks itself with a thread.suspend-then-promote that targets run's
;; thread which, at that point, is *running* (on the stack below the reentrant
;; call). A running thread is not "ready", so the promote must not switch to
;; it and instead falls back to a plain suspend.
(component
  (core module $Wiring
    (type $ft (func (result i32)))
    (table (export "tbl") 2 2 funcref)
    (func (export "to-mid")   (result i32) (call_indirect (type $ft) (i32.const 0)))
    (func (export "to-check") (result i32) (call_indirect (type $ft) (i32.const 1)))
  )
  (core instance $wiring (instantiate $Wiring))
  (func $to-mid (result u32) (canon lift (core func $wiring "to-mid")))
  (func $to-check (result u32) (canon lift (core func $wiring "to-check")))

  (component $A
    (import "mid" (func $mid (result u32)))
    (import "check" (func $check (result u32)))
    (canon lower (func $mid) (core func $mid'))
    (canon lower (func $check) (core func $check'))
    (canon thread.index (core func $thread.index))
    (canon thread.suspend-then-promote (core func $thread.suspend-then-promote))
    (canon thread.yield-then-resume (core func $thread.yield-then-resume))
    (canon thread.suspend-then-resume (core func $thread.suspend-then-resume))
    (core module $AM
      (import "" "mid" (func $mid (result i32)))
      (import "" "check" (func $check (result i32)))
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "thread.suspend-then-promote" (func $thread.suspend-then-promote (param i32) (result i32)))
      (import "" "thread.yield-then-resume" (func $thread.yield-then-resume (param i32) (result i32)))
      (import "" "thread.suspend-then-resume" (func $thread.suspend-then-resume (param i32) (result i32)))
      (global $run-thread (mut i32) (i32.const 0))
      (global $inner-thread (mut i32) (i32.const 0))
      ;; reenters $A through $B; "mid" hands back the state of its call to
      ;; "inner", which must be STARTED because "inner" blocked
      (func (export "run") (result i32)
        (global.set $run-thread (call $thread.index))
        (if (i32.ne (call $mid) (i32.const 1 (; STARTED ;)))
          (then unreachable))
        ;; control is back here with "inner" still suspended, still holding
        ;; $A's exclusive lock; switch to it, staying ready ourselves
        (if (call $thread.yield-then-resume (global.get $inner-thread))
          (then unreachable))
        ;; "inner" exited and this thread was picked back up
        (call $check))
      ;; async-typed, but lifted with the sync ABI: takes $A's exclusive lock
      ;; and holds it until it returns
      (func (export "inner") (result i32)
        (global.set $inner-thread (call $thread.index))
        ;; run's thread is running (this reentrant call is on top of it), so
        ;; it is not "ready" and this must fall back to a plain suspend
        (if (call $thread.suspend-then-promote (global.get $run-thread))
          (then unreachable))
        (i32.const 42))
    )
    (core instance $am (instantiate $AM (with "" (instance
      (export "mid" (func $mid'))
      (export "check" (func $check'))
      (export "thread.index" (func $thread.index))
      (export "thread.suspend-then-promote" (func $thread.suspend-then-promote))
      (export "thread.yield-then-resume" (func $thread.yield-then-resume))
      (export "thread.suspend-then-resume" (func $thread.suspend-then-resume))))))
    ;; sync-typed: doesn't take $A's exclusive lock
    (func (export "run") (result u32) (canon lift (core func $am "run")))
    (func (export "inner") async (result u32) (canon lift (core func $am "inner")))
  )
  (instance $a (instantiate $A (with "mid" (func $to-mid)) (with "check" (func $to-check))))

  (component $B
    (import "inner" (func $inner async (result u32)))
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (canon lower (func $inner) async (memory (core memory $memory "mem")) (core func $inner'))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.poll (memory (core memory $memory "mem")) (core func $waitable-set.poll))
    (canon subtask.drop (core func $subtask.drop))
    (core module $BM
      (import "" "mem" (memory 1))
      (import "" "inner" (func $inner (param i32) (result i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.poll" (func $waitable-set.poll (param i32 i32) (result i32)))
      (import "" "subtask.drop" (func $subtask.drop (param i32)))
      (global $ws (mut i32) (i32.const 0))
      (global $sub (mut i32) (i32.const 0))
      (func $start (global.set $ws (call $waitable-set.new)))
      (start $start)
      ;; sync-typed export calling an async-typed import
      (func (export "mid") (result i32)
        (local $packed i32)
        (local.set $packed (call $inner (i32.const 4)))
        (global.set $sub (i32.shr_u (local.get $packed) (i32.const 4)))
        (call $waitable.join (global.get $sub) (global.get $ws))
        (i32.and (local.get $packed) (i32.const 0xf)))
      ;; called once "inner" has exited, so the poll must report it returned
      (func (export "check") (result i32)
        (if (i32.ne (call $waitable-set.poll (global.get $ws) (i32.const 8))
                    (i32.const 1 (; SUBTASK ;)))
          (then unreachable))
        (if (i32.ne (i32.load (i32.const 8)) (global.get $sub)) (then unreachable))
        (if (i32.ne (i32.load (i32.const 12)) (i32.const 2 (; RETURNED ;))) (then unreachable))
        (call $subtask.drop (global.get $sub))
        (i32.load (i32.const 4)))
    )
    (core instance $bm (instantiate $BM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "inner" (func $inner'))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.poll" (func $waitable-set.poll))
      (export "subtask.drop" (func $subtask.drop))))))
    (func (export "mid") (result u32) (canon lift (core func $bm "mid")))
    (func (export "check") (result u32) (canon lift (core func $bm "check")))
  )
  (instance $b (instantiate $B (with "inner" (func $a "inner"))))

  (canon lower (func $b "mid") (core func $mid'))
  (canon lower (func $b "check") (core func $check'))
  (core module $Elem
    (import "" "tbl" (table 2 2 funcref))
    (import "" "mid" (func $mid (result i32)))
    (import "" "check" (func $check (result i32)))
    (elem (i32.const 0) func $mid $check)
  )
  (core instance $elem (instantiate $Elem (with "" (instance
    (export "tbl" (table $wiring "tbl"))
    (export "mid" (func $mid'))
    (export "check" (func $check'))))))

  (export "run" (func $a "run"))
)
(assert_return (invoke "run") (u32.const 42))

;; Reentrance between two sibling instances, where the outer sync task returns
;; while a reentrant call's implicit thread is sitting ready:
;;   $A.run spawns an explicit thread and suspend-then-resumes it
;;     -> the explicit thread calls $B.mid
;;       -> $B.mid reenters $A.inner, creating a new task/implicit thread
;;         -> this new implicit thread yield-then-resumes run's implicit thread, which returns
;; Returning from "run" resolves the outer task, but the call can't return to
;; the caller: the explicit thread is still on the stack underneath. Instead,
;; the sync mini-scheduler driving the reentrant "inner" call must switch back
;; to inner's implicit thread, which stayed ready.
;; Additionally, "inner" starts by thread.yield-then-promote-ing the explicit
;; thread which, at that point, is *running* (on the stack below the reentrant
;; call). A running thread is not "ready", so the promote must not switch to
;; it and instead falls back to a plain yield.
(component
  (core module $Wiring
    (type $ft (func (result i32)))
    (table (export "tbl") 1 1 funcref)
    (func (export "to-mid") (result i32) (call_indirect (type $ft) (i32.const 0)))
  )
  (core instance $wiring (instantiate $Wiring))
  (func $to-mid (result u32) (canon lift (core func $wiring "to-mid")))

  (component $A
    (import "mid" (func $mid (result u32)))
    (canon lower (func $mid) (core func $mid'))
    (core module $Table (table (export "tbl") 1 1 funcref))
    (core instance $table (instantiate $Table))
    (core type $start-func-ty (func (param i32)))
    (alias core export $table "tbl" (core table $tbl))
    (core func $thread.new-indirect
      (canon thread.new-indirect $start-func-ty (core table $tbl)))
    (canon thread.index (core func $thread.index))
    (canon thread.suspend-then-resume (core func $thread.suspend-then-resume))
    (canon thread.yield-then-resume (core func $thread.yield-then-resume))
    (canon thread.yield-then-promote (core func $thread.yield-then-promote))
    (core module $AM
      (import "" "tbl" (table $tbl 1 1 funcref))
      (import "" "mid" (func $mid (result i32)))
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
      (import "" "thread.suspend-then-resume" (func $thread.suspend-then-resume (param i32) (result i32)))
      (import "" "thread.yield-then-resume" (func $thread.yield-then-resume (param i32) (result i32)))
      (import "" "thread.yield-then-promote" (func $thread.yield-then-promote (param i32) (result i32)))
      (global $outer-thread (mut i32) (i32.const 0))
      (global $explicit-thread (mut i32) (i32.const 0))
      (global $phase (mut i32) (i32.const 0))

      ;; the explicit thread spawned by "run"; the call into $B only returns
      ;; once the reentrant "inner" call has run all the way to completion
      (func $explicit (param i32)
        (if (i32.ne (global.get $phase) (i32.const 0)) (then unreachable))
        (if (i32.ne (call $mid) (i32.const 43)) (then unreachable))
        (if (i32.ne (global.get $phase) (i32.const 3)) (then unreachable)))
      (elem (table $tbl) (i32.const 0) func $explicit)

      (func (export "run") (result i32)
        (global.set $outer-thread (call $thread.index))
        (global.set $explicit-thread (call $thread.new-indirect (i32.const 0) (i32.const 0)))
        ;; switch to a fresh explicit thread of this same task, suspending
        (if (call $thread.suspend-then-resume (global.get $explicit-thread))
          (then unreachable))
        ;; resumed by "inner"'s implicit thread, which stayed ready
        (if (i32.ne (global.get $phase) (i32.const 1)) (then unreachable))
        (global.set $phase (i32.const 2))
        ;; resolves this task, but the explicit thread is still on the stack
        (i32.const 42))

      ;; sync-typed, so reentering $A doesn't need the exclusive lock; runs on
      ;; the implicit thread of a fresh task
      (func (export "inner") (result i32)
        (if (i32.ne (global.get $phase) (i32.const 0)) (then unreachable))
        ;; the explicit thread is running (this reentrant call is on top of
        ;; it), so it is not "ready" and this must fall back to a plain yield
        ;; without switching
        (if (call $thread.yield-then-promote (global.get $explicit-thread))
          (then unreachable))
        (global.set $phase (i32.const 1))
        ;; switch to run's implicit thread, staying ready ourselves
        (if (call $thread.yield-then-resume (global.get $outer-thread))
          (then unreachable))
        ;; "run" returned, and instead of returning to the caller the sync
        ;; mini-scheduler picked this thread back up
        (if (i32.ne (global.get $phase) (i32.const 2)) (then unreachable))
        (global.set $phase (i32.const 3))
        (i32.const 43))
    )
    (core instance $am (instantiate $AM (with "" (instance
      (export "tbl" (table $tbl))
      (export "mid" (func $mid'))
      (export "thread.index" (func $thread.index))
      (export "thread.new-indirect" (func $thread.new-indirect))
      (export "thread.suspend-then-resume" (func $thread.suspend-then-resume))
      (export "thread.yield-then-resume" (func $thread.yield-then-resume))
      (export "thread.yield-then-promote" (func $thread.yield-then-promote))))))
    (func (export "run") (result u32) (canon lift (core func $am "run")))
    (func (export "inner") (result u32) (canon lift (core func $am "inner")))
  )
  (instance $a (instantiate $A (with "mid" (func $to-mid))))

  (component $B
    (import "inner" (func $inner (result u32)))
    (canon lower (func $inner) (core func $inner'))
    (core module $BM
      (import "" "inner" (func $inner (result i32)))
      ;; sync-typed export making a sync call back into $A
      (func (export "mid") (result i32) (call $inner))
    )
    (core instance $bm (instantiate $BM (with "" (instance
      (export "inner" (func $inner'))))))
    (func (export "mid") (result u32) (canon lift (core func $bm "mid")))
  )
  (instance $b (instantiate $B (with "inner" (func $a "inner"))))

  (canon lower (func $b "mid") (core func $mid'))
  (core module $Elem
    (import "" "tbl" (table 1 1 funcref))
    (import "" "mid" (func $mid (result i32)))
    (elem (i32.const 0) func $mid)
  )
  (core instance $elem (instantiate $Elem (with "" (instance
    (export "tbl" (table $wiring "tbl"))
    (export "mid" (func $mid'))))))

  (export "run" (func $a "run"))
)
(assert_return (invoke "run") (u32.const 42))

;; While 'subtask.cancel' is claiming the subtask being cancelled, a reentrant
;; call into the cancelling instance cannot 'waitable.join' that subtask.
(component
  (canon waitable-set.new (core func $waitable-set.new))
  (canon waitable.join (core func $waitable.join))
  (canon subtask.cancel (core func $subtask.cancel))
  (core module $M1
    (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
    (import "" "waitable.join" (func $waitable.join (param i32 i32)))
    (global $ws (mut i32) (i32.const 0))
    (global $sub (export "sub") (mut i32) (i32.const 0))
    (func $start (global.set $ws (call $waitable-set.new)))
    (start $start)
    ;; called by the cancelled subtask while "run" is inside 'subtask.cancel'
    (func (export "back")
      (call $waitable.join (global.get $sub) (global.get $ws))
      unreachable)
  )
  (core instance $m1 (instantiate $M1 (with "" (instance
    (export "waitable-set.new" (func $waitable-set.new))
    (export "waitable.join" (func $waitable.join))))))
  (func $back (canon lift (core func $m1 "back")))

  (component $C
    (import "back" (func $back))
    (canon lower (func $back) (core func $back'))
    (canon task.cancel (core func $task.cancel))
    (canon waitable-set.new (core func $waitable-set.new))
    (core module $CM
      (import "" "back" (func $back))
      (import "" "task.cancel" (func $task.cancel))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (global $ws (mut i32) (i32.const 0))
      (func $start (global.set $ws (call $waitable-set.new)))
      (start $start)
      ;; parks in its event loop on a set that never gets an event, so only the
      ;; delivery of a pending cancellation can wake this task
      (func (export "f") (result i32)
        (i32.or (i32.const 2 (; WAIT ;)) (i32.shl (global.get $ws) (i32.const 4))))
      (func (export "f-cb") (param i32 i32 i32) (result i32)
        (if (i32.ne (local.get 0) (i32.const 6 (; TASK_CANCELLED ;))) (then unreachable))
        (call $task.cancel)
        ;; reenter the parent, which is still inside 'subtask.cancel'
        (call $back)
        unreachable)
    )
    (core instance $cm (instantiate $CM (with "" (instance
      (export "back" (func $back'))
      (export "task.cancel" (func $task.cancel))
      (export "waitable-set.new" (func $waitable-set.new))))))
    (func (export "f") async
      (canon lift (core func $cm "f") async (callback (core func $cm "f-cb"))))
  )
  (instance $c (instantiate $C (with "back" (func $back))))
  (canon lower (func $c "f") async (core func $f'))

  (core module $M2
    (import "" "f" (func $f (result i32)))
    (import "" "subtask.cancel" (func $subtask.cancel (param i32) (result i32)))
    (import "" "sub" (global $sub (mut i32)))
    (func (export "run") (result i32)
      (local $p i32)
      (local.set $p (call $f))
      (if (i32.ne (i32.and (local.get $p) (i32.const 0xf)) (i32.const 1 (; STARTED ;)))
        (then unreachable))
      (global.set $sub (i32.shr_u (local.get $p) (i32.const 4)))
      ;; the cancelled subtask reenters this instance and traps in "back"
      (drop (call $subtask.cancel (global.get $sub)))
      unreachable)
  )
  (core instance $m2 (instantiate $M2 (with "" (instance
    (export "f" (func $f'))
    (export "subtask.cancel" (func $subtask.cancel))
    (export "sub" (global $m1 "sub"))))))
  (func (export "run") (result u32) (canon lift (core func $m2 "run")))
)
(assert_trap (invoke "run") "waitable cannot be used synchronously while added to a waitable set")
