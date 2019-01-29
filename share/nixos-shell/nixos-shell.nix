{ lib, options, config, pkgs, ... }:

let
  nixos_config = builtins.getEnv "QEMU_NIXOS_CONFIG";
  cfg = config.nixos-shell;
in {
  imports = lib.optional (nixos_config != "") nixos_config ++ [
    <nixpkgs/nixos/modules/virtualisation/qemu-vm.nix>
  ];

  options.nixos-shell = with lib; {
    extraPath = mkOption {
      type = types.str;
      default = "";
    };

    mounts = let
      cache = mkOption {
        type = types.enum ["none" "loose" "fscache" "mmap"];
        default = "loose"; # bad idea? Well, at least it is fast!1!!
      };
    in {
      mountHome = mkOption {
        type = types.bool;
        default = true;
      };

      mountNixProfile = mkOption {
        type = types.bool;
        default = true;
      };

      inherit cache;

      extraMounts = mkOption {
        type = types.attrsOf (types.submodule ({ config, ... }: {
          options = {
            target = mkOption {
              type = types.path;
            };

            inherit cache;

            tag = mkOption {
              type = types.str;
              internal = true;
            };
          };

          config.tag = lib.mkVMOverride (
            builtins.substring 0 31 ( # tags must be shorter than 32 bytes
              "a" + # tags must not begin with a digit
              builtins.hashString "md5" config._module.args.name
            )
          );
        }));
        default = {};
      };
    };
  };

  config = let
    user = builtins.getEnv "USER";
    shell = builtins.baseNameOf (builtins.getEnv "SHELL");
  in lib.mkMerge [
    # Enable the module of the user's shell for some sensible defaults.
    (lib.mkIf (options.programs ? ${shell}.enable) {
      programs.${shell}.enable = lib.mkVMOverride true;
    })

    (lib.mkIf (pkgs ? ${shell}) {
      users.extraUsers.root.shell = lib.mkVMOverride pkgs.${shell};
    })

    (let
      home = builtins.getEnv "HOME";
    in lib.mkIf (home != "" && cfg.mounts.mountHome) {
      users.extraUsers.root.home = lib.mkVMOverride home;
    })

    # Allow passwordless ssh login with the user's key if it exists.
    (let
      pubkey = "${builtins.getEnv "HOME"}/.ssh/id_rsa.pub";
    in lib.mkIf (builtins.pathExists pubkey) {
      users.users.root.openssh.authorizedKeys.keyFiles = [ pubkey ];
    })

    {
      # Allow the user to login as root without password.
      users.extraUsers.root.initialHashedPassword = "";

      services.mingetty.helpLine = ''
        Log in as "root" with an empty password.
      '';

      virtualisation = {
        graphics = lib.mkVMOverride false;
        memorySize = lib.mkVMOverride "500M";

        qemu.options = let
          nixProfile = "/nix/var/nix/profiles/per-user/${user}/profile/";
        in
          lib.optional cfg.mounts.mountHome "-virtfs local,path=/home,security_model=none,mount_tag=home" ++
          lib.optional (cfg.mounts.mountNixProfile && builtins.pathExists nixProfile) "-virtfs local,path=${nixProfile},security_model=none,mount_tag=nixprofile" ++
          lib.mapAttrsToList (target: mount: "-virtfs local,path=${builtins.toString mount.target},security_model=none,mount_tag=${mount.tag}") cfg.mounts.extraMounts;
      };

      # build-vm overrides our filesystem settings in nixos-config
      boot.initrd.postMountCommands =
        (lib.optionalString cfg.mounts.mountHome ''
          mkdir -p $targetRoot/home/
          mount -t 9p home $targetRoot/home/ -o trans=virtio,version=9p2000.L,cache=${cfg.mounts.cache}
        '') +
        (lib.optionalString (user != "" && cfg.mounts.mountNixProfile) ''
          mkdir -p $targetRoot/nix/var/nix/profiles/per-user/${user}/profile/
          mount -t 9p nixprofile $targetRoot/nix/var/nix/profiles/per-user/${user}/profile/ -o trans=virtio,version=9p2000.L,cache=${cfg.mounts.cache}
        '') +
        builtins.concatStringsSep " " (lib.mapAttrsToList (target: mount: ''
          mkdir -p $targetRoot/${target}
          mount -t 9p ${mount.tag} $targetRoot/${target} -o trans=virtio,version=9p2000.L,cache=${mount.cache}
        '') cfg.mounts.extraMounts);

      environment = {
        systemPackages = with pkgs; [
          xterm # for resize command
        ];

        loginShellInit = let
          pwd = builtins.getEnv "PWD";
          term = builtins.getEnv "TERM";
        in ''
          # fix terminal size
          eval "$(resize)"

          ${lib.optionalString (pwd != "") "cd '${pwd}' 2>/dev/null"}
          ${lib.optionalString (term != "") "export TERM='${term}'"}
          ${lib.optionalString (cfg.extraPath != "") "export PATH='${cfg.extraPath}:$PATH'"}
        '';
      };

      networking.firewall.enable = lib.mkVMOverride false;
    }
  ];
}
