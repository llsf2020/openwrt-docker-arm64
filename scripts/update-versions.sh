#!/usr/bin/env bash
# Looks for newer upstream versions and rewrites, in place:
#   versions.env       newest ImmortalWrt point release of IMMORTALWRT_BRANCH, its
#                      feeds, newest kernel of KERNEL_BRANCH with the matching
#                      toolchain, the newest packager commit and AdGuard Home
#   versions-next.env  the same with a newer ImmortalWrt branch and/or kernel
#                      branch, for a test build; removed when there is none
#   docker/sources.txt, native/sources.txt, docker/oaf-netns/UPSTREAM_COMMIT
#                      newest commit of each source, kept back when our patches
#                      no longer apply or a package directory is gone
# The branches are only ever changed by hand.
#
# Needs bash, curl, git, jq, gh (with GH_TOKEN). Run from the repository root.
# Writes a summary to $NOTES and problems to $PROBLEMS ("title<TAB>details" per line).
set -euo pipefail

DL_BASE=https://downloads.immortalwrt.org/releases
TARGET=armsr/armv8
PKG_ARCH=aarch64_generic
FEEDS="base luci packages routing telephony"
KERNEL_REPO=ophub/kernel
PACKAGER_URL=https://github.com/ophub/amlogic-s9xxx-openwrt.git
AGH_REPO=AdguardTeam/AdGuardHome
AGH_ASSET=AdGuardHome_linux_arm64.tar.gz

NOTES="${NOTES:-update-notes.md}"
PROBLEMS="${PROBLEMS:-update-problems.txt}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
: > "$NOTES"
: > "$PROBLEMS"

note() { echo "- $*" | tee -a "$NOTES"; }
problem() { echo "::warning::$1: $2"; printf '%s\t%s\n' "$1" "$2" >> "$PROBLEMS"; }
get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1; }
ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]; }
newest() { sort -V | tail -n1; }

[ -f versions.env ] || { echo "versions.env not found" >&2; exit 1; }
IW_BRANCH="$(get versions.env IMMORTALWRT_BRANCH)"
K_BRANCH="$(get versions.env KERNEL_BRANCH)"
[ -n "$IW_BRANCH" ] && [ -n "$K_BRANCH" ] || { echo "IMMORTALWRT_BRANCH / KERNEL_BRANCH missing" >&2; exit 1; }

# ---------------------------------------------------------------- ImmortalWrt
# stable releases only: X.Y.Z, no -rc, no SNAPSHOT
curl -fsSL "$DL_BASE/" | grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+/"' \
  | sed -E 's/^href="([^/]+)\/"$/\1/' | sort -uV > "$WORK/iw-releases"
[ -s "$WORK/iw-releases" ] || { echo "no ImmortalWrt releases found" >&2; exit 1; }
iw_latest_in() { grep -E "^${1//./\\.}\.[0-9]+$" "$WORK/iw-releases" | newest; }
iw_newest_branch() { sed -E 's/\.[0-9]+$//' "$WORK/iw-releases" | newest; }

feed_index() { # url of a feed directory -> its index on stdout
  local f
  for f in packages.adb Packages.gz index.json; do
    curl -fsSL "$1/$f" 2>/dev/null && return 0
  done
  return 1
}

iw_block() { # release -> KEY=VALUE lines
  local rel="$1" dl="$DL_BASE/$1/targets/$TARGET" sums sdk ib f
  sums="$(curl -fsSL "$dl/sha256sums")"
  sdk="$(grep -E '^[0-9a-f]{64} \*immortalwrt-sdk-.*\.Linux-x86_64\.tar\.zst$' <<<"$sums")"
  ib="$(grep -E '^[0-9a-f]{64} \*immortalwrt-imagebuilder-.*\.Linux-x86_64\.tar\.zst$' <<<"$sums")"
  [ "$(wc -l <<<"$sdk")" -eq 1 ] && [ -n "$sdk" ] || { echo "SDK for $rel not found" >&2; return 1; }
  [ "$(wc -l <<<"$ib")" -eq 1 ] && [ -n "$ib" ] || { echo "ImageBuilder for $rel not found" >&2; return 1; }
  # feeds change between point releases too; their indexes decide whether to rebuild
  {
    for f in $FEEDS; do feed_index "$DL_BASE/$rel/packages/$PKG_ARCH/$f" || { echo "feed $f missing" >&2; return 1; }; done
    feed_index "$dl/packages" || { echo "target feed missing" >&2; return 1; }
  } > "$WORK/feeds-$rel"
  echo "RELEASE=$rel"
  echo "DL=$dl"
  echo "SDK=$(sed -E 's/^[0-9a-f]+ \*(.*)\.tar\.zst$/\1/' <<<"$sdk")"
  echo "SDK_SHA256=${sdk%% *}"
  echo "IB_NAME=$(sed -E 's/^[0-9a-f]+ \*(.*)\.tar\.zst$/\1/' <<<"$ib")"
  echo "IB_SHA256=${ib%% *}"
  echo "FEEDS_HASH=$(sha256sum < "$WORK/feeds-$rel" | cut -c1-16)"
}

