{
  inputs ? { },
  guest ? false,
}:
{
  pkgs,
  lib,
  config,
  ...
}:

let
  vgpuCfg = config.hardware.nvidia.vgpu;
  pref = if guest then "grid" else "vgpu";

  pinnedPkgs =
    if inputs ? "nixpkgs" then
      import inputs.nixpkgs {
        system = "x86_64-linux";
        inherit (config.nixpkgs) config;
      }
    else
      pkgs;

  merged = !guest && (lib.elem "nvidia" config.services.xserver.videoDrivers);
  patcherArgs =
    with vgpuCfg.patcher;
    builtins.concatStringsSep " " (
      lib.optionals (!options.doNotForceGPLLicense) [
        "--enable-nvidia-gpl-for-experimenting"
        "--force-nvidia-gpl-I-know-it-is-wrong"
      ]
      # TODO: nvidia-open support
      # ++ lib.optional (!(options.doNotPatchNvidiaOpen or true)) "--nvoss"
      ++ lib.optional (options.remapP40ProfilesToV100D or false) "--remap-p2v"
      ++ options.extra
      ++ [
        (
          if merged then
            "general-merge"
          else if guest then
            "grid"
          else
            "vgpu-kvm"
        )
      ]
    );

  requireNvidiaFile =
    { name, ... }@args:
    pkgs.requireFile (
      args
      // rec {
        url = "https://www.nvidia.com/object/vGPU-software-driver.html";
        message = ''
          Unfortunately, we cannot download file ${name} automatically.
          Please go to ${url} to download it yourself or ask the vGPU Discord community
          for support (https://discord.com/invite/5rQsSV3Byq). Add it to the Nix store
          using either
            nix-store --add-fixed sha256 ${name}
          or
            nix-prefetch-url --type sha256 file:///path/to/${name}
        '';
      }
    );
  getDriver =
    {
      name ? "",
      url ? "",
      sha256 ? null,
      zipFilename,
      zipSha256,
      guestSha256,
      version,
      gridVersion,
      curlOptsList ? [ ],
    }@args:
    let
      sha256 =
        if args.sha256 != null then
          args.sha256
        else if guest && !(lib.hasSuffix ".zip" args.name) then
          guestSha256
        else
          zipSha256;
      name =
        if args.name != "" then
          args.name
        else if !guest && sha256 != args.sha256 then
          zipFilename
        else
          "NVIDIA-Linux-x86_64-${version}-${if guest then "grid" else "vgpu-kvm"}.run";
      url =
        if args.url != "" then
          args.url
        else if guest && args.name == "" && args.sha256 == null then
          "https://storage.googleapis.com/nvidia-drivers-us-public/GRID/vGPU${gridVersion}/${name}"
        else
          null;
    in
    lib.throwIf ((lib.hasSuffix ".zip" name) && sha256 != zipSha256)
      ''
        The .run file was expected as the source of the NVIDIA vGPU driver due to a overriden hash, got a .zip GRID archive instead
      ''
      lib.throwIf
      ((lib.hasSuffix ".run" name) && sha256 == zipSha256)
      ''
        Please specify the correct SHA256 hash of the NVIDIA vGPU driver in `hardware.nvidia.vgpu.driverSource.sha256`
        (for example with `nix-hash --flat --base64 --type sha256 /path/to/${name}`)
      ''
      (
        if url == null then
          (requireNvidiaFile { inherit name sha256; })
        else
          (pkgs.fetchurl {
            inherit
              name
              url
              sha256
              curlOptsList
              ;
          })
      );

  overlayNvidiaPackages =
    args:
    (self: super: {
      linuxKernel = super.linuxKernel // {
        packagesFor =
          kernel:
          (super.linuxKernel.packagesFor kernel).extend (
            _: super': {
              nvidiaPackages = super'.nvidiaPackages.extend (_: _: args);
            }
          );
      };
    });

  mkVgpuDriver =
    args:
    let
      version = if guest then args.guestVersion else args.version;
      args' =
        {
          inherit version;
          vgpuPatcher = if vgpuCfg.patcher.enable then args.vgpuPatcher else null;
          settingsVersion = args.generalVersion;
          persistencedVersion = args.generalVersion;
        }
        // (builtins.removeAttrs args [
          "version"
          "guestVersion"
          "sha256"
          "guestSha256"
          "openSha256"
          "generalVersion"
          "gridVersion"
          "zipFilename"
          "vgpuPatcher"
        ]);
      src = getDriver {
        inherit (vgpuCfg.driverSource)
          name
          url
          sha256
          curlOptsList
          ;
        inherit (args) guestSha256 gridVersion zipFilename;
        inherit version;
        zipSha256 = args.sha256;
      };
    in
    pinnedPkgs.callPackage (import ./nvidia-vgpu args') {
      inherit (config.boot.kernelPackages) kernel;
      inherit
        src
        guest
        merged
        patcherArgs
        ;
    };
  mkVgpuPatcher =
    args: vgpuDriver:
    pinnedPkgs.callPackage ./patcher (
      args
      // {
        inherit vgpuDriver merged;
        extraVGPUProfiles = vgpuCfg.patcher.copyVGPUProfiles or { };
        fetchGuests = vgpuCfg.patcher.enablePatcherCmd or false;
      }
    );
  vgpuNixpkgsPkgs = {
    inherit mkVgpuDriver mkVgpuPatcher;

    "${pref}_17_5" = mkVgpuDriver {
      version = "550.144.02";
      sha256 = "sha256-VeXJUqF82jp3wEKmCaH5VKQTS9e0gQmwkorf4GBcS8g=";
      guestVersion = "550.144.03";
      guestSha256 = "sha256-7EWHVpF6mzyhPUmASgbTJuYihUhqcNdvKDTHYQ53QFY=";
      openSha256 = null; # TODO: nvidia-open support
      generalVersion = "550.144.03";
      settingsSha256 = "sha256-ZopBInC4qaPvTFJFUdlUw4nmn5eRJ1Ti3kgblprEGy4=";
      usePersistenced = false;
      gridVersion = "17.5";
      zipFilename = "NVIDIA-GRID-Linux-KVM-550.144.02-550.144.03-553.62.zip";
      vgpuPatcher = null;
    };
    "${pref}_17_4" = mkVgpuDriver {
      version = "550.127.06";
      sha256 = "sha256-w5Oow0G8R5QDckNw+eyfeaQm98JkzsgL0tc9HIQhE/g=";
      guestVersion = "550.127.05";
      guestSha256 = "sha256-gV9T6UdjhM3fnzITfCmxZDYdNoYUeZ5Ocf9qjbrQWhc=";
      openSha256 = null; # TODO: nvidia-open support
      generalVersion = "550.127.05";
      settingsSha256 = "sha256-cUSOTsueqkqYq3Z4/KEnLpTJAryML4Tk7jco/ONsvyg=";
      persistencedSha256 = "sha256-8nowXrL6CRB3/YcoG1iWeD4OCYbsYKOOPE374qaa4sY=";
      gridVersion = "17.4";
      zipFilename = "NVIDIA-GRID-Linux-KVM-550.127.06-550.127.05-553.24.zip";
      vgpuPatcher = null;
    };
    "${pref}_17_3" = mkVgpuDriver {
      version = "550.90.05";
      sha256 = "sha256-ydNOnbhbqkO2gVaUQXsIWCZsbjw0NMEYl9iV0T01OX0=";
      guestVersion = "550.90.07";
      guestSha256 = "sha256-hR0b+ctNdXhDA6J1Zo1tYEgMtCvoBQ4jQpQvg1/Kjg4=";
      openSha256 = null; # TODO: nvidia-open support
      generalVersion = "550.90.07";
      settingsSha256 = "sha256-sX9dHEp9zH9t3RWp727lLCeJLo8QRAGhVb8iN6eX49g=";
      persistencedSha256 = "sha256-qe8e1Nxla7F0U88AbnOZm6cHxo57pnLCqtjdvOvq9jk=";
      gridVersion = "17.3";
      zipFilename = "NVIDIA-GRID-Linux-KVM-550.90.05-550.90.07-552.74.zip";
      vgpuPatcher = mkVgpuPatcher {
        version = "550.90";
        rev = "8f19e550540dcdeccaded6cb61a71483ea00d509";
        sha256 = "sha256-TyZkZcv7RI40U8czvcE/kIagpUFS/EJhVN0SYPzdNJM=";
        generalVersion = "550.90.07";
        generalSha256 = "sha256-Uaz1edWpiE9XOh0/Ui5/r6XnhB4iqc7AtLvq4xsLlzM=";
        linuxGuest = "550.90.07";
        linuxSha256 = "sha256-hR0b+ctNdXhDA6J1Zo1tYEgMtCvoBQ4jQpQvg1/Kjg4=";
        windowsGuestFilename = "552.74_grid_win10_win11_server2022_dch_64bit_international.exe";
        windowsSha256 = "sha256-UU+jbwlfg9xCie8IjPASb/gWalcEzAwzy+VAmgr0868=";
        gridVersion = "17.3";
      };
    };
    "${pref}_16_9" = mkVgpuDriver {
      version = "535.230.02";
      sha256 = "sha256-FMzf35R3o6bXVoAcYXrL3eBEFkQNRh96RnZ/qn5eeWs=";
      guestVersion = "535.230.02";
      guestSha256 = "sha256-7/ujzYAMNnMFOT/pV+z4dYsbMUDaWf5IoqNHDr1Pf/w=";
      openSha256 = null; # TODO: nvidia-open support
      generalVersion = "535.113.01"; # HACK: nvidia-settings Github doesn't include 535.230.02 tag
      settingsSha256 = "sha256-hiX5Nc4JhiYYt0jaRgQzfnmlEQikQjuO0kHnqGdDa04=";
      usePersistenced = false;
      gridVersion = "16.9";
      zipFilename = "NVIDIA-GRID-Linux-KVM-535.230.02-539.19.zip";
      vgpuPatcher = null;
    };
    "${pref}_16_8" = mkVgpuDriver {
      version = "535.216.01";
      sha256 = "sha256-7C5cELcb2akv8Vpg+or2317RUK2GOW4LXvrtHoYOi/4=";
      guestVersion = "535.216.01";
      guestSha256 = "sha256-47s58S1X72lmLq8jA+n24lDLY1fZQKIGtzfKLG+cXII=";
      openSha256 = null; # TODO: nvidia-open support
      generalVersion = "535.216.01";
      settingsSha256 = "sha256-9PgaYJbP1s7hmKCYmkuLQ58nkTruhFdHAs4W84KQVME=";
      persistencedSha256 = "sha256-ckF/BgDA6xSFqFk07rn3HqXuR0iGfwA4PRxpP38QZgw=";
      gridVersion = "16.8";
      zipFilename = "NVIDIA-GRID-Linux-KVM-535.216.01-538.95.zip";
      vgpuPatcher = null;
    };
    "${pref}_16_5" = mkVgpuDriver {
      version = "535.161.05";
      sha256 = "sha256-uXBzzFcDfim1z9SOrZ4hz0iGCElEdN7l+rmXDbZ6ugs=";
      guestVersion = "535.161.08";
      guestSha256 = "sha256-5K1hmS+Oax6pGdS8pBthVQferAbVXAHfaLbd0fzytCA=";
      openSha256 = null;
      generalVersion = "535.161.07";
      settingsSha256 = "sha256-qKiKSNMUM8UftedmXtidVbu9fOkxzIXzBRIZNb497OU=";
      persistencedSha256 = "sha256-1kblNpRPlZ446HpKF1yMSK36z0QDQpMtu6HCdRdqwo8=";
      gridVersion = "16.5";
      zipFilename = "NVIDIA-GRID-Linux-KVM-535.161.05-535.161.08-538.46.zip";
      vgpuPatcher = mkVgpuPatcher {
        version = "535.161";
        rev = "59c75f98baf4261cf42922ba2af5d413f56f0621";
        sha256 = "sha256-IUBK+ni+yy/IfjuGM++4aOLQW5vjNiufOPfXOIXCDeI=";
        generalVersion = "535.161.07";
        generalSha256 = "sha256-7cUn8dz6AhKjv4FevzAtRe+WY4NKQeEahR3TjaFZqM0=";
        linuxGuest = "535.161.08";
        linuxSha256 = "sha256-5K1hmS+Oax6pGdS8pBthVQferAbVXAHfaLbd0fzytCA=";
        windowsGuestFilename = "538.46_grid_win10_win11_server2019_server2022_dch_64bit_international.exe";
        windowsSha256 = "sha256-GHD2kVo1awyyZZvu2ivphrXo2XhanVB9rU2mwmfjXE4=";
        gridVersion = "16.5";
      };
    };
    "${pref}_16_2" = mkVgpuDriver {
      version = "535.129.03";
      sha256 = "sha256-tFgDf7ZSIZRkvImO+9YglrLimGJMZ/fz25gjUT0TfDo=";
      guestVersion = "535.129.03";
      guestSha256 = "sha256-RWemnuEuZRPszUvy+Mj1/rXa5wn8tsncXMeeJHKnCxw=";
      openSha256 = null;
      generalVersion = "535.129.03";
      settingsSha256 = "sha256-QKN/gLGlT+/hAdYKlkIjZTgvubzQTt4/ki5Y+2Zj3pk=";
      persistencedSha256 = "sha256-FRMqY5uAJzq3o+YdM2Mdjj8Df6/cuUUAnh52Ne4koME=";
      gridVersion = "16.2";
      zipFilename = "NVIDIA-GRID-Linux-KVM-535.129.03-537.70.zip";
      vgpuPatcher = mkVgpuPatcher {
        version = "535.129";
        rev = "3765eee908858d069e7b31842f3486095b0846b5";
        sha256 = "sha256-jNyZbaeblO66aQu9f+toT8pu3Tgj1xpdiU5DgY82Fv8=";
        generalVersion = "535.129.03";
        generalSha256 = "sha256-5tylYmomCMa7KgRs/LfBrzOLnpYafdkKwJu4oSb/AC4=";
        linuxGuest = "535.129.03";
        linuxSha256 = "sha256-RWemnuEuZRPszUvy+Mj1/rXa5wn8tsncXMeeJHKnCxw=";
        windowsGuestFilename = "537.70_grid_win10_win11_server2019_server2022_dch_64bit_international.exe";
        windowsSha256 = "sha256-3eBuhVfIpPo5Cq4KHGBuQk+EBKdTOgpqcvs+AZo0q3M=";
        gridVersion = "16.2";
      };
    };
  };
