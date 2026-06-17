{ config, lib, pkgs, ... }:

let
  healthScript = pkgs.writeShellScript "py-base-health" ''
    #!${pkgs.python3}/bin/python3
    import http.server
    import json
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/health":
                self.send_response(404); self.end_headers(); return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok", "template": "py-base"}).encode())
        def log_message(self, *args): pass
    http.server.HTTPServer(("0.0.0.0", 8080), H).serve_forever()
  '';
in
{
  options.services.hebrah-py-base.enable = lib.mkEnableOption "hebrah py-base template";

  config = {
    services.hebrah-py-base.enable = lib.mkDefault true;
    environment.systemPackages = [ pkgs.python3 pkgs.python3Packages.pip ];
    networking.firewall.allowedTCPPorts = [ 8080 ];
    systemd.services.hebrah-py-base-health = {
      description = "py-base health HTTP :8080";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        ExecStart = "${healthScript}";
      };
    };
  };
}
