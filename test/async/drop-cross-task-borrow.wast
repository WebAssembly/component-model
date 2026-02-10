;; This test has 3 components $C, $D and $E
;; $C just implements a resource type that's used by $D and $E
;; $E calls async function $D.dont-drop, lending it a handle.
;; $D.dont-drop blocks, waiting on an empty waitable-set
;; $E then calls $D.drop-handle which drops the handle that $D.dont-drop
;;  was lent, albeit from the "wrong" task ($D.drop-handle).
;; Then $E calls $D.resume-dont-drop to unblock $D.dont-drop, which
;;  will call task.return which should not trap.
(component definition $Test
  (component $C
    (type $R' (resource (rep i32)))
    (canon resource.new $R' (core func $resource.new))
    (core module $CM (func (export "id") (param i32) (result i32) (local.get 0)))
    (core instance $cm (instantiate $CM))
    (alias core export $cm "id" (core func $resource.rep))
    (export $R "R" (type $R'))
    (func (export "R-new") (param "rep" u32) (result (own $R)) (canon lift (core func $resource.new)))
    (func (export "R-rep") (param "self" (borrow $R)) (result u32) (canon lift (core func $resource.rep)))
  )

  (component $D
    (import "c" (instance $d
      (export "R" (type $R (sub resource)))
      (export "R-new" (func (param "rep" u32) (result (own $R))))
      (export "R-rep" (func (param "self" (borrow $R)) (result u32)))
    ))
    (core module $DM
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "future.new" (func $future.new (result i64)))
      (import "" "future.read" (func $future.read (param i32 i32) (result i32)))
      (import "" "future.write" (func $future.write (param i32 i32) (result i32)))
      (import "" "task.return0" (func $task.return0))
      (import "" "task.return1" (func $task.return1 (param i32)))
      (import "" "R-rep" (func $R-rep (param i32) (result i32)))
      (import "" "R-drop" (func $R-drop (param i32)))

      (global $handle (mut i32) (i32.const 0))
      (global $dont-drop-result (mut i32) (i32.const 0))
      (global $dont-drop-ws (mut i32) (i32.const 0))

      (func (export "dont-drop") (param $h i32) (result i32)
        ;; Stash the given (borrow $R) handle in a global.
        (global.set $handle (local.get $h))
        ;; Stash the result of $R-rep in a global for later task.return
        (global.set $dont-drop-result (call $R-rep (local.get $h)))
        ;; Stash the waitable-set we're waiting on in a global for resume-dont-drop to use
        (global.set $dont-drop-ws (call $waitable-set.new))
        (i32.or (i32.const 2 (; WAIT ;)) (i32.shl (global.get $dont-drop-ws) (i32.const 4)))
      )
      (func (export "dont-drop-cb") (param i32 i32 i32) (result i32)
        ;; We were resumed by resume-dont-drop
        (call $task.return1 (global.get $dont-drop-result))
        (i32.const 0 (; EXIT ;))
      )
      (func (export "drop-handle") (result i32)
        ;; Drops the borrowed handle passed to dont-drop
        (local $result i32)
        (local.set $result (call $R-rep (global.get $handle)))
        (call $R-drop (global.get $handle))
        (local.get $result)
      )
      (func (export "resume-dont-drop")
        ;; Add a waitable with a pending event to dont-drop's waitable-set to
        ;; wake it up.
        (local $ret i32) (local $ret64 i64)
        (local $futw i32) (local $futr i32)
        (local.set $ret64 (call $future.new))
        (local.set $futr (i32.wrap_i64 (local.get $ret64)))
        (local.set $futw (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
        (local.set $ret (call $future.read (local.get $futr) (i32.const 0xdeadbeef)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))
        (local.set $ret (call $future.write (local.get $futw) (i32.const 0xdeadbeef)))
        (if (i32.ne (i32.const 0 (; COMPLETED ;)) (local.get $ret))
          (then unreachable))
        (call $waitable.join (local.get $futr) (global.get $dont-drop-ws))
      )
      (func (export "drop-other-and-self") (param $h i32) (result i32)
        (local $result i32)
        (local.set $result (call $R-rep (global.get $handle)))
        (call $R-drop (global.get $handle))
        (call $R-drop (local.get $h))
        (call $task.return1 (local.get $result))
        (i32.const 0 (; EXIT ;))
      )
      (func (export "drop-wrong-one") (param $h i32) (result i32)
        (call $R-drop (global.get $handle))
        ;; trap b/c $h wasn't dropped
        (call $task.return0)
        (i32.const 0 (; EXIT ;))
      )
      (func (export "unreachable-cb") (param i32 i32 i32) (result i32)
        unreachable
      )
    )
    (type $FT (future))
    (alias export $d "R" (type $R))
    (canon task.return (core func $task.return0))
    (canon task.return (result u32) (core func $task.return1))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon future.new $FT (core func $future.new))
    (canon future.read $FT async (core func $future.read))
    (canon future.write $FT async (core func $future.write))
    (canon lower (func $d "R-rep") (core func $R-rep))
    (canon resource.drop $R (core func $R-drop))
    (core instance $dm (instantiate $DM (with "" (instance
      (export "task.return0" (func $task.return0))
      (export "task.return1" (func $task.return1))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "future.new" (func $future.new))
      (export "future.read" (func $future.read))
      (export "future.write" (func $future.write))
      (export "R-rep" (func $R-rep))
      (export "R-drop" (func $R-drop))
    ))))
    (func (export "dont-drop") async (param "self" (borrow $R)) (result u32)
      (canon lift (core func $dm "dont-drop") async (callback (func $dm "dont-drop-cb")))
    )
    (func (export "drop-handle") (result u32)
      (canon lift (core func $dm "drop-handle"))
    )
    (func (export "resume-dont-drop")
      (canon lift (core func $dm "resume-dont-drop"))
    )
    (func (export "drop-other-and-self") (param "self" (borrow $R)) (result u32)
      (canon lift (core func $dm "drop-other-and-self") async (callback (func $dm "unreachable-cb")))
    )
    (func (export "drop-wrong-one") (param "self" (borrow $R))
      (canon lift (core func $dm "drop-wrong-one") async (callback (func $dm "unreachable-cb")))
    )
  )

  (component $E
    (import "c" (instance $c
      (export "R" (type $R (sub resource)))
      (export "R-new" (func (param "rep" u32) (result (own $R))))
    ))
    (alias export $c "R" (type $R))
    (import "d" (instance $d
      (export "dont-drop" (func async (param "self" (borrow $R)) (result u32)))
      (export "drop-handle" (func (result u32)))
      (export "resume-dont-drop" (func))
      (export "drop-other-and-self" (func (param "self" (borrow $R)) (result u32)))
      (export "drop-wrong-one" (func (param "self" (borrow $R))))
    ))
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $EM
      (import "" "mem" (memory 1))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (import "" "R-new" (func $R-new (param i32) (result i32)))
      (import "" "dont-drop" (func $dont-drop (param i32 i32) (result i32)))
      (import "" "drop-handle" (func $drop-handle (result i32)))
      (import "" "resume-dont-drop" (func $resume-dont-drop))
      (import "" "drop-other-and-self" (func $drop-other-and-self (param i32) (result i32)))
      (import "" "drop-wrong-one" (func $drop-wrong-one (param i32)))
      (func (export "drop-other-no-self") (result i32)
        (local $ret i32)
        (local $retp i32) (local $retp2 i32)
        (local $handle i32)
        (local $subtask i32)
        (local $magic i32)
        (local $ws i32) (local $event_code i32)

        ;; Create a resource storing $magic as it's rep
        (local.set $magic (i32.const 10))
        (local.set $handle (call $R-new (local.get $magic)))

        ;; Kick off a call to dont-drop that will block
        (local.set $retp (i32.const 16))
        (local.set $ret (call $dont-drop (local.get $handle) (local.get $retp)))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; drop-handle should return the rep of the handle passed to dont-drop
        (local.set $ret (call $drop-handle))
        (if (i32.ne (local.get $magic) (local.get $ret))
          (then unreachable))

        ;; this unblocks $subtask
        (call $resume-dont-drop)

        ;; now wait for $subtask to return, so that it can run before the test is over
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $subtask) (local.get $ws))
        (local.set $retp2 (i32.const 32))
        (local.set $event_code (call $waitable-set.wait (local.get $ws) (local.get $retp2)))
        (if (i32.ne (i32.const 1 (; SUBTASK ;)) (local.get $event_code))
          (then unreachable))
        (if (i32.ne (local.get $subtask) (i32.load (local.get $retp2)))
          (then unreachable))
        (if (i32.ne (i32.const 2 (; RETURNED=2 | (0<<4) ;)) (i32.load offset=4 (local.get $retp2)))
          (then unreachable))

        ;; $subtask should return the rep passed to $R-new.
        (if (i32.ne (local.get $magic) (i32.load (local.get $retp)))
          (then unreachable))

        i32.const 42
      )
      (func (export "drop-other-and-self") (result i32)
        (local $ret i32)
        (local $retp i32) (local $retp2 i32)
        (local $handle i32)
        (local $subtask i32)
        (local $magic i32)
        (local $ws i32) (local $event_code i32)

        ;; Create a resource storing $magic as it's rep
        (local.set $magic (i32.const 11))
        (local.set $handle (call $R-new (local.get $magic)))

        ;; Kick off a call to dont-drop that will block
        (local.set $retp (i32.const 16))
        (local.set $ret (call $dont-drop (local.get $handle) (local.get $retp)))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; This will drop dont-drop's *and* its own borrowed handle
        (local.set $ret (call $drop-other-and-self (local.get $handle)))
        (if (i32.ne (local.get $magic) (local.get $ret))
          (then unreachable))

        ;; this unblocks $subtask
        (call $resume-dont-drop)

        ;; now wait for $subtask to return, so that it can run before the test is over
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $subtask) (local.get $ws))
        (local.set $retp2 (i32.const 32))
        (local.set $event_code (call $waitable-set.wait (local.get $ws) (local.get $retp2)))
        (if (i32.ne (i32.const 1 (; SUBTASK ;)) (local.get $event_code))
          (then unreachable))
        (if (i32.ne (local.get $subtask) (i32.load (local.get $retp2)))
          (then unreachable))
        (if (i32.ne (i32.const 2 (; RETURNED=2 | (0<<4) ;)) (i32.load offset=4 (local.get $retp2)))
          (then unreachable))

        ;; $subtask should return the rep passed to $R-new.
        (if (i32.ne (local.get $magic) (i32.load (local.get $retp)))
          (then unreachable))

        i32.const 43
      )
      (func (export "drop-other-miss-self")
        (local $ret i32)
        (local $retp i32)
        (local $handle i32)
        (local $subtask i32)

        (local.set $handle (call $R-new (i32.const 42)))

        ;; Kick off a call to dont-drop that will block
        (local.set $retp (i32.const 16))
        (local.set $ret (call $dont-drop (local.get $handle) (local.get $retp)))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; Call drop-wrong-one which will drop the above call's borrow, but not its own and trap
        (call $drop-wrong-one (local.get $handle))
      )
    )
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory $memory "mem") (core func $waitable-set.wait))
    (canon lower (func $c "R-new") (core func $R-new))
    (canon lower (func $d "dont-drop") async (memory $memory "mem") (core func $dont-drop))
    (canon lower (func $d "drop-handle") (core func $drop-handle))
    (canon lower (func $d "resume-dont-drop") (core func $resume-dont-drop))
    (canon lower (func $d "drop-other-and-self") (core func $drop-other-and-self))
    (canon lower (func $d "drop-wrong-one") (core func $drop-wrong-one))
    (core instance $em (instantiate $EM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "R-new" (func $R-new))
      (export "dont-drop" (func $dont-drop))
      (export "drop-handle" (func $drop-handle))
      (export "resume-dont-drop" (func $resume-dont-drop))
      (export "drop-other-and-self" (func $drop-other-and-self))
      (export "drop-wrong-one" (func $drop-wrong-one))
    ))))
    (func (export "drop-other-no-self") async (result u32) (canon lift (core func $em "drop-other-no-self")))
    (func (export "drop-other-and-self") async (result u32) (canon lift (core func $em "drop-other-and-self")))
    (func (export "drop-other-miss-self") async (canon lift (core func $em "drop-other-miss-self")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "c" (instance $c))))
  (instance $e (instantiate $E (with "c" (instance $c)) (with "d" (instance $d))))
  (func (export "drop-other-no-self") (alias export $e "drop-other-no-self"))
  (func (export "drop-other-and-self") (alias export $e "drop-other-and-self"))
  (func (export "drop-other-miss-self") (alias export $e "drop-other-miss-self"))
)

(component instance $i $Test)
(assert_return (invoke "drop-other-no-self") (u32.const 42))
(component instance $i $Test)
(assert_return (invoke "drop-other-and-self") (u32.const 43))
(component instance $i $Test)
(assert_trap (invoke "drop-other-miss-self") "borrow handles still remain at the end of the call")
