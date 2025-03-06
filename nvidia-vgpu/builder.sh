# Copyright (c) 2003-2024 Eelco Dolstra and the Nixpkgs/NixOS contributors
#
# Original source code:
# https://github.com/NixOS/nixpkgs/blob/85149743aab230dfbf3ffd538a8dd44972883b59/pkgs/os-specific/linux/nvidia-x11/builder.sh

if [ -e "$NIX_ATTRS_SH_FILE" ]; then . "$NIX_ATTRS_SH_FILE"; elif [ -f .attrs.sh ]; then . .attrs.sh; fi
source $stdenv/setup

unpackManually() {
    skip=$(sed 's/^skip=//; t; d' $src)
    tail -n +$skip $src | bsdtar xvf -
    sourceRoot=.
}


unpackFile() {
    if [ -z "$patcher" ]; then
        if [[ $src = *.zip ]]; then
            if [ "$guest" = "1" ]; then
                unzip -j $src "Guest_Drivers/*-grid.run"
            else
                unzip -j $src "Host_Drivers/*-vgpu-kvm.run"
            fi
            src=$(ls -1 *.run)
        fi
        sh $src -x || unpackManually
    else
        # TODO: use fixupPhase for patching?
        $patcher/bin/nvidia-vup $patcherArgs
        sourceRoot=$(ls -d NVIDIA-Linux-x86_64-*-patched)
    fi
}


buildPhase() {
    runHook preBuild

    if [ -n "$bin" ]; then
        # Create the module.
        echo "Building linux driver against kernel: $kernel";
        # TODO: nvidia-open support
        cd kernel
        unset src # used by the nv makefile
        make $makeFlags -j $NIX_BUILD_CORES module

        cd ..
    fi

    runHook postBuild
}


