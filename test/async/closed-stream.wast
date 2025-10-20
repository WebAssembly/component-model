;; This test contains a single component $A which imports a closed stream
;; whose instantiation shouldn't trap.

(component definition $Tester
  (component $A
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $CM
      (import "" "mem" (memory 1))
      (import "" "stream.new" (func $stream.new (result i64)))
      (func $get-stream-reader (export "get-stream-reader") (result i32)
        (i32.wrap_i64 (call $stream.new))
      )
    )
    (type $ST (stream u8))
    (canon stream.new $ST (core func $stream.new))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "stream.new" (func $stream.new))
    ))))
    (func (export "get-stream-reader") (result (stream u8)) (canon lift (core func $cm "get-stream-reader")))
  )
  (instance $a (instantiate $A))
)
(component instance $new-tester-instance $Tester)
