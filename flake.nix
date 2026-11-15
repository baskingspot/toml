{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.follows = "baskingspot/flake-parts";
    baskingspot = {
      url = "github:baskingspot/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # imports and inputsFrom below mirror each other. Zig 0.17 is the only
      # version this repo supports, so the default shell is the whole
      # toolchain contract.
      imports = with inputs.baskingspot.flakeModules; [
        base
        docs
        zig."0.17"
      ];

      perSystem =
        { pkgs, config, ... }:
        {
          devShells.default = pkgs.mkShell {
            inputsFrom = [
              config.devShells.base
              config.devShells.docs
              config.devShells."zig-0-17"
            ];
            # Lint against the 0.17 std, the one this repo supports, so a
            # deprecation from a newer std cannot fire.
            packages = [ config.packages."ziglint-0-17" ];
          };
        };
    };
}
