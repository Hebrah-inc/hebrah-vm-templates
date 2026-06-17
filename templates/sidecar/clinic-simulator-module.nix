{ config, lib, pkgs, ... }:

let
  clinicServer = pkgs.writeScript "hebrah-clinic-hl7" ''
    #!${pkgs.python3}/bin/python3
    ${lib.readFile ../packages/clinic-hl7-server.py}
  '';
in
{
  options.services.hebrah-clinic-simulator = {
    enable = lib.mkEnableOption "hebrah clinic FHIR + HL7 simulator microVM";
  };

  config = {
    services.hebrah-clinic-simulator.enable = lib.mkDefault true;

    systemd.services.hebrah-clinic-fhir = {
      description = "Clinic simulator FHIR + HL7 send endpoint on :8081";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        Environment = [
          "HEBRAH_CONFIG_DIR=/hebrah-config"
          "HEBRAH_CLINIC_HTTP_PORT=8081"
        ];
        ExecStart = clinicServer;
      };
    };

    networking.firewall.allowedTCPPorts = [ 8081 ];
  };
}
