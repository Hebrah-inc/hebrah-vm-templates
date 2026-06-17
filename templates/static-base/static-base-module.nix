{ config, lib, pkgs, ... }:

let
  healthScript = pkgs.writeShellScript "static-base-health" ''
    #!${pkgs.python3}/bin/python3
    import http.server, json
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/health":
                self.send_response(404); self.end_headers(); return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok", "template": "static-base"}).encode())
        def log_message(self, *args): pass
    http.server.HTTPServer(("0.0.0.0", 8080), H).serve_forever()
  '';
in
{
  options.services.hebrah-static-base.enable = lib.mkEnableOption "hebrah static-base template";

  config = {
    services.hebrah-static-base.enable = lib.mkDefault true;
    environment.systemPackages = [ pkgs.nginx ];
    networking.firewall.allowedTCPPorts = [ 8080 ];
    systemd.services.hebrah-static-base-health = {
      description = "static-base health HTTP :8080";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        ExecStart = "${healthScript}";
      };
    };
  };
}
