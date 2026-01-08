(component (component
  (import "a" (func))
  (import "a1" (func))
  (import "a-1" (func))
  (import "a-1-b-2-c-3" (func))
  (import "B" (func))
  (import "B1" (func))
  (import "B-1" (func))
  (import "B-1-C-2-D-3" (func))
  (import "a11-B11-123-ABC-abc" (func))
))
(assert_invalid
  (component
    (import "1" (func)))
  "is not in kebab case")
(assert_invalid
  (component
    (import "1-a" (func)))
  "is not in kebab case")
