{
  description = "Conduktor container-images dev environment (apko, cosign, scanners, linters)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          name = "conduktor-container-images";

          packages = with pkgs; [
            # Image build + supply chain
            apko
            melange # builds the local conduktor-debug-scripts APK
            cosign
            syft
            crane # OCI registry poking (crane manifest, crane pull)

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
            echo "  apko $(apko version --json | jq -r .gitVersion 2>/dev/null | head -n1)"
            echo "  melange $(melange version --json | jq -r .gitVersion 2>/dev/null | head -n1)"
            echo "  cosign $(cosign version --json | jq -r .gitVersion 2>/dev/null || cosign version 2>&1 | head -n1)"
            echo "  trivy $(trivy --version -f json | jq -r .Version 2>/dev/null || trivy --version 2>&1 | head -n1)"
            echo "  grype $(grype version -o json | jq -r .version 2>/dev/null || grype version 2>&1 | head -n1)"
            echo
            echo "Run 'make help' to see dev targets."
          '';
        };
      }
    );
}
