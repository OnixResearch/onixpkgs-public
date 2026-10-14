{
  lib,
  python3,
  writeShellApplication,
}:
let
  python = python3.withPackages (ps: [
    ps.pyarrow
    ps.huggingface-hub
    ps.fsspec
    ps.aiohttp
  ]);
in
writeShellApplication {
  name = "arxiv-corpus";
  text = ''
    export HF_HUB_DISABLE_TELEMETRY=1
    exec ${python}/bin/python ${./server.py} "$@"
  '';
  meta = {
    description = "Search the arXiv Complete metadata snapshot and read selected paper text";
    platforms = lib.platforms.linux;
    mainProgram = "arxiv-corpus";
  };
}
