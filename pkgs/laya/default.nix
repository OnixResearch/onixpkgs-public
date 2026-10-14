{
  lib,
  python3,
  fetchurl,
  writeShellApplication,
}:
let
  cpuPython = python3.override {
    packageOverrides = final: previous: {
      torch = previous.torch.override {
        cudaSupport = false;
        rocmSupport = false;
      };
      laya = final.buildPythonPackage {
        pname = "laya";
        version = "0.3.4";
        format = "wheel";
        src = fetchurl {
          url = "https://files.pythonhosted.org/packages/09/b4/0f22ac636d2545e6f4a7fcaf3a65bc2715ff1db3a667bc5b930e4f40c057/laya-0.3.4-py3-none-any.whl";
          sha256 = "8bf1c5cc5cbf6abebf63a6346b4babedd5692f88a75aa9e0cc01ed4145a9a14b";
        };
        dependencies = [
          final.torch
          final.transformers
          final.safetensors
          final.huggingface-hub
          final.numpy
        ];
        pythonImportsCheck = [ "laya" ];
        USE_TF = "0";
      };
    };
  };
  python = cpuPython.withPackages (ps: [ ps.laya ]);
in
writeShellApplication {
  name = "laya-server";
  text = ''
    export USE_TF=0 HF_HUB_DISABLE_TELEMETRY=1 TOKENIZERS_PARALLELISM=false
    exec ${python}/bin/python ${./server.py} "$@"
  '';
  meta = {
    description = "Private CPU-only typed decisions with the pinned Laya checkpoint";
    platforms = lib.platforms.linux;
    mainProgram = "laya-server";
  };
}
