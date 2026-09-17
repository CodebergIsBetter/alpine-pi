#!/usr/bin/env bash
# build-image.sh — build one alpine-pi image variant with pmbootstrap.
#
# Usage: build-image.sh <headless|sway|xfce4> [outdir]
#
# pmbootstrap normally gets its settings from an interactive "pmbootstrap init".
# CI has no terminal, so the config file is written directly instead; every
# value comes from config/alpinepi.env so the images and the docs cannot drift
# apart.
set -euo pipefail

VARIANT="${1:-}"
OUTDIR="${2:-$PWD/out}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "$VARIANT" in
	headless) UI=none ;;
	sway)     UI=sway ;;
	xfce4)    UI=xfce4 ;;
	*) echo "usage: $0 <headless|sway|xfce4> [outdir]" >&2; exit 2 ;;
esac

# shellcheck source=../config/alpinepi.env
. "$REPO_ROOT/config/alpinepi.env"

CHECKOUT="$REPO_ROOT/checkout"
PMB="$CHECKOUT/pmbootstrap"
APORTS="$CHECKOUT/pmaports"

# ------------------------------------------------------------------ #
# 1. Fetch the forks
# ------------------------------------------------------------------ #
mkdir -p "$CHECKOUT"
clone_or_update() {
	local url="$1" dir="$2"
	if [ -d "$dir/.git" ]; then
		git -C "$dir" fetch --quiet origin "$ALPINEPI_BRANCH"
		# The fork's branch is rebased on upstream daily, so its history is
		# rewritten and "git pull" would try to merge divergent histories.
		git -C "$dir" reset --quiet --hard "origin/$ALPINEPI_BRANCH"
	else
		git clone --quiet --branch "$ALPINEPI_BRANCH" "$url" "$dir"
	fi
	echo "  $(basename "$dir") $(git -C "$dir" rev-parse --short HEAD) $(git -C "$dir" log -1 --format=%s)"
}

# pmbootstrap refuses to use a pmaports checkout that has no remote pointing at
# the canonical upstream: pmb.helpers.git.get_upstream_remote() scans the
# remotes for one of postmarketOS' own URLs and aborts with
#
#   pmaports: could not find remote name for any URL '[...]' in git repository
#
# when none matches. It only wants the remote NAME, to build refs like
# "<remote>/<branch>" - it does not fetch from it here.
#
# A developer never hits this because their pmaports was cloned from GitLab in
# the first place. CI clones the fork from GitHub, so origin points at GitHub
# and the lookup finds nothing. Add the canonical URL as a second remote and
# leave origin alone, since origin is what we fetch and reset the branch from.
add_upstream_remote() {
	local dir="$1" url="$2"
	git -C "$dir" remote remove pmos-upstream 2>/dev/null || true
	git -C "$dir" remote add pmos-upstream "$url"
}

echo "[build] checkouts:"
clone_or_update "$ALPINEPI_PMBOOTSTRAP_REPO" "$PMB"
clone_or_update "$ALPINEPI_PMAPORTS_REPO" "$APORTS"
add_upstream_remote "$APORTS" "https://gitlab.postmarketos.org/postmarketOS/pmaports.git"

# ------------------------------------------------------------------ #
# 2. Write pmbootstrap's config and create its work folder
# ------------------------------------------------------------------ #
# The work folder is named explicitly rather than left to pmbootstrap's
# default, because the next block has to create it and step 4 has to find the
# image inside it.
# pmbootstrap reads channels.cfg by running
#
#   git show <upstream-remote>/main:channels.cfg
#
# against the pmaports clone, i.e. from a remote-TRACKING ref, not over the
# network. A developer has that ref because their pmaports was cloned from
# GitLab. CI clones the fork from GitHub and only adds the canonical URL as a
# remote above, so pmos-upstream/main has never been fetched and does not
# exist - the second CI run failed with
#
#   ERROR: Failed to read channels.cfg from 'pmos-upstream/main' branch of
#   your local pmaports clone
#
# PMB_CHANNELS_CFG is pmbootstrap's own documented override and takes a plain
# file path. Point it at the checkout's own channels.cfg: the fork carries the
# file in-tree, so this needs no network and no upstream ref, and the fork
# stays the single source of truth rather than something fetched from
# postmarketOS at build time.
export PMB_CHANNELS_CFG="$APORTS/channels.cfg"
[ -f "$PMB_CHANNELS_CFG" ] || {
	echo "ERROR: $PMB_CHANNELS_CFG missing - the pmaports fork should carry it" >&2
	exit 1
}

WORK_DIR="${ALPINEPI_WORK:-$HOME/.local/var/pmbootstrap}"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/pmbootstrap_v3.cfg"
mkdir -p "$(dirname "$CFG")"
cat > "$CFG" <<CFGEOF
[pmbootstrap]
aports = $APORTS
device = $ALPINEPI_DEVICE
work = $WORK_DIR
extra_packages = none
hostname = $ALPINEPI_HOSTNAME
user = $ALPINEPI_USER
ui = $UI
locale = $ALPINEPI_LOCALE
timezone = $ALPINEPI_TIMEZONE
headless = True
is_default_channel = False