# --------------------------------------------------------------------- kernel
gh api "repos/$KERNEL_REPO/releases/tags/kernel_stable" > "$WORK/kernel.json"
gh api "repos/$KERNEL_REPO/releases/tags/toolchain" > "$WORK/toolchain.json"
jq -r '.assets[].name' "$WORK/kernel.json" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$' \
  | sed 's/\.tar\.gz$//' | sort -uV > "$WORK/kernels"
[ -s "$WORK/kernels" ] || { echo "no kernels found" >&2; exit 1; }
k_latest_in() { grep -E "^${1//./\\.}\.[0-9]+$" "$WORK/kernels" | newest; }
k_newest_branch() { sed -E 's/\.[0-9]+$//' "$WORK/kernels" | newest; }
digest() { jq -r --arg n "$2" '.assets[] | select(.name==$n) | .digest // empty' "$1" | sed 's/^sha256://'; }

kernel_block() { # version, file to reuse the toolchain from -> KEY=VALUE lines
  local v="$1" old="$2" sha hdr cc lv tc tcsha
  sha="$(digest "$WORK/kernel.json" "$v.tar.gz")"
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "no digest for kernel $v" >&2; return 1; }
  if [ "$(get "$old" KERNEL_VERSION)" = "$v" ] && [ "$(get "$old" KERNEL_SHA256)" = "$sha" ] \
     && [ -n "$(get "$old" TOOLCHAIN)" ]; then
    lv="$(get "$old" KERNEL_LOCALVERSION)"
    tc="$(get "$old" TOOLCHAIN)"
  else
    # the kernel's compiler is only recorded in its headers
    gh release download kernel_stable -R "$KERNEL_REPO" -p "$v.tar.gz" -D "$WORK" --clobber >&2
    echo "$sha  $WORK/$v.tar.gz" | sha256sum -c - >&2
    mkdir -p "$WORK/k-$v"
    tar -xzf "$WORK/$v.tar.gz" -C "$WORK/k-$v"
    hdr="$(find "$WORK/k-$v" -name "header-$v*.tar.gz" | head -n1)"
    [ -n "$hdr" ] || { echo "no headers in kernel $v" >&2; return 1; }
    tar -xzf "$hdr" -C "$WORK/k-$v" include/config/auto.conf include/generated/utsrelease.h
    lv="$(sed -nE "s/^#define UTS_RELEASE \"${v//./\\.}(.*)\"$/\1/p" "$WORK/k-$v/include/generated/utsrelease.h")"
    cc="$(sed -n 's/^CONFIG_CC_VERSION_TEXT=//p' "$WORK/k-$v/include/config/auto.conf" | tr -d '"')"
    tc="$(sed -nE 's/.*Arm GNU Toolchain ([0-9]+\.[0-9]+)\.[Rr]el([0-9]+).*/arm-gnu-toolchain-\1.rel\2-aarch64-aarch64-none-linux-gnu/p' <<<"$cc")"
    [ -n "$tc" ] || { echo "kernel $v built with '$cc', no matching toolchain name" >&2; return 1; }
    rm -rf "$WORK/$v.tar.gz" "$WORK/k-$v"
  fi
  tcsha="$(digest "$WORK/toolchain.json" "$tc.tar.xz")"
  [[ "$tcsha" =~ ^[0-9a-f]{64}$ ]] || { echo "toolchain $tc.tar.xz not in $KERNEL_REPO" >&2; return 1; }
  echo "KERNEL_VERSION=$v"
  echo "KERNEL_LOCALVERSION=$lv"
  echo "KERNEL_SHA256=$sha"
  echo "TOOLCHAIN=$tc"
  echo "TOOLCHAIN_SHA256=$tcsha"
}

