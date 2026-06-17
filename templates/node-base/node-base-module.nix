{ config, lib, pkgs, ... }:

let
  healthScript = pkgs.writeShellScript "node-base-health" ''
    #!${pkgs.nodejs}/bin/node
    const http = require("http");
    http.createServer((req, res) => {
      if (req.url !== "/health") { res.writeHead(404); return res.end(); }
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "ok", template: "node-base" }));
    }).listen(8080, "0.0.0.0");
  '';
in
{
  options.services.hebrah-node-base.enable = lib.mkEnableOption "hebrah node-base template";

  config = {
    services.hebrah-node-base.enable = lib.mkDefault true;
    environment.systemPackages = [ pkgs.nodejs pkgs.nodePackages.npm ];
    networking.firewall.allowedTCPPorts = [ 8080 ];
    systemd.services.hebrah-node-base-health = {
      description = "node-base health HTTP :8080";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        ExecStart = "${healthScript}";
      };
    };
  };
}
