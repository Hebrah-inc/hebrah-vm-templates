{ lib, pkgs, python3 }:

pkgs.writeScriptBin "hebrah-sidecar-hl7" ''
  #!${python3}/bin/python3
  ${lib.readFile ./hebrah-sidecar-hl7.py}
''
