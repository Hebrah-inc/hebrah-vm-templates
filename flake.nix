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

      hebrahQemuExtraArgsScript = hypervisor: guestPkgs: qemuMachine:
        guestPkgs.writeShellScript "hebrah-extra-args" ''
          set -euo pipefail
          CONFIG_DIR="''${HEBRAH_VM_CONFIG_DIR:?HEBRAH_VM_CONFIG_DIR required}"
          PORT="''${HEBRAH_HEALTH_HOST_PORT:?HEBRAH_HEALTH_HOST_PORT required}"
          WB_PORT="''${HEBRAH_WRITEBACK_HOST_PORT:-$((PORT + 1))}"
          HL7_PORT="''${HEBRAH_HL7_HOST_PORT:-$((PORT + 2))}"
          MLLP_PORT="''${HEBRAH_MLLP_HOST_PORT:-$((PORT + 3))}"
          FHIR_PORT="''${HEBRAH_FHIR_HOST_PORT:-$((PORT + 4))}"
          HYP="${hypervisor}"
          if [ "$HYP" = "qemu" ]; then
            echo "-netdev user,id=hebrah0,hostfwd=tcp:127.0.0.1:''${PORT}-:8080,hostfwd=tcp:127.0.0.1:''${WB_PORT}-:8082,hostfwd=tcp:127.0.0.1:''${HL7_PORT}-:8083,hostfwd=tcp:127.0.0.1:''${MLLP_PORT}-:2575,hostfwd=tcp:127.0.0.1:''${FHIR_PORT}-:8090"
            if [ "${qemuMachine}" = "microvm" ]; then
              echo "-device virtio-net-device,netdev=hebrah0"
              echo "-fsdev local,id=hebrahconfig,path=''${CONFIG_DIR},security_model=mapped-xattr,fmode=0644,dmode=0755,writeout=immediate"
              echo "-device virtio-9p-device,mount_tag=hebrah-config,fsdev=hebrahconfig"
            else
              echo "-device virtio-net-pci,netdev=hebrah0"
              echo "-fsdev local,id=hebrahconfig,path=''${CONFIG_DIR},security_model=mapped-xattr,fmode=0644,dmode=0755,writeout=immediate"
              echo "-device virtio-9p-pci,mount_tag=hebrah-config,fsdev=hebrahconfig"
            fi
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
        sidecar-base-fc = {
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
        let
          # qemu-for-vm-tests on Linux lacks "virt"; use microvm machine + virtio-net-device.
          qemuMachine =
            if guestSystem == "x86_64-linux" then "microvm" else "virt";
        in
        [
          microvm.nixosModules.microvm
          extraModule
          {
            networking.hostName = name;
            system.stateVersion = "24.11";
            microvm = {
              vcpu = 1;
              mem = if hypervisor == "firecracker" then 768 else 1024;
              cpu = "max";
              inherit hypervisor;
              qemu.machine = qemuMachine;
              volumes = [
                { mountPoint = "/var"; image = "var.img"; size = 256; }
              ];
              # QEMU/vfkit: user-mode net + hostfwd via extraArgsScript.
              # Firecracker: tap only (user net unsupported); launch.sh creates/patches tap at runtime.
              interfaces =
                if hypervisor == "firecracker" then [
                  { type = "tap"; id = "hb-fc0"; mac = "02:fc:00:00:00:01"; }
                ] else guestPkgs.lib.optionals (hypervisor != "qemu") [
                  { type = "user"; id = "eth0"; mac = "02:fc:00:00:00:01"; }
                ];
              socket = guestPkgs.lib.mkIf (hypervisor == "firecracker") "firecracker.sock";
              firecracker = guestPkgs.lib.optionalAttrs (hypervisor == "firecracker") {
                extraConfig = {
                  mmds-config = {
                    version = "V1";
                    ipv4_address = "169.254.169.254";
                    network_interfaces = [ "hb-fc0" ];
                  };
                };
              };
              extraArgsScript = guestPkgs.lib.optionalString (hypervisor == "qemu" || hypervisor == "vfkit")
                "${hebrahQemuExtraArgsScript hypervisor guestPkgs qemuMachine}";
              balloon = false;
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
          hypervisor =
            if templateId == "sidecar-base-fc" then "firecracker"
            else "qemu";
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
            "hypervisor": "${hypervisor}",
            "host_system": "${hostSystem}"
          }
          EOF
          ${if hypervisor == "firecracker" then ''
            cp ${./scripts/launch-firecracker.sh} $out/launch.sh
            cp ${./scripts/fc-snapshot-lib.sh} $out/fc-snapshot-lib.sh
            chmod +x $out/launch.sh $out/fc-snapshot-lib.sh
            # Pre-baked var.img for pool snapshot refill (skips mkfs.ext4 per slot).
            truncate -s 256M $out/var.img
            ${pkgs.e2fsprogs}/bin/mkfs.ext4 -F -L var $out/var.img
          '' else ''
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
            CONFIG_DIR="''${HEBRAH_VM_CONFIG_DIR:?HEBRAH_VM_CONFIG_DIR required}"
            LOGFILE="''${HEBRAH_VM_LOGFILE:-$CONFIG_DIR/vm.log}"
            mkdir -p "$CONFIG_DIR" "$(dirname "$LOGFILE")"
            cd "$CONFIG_DIR"
            nohup "$RUNNER" >"$LOGFILE" 2>&1 &
            echo $! > "''${HEBRAH_VM_PIDFILE:?}"
            LAUNCH
            chmod +x $out/launch.sh
          ''}
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
