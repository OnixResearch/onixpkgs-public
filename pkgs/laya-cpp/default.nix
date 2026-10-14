{
  lib,
  stdenv,
  fetchzip,
  fetchurl,
  cmake,
  ninja,
  pkg-config,
  icu,
  nlohmann_json,
  vulkan-headers,
  vulkan-loader,
  shaderc,
  spirv-headers,
  python3,
  runCommand,
  writeShellApplication,
  writeText,
}:
let
  runtimeRevision = "3ca6a325f9b357da518f8030ad6edece3c80146a";
  manifest = builtins.fromJSON (builtins.readFile ./model-manifest.json);
  provenance = writeText "laya-cpp-source-manifest.json" (
    builtins.toJSON {
      runtime = "laya.cpp";
      runtime_revision = runtimeRevision;
      source_url = "https://github.com/lkarlslund/laya.cpp";
      ggml_revision = "456172ec733a135778adcd32d00e576a58232e45";
      httplib_revision = "dc6faf5c17c1e3c30b5d59e31ae2e890a35e64e1";
      model = manifest.repo;
      inherit (manifest) revision;
      patches = [
        {
          name = "vulkan-only.patch";
          description = "Reject nonphysical Vulkan GPU devices; inference arithmetic is unchanged";
          sha256 = builtins.hashFile "sha256" ./vulkan-only.patch;
        }
      ];
    }
  );
  ggml = fetchzip {
    url = "https://github.com/ggml-org/ggml/archive/456172ec733a135778adcd32d00e576a58232e45.tar.gz";
    sha256 = "0jjxpmnbc7kfq00f5z8j49lqhdj7aklsvj7c5a0wr845fhd388n1";
  };
  httplib = fetchzip {
    url = "https://github.com/yhirose/cpp-httplib/archive/dc6faf5c17c1e3c30b5d59e31ae2e890a35e64e1.tar.gz";
    sha256 = "18whxq0435nxqczn0szas7qnv47dj7l3hlhzzz3ca70hbsgp5id6";
  };
  native = stdenv.mkDerivation {
    pname = "laya-cpp";
    version = "0.2.0-${builtins.substring 0 7 runtimeRevision}";
    src = fetchzip {
      url = "https://github.com/lkarlslund/laya.cpp/archive/${runtimeRevision}.tar.gz";
      sha256 = "1syypypdh66k8hrac1znyvscpfbxjzhm6lf377y3rl77x7425d4p";
    };
    postUnpack = ''
      mkdir -p "$sourceRoot/third_party/ggml" "$sourceRoot/third_party/cpp-httplib"
      cp -R ${ggml}/. "$sourceRoot/third_party/ggml/"
      cp -R ${httplib}/. "$sourceRoot/third_party/cpp-httplib/"
      chmod -R u+w "$sourceRoot/third_party"
    '';
    patches = [ ./vulkan-only.patch ];
    nativeBuildInputs = [
      cmake
      ninja
      pkg-config
      shaderc
    ];
    buildInputs = [
      icu
      nlohmann_json
      vulkan-headers
      vulkan-loader
      spirv-headers
    ];
    cmakeFlags = [
      "-DLAYA_CUDA=OFF"
      "-DLAYA_VULKAN=ON"
      "-DBUILD_TESTING=OFF"
      "-DBUILD_SHARED_LIBS=ON"
      "-DGGML_NATIVE=OFF"
      "-DGGML_CCACHE=OFF"
      "-DGGML_BACKEND_DL=OFF"
      "-DGGML_BUILD_COMMIT=456172ec733a135778adcd32d00e576a58232e45"
      "-DCMAKE_INSTALL_LIBDIR=lib"
      "-DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON"
    ];
    postPatch = ''
      echo 'install(TARGETS laya laya-cli LIBRARY DESTINATION lib RUNTIME DESTINATION bin)' >> CMakeLists.txt
    '';
    preConfigure = ''
      cmakeFlagsArray+=("-DCMAKE_INSTALL_RPATH=$out/lib")
    '';
    postInstall = ''
      install -Dm644 ../LICENSE "$out/share/licenses/laya-cpp/LICENSE"
      install -Dm644 ../third_party/ggml/LICENSE "$out/share/licenses/laya-cpp/ggml-LICENSE"
      install -Dm644 ../third_party/cpp-httplib/LICENSE "$out/share/licenses/laya-cpp/cpp-httplib-LICENSE"
      install -Dm644 ${./vulkan-only.patch} "$out/share/laya-cpp/vulkan-only.patch"
      install -Dm644 ${provenance} "$out/share/laya-cpp/source-manifest.json"
    '';
    meta = {
      description = "Laya native compensated FP32 inference restricted to physical Vulkan GPUs";
      homepage = "https://github.com/lkarlslund/laya.cpp";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
    };
  };
  modelCard = fetchurl {
    url = "https://huggingface.co/${manifest.repo}/resolve/${manifest.revision}/README.md";
    sha256 = "1vk0am7mdmri07ikxhrvnsln8qk272513ljmnx5pb13lv0lid49k";
  };
  modelLicense = fetchurl {
    url = "https://www.apache.org/licenses/LICENSE-2.0.txt";
    sha256 = "0c1xaay1fd00xgri0z447q2i8s3mpxqw9da27hfd6fznjsdp9iyg";
  };
  model =
    runCommand "laya-english-${manifest.revision}"
      {
        meta.license = lib.licenses.asl20;
      }
      ''
        mkdir -p "$out"
        ${lib.concatMapStringsSep "\n" (
          file:
          let
            source = fetchurl { inherit (file) url sha256; };
          in
          ''
            mkdir -p "$out/${builtins.dirOf file.path}"
            ln -s ${source} "$out/${file.path}"
          ''
        ) manifest.files}
        cp ${./model-manifest.json} "$out/model-manifest.json"
        cp ${modelCard} "$out/MODEL_CARD"
        cp ${modelLicense} "$out/LICENSE"
      '';
  adapter = runCommand "laya-cpp-adapter" { } ''
    mkdir -p "$out"
    cp ${./server.py} "$out/server.py"
    cp ${../laya/server.py} "$out/laya_api.py"
  '';
in
writeShellApplication {
  name = "laya-cpp-server";
  text = ''
    export LAYA_CPP_CLI=${native}/bin/laya-cli
    export LAYA_CPP_MODEL=${model}
    export LAYA_CPP_RUNTIME_REVISION=${runtimeRevision}
    export LAYA_CPP_PROVENANCE=${provenance}
    export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1
    exec ${python3}/bin/python -I ${adapter}/server.py "$@"
  '';
  passthru = { inherit native model; };
  meta = {
    description = "Private Laya typed decisions using resident compensated FP32 Vulkan inference";
    platforms = lib.platforms.linux;
    mainProgram = "laya-cpp-server";
  };
}