in
{
  imports = [
    # Load host- or guest-specific options and config
    (if guest then ./guest.nix else ./host.nix)
  ];
  options = {
    hardware.nvidia.vgpu = {
      patcher = {
        enable = lib.mkEnableOption "driver patching using vGPU-Unlock-patcher";
        options.doNotForceGPLLicense = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Disables a kernel module hack that makes the driver usable on higher kernel versions.
            Turn it on if you have patched the kernel for support. Has no effect starting from 17.2.
          '';
        };
        # TODO: 17.x
        /*
          options.doNotPatchNvidiaOpen = lib.mkOption {
            type = lib.lib.types.bool;
            default = true;
            description = ''
              Will not patch open source NVIDIA kernel modules. For 17.x releases only.
              Enabled by default as a reinsurance against the possibility that you use open source drivers without even knowing it
              (for example, by accidentally setting `hardware.nvidia.open = true;`).
            '';
          };
        */
        options.extra = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "--test-dmabuf-export" ];
          description = "Extra flags to pass to the patcher.";
        };
      };
      driverSource.name = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "NVIDIA-GRID-Linux-KVM-535.129.03-537.70.zip";
        description = "The name of the driver file.";
      };
      driverSource.url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "";
        example = "https://drive.google.com/uc?export=download&id=n0TaR34LliNKG3t7h4tYOuR5elF";
        description = "The address of your local server from which to download the driver, if any.";
      };
      driverSource.sha256 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "sha256-tFgDf7ZSIZRkvImO+9YglrLimGJMZ/fz25gjUT0TfDo=";
        description = ''
          SHA256 hash of your driver. Note that anything other than null will automatically require a .run file, not a .zip GRID archive.
          Set the value to "" to get the correct hash (only when fetching from an HTTP(s) server).
        '';
      };
      driverSource.curlOptsList = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "-u"
          "admin:12345678"
        ];
        description = "Additional curl options, similar to curlOptsList in pkgs.fetchurl.";
      };
    };
  };
  config = {
    assertions = lib.optionals (config.hardware.nvidia.package ? vgpuPatcher) [
      {
        assertion = (pkgs.stdenv.hostPlatform.system == "x86_64-linux");
        message = "nvidia-vgpu only supports platform x86_64-linux";
      }
      {
        assertion = (merged -> vgpuCfg.patcher.enable);
        message = ''
          vGPU-Unlock-patcher must be enabled to make merged NVIDIA vGPU/GRID driver
          (did you accidentally set `services.xserver.videoDrivers = ["nvidia"]`?)
        '';
      }
      {
        assertion = (config.hardware.nvidia.package.vgpuPatcher == null -> !vgpuCfg.patcher.enable);
        message = "vGPU-Unlock-patcher is not supported for vGPU version ${config.hardware.nvidia.package.version}";
      }
    ];
    # Add our packages to nvidiaPackages
    nixpkgs.overlays = [
      (overlayNvidiaPackages (
        vgpuNixpkgsPkgs
        // {
          vgpuNixpkgsOverlay = overlayNvidiaPackages vgpuNixpkgsPkgs;
        }
      ))
    ];
  };
}
