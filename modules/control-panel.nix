{ pkgs, ... }:

{
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "ostrium-kernel" (
      builtins.readFile ../files/ostrium-kernel
    ))
    (pkgs.writeShellScriptBin "ostrium-control" (
      builtins.readFile ../files/ostrium-control
    ))
    pkgs.jq
  ];
}
