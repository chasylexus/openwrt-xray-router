# sing-box-router-bin

This is a deliberately small personal OpenWrt package for the router stack in
this repository. It installs the official SagerNet arm64-musl binary at the
path already used by `sing-box-router`:

```text
/usr/local/bin/sing-box
```

The version and release archive SHA-256 are pinned in `Makefile`. The package
does not install secrets, replace `/etc/sing-box-router`, enable a service, or
restart a running service.

## Build for NanoPi R5S / OpenWrt 25.12.5

From the repository root on macOS with Docker Desktop running:

```sh
sh tools/build-sing-box-router-bin.sh
```

The resulting APK and its SHA-256 file are written below:

```text
dist/openwrt-25.12.5-rockchip-armv8/
```

The build helper verifies the official OpenWrt SDK checksum, performs the build
inside an amd64 Linux container, and writes verbose output only to
`.cache/sing-box-router-bin-build.log`.

## Install without disrupting the active service

Copy the APK to the router and install it locally:

```sh
apk add --allow-untrusted /tmp/sing-box-router-bin-1.13.11-r1.apk
/usr/local/bin/sing-box version
/usr/local/bin/sing-box -D /var/lib/sing-box-router -C /etc/sing-box-router check
```

Installing this package does not restart `sing-box-router`. The package also
adds `/usr/local/bin/sing-box` to `/etc/sysupgrade.conf`.

## owut limitation

The public OpenWrt Sysupgrade Server cannot resolve packages that exist only in
this personal repository. If this package is installed, exclude its package
name from a public ASU build and verify that the binary is in the configuration
backup:

```sh
sysupgrade -l | grep -Fx /usr/local/bin/sing-box
owut check -V 25.12.5 -r sing-box-router-bin
```

The binary is then restored as a preserved file. Reinstall the matching local
APK after the firmware upgrade if package-manager ownership is desired again.
