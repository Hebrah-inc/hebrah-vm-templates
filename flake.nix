{
  description = "hebrah golden VM templates — sidecar-base, py-base, node-base, static-base";

  nixConfig = {
    extra-substituters = [ "https://microvm.cachix.org" ];
    extra-trusted-public-keys = [
      "microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, microvm }:
    let
      lib = nixpkgs.lib;
      hostSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      guestSystemForHost = hostSystem:
        if lib.hasSuffix "-darwin" hostSystem then
          if lib.hasPrefix "aarch64" hostSystem then "aarch64-linux" else "x86_64-linux"
        else
          hostSystem;

      hebrahQemuExtraArgsScript = hypervisor: guestPkgs:
        guestPkgs.writeShellScript "hebrah-extra-args" ''
          set -euo pipefail
          CONFIG_DIR="''${HEBRAH_VM_CONFIG_DIR:?HEBRAH_VM_CONFIG_DIR required}"
          PORT="''${HEBRAH_HEALTH_HOST_PORT:?HEBRAH_HEALTH_HOST_PORT required}"
          WB_PORT="''${HEBRAH_WRITEBACK_HOST_PORT:-$((PORT + 1))}"
          HL7_PORT="''${HEBRAH_HL7_HOST_PORT:-$((PORT + 2))}"
          MLLP_PORT="''${HEBRAH_MLLP_HOST_PORT:-$((PORT + 3))}"
          HYP="${hypervisor}"
          if [ "$HYP" = "qemu" ]; then
            echo "-netdev user,id=hebrah0,hostfwd=tcp:127.0.0.1:''${PORT}-:8080,hostfwd=tcp:127.0.0.1:''${WB_PORT}-:8082,hostfwd=tcp:127.0.0.1:''${HL7_PORT}-:8083,hostfwd=tcp:127.0.0.1:''${MLLP_PORT}-:2575"
            echo "-device virtio-net-device,netdev=hebrah0"
            echo "-fsdev local,id=hebrahconfig,path=''${CONFIG_DIR},security_model=mapped-xattr,fmode=0644,dmode=0755,writeout=immediate"
            echo "-device virtio-9p-device,mount_tag=hebrah-config,fsdev=hebrahconfig"
          elif [ "$HYP" = "vfkit" ]; then
            echo "--device virtio-fs,sharedDir=''${CONFIG_DIR},mountTag=hebrah-config"
          fi
        '';

      templateSpecs = {
        sidecar-base = {
          hostName = "hebrah-sidecar";
          module = ./templates/sidecar/sidecar-module.nix;
          serviceOption = "services.hebrah-sidecar.enable";
        };
        py-base = {
          hostName = "hebrah-py-base";
          module = ./templates/py-base/py-base-module.nix;
          serviceOption = "services.hebrah-py-base.enable";
        };
        node-base = {
          hostName = "hebrah-node-base";
          module = ./templates/node-base/node-base-module.nix;
          serviceOption = "services.hebrah-node-base.enable";
        };
        static-base = {
          hostName = "hebrah-static-base";
          module = ./templates/static-base/static-base-module.nix;
          serviceOption = "services.hebrah-static-base.enable";
        };
      };

      mkMicrovmModule = { name, extraModule, hypervisor }:
        { guestSystem, guestPkgs }:
        [
          microvm.nixosModules.microvm
          extraModule
          {
            networking.hostName = name;
            system.stateVersion = "24.11";
            microvm = {
              vcpu = 1;
              mem = 1024;
              inherit hypervisor;
              qemu.machine = "microvm";
              volumes = [
                { mountPoint = "/var"; image = "var.img"; size = 256; }
              ];
              interfaces = guestPkgs.lib.optionals (hypervisor != "qemu") [
                { type = "user"; id = "eth0"; mac = "02:fc:00:00:00:01"; }
              ];
              extraArgsScript = "${hebrahQemuExtraArgsScript hypervisor guestPkgs}";
            };
          }
        ];

      mkGuestConfig = { name, extraModule, hypervisor, guestSystem }:
        nixpkgs.lib.nixosSystem {
          system = guestSystem;
          modules = mkMicrovmModule {
            inherit name extraModule hypervisor;
          } {
            guestSystem = guestSystem;
            guestPkgs = nixpkgs.legacyPackages.${guestSystem};
          };
        };

      mkGoldenBundle = templateId: hostSystem:
        let
          spec = templateSpecs.${templateId};
          guestSystem = guestSystemForHost hostSystem;
          pkgs = nixpkgs.legacyPackages.${hostSystem};
          hypervisor = "qemu";
          guestCfg = mkGuestConfig {
            name = spec.hostName;
            extraModule = spec.module;
            inherit hypervisor guestSystem;
          };
          runner = guestCfg.config.microvm.declaredRunner;
          rootfs = guestCfg.config.microvm.buildRootfs or null;
        in
        pkgs.runCommand "hebrah-golden-${templateId}" { } ''
          mkdir -p $out
          cp -r ${runner} $out/runner
          ${lib.optionalString (rootfs != null) ''
            if [ -f ${rootfs}/rootfs.erofs ]; then
              cp ${rootfs}/rootfs.erofs $out/rootfs.erofs
            elif [ -f ${rootfs}/nix/store ]; then
              cp -r ${rootfs}/* $out/ 2>/dev/null || true
            else
              cp ${rootfs} $out/rootfs.erofs 2>/dev/null || ln -s ${rootfs} $out/rootfs.erofs
            fi
          ''}
          cat > $out/manifest.json <<EOF
          {
            "template_id": "${templateId}",
            "guest_system": "${guestSystem}",
            "hypervisor": "qemu",
            "host_system": "${hostSystem}"
          }
          EOF
          cat > $out/launch.sh <<'LAUNCH'
          #!/usr/bin/env bash
          set -euo pipefail
          GOLDEN_DIR="$(cd "$(dirname "$0")" && pwd)"
          RUNNER="$GOLDEN_DIR/runner/bin/microvm-run"
          if [ ! -x "$RUNNER" ]; then
            RUNNER="$(find "$GOLDEN_DIR/runner/bin" -maxdepth 1 -type f -perm -111 2>/dev/null | head -1)"
          fi
          if [ ! -x "$RUNNER" ]; then
            echo "microvm runner not found under $GOLDEN_DIR/runner/bin" >&2
            exit 1
          fi
          LOGFILE="''${HEBRAH_VM_LOGFILE:-''${HEBRAH_VM_CONFIG_DIR:?}/vm.log}"
          mkdir -p "$(dirname "$LOGFILE")"
          nohup "$RUNNER" >"$LOGFILE" 2>&1 &
          echo $! > "''${HEBRAH_VM_PIDFILE:?}"
          LAUNCH
          chmod +x $out/launch.sh
        '';

      mkHostPackages = hostSystem:
        let
          pkgs = nixpkgs.legacyPackages.${hostSystem};
          goldenPkgs = lib.mapAttrs (
            id: _: mkGoldenBundle id hostSystem
          ) templateSpecs;
        in
        goldenPkgs // {
          default = goldenPkgs.sidecar-base;
        };

      nixosConfigurations = lib.mapAttrs (
        id: spec:
        mkGuestConfig {
          name = spec.hostName;
          extraModule = spec.module;
          hypervisor = "qemu";
          guestSystem = "aarch64-linux";
        }
      ) templateSpecs;

    in
    {
      inherit nixosConfigurations;

      packages = lib.genAttrs hostSystems (hostSystem: mkHostPackages hostSystem);

      devShells = lib.genAttrs hostSystems (hostSystem:
        let pkgs = nixpkgs.legacyPackages.${hostSystem};
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [ nix nixfmt-classic jq curl ];
            shellHook = ''
              echo "hebrah-vm-templates (${hostSystem})"
              echo "  nix build .#packages.${hostSystem}.sidecar-base"
            '';
          };
        });
    };
}
