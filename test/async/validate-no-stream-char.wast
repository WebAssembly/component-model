;; Test that `stream<char>` is rejected as a validation error.
;; This is a temporary limitation; see https://github.com/WebAssembly/component-model/pull/607
(assert_invalid
  (component
    (type (stream char))
  )
  "`stream<char>` is not valid")
