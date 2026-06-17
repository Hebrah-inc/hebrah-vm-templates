{ lib, pkgs, python3 }:

pkgs.writeScript "hebrah-sidecar-health" ''
  #!${python3}/bin/python3
  ${lib.readFile ./hebrah-sidecar-health.py}
''
