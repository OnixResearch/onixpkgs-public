{
  lib,
  stdenv,
  rustPlatform,
  fetchFromGitHub,
  bash,
  b3sum,
  cmake,
  gitMinimal,
  jq,
  ninja,
  pkg-config,
  python3,
  llvmPackages,
  openssl,
  zlib,
  vulkan-headers,
  vulkan-loader,
  shaderc,
  spirv-headers,
  backend ? "cpu",
}:

assert lib.assertMsg (builtins.elem backend [
  "cpu"
  "vulkan"
]) "mesh-llm: supported backend profiles are cpu and vulkan";

let
  meshVersion = "0.72.1";
  meshRevision = "c14e458d38e201fa60d734f18e399aa2237033dd";
  meshSourceHash = "sha256-towoWqi33GlRlgG4e6bi6YumNYellUG6yGYq+ZV6nGw=";
  llamaRevision = "e3546c7948e3af463d0b401e6421d5a4c2faf565";
  llamaSourceHash = "sha256-X1wehkLYHl/ug/xWB3jhnp2NdEmw/8uD/ZS6AwIlJx0=";
  dependencyHash = "sha256-RjT8O0sXDmpDEDUaqhyhjG5bFBq3AXCn1x91D+9nT8s=";
  sourcePatch = ./mesh-llm-join-file.patch;
  runtimeLibraryPath = lib.makeLibraryPath (
    [
      stdenv.cc.cc.lib
      openssl
      zlib
    ]
    ++ lib.optional (backend == "vulkan") vulkan-loader
  );

  meshSource = fetchFromGitHub {
    owner = "Mesh-LLM";
    repo = "mesh-llm";
    rev = meshRevision;
    hash = meshSourceHash;
  };

  llamaSource = fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    rev = llamaRevision;
    hash = llamaSourceHash;
  };

  commonPreBuild = ''
    export LLAMA_STAGE_BACKEND='${backend}'
    export LLAMA_STAGE_LINK_MODE=static
    export LLAMA_STAGE_GGML_NATIVE=OFF
    export LLAMA_STAGE_USE_SCCACHE=0
    export LLAMA_STAGE_BUILD_DIR="$PWD/.deps/llama-build/build-stage-abi-static-${backend}"
    export SKIPPY_LLAMA_AUTO_BUILD=0
    export MESH_LLM_AUTO_BUILD_LLAMA=0
    export MESH_LLM_BUILD_VERSION='${meshVersion}+gc14e458d38e2'
    export RUSTFLAGS="''${RUSTFLAGS:+$RUSTFLAGS }-C link-arg=-fuse-ld=lld"

    LLAMA_WORKDIR="$PWD/.deps/llama.cpp" \
      LLAMA_BUILD_DIR="$LLAMA_STAGE_BUILD_DIR" \
      scripts/build-llama.sh
  '';
  vulkanCmakeArgs = lib.concatStringsSep " " [
    "-DSPIRV-Headers_DIR=${spirv-headers}/share/cmake/SPIRV-Headers"
    "-DCMAKE_CXX_FLAGS=-I${spirv-headers}/include"
  ];
  vulkanPreBuild =
    builtins.replaceStrings
      [ "scripts/build-llama.sh" ]
      [
        "scripts/build-llama.sh ${vulkanCmakeArgs}"
      ]
      commonPreBuild;
