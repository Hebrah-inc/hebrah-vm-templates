{ lib, pkgs, python3 }:

pkgs.writeScript "hebrah-sidecar-writeback" ''
  #!${python3}/bin/python3
  ${lib.readFile ./hebrah-sidecar-writeback.py}
''
