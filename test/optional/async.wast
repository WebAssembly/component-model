;; `optional` combined with async. `stream` and `future` types, like other
;; non-function types, need not be `optional` when they use an `optional`
;; resource type, but `stream.new` and `future.new` trap at runtime if their
;; element type uses an `optional` resource type that is not present, and an
;; async-lowered call of a function that is not present traps.
(component definition
  (import "t" (type $t (sub optional resource)))
  (type $l (list (option (own $t))))
  (type $s (stream (own $t)))
  (type $fu (future $l))
  (import "f" (func optional async (param "l" $l) (result $s)))
  (import "[static]t.g" (func optional async))
  (canon stream.new $s (core func))
  (canon future.new $fu (core func)))

(assert_invalid
  (component
    (import "t" (type $t (sub optional resource)))
    (import "f" (func async (result (stream (own $t))))))
  "must be optional")

(component definition $Tester
  (component $Impl
    (type $R (resource (rep i32)))
    (export "r" (type $R)))
  (component $User
    (import "r" (type $r (sub optional resource)))
    (import "f" (func $f optional async))
    (type $S (stream (own $r)))
    (type $F (future (own $r)))
    (canon stream.new $S (core func $stream.new))
    (canon future.new $F (core func $future.new))
    (canon lower (func $f) async (core func $f'))
    (core module $M
      (import "" "stream.new" (func $stream.new (result i64)))
      (import "" "future.new" (func $future.new (result i64)))
      (import "" "f" (func $f (result i32)))
      (func (export "call-f") (drop (call $f)))
      (func (export "new-stream") (drop (call $stream.new)))
      (func (export "new-future") (drop (call $future.new))))
    (core instance $m (instantiate $M (with "" (instance
      (export "stream.new" (func $stream.new))
      (export "future.new" (func $future.new))
      (export "f" (func $f'))))))
    (func (export "call-f") (canon lift (core func $m "call-f")))
    (func (export "new-stream") (canon lift (core func $m "new-stream")))
    (func (export "new-future") (canon lift (core func $m "new-future"))))

  (instance $impl (instantiate $Impl))
  (instance $present (instantiate $User (with "r" (type $impl "r"))))
  (instance $absent (instantiate $User))
  (export "present-new-stream" (func $present "new-stream"))
  (export "present-new-future" (func $present "new-future"))
  (export "absent-new-stream" (func $absent "new-stream"))
  (export "absent-new-future" (func $absent "new-future"))
  (export "absent-call-f" (func $absent "call-f")))

(component instance $t $Tester)
(assert_return (invoke "present-new-stream"))
(assert_return (invoke "present-new-future"))
(assert_trap (invoke "absent-new-stream") "resource type is not present")
(component instance $t $Tester)
(assert_trap (invoke "absent-new-future") "resource type is not present")
(component instance $t $Tester)
(assert_trap (invoke "absent-call-f") "function is not present")
