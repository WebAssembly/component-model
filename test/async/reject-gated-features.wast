(assert_invalid
  (component
    (type $RT (resource (rep i32)))
    (canon resource.drop $RT async (core func $drop))
  )
  "failed to parse WebAssembly module"
)
(assert_invalid
  (component
    (canon subtask.cancel async (core func $subtask-cancel))
  )
  "async `subtask.cancel` requires the component model async builtins feature"
)
(assert_invalid
  (component
    (type $ST (stream u8))
    (canon stream.cancel-read $ST async (core func $cancel-read))
  )
  "async `stream.cancel-read` requires the component model async builtins feature"
)
(assert_invalid
  (component
    (type $ST (stream u8))
    (canon stream.cancel-write $ST async (core func $cancel-read))
  )
  "async `stream.cancel-write` requires the component model async builtins feature"
)
(assert_invalid
  (component
    (type $FT (future u8))
    (canon future.cancel-read $FT async (core func $cancel-read))
  )
  "async `future.cancel-read` requires the component model async builtins feature"
)
(assert_invalid
  (component
    (type $FT (future u8))
    (canon future.cancel-write $FT async (core func $cancel-read))
  )
  "async `future.cancel-write` requires the component model async builtins feature"
)
