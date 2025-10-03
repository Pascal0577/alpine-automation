{
  description = "Development shell for alpine-automation";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    {
      devShell.x86_64-linux = nixpkgs.lib.mkShell {
        buildInputs = with nixpkgs; [
          squashfsTools
          e2fsprogs
          cpio
          systemdUkify
        ];
      };
    };
}
