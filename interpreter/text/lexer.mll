{
open Parser
open Putil

let error lexbuf msg = raise (Script.Syntax (region lexbuf, msg))
let error_nest start lexbuf msg =
  lexbuf.Lexing.lex_start_p <- start;
  error lexbuf msg

let string s =
  let b = Buffer.create (String.length s) in
  let i = ref 1 in
  while !i < String.length s - 1 do
    let c = if s.[!i] <> '\\' then s.[!i] else
      match (incr i; s.[!i]) with
      | 'n' -> '\n'
      | 'r' -> '\r'
      | 't' -> '\t'
      | '\\' -> '\\'
      | '\'' -> '\''
      | '\"' -> '\"'
      | 'u' ->
        let j = !i + 2 in
        i := String.index_from s j '}';
        let n = int_of_string ("0x" ^ String.sub s j (!i - j)) in
        let bs = Wasm.Utf8.encode [n] in
        Buffer.add_substring b bs 0 (String.length bs - 1);
        bs.[String.length bs - 1]
      | h ->
        incr i;
        Char.chr (int_of_string ("0x" ^ String.make 1 h ^ String.make 1 s.[!i]))
    in Buffer.add_char b c;
    incr i
  done;
  Buffer.contents b

}

let sign = '+' | '-'
let digit = ['0'-'9']
let hexdigit = ['0'-'9''a'-'f''A'-'F']
let num = digit ('_'? digit)*
let hexnum = hexdigit ('_'? hexdigit)*

let letter = ['a'-'z''A'-'Z']
let symbol =
  ['+''-''*''/''\\''^''~''<''>''!''?''@''#''$''%''&''|'':''`''.''\'']

let space = [' ''\t''\n''\r']
let ascii = ['\x00'-'\x7f']
let ascii_no_nl = ['\x00'-'\x09''\x0b'-'\x7f']
let utf8cont = ['\x80'-'\xbf']
let utf8enc =
    ['\xc2'-'\xdf'] utf8cont
  | ['\xe0'] ['\xa0'-'\xbf'] utf8cont
  | ['\xed'] ['\x80'-'\x9f'] utf8cont
  | ['\xe1'-'\xec''\xee'-'\xef'] utf8cont utf8cont
  | ['\xf0'] ['\x90'-'\xbf'] utf8cont utf8cont
  | ['\xf4'] ['\x80'-'\x8f'] utf8cont utf8cont
  | ['\xf1'-'\xf3'] utf8cont utf8cont utf8cont
let utf8 = ascii | utf8enc
let utf8_no_nl = ascii_no_nl | utf8enc

let escape = ['n''r''t''\\''\'''\"']
let character =
    [^'"''\\''\x00'-'\x1f''\x7f'-'\xff']
  | utf8enc
  | '\\'escape
  | '\\'hexdigit hexdigit 
  | "\\u{" hexnum '}'

let nat = num | "0x" hexnum
let int = sign nat
let frac = num
let hexfrac = hexnum
let float =
    sign? num '.' frac?
  | sign? num ('.' frac?)? ('e' | 'E') sign? num
  | sign? "0x" hexnum '.' hexfrac?
  | sign? "0x" hexnum ('.' hexfrac?)? ('p' | 'P') sign? num
  | sign? "inf"
  | sign? "nan"
  | sign? "nan:" "0x" hexnum
let string = '"' character* '"'
let reserved = (letter | digit | '_' | symbol )+
let name = '$' reserved

