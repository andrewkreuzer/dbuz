{
  description = "dbus";

  inputs = {
    nixpkgs.url      = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url  = "github:numtide/flake-utils";
    zig.url          = "github:mitchellh/zig-overlay";
  };

  outputs = { nixpkgs, flake-utils, ... } @ inputs:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [
          (final: prev: {
            zig = inputs.zig.packages.${prev.system}."0.14.1";

            dbuz = prev.callPackage ./nix/package.nix {};
          })
        ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };
      in rec {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            zig
            lldb
            gdb
            # linuxKernel.packages.linux_libre.perf
            bpftrace
            valgrind
          ];
        };

        packages.dbuz = pkgs.dbuz;
        defaultPackage = packages.dbuz;
      }
    );
}
