
;; the result of `task.return` cannot contain a `borrow`
(assert_invalid
  (component
    (type $r (resource (rep i32)))
    (core func (canon task.return (result (borrow $r)))))
  "`task.return` result cannot contain a `borrow` type")
(assert_invalid
  (component
    (type $r (resource (rep i32)))
    (type $t (tuple u32 (borrow $r)))
    (core func (canon task.return (result $t))))
  "`task.return` result cannot contain a `borrow` type")
(component
  (type $r (resource (rep i32)))
  (core func (canon task.return (result (own $r)))))
