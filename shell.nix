let
  nixpkgs = fetchTarball "https://github.com/NixOS/nixpkgs/tarball/nixos-25.11";
  pkgs = import nixpkgs {
    config = { };
    overlays = [ ];
  };
in

pkgs.mkShell {
  packages = with pkgs; [
    goose
  ];

  # shellHook = ''
  #   export LD_LIBRARY_PATH=${pkgs.SDL2}/lib:$LD_LIBRARY_PATH
  # '';
}
