let
  pkgs = import <nixpkgs> {};
  haskellPackages = pkgs.haskellPackages.override {
    extension = self: super: {
      hadoom = self.callPackage ./. {};
      sdl2 = self.callPackage /home/ollie/work/sdl2 {};
      linear = self.callPackage /home/ollie/work/linear {};
    };
 };

       in pkgs.lib.overrideDerivation haskellPackages.hadoom (attrs: {
       buildInputs = [ haskellPackages.cabalInstall ] ++ attrs.buildInputs;
       })
