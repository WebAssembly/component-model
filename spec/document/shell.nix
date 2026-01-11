{ nixpkgs ? import <nixpkgs> {} }: with nixpkgs;
stdenv.mkDerivation {
  name = "wasm-components-spec";
  buildInputs = [ texlive.combined.scheme-full ];
}
