{
  pkgs,
  irohSsh,
}:

let
  childFailureExitCode = 23;
  commandTimeoutSeconds = 30;
  testEndpointId = "0000000000000000000000000000000000000000000000000000000000000000";
in
pkgs.runCommand "iroh-ssh-child-status-check"
  {
    nativeBuildInputs = [
      irohSsh
      pkgs.coreutils
    ];
  }
  ''
    mkdir fake-bin home
    cat > fake-bin/ssh <<'SCRIPT'
    #!${pkgs.runtimeShell}
    exit "$ONIX_FAKE_SSH_EXIT_CODE"
    SCRIPT
    chmod +x fake-bin/ssh

    run_case() {
      expected="$1"
      set +e
      HOME="$PWD/home" \
        PATH="$PWD/fake-bin:${pkgs.coreutils}/bin" \
        ONIX_FAKE_SSH_EXIT_CODE="$expected" \
        timeout ${toString commandTimeoutSeconds} \
        ${irohSsh}/bin/iroh-ssh connect root@${testEndpointId} \
        > "case-$expected.log" 2>&1
      actual="$?"
      set -e
      test "$actual" -eq "$expected"
    }

    run_case 0
    run_case ${toString childFailureExitCode}

    mkdir -p "$out"
    printf 'positive_child_status=pass\nnegative_child_status=pass\nchild_failure_exit=%s\n' \
      ${toString childFailureExitCode} > "$out/receipt.txt"
  ''