# ------------------------------------------------------- packager, AdGuard Home
PACKAGER_COMMIT="$(git ls-remote "$PACKAGER_URL" HEAD | cut -f1)"
[[ "$PACKAGER_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "packager HEAD not found" >&2; exit 1; }
gh api "repos/$AGH_REPO/releases/latest" > "$WORK/agh.json"
AGH_VERSION="$(jq -r .tag_name "$WORK/agh.json")"
AGH_SHA256="$(digest "$WORK/agh.json" "$AGH_ASSET")"
[[ "$AGH_SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo "no digest for $AGH_ASSET $AGH_VERSION" >&2; exit 1; }

write_versions() { # file iw_branch k_branch old_file
  local out="$1" rel kv
  rel="$(iw_latest_in "$2")"
  kv="$(k_latest_in "$3")"
  [ -n "$rel" ] || { echo "no release in ImmortalWrt $2" >&2; return 1; }
  [ -n "$kv" ] || { echo "no kernel in branch $3" >&2; return 1; }
  {
    echo "# Written by scripts/update-versions.sh (auto-update.yml)."
    echo "# Only the two branches are edited by hand; everything else follows them."
    echo "IMMORTALWRT_BRANCH=$2"
    echo "KERNEL_BRANCH=$3"
    iw_block "$rel"
    kernel_block "$kv" "$4"
    echo "PACKAGER_COMMIT=$PACKAGER_COMMIT"
    echo "AGH_VERSION=$AGH_VERSION"
    echo "AGH_SHA256=$AGH_SHA256"
  } > "$WORK/new"
  if ! cmp -s "$WORK/new" "$out"; then
    if [ -f "$out" ]; then
      diff <(grep -v '^#' "$out") <(grep -v '^#' "$WORK/new") | sed -n 's/^> /  /p' > "$WORK/changed" || true
    else
      grep -v '^#' "$WORK/new" | sed 's/^/  /' > "$WORK/changed"
    fi
    note "$out:"
    cat "$WORK/changed" | tee -a "$NOTES"
    mv "$WORK/new" "$out"
  fi
}

write_versions versions.env "$IW_BRANCH" "$K_BRANCH" versions.env

IW_NEXT="$(iw_newest_branch)"
K_NEXT="$(k_newest_branch)"
ver_gt "$IW_NEXT" "$IW_BRANCH" || IW_NEXT="$IW_BRANCH"
ver_gt "$K_NEXT" "$K_BRANCH" || K_NEXT="$K_BRANCH"
if [ "$IW_NEXT" != "$IW_BRANCH" ] || [ "$K_NEXT" != "$K_BRANCH" ]; then
  if [ -f versions-next.env ]; then old=versions-next.env; else old=versions.env; fi
  write_versions versions-next.env "$IW_NEXT" "$K_NEXT" "$old"
elif [ -f versions-next.env ]; then
  rm versions-next.env
  note "versions-next.env removed: no newer major version"
fi

# -------------------------------------------------------------------- sources
declare -A HEADS
head_of() {
  [ -n "${HEADS[$1]:-}" ] || HEADS[$1]="$(git ls-remote "$1" HEAD | cut -f1)"
  echo "${HEADS[$1]}"
}

checkout_at() { # url commit -> directory on stdout
  local d="$WORK/src-$2"
  # called in a command substitution, where set -e does not apply
  [ -d "$d" ] || {
    git init -q "$d" &&
    git -C "$d" fetch -q --depth 1 "$1" "$2" &&
    git -C "$d" -c advice.detachedHead=false checkout -q FETCH_HEAD
  } >&2 || { rm -rf "$d"; return 1; }
  echo "$d"
}

bump_sources() { # sources.txt, directory with the oaf patches
  local file="$1" oafdir="$2" name url commit dirs new d p ok
  local -a patches
  cp "$file" "$WORK/sources.in"
  while read -r name url commit dirs; do
    case "$name" in ''|\#*) continue ;; esac
    new="$(head_of "$url")"
    [[ "$new" =~ ^[0-9a-f]{40}$ ]] || { problem "$name in $file: cannot read the upstream HEAD" "$url"; continue; }
    [ "$new" = "$commit" ] && continue
    ok=1
    d="$(checkout_at "$url" "$new")" || { problem "$name in $file: cannot fetch the upstream HEAD" "$url $new"; continue; }
    for p in $dirs; do
      [ "$p" = . ] || [ -d "$d/$p" ] || { problem "$name in $file: a package directory is gone upstream" "$p is not in $url at $new; kept $commit"; ok=0; }
    done
    patches=()
    if [ "$name" = oaf ]; then patches+=("$PWD/$oafdir"/*.patch); fi
    if [ -d "patches/$name" ]; then patches+=("$PWD/patches/$name"/*.patch); fi
    if [ "$ok" = 1 ] && [ "${#patches[@]}" -gt 0 ]; then
      git -C "$d" apply --check "${patches[@]}" 2>"$WORK/apply.log" \
        || { problem "$name in $file: our patches no longer apply upstream" "kept $commit, $url is at $new: $(head -n3 "$WORK/apply.log" | tr '\n' ' ')"; ok=0; }
    fi
    [ "$ok" = 1 ] || continue
    awk -v n="$name" -v o="$commit" -v c="$new" '$1==n { sub(o, c) } { print }' "$file" > "$WORK/sources" \
      && cat "$WORK/sources" > "$file"
    note "$file: $name ${commit::7} -> ${new::7}"
  done < "$WORK/sources.in"
}

bump_sources docker/sources.txt docker/oaf-netns
bump_sources native/sources.txt native/patches

oaf="$(awk '$1=="oaf"{print $3}' docker/sources.txt)"
if [ -n "$oaf" ] && [ "$oaf" != "$(cat docker/oaf-netns/UPSTREAM_COMMIT)" ]; then
  echo "$oaf" > docker/oaf-netns/UPSTREAM_COMMIT
fi

[ -s "$NOTES" ] || echo "- nothing new" > "$NOTES"
