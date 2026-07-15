{ lib, pkgs, python3 }:

pkgs.writeScriptBin "hebrah-synthetic-ehr" ''
  #!${python3}/bin/python3
  ${lib.readFile ./hebrah-synthetic-ehr.py}
''
