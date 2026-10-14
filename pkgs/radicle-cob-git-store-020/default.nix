{
  lib,
  radicle-cob-git-store,
}:

radicle-cob-git-store.override {
  crateSource = lib.cleanSource ./vendor/onix-radicle-cob-git-store;
  crateLock = ./vendor/onix-radicle-cob-git-store/Cargo.lock;
  crateVersion = "0.1.1";
}
