exception Invalid of Wasm.Source.region * string

val infer_component
    : Etypes.ctx -> Ast.IntAst.component
      -> Etypes.component_type (* raises Invalid *)