rule token = parse
  | "(" { LPAR }
  | ")" { RPAR }

  | nat as s { NAT s }
  | string as s { STRING (string s) }
  | '"'character*('\n'|eof) { error lexbuf "unclosed string literal" }
  | '"'character*['\x00'-'\x09''\x0b'-'\x1f''\x7f']
    { error lexbuf "illegal control character in string literal" }
  | '"'character*'\\'_
    { error_nest (Lexing.lexeme_end_p lexbuf) lexbuf "illegal escape" }

  | "component" { COMPONENT }
  | "module" { MODULE }
  | "instance" { INSTANCE }

  | "core" { CORE }

  | "func" { FUNC }
  | "table" { TABLE }
  | "memory" { MEMORY }
  | "global" { GLOBAL }
  | "value" { VALUE }
  | "type" { TYPE }
  | "with" { WITH }
  | "instantiate" { INSTANTIATE }
  | "alias" { ALIAS }

  | "import" { IMPORT }
  | "export" { EXPORT }
  | "outer" { OUTER }

  | "bool" {BOOL }
  | "s8" { SIGNED(Ast.VI_8) }
  | "s16" { SIGNED(Ast.VI_16) }
  | "s32" { SIGNED(Ast.VI_32) }
  | "s64" { SIGNED(Ast.VI_64) }
  | "u8" { UNSIGNED(Ast.VI_8) }
  | "u16" { UNSIGNED(Ast.VI_16) }
  | "u32" { UNSIGNED(Ast.VI_32) }
  | "u64" { UNSIGNED(Ast.VI_64) }
  | "i32" { I32 }
  | "float32" { FLOAT(Ast.VF_32) }
  | "float64" { FLOAT(Ast.VF_64) }
  | "char" { CHAR }
  | "string" { TSTRING }
  | "record" { RECORD }
  | "variant" { VARIANT }
  | "list" { LIST }
  | "tuple" { TUPLE }
  | "flags" { FLAGS }
  | "enum" { ENUM }
  | "union" { UNION }
  | "option" { OPTION }
  | "error" { ERROR }
  | "field" { FIELD }
  | "case" { CASE }
  | "refines" { REFINES }
  | "param" { PARAM }
  | "result" { RESULT }
  | "own" { OWN }
  | "borrow" { BORROW }
  | "eq" { EQ }
  | "sub" { SUB }
  | "resource" { RESOURCE }
  | "resource.new" { RESOURCE_NEW }
  | "resource.drop" { RESOURCE_DROP }
  | "resource.rep" { RESOURCE_REP }
  | "rep" { REP }
  | "dtor" { DTOR }
  | "canon" { CANON }
  | "lift" { LIFT }
  | "lower" { LOWER }
  | "string-encoding" { STRINGENCODING }
  | "=" { EQS }
  | "utf8" { UTF8 }
  | "utf16" { UTF16 }
  | "latin1+utf16" { LATIN1UTF16 }
  | "realloc" { REALLOC }
  | "post-return" { POSTRETURN }
  | "start" { START }

  (* scripts *)
  | "input" { INPUT }
  | "binary" { BIN }
  | "quote" { QUOTE }
  | "assert_invalid" { ASSERT_INVALID }
  | "assert_malformed" { ASSERT_MALFORMED }

  | name as s { VAR s }

  | ";;"utf8_no_nl*eof { EOF }
  | ";;"utf8_no_nl*'\n' { Lexing.new_line lexbuf; token lexbuf }
  | ";;"utf8_no_nl* { token lexbuf (* causes error on following position *) }
  | "(;" { comment (Lexing.lexeme_start_p lexbuf) lexbuf; token lexbuf }
  | space#'\n' { token lexbuf }
  | '\n' { Lexing.new_line lexbuf; token lexbuf }
  | eof { EOF }

  | reserved as s { error lexbuf ("unknown operator: " ^ s) }
  | utf8 { error lexbuf "malformed operator" }
  | _ { error lexbuf "malformed UTF-8 encoding" }

and comment start = parse
  | ";)" { () }
  | "(;" { comment (Lexing.lexeme_start_p lexbuf) lexbuf; comment start lexbuf }
  | '\n' { Lexing.new_line lexbuf; comment start lexbuf }
  | eof { error_nest start lexbuf "unclosed comment" }
  | utf8 { comment start lexbuf }
  | _ { error lexbuf "malformed UTF-8 encoding" }
