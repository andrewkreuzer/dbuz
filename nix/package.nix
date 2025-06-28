{ stdenv
, callPackage
, zig_0_14
, optimize ? "ReleaseFast"
, pkgs
}: let
  zig_hook = zig_0_14.hook.overrideAttrs {
    zig_default_flags = "-Dcpu=baseline -Doptimize=${optimize} --color off";
  };
in

stdenv.mkDerivation {
  pname = "dbuz";
  version = "0.0.0";

  src = ./..;

  nativeBuildInputs = [ zig_hook ];
  buildInputs = [];

  zigBuildFlags = [
    "--prefix $out install"
  ];

  dontConfigure = true;

  postPatch = ''
    ln -s ${callPackage ../build.zig.zon.nix { }} $ZIG_GLOBAL_CACHE_DIR/p
  '';

  preBuild = ''
    # Necessary for zig cache to work
    export HOME=$TMPDIR
  '';

  outputs = [ "out" ];

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
}
