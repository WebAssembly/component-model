;; each case of the version splitting rules
(component definition
  (import "a:b/c@1" (versionsuffix ".2.3") (instance))                  ;; 1.2.3
  (import "a:b/d@1" (versionsuffix ".2.3+sha.5114f85") (instance))      ;; 1.2.3+sha.5114f85
  (import "a:b/e@10" (versionsuffix ".0.0") (instance))                 ;; 10.0.0
  (import "a:b/f@0.2" (versionsuffix ".6") (instance))                  ;; 0.2.6
  (import "a:b/g@0.2" (versionsuffix ".6+sha.5114f85") (instance))      ;; 0.2.6+sha.5114f85
  (import "a:b/h@0.10" (versionsuffix ".0") (instance))                 ;; 0.10.0
  (import "a:b/i@0.0.1" (instance))                                     ;; 0.0.1
  (import "a:b/j@0.0.1" (versionsuffix "+sha.5114f85") (instance))      ;; 0.0.1+sha.5114f85
  (import "a:b/k@0.0.0" (instance))                                     ;; 0.0.0
  (import "a:b/l@0.0.12" (versionsuffix "+b") (instance))               ;; 0.0.12+b
)

;; pre-release labels aren't split by canonicalization, but the concatenation is
;; still a valid semver and thus valid
(component definition
  (import "a:b/c@1" (versionsuffix ".2.3-alpha") (instance))
  (import "a:b/d@1" (versionsuffix ".2.3-alpha.1+sha") (instance))
  (import "a:b/e@0.0.1" (versionsuffix "-alpha") (instance))
  (import "a:b/f@0.0.1" (versionsuffix "-alpha+sha") (instance))
)

;; an explicitly-empty versionsuffix is equivalent to no versionsuffix
(component definition
  (import "a:b/c@0.0.1" (versionsuffix "") (instance))
)

;; when canonversion is not itself a valid semver, a versionsuffix is required
(assert_invalid
  (component (import "a:b/c@1" (instance)))
  "is not valid")
(assert_invalid
  (component (import "a:b/c@0.2" (instance)))
  "is not valid")
(assert_invalid
  (component (import "a:b/c@1" (versionsuffix "") (instance)))
  "is not valid")
(assert_invalid
  (component (import "a:b/c@0.2" (versionsuffix "") (instance)))
  "is not valid")

;; the concatenation must be a valid semver
(assert_invalid
  (component (import "a:b/c@1" (versionsuffix ".2") (instance)))
  "is not valid")
(assert_invalid
  (component (import "a:b/c@1" (versionsuffix "+sha") (instance)))
  "is not valid")
(assert_invalid
  (component (import "a:b/c@1" (versionsuffix "-alpha") (instance)))
  "is not valid")
(assert_invalid
  (component (import "a:b/c@1" (versionsuffix "2.3") (instance)))
  "is not valid")
(assert_invalid
  (component (import "a:b/c@1" (versionsuffix ".2.3.4") (instance)))
  "is not valid")

;; versions matching neither canonversion nor valid semver
(assert_invalid
  (component (import "a:b/c@0" (versionsuffix ".1.0") (instance)))
  "is not valid")
(assert_invalid
  (component (import "a:b/c@0.0" (versionsuffix ".1") (instance)))
  "is not valid")
(assert_invalid
  (component (import "a:b/c@01" (versionsuffix ".2.3") (instance)))
  "is not valid")
(assert_invalid
  (component (import "a:b/c@0.01" (versionsuffix ".3") (instance)))
  "is not valid")
(assert_invalid
  (component (import "a:b/c@0.0.01" (instance)))
  "is not valid")

;; a versionsuffix requires an interfacename with a canonversion
(assert_invalid
  (component (import "a" (versionsuffix ".2.3") (instance)))
  "is not valid")
(assert_invalid
  (component (import "a" (versionsuffix "") (instance)))
  "is not valid")
(assert_invalid
  (component (import "a:b/c" (versionsuffix ".2.3") (instance)))
  "is not valid")
(assert_invalid
  (component (import "a:b/c" (versionsuffix "") (instance)))
  "is not valid")
(assert_invalid
  (component (import "a:b/c@1.2.3" (versionsuffix "+sha") (instance)))
  "is not valid")
(assert_invalid
  (component (import "a:b/c@1.2.3" (versionsuffix "") (instance)))
  "is not valid")
(assert_invalid
  (component (import "a:b/c@0.2.6" (versionsuffix "+sha") (instance)))
  "is not valid")
(assert_invalid
  (component (import "a:b/c@0.2.6" (versionsuffix "") (instance)))
  "is not valid")
(assert_invalid
  (component (import "a:b/c@0.0.1-alpha" (versionsuffix "+sha") (instance)))
  "is not valid")
(assert_invalid
  (component (import "a:b/c@0.0.1-alpha" (versionsuffix "") (instance)))
  "is not valid")

;; versionsuffix composes with external-id (in either order)
(component definition
  (import "a:b/c@1" (versionsuffix ".2.3") (external-id "x") (instance))
  (import "a:b/d@1" (external-id "y") (versionsuffix ".2.3") (instance))
)

;; versionsuffix is allowed in all import/export positions
(component definition
  (import "a:b/i@0.2" (versionsuffix ".1") (instance $i
    (export "a:b/n@1" (versionsuffix ".0.0") (instance))
  ))
  (export "a:b/i@0.3" (versionsuffix ".0") (instance $i))

  (type (instance
    (export "a:b/c@1" (versionsuffix ".2.3") (instance))
  ))
  (type (component
    (import "a:b/c@1" (versionsuffix ".2.3") (instance))
    (export "a:b/c@0.2" (versionsuffix ".6") (instance))
  ))

  (instance
    (export "a:b/i@1" (versionsuffix ".2.3") (instance $i))
  )
  (component $C (import "a:b/f@1" (versionsuffix ".0.0") (instance
    (export "a:b/g@1" (versionsuffix ".0.0") (instance))
  )))
  (instance (instantiate $C (with "a:b/f@1" (instance
    (export "a:b/g@1" (versionsuffix ".2.3") (instance $i))
  ))))
)

;; versionsuffix is ignored by name uniqueness...
(assert_invalid
  (component
    (import "a:b/c@1" (versionsuffix ".2.3") (instance))
    (import "a:b/c@1" (versionsuffix ".4.5") (instance)))
  "conflicts with previous name")
(assert_invalid
  (component
    (import "a:b/c@1" (versionsuffix ".2.3") (instance))
    (import "a:b/c@1" (versionsuffix ".2.3") (instance)))
  "conflicts with previous name")
(assert_invalid
  (component
    (import "i" (instance))
    (export "a:b/c@0.2" (versionsuffix ".1") (instance 0))
    (export "a:b/c@0.2" (versionsuffix ".2") (instance 0)))
  "conflicts with previous name")

;; versionsuffix doesn't participate in type checking
(component definition
  (import "s" (instance $s
    (export "a:b/e@1" (versionsuffix ".9.9") (instance))
  ))
  (component $c
    (import "a:b/i@0.2" (versionsuffix ".1") (instance
      (export "a:b/e@1" (versionsuffix ".0.0") (instance))
    ))
  )
  (instance (instantiate $c (with "a:b/i@0.2" (instance $s))))
)
(assert_invalid
  (component
    (import "s" (instance $s))
    (component $c
      (import "a:b/i@0.2" (versionsuffix ".1") (instance))
    )
    (instance (instantiate $c (with "a:b/i@0.2.1" (instance $s))))
  )
  "missing import named `a:b/i@0.2`")
