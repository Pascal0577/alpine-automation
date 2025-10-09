{
  description = "Development shell for alpine-automation";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
  let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
  in
  {
    devShell.x86_64-linux = pkgs.mkShell {
      buildInputs = with pkgs; [
        squashfsTools
        e2fsprogs
        cpio
        binutils
      ];
    };
  };
}
