{ nixpkgs ? import <nixpkgs> {} }: with nixpkgs; with ocaml-ng.ocamlPackages_4_14;
buildDunePackage rec {
  pname = "wasm-components";
  version = "idk";
  useDune2 = true;
  src = ./.;
  nativeBuildInputs = [ menhir ];
  buildInputs = [ menhirLib (import ../../spec/interpreter { inherit nixpkgs; }) ];
}
