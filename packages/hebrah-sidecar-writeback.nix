{ lib, pkgs, python3 }:

pkgs.writeScriptBin "hebrah-sidecar-writeback" ''
  #!${python3}/bin/python3
  ${lib.readFile ./hebrah-sidecar-writeback.py}
''
