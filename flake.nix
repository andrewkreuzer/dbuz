{
  description = "dbus";

  inputs = {
    nixpkgs.url      = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url  = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    zig.url = "github:mitchellh/zig-overlay";
  };

  outputs = { nixpkgs, zig, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [];
        pkgs = import nixpkgs {
          inherit system overlays;
        };
        meta = {
          description = "dbus";
          homepage = "https://github.com/andrewkreuzer/dbuz";
          license = with pkgs.lib.licenses; [ mit ];
          maintainers = [{
            name = "Andrew Kreuzer";
            email = "me@andrewkreuzer.com";
            github = "andrewkreuzer";
            githubId = 17596952;
          }];
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig.packages.${system}."0.14.0"
            lldb
            gdb
          ];
        };
      }
    );
}
