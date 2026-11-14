exception Abort of Wasm.Source.region * string
exception Assert of Wasm.Source.region * string
exception IO of Wasm.Source.region * string

val trace : string -> unit

val run_string : string -> bool
val run_file : string -> bool
val run_stdin : unit -> unit