in
rustPlatform.buildRustPackage {
  pname = "mesh-llm-headless-${backend}";
  version = meshVersion;
  src = meshSource;

  patches = [ sourcePatch ];
  dontUseCmakeConfigure = true;
  dontUseNinjaBuild = true;
  dontUseNinjaInstall = true;

  cargoLock = {
    lockFile = meshSource + "/Cargo.lock";
    outputHashes = {
      "hf-hub-1.0.0" = dependencyHash;
    };
  };

  nativeBuildInputs = [
    bash
    b3sum
    cmake
    gitMinimal
    jq
    ninja
    pkg-config
    python3
    llvmPackages.lld
  ]
  ++ lib.optionals (backend == "vulkan") [
    shaderc
    spirv-headers
  ];

  buildInputs = [
    stdenv.cc.cc.lib
    openssl
    zlib
  ]
  ++ lib.optionals (backend == "vulkan") [
    vulkan-headers
    vulkan-loader
  ];

  postPatch = ''
    patchShebangs scripts
    mkdir -p .deps/llama.cpp
    cp -R ${llamaSource}/. .deps/llama.cpp/
    chmod -R u+w .deps/llama.cpp

    export GIT_AUTHOR_DATE='2000-01-01T00:00:00Z'
    export GIT_COMMITTER_DATE='2000-01-01T00:00:00Z'
    git -C .deps/llama.cpp init --quiet
    git -C .deps/llama.cpp config user.name "OnixOS reproducible package"
    git -C .deps/llama.cpp config user.email "onixos-package@invalid"
    git -C .deps/llama.cpp add .
    git -C .deps/llama.cpp commit --quiet -m "pin reviewed llama.cpp source"

    while IFS= read -r patch_file; do
      git -C .deps/llama.cpp am "$PWD/$patch_file"
    done < <(find third_party/llama.cpp/patches -maxdepth 1 -type f -name '*.patch' -print | sort)

    printf '%s\n' '${llamaRevision}' > .deps/llama.cpp/.mesh-llm-upstream-sha
    git -C .deps/llama.cpp rev-parse HEAD > .deps/llama.cpp/.mesh-llm-patched-sha
    b3sum third_party/llama.cpp/patches/*.patch | b3sum | cut -d ' ' -f 1 \
      > .deps/llama.cpp/.mesh-llm-patch-digest
  '';

  preBuild = if backend == "vulkan" then vulkanPreBuild else commonPreBuild;

  cargoBuildFlags = [
    "-p"
    "mesh-llm"
    "--bin"
    "mesh-llm"
    "--no-default-features"
  ];

  cargoTestFlags = [
    "-p"
    "mesh-llm"
    "--lib"
    "join_file"
  ];
  checkNoDefaultFeatures = true;
  checkPhase = ''
    runHook preCheck
    export LD_LIBRARY_PATH='${runtimeLibraryPath}'
    cargo test -p mesh-llm --lib --no-default-features join_file
    runHook postCheck
  '';

  postFixup = ''
    patchelf --add-rpath '${runtimeLibraryPath}' "$out/bin/mesh-llm"

    provenance_dir="$out/share/mesh-llm"
    mkdir -p "$provenance_dir"

    cat > "$provenance_dir/source-envelope.json" <<'EOF'
    {"backend":"${backend}","dependency_vendor_hash":"${dependencyHash}","headless":true,"llama_revision":"${llamaRevision}","llama_source_hash":"${llamaSourceHash}","mesh_revision":"${meshRevision}","mesh_source_hash":"${meshSourceHash}","mesh_version":"${meshVersion}","patch":"mesh-llm-join-file.patch","schema":"onixos.mesh-llm.source-envelope.v1"}
    EOF

    cargo metadata --format-version 1 --locked --offline \
      | jq -S '[.packages[] | {license, name, source, version}] | sort_by(.name, .version)' \
      > "$provenance_dir/license-inventory.json"

    source_blake3="$(b3sum "$provenance_dir/source-envelope.json" | cut -d ' ' -f 1)"
    license_inventory_blake3="$(b3sum "$provenance_dir/license-inventory.json" | cut -d ' ' -f 1)"
    binary_blake3="$(b3sum "$out/bin/mesh-llm" | cut -d ' ' -f 1)"
    cargo_lock_blake3="$(b3sum Cargo.lock | cut -d ' ' -f 1)"
    patch_blake3="$(b3sum ${sourcePatch} | cut -d ' ' -f 1)"

    cat > "$provenance_dir/provenance.json" <<EOF
    {"backend":"${backend}","binary_blake3":"$binary_blake3","cargo_lock_blake3":"$cargo_lock_blake3","dependency_vendor_hash":"${dependencyHash}","headless":true,"license_inventory_blake3":"$license_inventory_blake3","llama_revision":"${llamaRevision}","llama_source_hash":"${llamaSourceHash}","mesh_revision":"${meshRevision}","mesh_source_hash":"${meshSourceHash}","mesh_version":"${meshVersion}","patch_blake3":"$patch_blake3","release_attestation":"missing-source-build","schema":"onixos.mesh-llm.package-provenance.v1","source_blake3":"$source_blake3","upstream_license_expression":"MIT OR Apache-2.0"}
    EOF
  '';

  passthru.provenance = {
    inherit backend;
    cargoVendorHash = dependencyHash;
    inherit
      llamaRevision
      meshRevision
      meshSourceHash
      llamaSourceHash
      ;
    inherit sourcePatch;
  };

  meta = {
    description = "Pinned headless ${backend} build of Mesh LLM for private OnixOS service profiles";
    homepage = "https://github.com/Mesh-LLM/mesh-llm";
    license = with lib.licenses; [
      mit
      asl20
    ];
    mainProgram = "mesh-llm";
    platforms = lib.platforms.unix;
  };
}