installPhase() {
    runHook preInstall

    # Install libGL and friends.

    # since version 391, 32bit libraries are bundled in the 32/ sub-directory
    if [ "$i686bundled" = "1" ]; then
        mkdir -p "$lib32/lib"
        cp -prd 32/*.so.* "$lib32/lib/"
        if [ -d 32/tls ]; then
            cp -prd 32/tls "$lib32/lib/"
        fi
    fi

    mkdir -p "$out/lib"
    cp -prd *.so.* "$out/lib/"
    if [ -d tls ]; then
        cp -prd tls "$out/lib/"
    fi

    # Install systemd power management executables
    if [ -e systemd/nvidia-sleep.sh ]; then
        mv systemd/nvidia-sleep.sh ./
    fi
    if [ -e nvidia-sleep.sh ]; then
        sed -E 's#(PATH=).*#\1"$PATH"#' nvidia-sleep.sh > nvidia-sleep.sh.fixed
        install -Dm755 nvidia-sleep.sh.fixed $out/bin/nvidia-sleep.sh
    fi

    if [ -e systemd/system-sleep/nvidia ]; then
        mv systemd/system-sleep/nvidia ./
    fi
    if [ -e nvidia ]; then
        sed -E "s#/usr(/bin/nvidia-sleep.sh)#$out\\1#" nvidia > nvidia.fixed
        install -Dm755 nvidia.fixed $out/lib/systemd/system-sleep/nvidia
    fi

    [ "$guiBundled" = "1" ] && for i in $lib32 $out; do
        rm -f $i/lib/lib{glx,nvidia-wfb}.so.* # handled separately
        rm -f $i/lib/libnvidia-gtk* # built from source
        rm -f $i/lib/libnvidia-wayland-client* # built from source
        if [ "$useGLVND" = "1" ]; then
            # Pre-built libglvnd
            rm $i/lib/lib{GL,GLX,EGL,GLESv1_CM,GLESv2,OpenGL,GLdispatch}.so.*
        fi
        # Use ocl-icd instead
        rm -f $i/lib/libOpenCL.so*
        # Move VDPAU libraries to their place
        mkdir $i/lib/vdpau
        mv $i/lib/libvdpau* $i/lib/vdpau

        # Compatibility with openssl 1.1, unused
        rm -f $i/lib/libnvidia-pkcs11.so*

        # Install ICDs, make absolute paths.
        # Be careful not to modify any original files because this runs twice.

        # OpenCL
        sed -E "s#(libnvidia-opencl)#$i/lib/\\1#" nvidia.icd > nvidia.icd.fixed
        install -Dm644 nvidia.icd.fixed $i/etc/OpenCL/vendors/nvidia.icd

        # Vulkan
        if [ -e nvidia_icd.json.template ] || [ -e nvidia_icd.json ]; then
            if [ -e nvidia_icd.json.template ]; then
                # template patching for version < 435
                sed "s#__NV_VK_ICD__#$i/lib/libGLX_nvidia.so#" nvidia_icd.json.template > nvidia_icd.json.fixed
            else
                sed -E "s#(libGLX_nvidia)#$i/lib/\\1#" nvidia_icd.json > nvidia_icd.json.fixed
            fi

            # nvidia currently only supports x86_64 and i686
            if [ "$i" == "$lib32" ]; then
                install -Dm644 nvidia_icd.json.fixed $i/share/vulkan/icd.d/nvidia_icd.i686.json
            else
                install -Dm644 nvidia_icd.json.fixed $i/share/vulkan/icd.d/nvidia_icd.x86_64.json
            fi
        fi

        if [ -e nvidia_layers.json ]; then
            sed -E "s#(libGLX_nvidia)#$i/lib/\\1#" nvidia_layers.json > nvidia_layers.json.fixed
            install -Dm644 nvidia_layers.json.fixed $i/share/vulkan/implicit_layer.d/nvidia_layers.json
        fi

        if [ -e nvidia_icd_vksc.json ]; then
            sed -E "s#(libnvidia-vksc-core)#$i/lib/\\1#" nvidia_icd_vksc.json > nvidia_icd_vksc.json.fixed
            install -Dm644 nvidia_icd_vksc.json.fixed $i/share/vulkan/icd.d/nvidia_icd_vksc.json
        fi

        # EGL
        if [ "$useGLVND" = "1" ]; then
            mkdir -p "$i/share/egl/egl_external_platform.d"
            for icdname in $(find . -name '*_nvidia*.json')
            do
                cat "$icdname" | jq ".ICD.library_path |= \"$i/lib/\(.)\"" | tee "$i/share/egl/egl_external_platform.d/$icdname"
            done

            # glvnd icd
            mkdir -p "$i/share/glvnd/egl_vendor.d"
            mv "$i/share/egl/egl_external_platform.d/10_nvidia.json" "$i/share/glvnd/egl_vendor.d/10_nvidia.json"

            if [[ -f "$i/share/egl/egl_external_platform.d/15_nvidia_gbm.json" ]]; then
              mkdir -p $i/lib/gbm
              ln -s $i/lib/libnvidia-allocator.so $i/lib/gbm/nvidia-drm_gbm.so
            fi
        fi

        # Install libraries needed by Proton to support DLSS
        for winelib in $(find . -name '*nvngx*.dll')
        do
            install -Dm644 -t $i/lib/nvidia/wine/ "$winelib"
        done
    done


    # OptiX tries loading `$ORIGIN/nvoptix.bin` first
    if [ -e nvoptix.bin ]; then
        install -Dm444 -t $out/lib/ nvoptix.bin
    fi

    if [ -e vgpuConfig.xml ]; then
        install -Dm644 vgpuConfig.xml $out/vgpuConfig.xml
    fi

    if [ -e nvidia-topologyd.conf.template ] && [ -e gridd.conf.template ]; then
        install -Dm644 gridd.conf.template $out/gridd.conf.template
        install -Dm644 nvidia-topologyd.conf.template $out/nvidia-topologyd.conf.template
    fi

    if [ -n "$bin" ]; then
        [ "$guiBundled" = "1" ] && (
        # Install the X drivers.
        mkdir -p $bin/lib/xorg/modules
        if [ -f libnvidia-wfb.so ]; then
            cp -p libnvidia-wfb.* $bin/lib/xorg/modules/
        fi
        mkdir -p $bin/lib/xorg/modules/drivers
        cp -p nvidia_drv.so $bin/lib/xorg/modules/drivers
        mkdir -p $bin/lib/xorg/modules/extensions
        cp -p libglx*.so* $bin/lib/xorg/modules/extensions
        )

        # Install the kernel module.
        mkdir -p $bin/lib/modules/$kernelVersion/misc
        # TODO: nvidia-open support
        for i in $(find ./kernel -name '*.ko'); do
            nuke-refs $i
            cp $i $bin/lib/modules/$kernelVersion/misc/
        done

        # Install application profiles.
        if [ "$useProfiles" = "1" ] && [ "$guiBundled" = "1" ]; then
            mkdir -p $bin/share/nvidia
            cp nvidia-application-profiles-*-rc $bin/share/nvidia/nvidia-application-profiles-rc
            cp nvidia-application-profiles-*-key-documentation $bin/share/nvidia/nvidia-application-profiles-key-documentation
        fi
    fi

    if [ -n "$firmware" ]; then
        # Install the GSP firmware
        install -Dm644 -t $firmware/lib/firmware/nvidia/$version firmware/gsp*.bin
    fi

    # All libs except GUI-only are installed now, so fixup them.
    for libname in $(find "$out/lib/" $(test -n "$lib32" && echo "$lib32/lib/") $(test -n "$bin" && echo "$bin/lib/") -name '*.so.*')
    do
      # I'm lazy to differentiate needed libs per-library, as the closure is the same.
      # Unfortunately --shrink-rpath would strip too much.
      if [[ -n $lib32 && $libname == "$lib32/lib/"* ]]; then
        patchelf --set-rpath "$lib32/lib:$libPath32" "$libname"
      else
        patchelf --set-rpath "$out/lib:$libPath" "$libname"
      fi

      # Manually create the right symlinks for the libraries.
      #
      # We can't just use ldconfig, because it does not create libfoo.so symlinks,
      # only libfoo.so.1.
      # Also, the symlink chain must be libfoo.so -> libfoo.so.1 -> libfoo.so.123.45,
      # or ldconfig will explode.
      # See: https://github.com/bminor/glibc/blob/6f3f6c506cdaf981a4374f1f12863b98ac7fea1a/elf/ldconfig.c#L854-L877
      libbase=$(basename "$libname")
      libdir=$(dirname "$libname")
      soname=$(patchelf --print-soname "$libname")
      unversioned=${libbase/\.so\.[0-9\.]*/.so}
      if [[ -n "$soname" ]]; then
        if [[ "$soname" != "$libbase" ]]; then
          ln -s "$libbase" "$libdir/$soname"
        fi

        if [[ "$soname" != "$unversioned" ]]; then
          ln -s "$soname" "$libdir/$unversioned"
        fi
      fi

      # FIXME: libglxserver_nvidia does not have a soname, but must still be symlinked
      if [[ "$unversioned" == "libglxserver_nvidia.so" ]]; then
        ln -s "$libbase" "$libdir/$unversioned"
      fi
    done

    if [ -n "$bin" ]; then
        # Install /share files.
        [ "$guiBundled" = "1" ] && (
        mkdir -p $bin/share/man/man1
        cp -p *.1.gz $bin/share/man/man1
        rm -f $bin/share/man/man1/{nvidia-xconfig,nvidia-settings,nvidia-persistenced}.1.gz
        )
        mkdir -p $bin/share/dbus-1/system.d
        if [ -e "nvidia-dbus.conf" ]; then
            install -Dm644 nvidia-dbus.conf $bin/share/dbus-1/system.d/nvidia-dbus.conf
        fi
        cat << EOF > $bin/share/dbus-1/system.d/nvidia-grid.conf
