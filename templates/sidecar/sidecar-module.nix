{ config, lib, pkgs, ... }:

let
  healthPkg = pkgs.callPackage ../../packages/hebrah-sidecar-health.nix { };
  hl7Pkg = pkgs.callPackage ../../packages/hebrah-sidecar-hl7.nix { };
  writebackPkg = pkgs.callPackage ../../packages/hebrah-sidecar-writeback.nix { };
in
{
  options.services.hebrah-sidecar = {
    enable = lib.mkEnableOption "hebrah connection sidecar agent";
  };

  config = {
    services.hebrah-sidecar.enable = lib.mkDefault true;

    # QEMU extraArgsScript exposes tag hebrah-config via virtio-9p — mount in guest.
    fileSystems."/hebrah-config" = lib.mkIf (config.microvm.hypervisor == "qemu") {
      device = "hebrah-config";
      fsType = "9p";
      options = [ "trans=virtio" "version=9p2000.L" "msize=104857600" "cache=none" "rw" ];
      neededForBoot = false;
    };

    systemd.tmpfiles.rules = lib.mkIf (config.microvm.hypervisor != "qemu") [
      "d /hebrah-config 0755 root root -"
    ];

    systemd.network.wait-online.enable = lib.mkDefault false;

    systemd.services.hebrah-sidecar-config = {
      description = "Load hebrah sidecar config from virtiofs share";
      wantedBy = [ "multi-user.target" ];
      before = [
        "hebrah-sidecar-health.service"
        "hebrah-sidecar-hl7.service"
        "hebrah-sidecar-writeback.service"
        "hebrah-sidecar-wg.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "hebrah-config-check" ''
          set -eu
          if [ -f /hebrah-config/hebrah.env ]; then
            cp /hebrah-config/hebrah.env /etc/hebrah.env
          fi
        '';
      };
    };

    systemd.services.hebrah-sidecar-health = {
      description = "hebrah sidecar health HTTP server";
      wantedBy = [ "multi-user.target" ];
      before = [
        "serial-getty@ttyS0.service"
        "getty@tty1.service"
      ];
      after = [
        "hebrah-sidecar-config.service"
        "remote-fs.target"
      ];
      requires = [ "hebrah-sidecar-config.service" ];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = "5s";
        StateDirectory = "hebrah-sidecar";
        RequiresMountsFor = "/hebrah-config";
        StandardOutput = "journal+console";
        StandardError = "journal+console";
        Environment = [
          "HEBRAH_CONFIG_DIR=/hebrah-config"
          "HEBRAH_STATE_DIR=/var/lib/hebrah-sidecar"
        ];
        ExecStartPre = pkgs.writeShellScript "hebrah-9p-probe" ''
          set -eu
          if [ -f /hebrah-config/hebrah.env ]; then
            # shellcheck disable=SC1091
            source /hebrah-config/hebrah.env
            cat > /hebrah-config/health.json <<EOF
{"status":"ok","vm_id":"''${HEBRAH_VM_ID:-unknown}","stage":"ready","org_id":"''${HEBRAH_ORG_ID:-}","connection_id":"''${HEBRAH_CONNECTION_ID:-}","environment":"''${HEBRAH_ENVIRONMENT:-}"}
EOF
          fi
        '';
        ExecStart = "${healthPkg}/bin/hebrah-sidecar-health";
      };
    };

    systemd.services.hebrah-sidecar-hl7 = {
      description = "hebrah sidecar HL7 MLLP + HTTP inject";
      wantedBy = [ "multi-user.target" ];
      after = [ "hebrah-sidecar-health.service" "hebrah-sidecar-config.service" ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "2s";
        Environment = [
          "HEBRAH_CONFIG_DIR=/hebrah-config"
          "HEBRAH_HL7_HTTP_PORT=8083"
          "HEBRAH_HL7_MLLP_PORT=2575"
        ];
        ExecStart = "${hl7Pkg}/bin/hebrah-sidecar-hl7";
      };
    };

    systemd.services.hebrah-sidecar-writeback = {
      description = "hebrah sidecar synthetic EHR write-back";
      wantedBy = [ "multi-user.target" ];
      after = [ "hebrah-sidecar-health.service" "hebrah-sidecar-config.service" ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "2s";
        Environment = [
          "HEBRAH_CONFIG_DIR=/hebrah-config"
          "HEBRAH_WRITEBACK_PORT=8082"
        ];
        ExecStart = "${writebackPkg}/bin/hebrah-sidecar-writeback";
      };
    };

    networking.firewall.allowedTCPPorts = [ 8080 8082 8083 2575 ];

    systemd.services.hebrah-sidecar-wg = {
      description = "hebrah sidecar WireGuard interface";
      wantedBy = [ "multi-user.target" ];
      after = [ "hebrah-sidecar-config.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "hebrah-wg-up" ''
          set -eu
          if [ ! -f /hebrah-config/hebrah.env ]; then
            exit 0
          fi
          # shellcheck disable=SC1091
          source /hebrah-config/hebrah.env
          if [ -z "''${HEBRAH_WG_PRIVATE_KEY:-}" ]; then
            exit 0
          fi
          mkdir -p /etc/wireguard
          umask 077
          cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = ''${HEBRAH_WG_PRIVATE_KEY}
Address = 10.8.0.2/32
ListenPort = ''${HEBRAH_WG_LISTEN_PORT:-51820}

EOF
          ${pkgs.wireguard-tools}/bin/wg-quick up wg0 || true
        '';
        ExecStop = "${pkgs.wireguard-tools}/bin/wg-quick down wg0";
      };
    };
  };
}
