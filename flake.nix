{
  nixConfig = {
    extra-substituters = [
      "https://nixpkgs-ruby.cachix.org"
      "https://nixpkgs-python.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nixpkgs-ruby.cachix.org-1:vrcdi50fTolOxWCZZkw0jakOnUI1T19oYJ+PRYdK4SM="
      "nixpkgs-python.cachix.org-1:hxjI7pFxTyuTHn2NkvWCrAUcNZLNS3ZAvfYNuYifcEU="
    ];
  };

  inputs = {
    nixpkgs = {
      url = "github:nixos/nixpkgs/nixos-unstable";
    };
    nixpkgs-ruby = {
      url = "github:bobvanderlinden/nixpkgs-ruby";
    };
    nixpkgs-python = {
      url = "github:cachix/nixpkgs-python";
    };
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs,
              nixpkgs-ruby,
              nixpkgs-python, pyproject-nix, uv2nix, pyproject-build-systems,
              ... }:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs { inherit system; };

      ruby = nixpkgs-ruby.packages.${system}."ruby-3.3";

      gems = pkgs.bundlerEnv {
        name = "asd-infra";
        inherit ruby;
        gemdir = ./.;
        gemConfig = pkgs.defaultGemConfig // {
          nokogiri = attrs: {
            env = { NIX_CFLAGS_COMPILE = "-Wno-error=incompatible-pointer-types"; };
          };
        };
      };

      python = nixpkgs-python.packages.${system}."3.12";

      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

      overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };

      pythonSet = (pkgs.callPackage pyproject-nix.build.packages {
          inherit python;
      }).overrideScope(
        nixpkgs.lib.composeManyExtensions [
          pyproject-build-systems.overlays.wheel
          overlay
        ]
      );

      virtualenv = pythonSet.mkVirtualEnv "asd-infra" workspace.deps.all;
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.bundix ruby gems
          pkgs.uv virtualenv
        ];
        env = {
          UV_NO_SYNC = "1";
          UV_PYTHON = pythonSet.python.interpreter;
          UV_PYTHON_DOWNLOADS = "never";
        };
        shellHook = ''
          unset PYTHONPATH
        '';
      };
    };
}
