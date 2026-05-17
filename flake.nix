{
  description = "rqbit - a BitTorrent client and server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib = pkgs.lib;

          rqbit-webui = pkgs.buildNpmPackage {
            pname = "rqbit-webui";
            version = "9.0.0-beta.2";

            # The package-lock.json lives at the workspace root, not inside webui/.
            src = ./.;

            # Run: nix build .#packages.x86_64-linux.default 2>&1 | grep "got:"
            # to obtain the correct hash after any package-lock.json change.
            npmDepsHash = "sha256-RiJ1mWg/dyczdXsdTgHV3Vf3zODF0DGYyKmhrwwMIJ0=";

            # Build only the webui workspace package.
            buildPhase = ''
              runHook preBuild
              npm run build --workspace=crates/librqbit/webui
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/dist
              cp -r crates/librqbit/webui/dist/. $out/dist
              runHook postInstall
            '';
          };
        in
        {
          default = pkgs.rustPlatform.buildRustPackage {
            pname = "rqbit";
            version = "9.0.0-beta.2";

            src = ./.;

            cargoLock = {
              lockFile = ./Cargo.lock;
            };

            nativeBuildInputs = [
              pkgs.installShellFiles
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.pkg-config ];

            buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.openssl ];

            # Copy the pre-built webui assets into place before the Rust build.
            preConfigure = ''
              mkdir -p crates/librqbit/webui/dist
              cp -r ${rqbit-webui}/dist/. crates/librqbit/webui/dist
            '';

            # Remove build.rs — it would try to run npm again inside the Nix
            # sandbox (no network). The webui is already built above.
            postPatch = ''
              rm crates/librqbit/build.rs
            '';

            # Default features include: webui, postgres, default-tls, prometheus.
            # postgres uses sqlx's pure-Rust driver — no libpq system dep needed.
            cargoBuildFlags = [
              "--package"
              "rqbit"
            ];
            cargoTestFlags = [
              "--package"
              "rqbit"
            ];

            postInstall = lib.optionalString (pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform) ''
              for shell in bash fish zsh; do
                installShellCompletion --cmd rqbit \
                  --$shell <($out/bin/rqbit completions $shell)
              done
            '';

            passthru.webui = rqbit-webui;

            meta = {
              description = "A BitTorrent client and server with HTTP API and web UI";
              homepage = "https://github.com/ikatson/rqbit";
              license = lib.licenses.asl20;
              mainProgram = "rqbit";
              platforms = lib.platforms.unix;
            };
          };
        }
      );

      overlays.default = final: prev: {
        rqbit = self.packages.${prev.system}.default;
      };

      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.services.rqbit;
          pkg = cfg.package;
        in
        {
          options.services.rqbit = {
            enable = lib.mkEnableOption "rqbit BitTorrent server";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
              defaultText = lib.literalExpression "rqbit.packages.\${system}.default";
              description = "The rqbit package to use.";
            };

            outputFolder = lib.mkOption {
              type = lib.types.str;
              example = "/var/lib/rqbit/downloads";
              description = "Folder where downloaded torrents are saved.";
            };

            httpListenAddr = lib.mkOption {
              type = lib.types.str;
              default = "127.0.0.1:3030";
              example = "0.0.0.0:3030";
              description = "Address and port for the HTTP API to listen on.";
            };

            persistenceLocation = lib.mkOption {
              type = lib.types.str;
              default = "/var/lib/rqbit";
              description = "Folder to store session state (session.json and .torrent files).";
            };

            openFirewall = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Open the HTTP API port in the firewall.";
            };

            user = lib.mkOption {
              type = lib.types.str;
              default = "rqbit";
              description = "User account under which rqbit runs.";
            };

            group = lib.mkOption {
              type = lib.types.str;
              default = "rqbit";
              description = "Group under which rqbit runs.";
            };

            extraArgs = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "--fastresume" ];
              description = "Additional arguments passed to `rqbit server start`.";
            };
          };

          config = lib.mkIf cfg.enable {
            users.users = lib.mkIf (cfg.user == "rqbit") {
              rqbit = {
                isSystemUser = true;
                group = cfg.group;
                description = "rqbit service user";
              };
            };

            users.groups = lib.mkIf (cfg.group == "rqbit") {
              rqbit = { };
            };

            networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [
              (lib.toInt (lib.last (lib.splitString ":" cfg.httpListenAddr)))
            ];

            systemd.services.rqbit = {
              description = "rqbit BitTorrent server";
              after = [ "network.target" ];
              wantedBy = [ "multi-user.target" ];

              serviceConfig = {
                # Create the output folder as root before dropping to the service
                # user. This handles paths outside /var/lib/rqbit (StateDirectory
                # already covers /var/lib/rqbit itself).
                ExecStartPre = "+${pkgs.coreutils}/bin/install -d -m 750 -o ${cfg.user} -g ${cfg.group} ${cfg.outputFolder}";

                Environment = [ "HOME=${cfg.persistenceLocation}" ];

                ExecStart = lib.escapeShellArgs (
                  [
                    "${pkg}/bin/rqbit"
                    "--http-api-listen-addr"
                    cfg.httpListenAddr
                    "server"
                    "start"
                    cfg.outputFolder
                    "--persistence-location"
                    cfg.persistenceLocation
                  ]
                  ++ cfg.extraArgs
                );

                User = cfg.user;
                Group = cfg.group;

                StateDirectory = "rqbit";
                StateDirectoryMode = "0750";

                Restart = "on-failure";
                RestartSec = "5s";

                NoNewPrivileges = true;
              };
            };
          };
        };
    };
}
