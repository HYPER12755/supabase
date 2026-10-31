{ pkgs, ... }: {
  channel = "stable-25.05";

  packages = [
    pkgs.nodejs_22
    pkgs.pnpm
    pkgs.git
    pkgs.gnumake
    pkgs.gcc
    pkgs.python3
    pkgs.pkg-config
    pkgs.cacert
    pkgs.openssl
    pkgs.jq
    pkgs.curl
    pkgs.gnutar
    pkgs.gzip
    pkgs.gnused
    pkgs.gnugrep
    pkgs.which
    pkgs.docker-compose
  ];

  services.docker.enable = true;

  idx.workspace.onStart = {
    docker-compose-plugin = ''
      mkdir -p "$HOME/.docker/cli-plugins"
      ln -sfn "${pkgs.docker-compose}/bin/docker-compose" "$HOME/.docker/cli-plugins/docker-compose"
    '';
  };
}