<busconfig>
    <type>system</type>
    <policy context="default">
        <allow own="nvidia.grid.server"/>
        <allow own="nvidia.grid.client"/>
        <allow send_requested_reply="true" send_type="method_return"/>
        <allow send_requested_reply="true" send_type="error"/>
        <allow receive_requested_reply="true" receive_type="method_return"/>
        <allow receive_requested_reply="true" receive_type="error"/>
        <allow send_destination="nvidia.grid.server"/>
        <allow receive_sender="nvidia.grid.client"/>
    </policy>
</busconfig>
EOF
        chmod 644 $bin/share/dbus-1/system.d/nvidia-grid.conf

        # Install the programs.
        for i in nvidia-cuda-mps-control nvidia-cuda-mps-server nvidia-smi nvidia-debugdump nvidia-powerd \
            nvidia-gridd nvidia-topologyd nvidia-vgpud nvidia-vgpu-mgr nvidia-xid-logd nvidia-pcc; do
            if [ -e "$i" ]; then
                install -Dm755 $i $bin/bin/$i
                # unmodified binary backup for mounting in containers
                install -Dm755 $i $bin/origBin/$i
                if [ $i == nvidia-vgpud ]; then
                    # make nvidia-vgpud look for vgpuConfig.xml in /etc/nvidia/vgpu
                    bbe \
                      -e "s|/usr/share/nvidia/vgpu/vgpuConfig.xml|/etc/nvidia/vgpu/vgpuConfig.xml\x00\x00\x00\x00\x00\x00|" \
                      -o $bin/bin/$i $i
                fi
                patchelf --interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
                    --set-rpath $out/lib:$libPath $bin/bin/$i
            fi
        done
        substituteInPlace nvidia-bug-report.sh \
          --replace /bin/grep grep \
          --replace /bin/ls ls
        install -Dm755 nvidia-bug-report.sh $bin/bin/nvidia-bug-report.sh

        if [ -e "sriov-manage" ]; then
            substituteInPlace sriov-manage \
              --replace /usr/lib/nvidia/sriov-manage sriov-manage
            install -Dm755 sriov-manage $bin/bin/sriov-manage
        fi
    fi

    runHook postInstall
}

genericBuild
