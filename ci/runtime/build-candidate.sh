#!/usr/bin/env bash
# Runs only inside the existing privileged builder on a disposable Actions host.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]] || {
    echo 'This spike builds only on GitHub-hosted Actions runners.' >&2
    exit 1
}
: "${MIRROR_URL:?Configure MIRROR_URL in the fork}"
case ${KERNEL_PACKAGE:-} in
    linux) mode=std ;;
    linux-lts) mode=lts ;;
    *) echo 'Unsupported kernel' >&2; exit 1 ;;
esac

cd /src
sudo chown -R buildbot:buildbot /src
mkdir -p runtime-candidate/{official,packages,recipes,metadata}
out=/src/runtime-candidate
printf 'source=%s\nrepository=%s\nrun=%s\nkernel=%s\nmirror=%s\nfailover=disabled\nsigning=unsigned-candidate\n' \
    "$GITHUB_SHA" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID" "$KERNEL_PACKAGE" "$MIRROR_URL" \
    > "$out/metadata/build.txt"

# Retain the exact official kernel archive and its signature for guest installation.
# A mirror/metadata race must fail the spike, rather than silently test another kernel.
sudo pacman -Syu --noconfirm
sudo pacman -Sw --noconfirm --nodeps --nodeps --cachedir "$out/official" "$KERNEL_PACKAGE"
kernel_url=$(pacman -Sp --nodeps --nodeps --print-format '%l' "$KERNEL_PACKAGE")
kernel_archive="$out/official/${kernel_url##*/}"
# Pacman normally saves the signature itself, owned by root. Reuse it rather
# than trying to overwrite it as buildbot; fetch only when it was not retained.
if [[ ! -s $kernel_archive.sig ]]; then
    sudo curl --fail --location --retry 3 "$kernel_url.sig" -o "$kernel_archive.sig"
fi
sudo pacman-key --verify "$kernel_archive.sig" "$kernel_archive"
printf '%s\n' "$kernel_url" > "$out/metadata/kernel-url.txt"

sed -i "s/^THREADS=.*/THREADS=$(nproc)/" ~/.config/clean-chroot-manager.conf
sudo ccm d || true
sudo bash build.sh -s -d -u utils update
sudo bash build.sh -s -d utils make
sudo bash build.sh -s -d "$mode" update
sudo bash build.sh -s -d "$mode" make

# Copy only fresh output; no production release download, signing, or publication.
for package in /scratch/.buildroot/root/repo/*.pkg.tar.zst; do
    name=$(pacman -Qp "$package" | awk '{print $1}')
    case "$name" in
        zfs-utils|zfs-tests|"zfs-$KERNEL_PACKAGE")
            cp "$package" "$out/packages/"
            tar -xOf "$package" .PKGINFO > "$out/metadata/$name.PKGINFO"
            tar -xOf "$package" .BUILDINFO > "$out/metadata/$name.BUILDINFO"
            ;;
    esac
done
for name in zfs-utils zfs-tests "zfs-$KERNEL_PACKAGE"; do
    test -s "$out/metadata/$name.PKGINFO"
done
cp packages/_utils/zfs-utils/PKGBUILD "$out/recipes/utils.PKGBUILD"
cp "packages/$KERNEL_PACKAGE/zfs-$KERNEL_PACKAGE/PKGBUILD" "$out/recipes/kernel.PKGBUILD"
repo-add "$out/packages/candidate.db.tar.gz" "$out"/packages/*.pkg.tar.zst
cd "$out"
find official packages recipes metadata -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