[providers]

[mirrors]
CFGEOF
echo "[build] config written for ui=$UI"

# Writing the config is not enough: "pmbootstrap init" is also the only thing
# that normally creates the work folder, and every other action refuses to run
# without it -
#   Work path not found, please run 'pmbootstrap init' to create it.
# An empty directory does not help either. With no "version" file the work
# folder migration reads version 0, compares it against pmb.config.work_version
# and gives up with "Sorry, we can't migrate that automatically". So do exactly
# what init does and no more: the directory, the version file, and cache_git
# (which must be owned by this user, or a later bind mount creates it as root).
#
# The version number is read out of the checkout rather than written here, so
# that a fork that bumps work_version does not silently produce a work folder
# pmbootstrap then refuses to migrate.
#
# The optional ":..." in the pattern tolerates an annotated constant
# ("work_version: int = 7") as well as a bare one. Not hypothetical tidiness:
# if this extraction comes back empty the build aborts here, on a fresh runner,
# before it has done anything - which is the exact class of failure this block
# exists to remove.
WORK_VERSION="$(grep -Eom1 '^work_version[[:space:]]*(:[^=]*)?=[[:space:]]*[0-9]+' \
	"$PMB/pmb/config/__init__.py" | grep -Eo '[0-9]+$' || true)"
[ -n "$WORK_VERSION" ] || {
	echo "ERROR: cannot read work_version from $PMB/pmb/config/__init__.py" >&2
	exit 1
}
mkdir -p "$WORK_DIR/cache_git"
chmod 700 "$WORK_DIR" "$WORK_DIR/cache_git"
if [ ! -f "$WORK_DIR/version" ]; then
	printf '%s\n' "$WORK_VERSION" > "$WORK_DIR/version"
fi
echo "[build] work folder $WORK_DIR (work_version $WORK_VERSION)"

# ------------------------------------------------------------------ #
# 3. Build
# ------------------------------------------------------------------ #
# The rootfs chroot MUST be zapped between variants: "pmbootstrap install"
# reuses an existing rootfs chroot and only *adds* the packages of the selected
# UI, so going sway -> none would leave every sway package in place and produce
# the same image under a different name.
cd "$PMB"
./pmbootstrap.py shutdown >/dev/null 2>&1 || true
sudo losetup -D 2>/dev/null || true
./pmbootstrap.py -y zap

# The arguments are built in an array so that an EMPTY ALPINEPI_WIFI_COUNTRY
# can omit --wifi-country altogether. That is the only way to ask for the world
# regulatory domain: pmbootstrap requires exactly two letters, so it rejects
# both "" and the conventional "00" literal, and passing a country always writes
# a country= line into wpa_supplicant.conf.
INSTALL_ARGS=(
	--password "$ALPINEPI_PASSWORD"
	--wifi-ssid "$ALPINEPI_WIFI_SSID"
	--wifi-psk "$ALPINEPI_WIFI_PSK"
)
if [ -n "${ALPINEPI_WIFI_COUNTRY:-}" ]; then
	INSTALL_ARGS+=(--wifi-country "$ALPINEPI_WIFI_COUNTRY")
else
	echo "[build] ALPINEPI_WIFI_COUNTRY is empty: no country= line, so the" \
		"image uses the world regulatory domain"
fi

./pmbootstrap.py -y -E "$ALPINEPI_EXTRA_SPACE" install "${INSTALL_ARGS[@]}"

./pmbootstrap.py shutdown >/dev/null 2>&1 || true

# ------------------------------------------------------------------ #
# 4. Collect
# ------------------------------------------------------------------ #
# $WORK_DIR, not "pmbootstrap config work": this script wrote that value into
# the config in step 2, so re-reading and re-parsing it could only introduce a
# disagreement (the parse used to strip spaces out of the path, which breaks
# any work folder whose path contains one).
SRC="$WORK_DIR/chroot_native/home/pmos/rootfs/$ALPINEPI_DEVICE.img"
[ -f "$SRC" ] || { echo "ERROR: no image at $SRC" >&2; exit 1; }

mkdir -p "$OUTDIR"
DEST="$OUTDIR/alpinepi-$ALPINEPI_DEVICE-$VARIANT.img"
sudo cp "$SRC" "$DEST"
sudo chown "$(id -u):$(id -g)" "$DEST"
echo "[build] $DEST ($(stat -c %s "$DEST") bytes)"

# Tell the workflow where the image landed. The device part of the name comes
# from config/alpinepi.env, so .github/workflows/build.yml must not spell it
# out a second time: it reads these outputs instead.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		echo "image=$DEST"
		echo "name=$(basename "$DEST" .img)"
	} >> "$GITHUB_OUTPUT"
fi
