;; Passing the index of the current thread to the four switch-to-another-thread
;; built-ins thread.{suspend,yield}-then-{resume,promote} traps
(component definition $Tester
  (core module $Core
    (import "" "thread.index" (func $thread-index (result i32)))
    (import "" "thread.suspend-then-resume" (func $thread.suspend-then-resume (param i32) (result i32)))
    (import "" "thread.yield-then-resume" (func $thread.yield-then-resume (param i32) (result i32)))
    (import "" "thread.suspend-then-promote" (func $thread.suspend-then-promote (param i32) (result i32)))
    (import "" "thread.yield-then-promote" (func $thread.yield-then-promote (param i32) (result i32)))
    (func (export "trap-if-suspend-then-resume-self")
      (drop (call $thread.suspend-then-resume (call $thread-index)))
      unreachable
    )
    (func (export "trap-if-yield-then-resume-self")
      (drop (call $thread.yield-then-resume (call $thread-index)))
      unreachable
    )
    (func (export "trap-if-suspend-then-promote-self")
      (drop (call $thread.suspend-then-promote (call $thread-index)))
      unreachable
    )
    (func (export "trap-if-yield-then-promote-self")
      (drop (call $thread.yield-then-promote (call $thread-index)))
      unreachable
    )
  )
  (canon thread.index (core func $thread.index))
  (canon thread.suspend-then-resume (core func $thread.suspend-then-resume))
  (canon thread.yield-then-resume (core func $thread.yield-then-resume))
  (canon thread.suspend-then-promote (core func $thread.suspend-then-promote))
  (canon thread.yield-then-promote (core func $thread.yield-then-promote))
  (core instance $core (instantiate $Core (with "" (instance
    (export "thread.index" (func $thread.index))
    (export "thread.suspend-then-resume" (func $thread.suspend-then-resume))
    (export "thread.yield-then-resume" (func $thread.yield-then-resume))
    (export "thread.suspend-then-promote" (func $thread.suspend-then-promote))
    (export "thread.yield-then-promote" (func $thread.yield-then-promote))
  ))))
  (func (export "trap-if-suspend-then-resume-self") (canon lift (core func $core "trap-if-suspend-then-resume-self")))
  (func (export "trap-if-yield-then-resume-self") (canon lift (core func $core "trap-if-yield-then-resume-self")))
  (func (export "trap-if-suspend-then-promote-self") (canon lift (core func $core "trap-if-suspend-then-promote-self")))
  (func (export "trap-if-yield-then-promote-self") (canon lift (core func $core "trap-if-yield-then-promote-self")))
)

(component instance $i $Tester)
(assert_trap (invoke "trap-if-suspend-then-resume-self") "cannot resume thread which is not suspended")
(component instance $i $Tester)
(assert_trap (invoke "trap-if-yield-then-resume-self") "cannot resume thread which is not suspended")
(component instance $i $Tester)
(assert_trap (invoke "trap-if-suspend-then-promote-self") "cannot resume thread which is not suspended") ;; TODO: will need to update error string
(component instance $i $Tester)
(assert_trap (invoke "trap-if-yield-then-promote-self") "cannot resume thread which is not suspended") ;; TODO: will need to update error string
