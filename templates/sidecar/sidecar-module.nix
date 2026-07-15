{ config, lib, pkgs, ... }:

let
  healthPkg = pkgs.callPackage ../../packages/hebrah-sidecar-health.nix { };
  hl7Pkg = pkgs.callPackage ../../packages/hebrah-sidecar-hl7.nix { };
  writebackPkg = pkgs.callPackage ../../packages/hebrah-sidecar-writeback.nix { };
  syntheticEhrPkg = pkgs.callPackage ../../packages/hebrah-synthetic-ehr.nix { };
in
{
  options.services.hebrah-sidecar = {
    enable = lib.mkEnableOption "hebrah connection sidecar agent";
  };

  config = {
    services.hebrah-sidecar.enable = lib.mkDefault true;

    # Faster Firecracker boot — no serial/login on microVM guests.
    systemd.services."serial-getty@ttyS0".enable = lib.mkIf (config.microvm.hypervisor == "firecracker") false;
    systemd.services."getty@tty1".enable = lib.mkIf (config.microvm.hypervisor == "firecracker") false;

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

    # Firecracker: IP comes from kernel cmdline (ip=…) patched by launch-firecracker.sh.
    networking.useDHCP = lib.mkIf (config.microvm.hypervisor == "firecracker") false;
    networking.useNetworkd = lib.mkIf (config.microvm.hypervisor == "firecracker") false;
    networking.firewall.enable = lib.mkIf (config.microvm.hypervisor == "firecracker") (lib.mkForce false);
    networking.nftables.enable = lib.mkIf (config.microvm.hypervisor == "firecracker") (lib.mkForce false);

    environment.systemPackages = lib.mkIf (config.microvm.hypervisor == "firecracker") [
      pkgs.curl
      pkgs.iproute2
    ];

    # Apply kernel ip=… autoconfig that NixOS scripted networking may skip.
    systemd.services.hebrah-fc-net = lib.mkIf (config.microvm.hypervisor == "firecracker") {
      description = "Configure Firecracker tap IP from kernel cmdline";
      wantedBy = [ "multi-user.target" ];
      after = [ "sysinit.target" "systemd-modules-load.service" ];
      before = [ "hebrah-sidecar-config.service" "hebrah-sidecar-health.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StandardOutput = "journal+console";
        StandardError = "journal+console";
        ExecStart = pkgs.writeShellScript "hebrah-fc-net" ''
          set -eu
          echo "hebrah-fc-net: ifaces=$(ls /sys/class/net | tr '\n' ' ')"
          CMDLINE="$(cat /proc/cmdline)"
          IP_TOKEN="$(printf '%s\n' "$CMDLINE" | tr ' ' '\n' | grep '^ip=' | head -1 || true)"
          echo "hebrah-fc-net: token=$IP_TOKEN"
          if [ -z "$IP_TOKEN" ]; then
            exit 0
          fi
          REST="''${IP_TOKEN#ip=}"
          CLIENT="''${REST%%:*}"
          REST2="''${REST#*:}"
          REST2="''${REST2#*:}"
          GW="''${REST2%%:*}"
          IFACE=""
          for cand in eth0 ens3 ens4 enp0s3 enp0s4 enp0s5; do
            if [ -e "/sys/class/net/$cand" ]; then
              IFACE="$cand"
              break
            fi
          done
          if [ -z "$IFACE" ]; then
            IFACE="$(ls /sys/class/net | grep -v '^lo$' | head -1 || true)"
          fi
          echo "hebrah-fc-net: iface=$IFACE client=$CLIENT gw=$GW"
          if [ -z "$IFACE" ] || [ -z "$CLIENT" ]; then
            exit 0
          fi
          ${pkgs.iproute2}/bin/ip link set "$IFACE" up
          ${pkgs.iproute2}/bin/ip addr replace "$CLIENT/24" dev "$IFACE"
          if [ -n "$GW" ]; then
            ${pkgs.iproute2}/bin/ip route replace default via "$GW" dev "$IFACE" || true
          fi
          ${pkgs.iproute2}/bin/ip route replace 169.254.169.254/32 dev "$IFACE" || true
          ${pkgs.iproute2}/bin/ip addr show "$IFACE" || true
        '';
      };
    };

    systemd.network.wait-online.enable = lib.mkDefault false;

    # Firecracker: no 9p — guest reads /etc/hebrah.env (MMDS / launch injection on Linux KVM).
    systemd.services.hebrah-sidecar-config = {
      description = "Load hebrah sidecar config from virtiofs share or /etc/hebrah.env";
      wantedBy = [ "multi-user.target" ];
      before = [
        "hebrah-sidecar-health.service"
        "hebrah-sidecar-hl7.service"
        "hebrah-sidecar-writeback.service"
        "hebrah-synthetic-ehr.service"
        "hebrah-sidecar-wg.service"
      ];
      after = lib.mkIf (config.microvm.hypervisor == "firecracker") [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "hebrah-config-check" ''
          set -eu
          if [ -f /hebrah-config/hebrah.env ]; then
            cp /hebrah-config/hebrah.env /etc/hebrah.env
          elif [ -f /etc/hebrah.env ]; then
            :
          else
            # MMDS V1 — orchestrator PUT {"hebrah.env": "..."} after boot
            IFACE=""
            for cand in ens3 eth0 enp0s3 enp0s4; do
              if [ -e "/sys/class/net/$cand" ]; then IFACE="$cand"; break; fi
            done
            if [ -z "$IFACE" ]; then
              IFACE="$(ls /sys/class/net | grep -v '^lo$' | head -1 || true)"
            fi
            if [ -n "$IFACE" ]; then
              ${pkgs.iproute2}/bin/ip route replace 169.254.169.254/32 dev "$IFACE" 2>/dev/null || true
            fi
            for _ in $(seq 1 30); do
              if ${pkgs.curl}/bin/curl -fsS --connect-timeout 1 http://169.254.169.254/hebrah.env \
                  -o /etc/hebrah.env 2>/dev/null; then
                break
              fi
              sleep 1
            done
          fi
          if [ -f /etc/hebrah.env ]; then
            mkdir -p /hebrah-config
            cp /etc/hebrah.env /hebrah-config/hebrah.env
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
        Restart = "always";
        RestartSec = "2s";
        StateDirectory = "hebrah-sidecar";
        # QEMU uses 9p /hebrah-config; Firecracker uses /etc/hebrah.env via MMDS (tmpfiles dir only).
        RequiresMountsFor = lib.mkIf (config.microvm.hypervisor == "qemu") [ "/hebrah-config" ];
        StandardOutput = "journal+console";
        StandardError = "journal+console";
        Environment = [
          "HEBRAH_CONFIG_DIR=/hebrah-config"
          "HEBRAH_STATE_DIR=/var/lib/hebrah-sidecar"
        ];
        EnvironmentFile = lib.mkIf (config.microvm.hypervisor == "firecracker") "-/etc/hebrah.env";
        ExecStartPre = pkgs.writeShellScript "hebrah-9p-probe" ''
          set -eu
          if [ -f /etc/hebrah.env ] && [ ! -f /hebrah-config/hebrah.env ]; then
            mkdir -p /hebrah-config
            cp /etc/hebrah.env /hebrah-config/hebrah.env 2>/dev/null || true
          fi
          if [ -f /hebrah-config/hebrah.env ]; then
            # shellcheck disable=SC1091
            source /hebrah-config/hebrah.env
            cat > /hebrah-config/health.json <<EOF
{"status":"ok","vm_id":"''${HEBRAH_VM_ID:-unknown}","stage":"ready","org_id":"''${HEBRAH_ORG_ID:-}","connection_id":"''${HEBRAH_CONNECTION_ID:-}","environment":"''${HEBRAH_ENVIRONMENT:-}"}
EOF
          elif [ -f /etc/hebrah.env ]; then
            # shellcheck disable=SC1091
            source /etc/hebrah.env
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
        ExecStartPre = lib.mkIf (config.microvm.hypervisor == "qemu") (pkgs.writeShellScript "hebrah-hl7-9p-slot" ''
          set -eu
          printf '%s\n' '{"message":""}' > /hebrah-config/hl7_inject.json
          printf '%s\n' '{}' > /hebrah-config/hl7_ack.json
        '');
        ExecStart = "${hl7Pkg}/bin/hebrah-sidecar-hl7";
      };
    };

    systemd.services.hebrah-sidecar-hl7-9p-inject = lib.mkIf (config.microvm.hypervisor == "qemu") {
      description = "Process HL7 inject file from 9p share";
      serviceConfig = {
        Type = "oneshot";
        Environment = [ "HEBRAH_CONFIG_DIR=/hebrah-config" ];
        ExecStart = "${hl7Pkg}/bin/hebrah-sidecar-hl7 --inject-file";
      };
    };

    systemd.timers.hebrah-sidecar-hl7-9p-inject = lib.mkIf (config.microvm.hypervisor == "qemu") {
      description = "Poll 9p share for hl7_inject.json";
      wantedBy = [ "multi-user.target" ];
      after = [ "hebrah-sidecar-config.service" "remote-fs.target" ];
      timerConfig = {
        OnBootSec = "15s";
        OnUnitActiveSec = "2s";
      };
    };

    systemd.services.hebrah-synthetic-ehr = {
      description = "hebrah per-VM synthetic EHR (vendor-aware FHIR store)";
      wantedBy = [ "multi-user.target" ];
      after = [ "hebrah-sidecar-config.service" ];
      before = [ "hebrah-sidecar-health.service" ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "2s";
        Environment = [
          "HEBRAH_CONFIG_DIR=/hebrah-config"
          "HEBRAH_STATE_DIR=/var/lib/hebrah-sidecar"
          "HEBRAH_SYNTHETIC_EHR_PORT=8090"
        ];
        ExecStart = "${syntheticEhrPkg}/bin/hebrah-synthetic-ehr";
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

    networking.firewall.allowedTCPPorts = [ 8080 8082 8083 8090 2575 ];

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
