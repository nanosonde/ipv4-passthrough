# justfile -- ipv4-passthrough task runner. https://just.systems
#
#   just            # list recipes
#   just test       # everything: parser + status + e2e
#   just check      # sh -n over every shell script

set shell := ["sh", "-cu"]

# OpenWrt target defaults (mediatek/filogic = e.g. GL.iNet Flint, BPI-R3...);
# override per invocation:  just sdk-download target=x86/64
target      := "mediatek/filogic"
owrt_version := "25.12.5"
sdk_dir     := "sdks"
out_dir     := "dist"

# List available recipes.
default:
    @just --list

# Run all three suites (parser + status are root-free; E2E is rootless).
test: test-parser test-status test-e2e

# Parser fixtures only; safe to run as any user, anywhere.
test-parser:
    sh tests/test-parser.sh

# luci-app-ip4pt status helper, against the same fakes as the parser test.
test-status:
    sh tests/test-status.sh

# Full E2E smoke in throwaway network namespaces (rootless via unshare).
# SKIP_PERSIST=1 cuts the reboot/restore scenario when iterating quickly.
test-e2e:
    sh tests/test-e2e.sh

# sh -n over every shell script (sources, package payload, tests).
check:
    #!/bin/sh
    rc=0
    for f in ip4pt-*.sh ip4pt.init \
             tests/test-*.sh tests/lib/*.sh \
             package/ip4pt/files/usr/lib/ip4pt/*.sh \
             package/ip4pt/files/usr/bin/ip4pt-gen-nft \
             package/ip4pt/files/etc/init.d/ip4pt \
             package/luci-app-ip4pt/root/usr/libexec/ip4pt-status \
             package/luci-app-ip4pt/root/usr/libexec/ip4pt-remove; do
        if sh -n "$f" 2>/tmp/ip4pt-synerr; then
            echo "OK   $f"
        else
            echo "ERR  $f"; cat /tmp/ip4pt-synerr; rc=1
        fi
    done
    rm -f /tmp/ip4pt-synerr
    exit $rc

# Download + extract the OpenWrt SDK for the target (idempotent).
# OpenWrt 25.x SDKs carry the toolchain triplet in BOTH the tarball name and
# the extracted dir: openwrt-sdk-<ver>-<t>_gcc-<x>_musl.Linux-x86_64.tar.zst
sdk-download target=target:
    #!/bin/sh
    t="$(echo '{{target}}' | tr '/' '-')"
    d="{{sdk_dir}}/openwrt-sdk-{{owrt_version}}-${t}_gcc-${gcc_ver:-14.3.0}_musl.Linux-x86_64"
    if [ -f "$d/rules.mk" ]; then echo "$d"; exit 0; fi
    mkdir -p "{{sdk_dir}}"
    # resolve the exact filename from the dir listing rather than guessing the
    # gcc version -- 25.12.5 currently ships gcc-14.3.0, but that can drift.
    idx="https://downloads.openwrt.org/releases/{{owrt_version}}/targets/{{target}}/"
    f="$( { command -v curl >/dev/null && curl -fsSL "$idx" || wget -qO- "$idx"; } \
          | grep -oE "openwrt-sdk-[0-9.]+-${t}[^\"']*\.tar\.zst" | sort -u | head -1 )"
    [ -n "$f" ] || { echo "no sdk tarball found in $idx"; exit 1; }
    tmp="{{sdk_dir}}/.sdk-$$.tar.zst"
    echo "downloading $idx$f"
    if command -v curl >/dev/null; then curl -fSL -o "$tmp" "$idx$f"; else wget -q -O "$tmp" "$idx$f"; fi || \
        { echo "download failed"; rm -f "$tmp"; exit 1; }
    unzstd -c "$tmp" | tar -x -C "{{sdk_dir}}" || { echo "extract failed"; rm -f "$tmp"; exit 1; }
    rm -f "$tmp"
    [ -f "$d/rules.mk" ] || { echo "extract produced no $d"; exit 1; }
    # one-time SDK prep: config the target + pull the package feeds so the
    # package's DEPENDS (tcpdump, ebtables) resolve and the build never drops
    # into menuconfig. Done here so package-build can just `make`.
    [ -f "$d/.config" ] || make -C "$d" defconfig >/dev/null
    [ -e "$d/feeds/base" ] || "$d"/scripts/feeds update >/dev/null 2>&1 || true
    echo "$d"

# Build the OpenWrt package against the SDK; auto-downloads it if absent.
#   just package-build                  # mediatek/filogic SDK into sdks/
#   just package-build ~/src/my-sdk     # your own existing SDK
#
# SPEED (measured): `make -C <sdk> package/ip4pt/compile` takes ~107s because
# that goal's `package/subdir` walks *every* selected package in the SDK
# (~1112 kmods+packages), repackaging all ~898 kernel modules each time.
# Invoking make INSIDE the package dir instead scopes the build to just this
# package: `make -C <sdk>/package/ip4pt compile TOPDIR=<sdk> <target>` ->
# ~0.14s, same .apk, same recorded Depends line. That is the path used below.
# FAKEROOT=env keeps apk mkpkg from being wrapped in fakeroot (pointless as
# the invoking user; was ~110s of the cost in the reference project).
#
# The first build must still run the full in-SDK path once: it is what
# bootstraps staging_dir/target-*/ with the toolchain + kernel headers the
# direct invocation reads. After that, direct rebuilds are ~0.14s.
package-build sdk="":
    #!/bin/sh
    sdk="{{sdk}}"
    if [ -z "$sdk" ]; then
        t="$(echo '{{target}}' | tr '/' '-')"
        sdk="{{sdk_dir}}/openwrt-sdk-{{owrt_version}}-${t}_gcc-14.3.0_musl.Linux-x86_64"
        [ -f "$sdk/rules.mk" ] || sdk="$(just sdk-download {{target}} | tail -n 1)"
    fi
    test -f "$sdk/rules.mk" || { echo "not an OpenWrt SDK: $sdk"; exit 2; }
    sdk=$(cd "$sdk" && pwd -P)   # absolute: the direct make needs it as TOPDIR
    # One-time SDK prep (if a caller handed us an SDK the download skipped).
    [ -f "$sdk/.config" ] || make -C "$sdk" defconfig >/dev/null
    [ -e "$sdk/feeds/base" ] || "$sdk"/scripts/feeds update >/dev/null 2>&1 || true
    for pkg in ip4pt luci-app-ip4pt; do
        test -e "$sdk/package/$pkg" || ln -s "$PWD/package/$pkg" "$sdk/package/$pkg"
    done
    # A package symlinked in after the SDK's defconfig ran is invisible to
    # .config -- and the compile gate checks CONFIG_PACKAGE_<pkg> -- so if
    # either package is missing from .config, regenerate it (defconfig keeps
    # existing choices; with CONFIG_ALL=y it just selects the newcomer).
    for pkg in ip4pt luci-app-ip4pt; do
        grep -q "CONFIG_PACKAGE_$pkg=" "$sdk/.config" || { make -C "$sdk" defconfig >/dev/null; break; }
    done
    # Bootstrap the target staging area once (needs the slow in-SDK path);
    # afterwards the direct per-package make is enough.
    if [ ! -d "$sdk"/staging_dir/target-*/usr/include ]; then
        echo "first build: bootstrapping SDK staging area (~2min, once)"
        make -C "$sdk" package/ip4pt/compile V=s FAKEROOT=env
    fi
    out="{{out_dir}}/$(echo '{{target}}' | tr '/' '-')"
    mkdir -p "$out"
    for pkg in ip4pt luci-app-ip4pt; do
        make -C "$sdk/package/$pkg" clean FAKEROOT=env >/dev/null 2>&1 || true
        # Drop any older build of this package from the SDK bin dir first:
        # the find below stages "the" artifact, and a stale r<N-1> apk left
        # over from a previous release would otherwise win the name glob.
        rm -f "$sdk"/bin/packages/*/*/"$pkg"-*.apk
        # scoped to this package only -- skips the package/subdir walk entirely
        make -C "$sdk/package/$pkg" compile FAKEROOT=env TOPDIR="$sdk"
        # stage the artifact out of the SDK into dist/<target>/
        art="$(find "$sdk/bin/packages" -name "$pkg-*.apk" 2>/dev/null | head -1)"
        [ -n "$art" ] || { echo "no $pkg .apk produced -- check the build output above"; exit 1; }
        cp -f "$art" "$out/"
        echo "-> $out/$(basename "$art")"
    done

# Remove test scratch and local build leftovers (never touches /etc).
clean:
    rm -rf tests/tmp tmp

# Remove downloaded SDKs too.
distclean: clean
    rm -rf "{{sdk_dir}}"
