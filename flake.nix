{
  description = "Conduktor container-images dev environment (apko, cosign, scanners, linters)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in {
        devShells.default = pkgs.mkShell {
          name = "conduktor-container-images";

          packages = with pkgs; [
            # Image build + supply chain
            apko
            cosign
            syft
            crane          # OCI registry poking (crane manifest, crane pull)

            # Scanning
            trivy
            grype

            # Config + workflow linting
            yamllint
            actionlint
            shellcheck

            # Secret scanning + pre-commit driver
            gitleaks
            pre-commit

            # Everyday plumbing
            gnumake
            jq
            yq-go
            git
            curl
          ];

          shellHook = ''
            echo "conduktor/container-images dev shell"
            echo "  apko $(apko version 2>/dev/null | head -n1)"
            echo "  cosign $(cosign version --json 2>/dev/null | jq -r .GitVersion 2>/dev/null || cosign version 2>&1 | head -n1)"
            echo "  trivy $(trivy --version 2>/dev/null | head -n1)"
            echo "  grype $(grype version 2>/dev/null | grep -i '^application' | awk '{print $2}')"
            echo
            echo "Run 'make help' to see dev targets."
          '';
        };
      });
}
