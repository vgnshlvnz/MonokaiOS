#!/usr/bin/env bash
# mkiso.sh — build a Debian live ISO with your packages.
# Edit the CONFIG section, then:  sudo ./mkiso.sh
# Runs directly on Debian, or automatically inside Docker on any other host.
set -euo pipefail

# ============================== CONFIG ==============================
DIST=trixie                      # trixie | bookworm | testing
ARCH=amd64                       # amd64 | arm64
NAME=netlive                     # ISO file name
HOST=netlive                     # hostname
USER_NAME=netops
USER_PASS="${USER_PASS:-changeme}" # login password (hashed at build time); CI passes it as a secret
TIMEZONE=Asia/Kuala_Lumpur
MIRROR=http://deb.debian.org/debian

PACKAGES=(
  # networking
  iproute2 ethtool iputils-ping bridge-utils vlan nftables iptables tcpdump tshark
  nmap mtr-tiny iperf3 socat netcat-openbsd curl wget bind9-dnsutils whois
  traceroute arping lldpd ipcalc
  # diagnostics / recovery
  htop iotop smartmontools lshw pciutils usbutils dmidecode parted testdisk
  gddrescue rsync lvm2 mdadm cryptsetup ntfs-3g btrfs-progs xfsprogs
  # tools
  openssh-server sudo git vim tmux python3 jq minicom picocom screen
  network-manager                # DHCP on wired NICs at boot
)

# Extra apt repositories, one per line:  "name|URI|suite|components|key"
#   key = https:// URL or a file path next to this script (ASCII or binary).
#   Written as deb822 /etc/apt/sources.list.d/<name>.sources with Signed-By,
#   so they stay usable on the live system. Leave components empty for flat repos.
APT_SOURCES=(
  # "docker|https://download.docker.com/linux/debian|trixie|stable|https://download.docker.com/linux/debian/gpg"
  # "tailscale|https://pkgs.tailscale.com/stable/debian|trixie|main|https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg"
  # "ai-workbench|https://workbench.download.nvidia.com/stable/linux/debian|default|proprietary|https://workbench.download.nvidia.com/stable/linux/gpgkey"
)
# Packages to install from those repositories.
REPO_PACKAGES=(
  # docker-ce docker-ce-cli containerd.io tailscale
  # <AI Workbench package: find its name with `apt-cache search workbench` after adding the repo>
)

# Desktop: none (console only) | xfce (classic, works everywhere incl. VMs)
#          | sway (tiling Wayland, i3-style keys)
#          | hyprland (tiling Wayland, from trixie-backports; needs a GPU — in QEMU use GL=1 ./testiso.sh)
DESKTOP=hyprland
DESKTOP_AUTOLOGIN=true           # boot straight into the desktop as USER_NAME

# Disk installer with A/B system slots (built into this script).
# On the live system run:  sudo netlive-ab install   (UEFI machines)
AB_INSTALLER=true

# Standard Debian installers (in addition to, or instead of, netlive-ab):
#   calamares        graphical installer on the live desktop ("Install Debian" / install-system)
#   debian-installer "Install" + "Graphical install" entries in the boot menu
#   both | none
STD_INSTALLER=both

# .deb files to install directly: URL or a file next to this script.
DEB_URLS=(
  "https://github.com/vercel/hyper/releases/download/v3.4.1/hyper_3.4.1_amd64.deb"   # Hyper terminal (needs a DESKTOP)
)

# Pin an exact Zig release from ziglang.org (checksum-verified) for source builds
# that need a specific version. Installed to /opt/zig, linked as /usr/local/bin/zig.
# Leave empty to skip. Do NOT also list zig in BREW_PACKAGES (brew's newer zig would win).
ZIG_VERSION="0.16.0"

# Build from source, one per line:  "name|source|ref|build command"
#   source  = git URL, tarball URL (.tar.gz/.xz/.bz2/.zst), or a directory next to this script
#   ref     = git branch/tag/commit (empty = default branch; ignored for tarballs/dirs)
#   command = how to build+install; empty = auto-detect (autogen/configure, CMake,
#             Meson, Cargo, Go, Zig, Makefile), always installing to /usr/local.
#   Toolchains from BREW_PACKAGES (e.g. zig) are on PATH during these builds.
#   Everything after the third | is the command, so it may contain | and &&.
SOURCE_BUILDS=(
  # "htop|https://github.com/htop-dev/htop.git|3.4.1|"
  # "mytool|./src/mytool||make && make install PREFIX=/usr/local"
  # "slosh|<slosh git URL>||"        # Zig project: add zig to BREW_PACKAGES
)
# Packages needed only to compile the above (added when SOURCE_BUILDS is non-empty).
SOURCE_BUILD_DEPS=(
  build-essential git curl ca-certificates pkg-config cmake autoconf automake libtool
  # meson ninja-build cargo golang libncurses-dev
)

# npm packages, installed globally into /usr/local (pulls in Debian's nodejs + npm).
NPM_PACKAGES=(
  # @anthropic-ai/claude-code
)

# Homebrew formulae (installed into /home/linuxbrew/.linuxbrew at build time).
# Leave empty to skip Homebrew entirely. Example: (k9s lazygit btop gping)
# Linux only: macOS casks (e.g. 'claude' desktop app) are skipped with a warning.
BREW_PACKAGES=(
  k9s lazygit btop gping
)
# ====================================================================

SELF="$(readlink -f "$0")"
WORK="$(dirname "${SELF}")/iso-build"

# Not Debian or not root? Re-run inside a privileged Debian container.
if [[ ! -f /etc/debian_version || ${EUID} -ne 0 ]] || ! grep -q '^ID=debian' /etc/os-release; then
  command -v docker >/dev/null || { echo "Run as root on Debian, or install Docker." >&2; exit 1; }
  exec docker run --rm --privileged -e USER_PASS -v "$(dirname "${SELF}")":/work -w /work \
    debian:stable bash "/work/$(basename "${SELF}")"
fi

command -v lb >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y -qq live-build openssl curl gpg ca-certificates >/dev/null; }

mkdir -p "${WORK}" && cd "${WORK}"
[[ -d config ]] && { lb clean; rm -rf config; }   # keeps the package cache
# A saved base system copied by git or a CI cache loses root ownership and /tmp's
# permissions, which breaks apt inside it. Detect that and rebuild it fresh.
if [[ -d cache/bootstrap ]] && { [[ "$(stat -c %u cache/bootstrap/etc/passwd 2>/dev/null)" != 0 ]] ||
                                 [[ "$(stat -c %a cache/bootstrap/tmp 2>/dev/null)" != 1777 ]]; }; then
  echo "Discarding damaged bootstrap cache (wrong ownership/permissions); rebuilding it"
  rm -rf cache/bootstrap .build
fi

lb config \
  --distribution "${DIST}" --architecture "${ARCH}" \
  --archive-areas "main contrib non-free-firmware" \
  --mirror-bootstrap "${MIRROR}" --mirror-chroot "${MIRROR}" --mirror-binary "${MIRROR}" \
  --binary-images iso-hybrid --image-name "${NAME}" \
  --debian-installer "$([[ "${STD_INSTALLER}" == debian-installer || "${STD_INSTALLER}" == both ]] && echo live || echo none)" \
  --memtest none \
  --backports "$([[ "${DESKTOP}" == hyprland && "${DIST}" == trixie ]] && echo true || echo false)" \
  --bootappend-live "boot=live components live-config.nocomponents=user-setup live-config.noautologin hostname=${HOST} timezone=${TIMEZONE} console=ttyS0,115200n8 console=tty0"

case "${DESKTOP}" in
  none) ;;
  xfce) PACKAGES+=(xorg lightdm lightdm-gtk-greeter xfce4 xfce4-terminal xfce4-whiskermenu-plugin
                   network-manager-gnome dbus-x11 firefox-esr fonts-dejavu) ;;
  sway) PACKAGES+=(sway swaybg swayidle swaylock waybar wofi foot xwayland
                   network-manager-gnome firefox-esr fonts-dejavu) ;;
  hyprland)
    # Hyprland itself comes from backports via a hook; companions from the main archive.
    [[ "${DIST}" == bookworm ]] && { echo "Hyprland needs DIST=trixie or newer" >&2; exit 1; }
    PACKAGES+=(kitty foot waybar wofi xwayland network-manager-gnome firefox-esr fonts-dejavu
               fonts-font-awesome polkitd libgl1-mesa-dri) ;;
  *) echo "DESKTOP must be none, xfce, sway or hyprland (got ${DESKTOP})" >&2; exit 1 ;;
esac
case "${STD_INSTALLER}" in
  calamares|both)
    if [[ "${DESKTOP}" == none ]]; then
      echo "Note: Calamares needs a DESKTOP; skipping it (debian-installer still available)" >&2
    else
      PACKAGES+=(calamares calamares-settings-debian)
    fi ;;
  debian-installer|none) ;;
  *) echo "STD_INSTALLER must be calamares, debian-installer, both or none" >&2; exit 1 ;;
esac
[[ "${AB_INSTALLER}" == true ]] && PACKAGES+=(gdisk dosfstools e2fsprogs rsync efibootmgr
                                               systemd-boot-efi squashfs-tools curl)  # not 'systemd-boot': its postinst fails without an ESP
[[ -n "${ZIG_VERSION}" ]] && PACKAGES+=(curl xz-utils python3 ca-certificates)
((${#SOURCE_BUILDS[@]})) && PACKAGES+=("${SOURCE_BUILD_DEPS[@]}")
((${#NPM_PACKAGES[@]})) && PACKAGES+=(nodejs npm)
# Homebrew needs these on the system.
((${#BREW_PACKAGES[@]})) && PACKAGES+=(build-essential procps curl file git ca-certificates)
printf '%s\n' "${PACKAGES[@]}" | grep -v '^#' > config/package-lists/custom.list.chroot

# Extra apt repositories: keys + deb822 sources copied into the image, then a
# hook installs REPO_PACKAGES from them.
inc=config/includes.chroot_after_packages/etc/apt
for src in "${APT_SOURCES[@]}"; do
  IFS='|' read -r r_name r_uri r_suite r_comp r_key <<< "${src}"
  [[ -n "${r_name}" && -n "${r_uri}" && -n "${r_suite}" && -n "${r_key}" ]] \
    || { echo "Bad APT_SOURCES entry (need name|URI|suite|components|key): ${src}" >&2; exit 1; }
  mkdir -p "${inc}/keyrings" "${inc}/sources.list.d"
  keyfile="${inc}/keyrings/${r_name}.gpg"
  if [[ "${r_key}" == http* ]]; then
    curl -fsSL "${r_key}" -o "${keyfile}.tmp" || { echo "Cannot download key for ${r_name}: ${r_key}" >&2; exit 1; }
  else
    cp "$(dirname "${SELF}")/${r_key#./}" "${keyfile}.tmp"
  fi
  if grep -q 'BEGIN PGP' "${keyfile}.tmp"; then
    gpg --dearmor < "${keyfile}.tmp" > "${keyfile}"; rm -f "${keyfile}.tmp"
  else
    mv "${keyfile}.tmp" "${keyfile}"
  fi
  {
    echo "Types: deb"
    echo "URIs: ${r_uri}"
    echo "Suites: ${r_suite}"
    [[ -n "${r_comp}" ]] && echo "Components: ${r_comp}"
    echo "Architectures: ${ARCH}"
    echo "Signed-By: /etc/apt/keyrings/${r_name}.gpg"
  } > "${inc}/sources.list.d/${r_name}.sources"
  echo "Added apt source: ${r_name}"
done

if ((${#REPO_PACKAGES[@]})); then
  ((${#APT_SOURCES[@]})) || echo "Note: REPO_PACKAGES set but APT_SOURCES empty — installing from Debian." >&2
  cat > config/hooks/normal/0050-repo-packages.hook.chroot <<EOF
#!/bin/sh
set -e
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ${REPO_PACKAGES[*]}
apt-get clean
EOF
  chmod +x config/hooks/normal/0050-repo-packages.hook.chroot
fi

# install-system: start Calamares as root on the current (Wayland or X11) session.
if [[ "${STD_INSTALLER}" == calamares || "${STD_INSTALLER}" == both ]] && [[ "${DESKTOP}" != none ]]; then
  mkdir -p config/includes.chroot_after_packages/usr/local/bin
  cat > config/includes.chroot_after_packages/usr/local/bin/install-system <<'EOF'
#!/bin/sh
# Launch the graphical installer (Calamares) with the session's display access.
if [ -n "$WAYLAND_DISPLAY" ]; then export QT_QPA_PLATFORM=wayland; fi
exec sudo -E calamares "$@"
EOF
  chmod 0755 config/includes.chroot_after_packages/usr/local/bin/install-system
fi

# A/B disk installer, embedded so it can never be left out of the image.
if [[ "${AB_INSTALLER}" == true ]]; then
  mkdir -p config/includes.chroot_after_packages/usr/local/bin
  cat > config/includes.chroot_after_packages/usr/local/bin/netlive-ab <<'NETLIVE_AB_EMBEDDED'
#!/usr/bin/env bash
# netlive-ab — install a netlive live image to disk with A/B system slots, and
# update it later without disturbing the running system.  UEFI only.
#
#   netlive-ab install                    guided: pick a disk, choose wipe or free space
#   netlive-ab install --disk /dev/nvme0n1 --mode free     next to an existing OS
#   netlive-ab install --disk /dev/sdb --mode wipe --yes   whole disk, no questions
#   netlive-ab update  <file.iso|https://…/file.iso>       write new image to the inactive slot
#   netlive-ab rollback                                    boot the other slot next time
#   netlive-ab status                                      slots, versions, boot health
#
# Layout (GPT):  [ESP] [netlive-boot 1G] [netlive-a] [netlive-b] [netlive-home]
#  - free mode reuses the disk's existing ESP and never touches other partitions
#  - systemd-boot with boot counting: a new slot gets 3 tries; if it never boots
#    successfully it is marked bad and the previous slot boots again by itself
#  - /home is shared by both slots and never rewritten by updates
set -euo pipefail

TRIES=3
BOOT_SIZE=1G
ESP_SIZE=512M
HOME_MIN=4G
P=netlive                                   # partition label prefix
WORK=""
DRY=0 YES=0 MAKE_DEFAULT=0 BOTH=0

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'netlive-ab: %s\n' "$*" >&2; exit 1; }
bytes() { numfmt --from=iec "${1^^}"; }
human() { numfmt --to=iec --suffix=B "$1"; }

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

need_root() { [[ ${EUID} -eq 0 ]] || die "run as root (sudo netlive-ab …)"; }
need_uefi() { [[ -d /sys/firmware/efi ]] || die "A/B install needs a UEFI system (this one booted in BIOS mode)"; }
need_tools() {
  local t missing=()
  for t in sgdisk partprobe mkfs.vfat mkfs.ext4 rsync efibootmgr blkid lsblk numfmt; do
    command -v "$t" >/dev/null || missing+=("$t")
  done
  ((${#missing[@]} == 0)) || die "missing tools: ${missing[*]}"
  [[ -f /usr/lib/systemd/boot/efi/systemd-bootx64.efi ]] || die "systemd-boot is not installed in this image (package systemd-boot-efi)"
}

cleanup() {
  [[ -n "${WORK}" && -d "${WORK}" ]] || return 0
  local m
  # unmount everything under WORK, deepest first
  while read -r m; do umount -l "$m" 2>/dev/null || true; done < <(findmnt -rno TARGET | grep "^${WORK}" | sort -r)
  rmdir "${WORK}"/* "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

newwork() { WORK="$(mktemp -d /tmp/netlive-ab.XXXXXX)"; mkdir -p "${WORK}"/{sq,iso,target,boot,esp,home}; }

partdev() { local l="/dev/disk/by-partlabel/$1"; [[ -e "$l" ]] && readlink -f "$l"; }
puuid()   { blkid -s PARTUUID -o value "$1"; }
fsuuid()  { blkid -s UUID -o value "$1"; }
parent()  { lsblk -no PKNAME "$1" | head -n1; }
partnum() { cat "/sys/class/block/$(basename "$1")/partition"; }

confirm() {
  ((YES)) && return 0
  local a; read -r -p "$1 Type YES to continue: " a
  [[ "$a" == YES ]] || die "aborted, nothing changed"
}

# ---------------------------------------------------------------- source image
# Sets SRC_SQFS and mounts it read-only at $WORK/sq; sets SRC_USED (bytes) and SRC_NAME.
open_source() {
  local src="${1:-}"
  if [[ -z "$src" ]]; then
    src=/run/live/medium/live/filesystem.squashfs
    [[ -f "$src" ]] || die "not running from the live image; give an ISO: netlive-ab $CMD <file.iso>"
    SRC_NAME="live medium"
  elif [[ "$src" == http://* || "$src" == https://* ]]; then
    local cache=/home/.netlive-cache
    [[ -d /home ]] && mountpoint -q /home || cache=/var/tmp
    mkdir -p "$cache"
    log "Downloading $src"
    ((DRY)) || curl -fL --progress-bar -o "$cache/update.iso" "$src" || die "download failed"
    src="$cache/update.iso"
  fi
  if [[ "$src" == *.iso ]]; then
    [[ -f "$src" ]] || die "no such file: $src"
    mount -o loop,ro "$src" "$WORK/iso"
    SRC_NAME="$(basename "$src")"
    src="$WORK/iso/live/filesystem.squashfs"
    [[ -f "$src" ]] || die "$SRC_NAME is not a netlive/Debian live ISO (no live/filesystem.squashfs)"
  fi
  SRC_NAME="${SRC_NAME:-$(basename "$src")}"
  SRC_SQFS="$src"
  mount -t squashfs -o loop,ro "$SRC_SQFS" "$WORK/sq"
  SRC_USED="$(du -sxB1 "$WORK/sq" | cut -f1)"
  log "Image: ${SRC_NAME} ($(human "$SRC_USED") installed)"
}

# Slot size: twice the installed size plus headroom for apt, minimum 10G.
default_slot_size() {
  local need=$(( SRC_USED * 2 + $(bytes 2G) )) min; min=$(bytes 10G)
  ((need < min)) && need=$min
  local g=$(( (need + (1<<30) - 1) >> 30 )); echo "${g}G"
}

# ---------------------------------------------------------------- slot writer
write_slot() {   # <slot a|b> <mode install|update>
  local slot="$1" mode="$2" dev t="$WORK/target" kver uuid_home uuid_boot uuid_esp
  dev="$(partdev "$P-$slot")" || die "partition $P-$slot not found"
  log "Writing slot ${slot^^} ($dev) — $(human "$SRC_USED") to copy"
  umount "$dev" 2>/dev/null || true
  mkfs.ext4 -F -q -L "$P-$slot" "$dev"
  mount "$dev" "$t"
  rsync -aHAXx --numeric-ids --info=progress2 "$WORK/sq/" "$t/"

  uuid_home="$(fsuuid "$(partdev "$P-home")")"
  uuid_boot="$(fsuuid "$(partdev "$P-boot")")"
  uuid_esp="$(fsuuid "$ESP_DEV")"
  cat > "$t/etc/fstab" <<EOF
# netlive-ab: slot ${slot^^}
PARTUUID=$(puuid "$dev")  /      ext4  defaults,noatime  0 1
UUID=${uuid_home}         /home  ext4  defaults,noatime  0 2
UUID=${uuid_boot}         /boot  vfat  umask=0077,x-systemd.automount  0 2
UUID=${uuid_esp}          /efi   vfat  umask=0077,noauto,x-systemd.automount  0 2
EOF
  mkdir -p "$t/efi"
  printf '%s\n' "$slot" > "$t/etc/netlive-slot"
  # Boot counting: systemd-boot decrements the entry's tries on each attempt;
  # this unit marks the slot good once the system is fully up.
  cat > "$t/etc/systemd/system/netlive-bless.service" <<'EOF'
[Unit]
Description=Mark this netlive slot as successfully booted
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/netlive-ab bless

[Install]
WantedBy=multi-user.target
EOF
  mkdir -p "$t/etc/systemd/system/multi-user.target.wants"
  ln -sf ../netlive-bless.service "$t/etc/systemd/system/multi-user.target.wants/netlive-bless.service"

  if [[ "$mode" == update ]]; then carry_over "$t"; fi

  # Turn the live image into a normal installed system.
  local d
  for d in dev proc sys run; do mount --rbind "/$d" "$t/$d"; mount --make-rslave "$t/$d"; done
  # shellcheck disable=SC2016  # expanded inside the chroot, not here
  chroot "$t" /bin/bash -euo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive
    live=$(dpkg-query -W -f "\${Package} \${Status}\n" live-boot live-boot-initramfs-tools \
           live-config live-config-systemd live-tools 2>/dev/null | awk "/ installed\$/{print \$1}")
    [ -n "$live" ] && apt-get purge -y -q $live >/dev/null
    rm -f /etc/systemd/system/getty@tty1.service.d/live-config_autologin.conf
    update-initramfs -u -k all >/dev/null'
  for d in run sys proc dev; do umount -R "$t/$d"; done

  kver="$(find "$t/lib/modules" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort -V | tail -n1)"
  mkdir -p "$WORK/boot/$P/$slot" "$WORK/boot/loader/entries"
  cp "$t/boot/vmlinuz-$kver"    "$WORK/boot/$P/$slot/vmlinuz"
  cp "$t/boot/initrd.img-$kver" "$WORK/boot/$P/$slot/initrd.img"

  rm -f "$WORK/boot/loader/entries/$P-$slot"*.conf
  cat > "$WORK/boot/loader/entries/$P-$slot+$TRIES.conf" <<EOF
title      Netlive slot ${slot^^} — ${SRC_NAME}
version    $(date +%Y%m%d%H%M%S)
sort-key   $P
linux      /$P/$slot/vmlinuz
initrd     /$P/$slot/initrd.img
options    root=PARTUUID=$(puuid "$dev") rw console=tty0
EOF
  if [[ "$mode" == install ]]; then return 0; fi
  sync; umount "$t"
}

# Settings that belong to this machine, not to the image.
carry_over() {
  local t="$1" f u hash
  for f in /etc/machine-id /etc/hostname /etc/hosts /etc/localtime /etc/timezone \
           /etc/NetworkManager/system-connections /etc/ssh/ssh_host_*; do
    [[ -e "$f" ]] && rsync -aR "$f" "$t/"
  done
  # Keep passwords of human users that exist in both systems.
  while IFS=: read -r u _ uid _; do
    ((uid >= 1000 && uid < 60000)) || continue
    grep -q "^$u:" "$t/etc/passwd" || continue
    hash="$(getent shadow "$u" | cut -d: -f2)"
    [[ -n "$hash" ]] && chroot "$t" usermod -p "$hash" "$u"
  done < /etc/passwd
}

# ---------------------------------------------------------------- bootloader
install_bootloader() {
  local disk="$1" esp_num efi="$WORK/esp" order new
  mkdir -p "$efi/EFI/$P" "$efi/loader"
  cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi "$efi/EFI/$P/systemd-bootx64.efi"
  if [[ -f "$efi/loader/loader.conf" ]] && ! grep -q '^# netlive-ab' "$efi/loader/loader.conf"; then
    warn "ESP already has a systemd-boot loader.conf from another system; leaving it as is"
  else
    printf '# netlive-ab\ndefault %s-*\ntimeout 3\neditor no\n' "$P" > "$efi/loader/loader.conf"
  fi
  esp_num="$(partnum "$ESP_DEV")"
  order="$(efibootmgr | sed -n 's/^BootOrder: //p')"
  # Remove our old entries, then add one.
  efibootmgr | sed -n 's/^Boot\([0-9A-F]\{4\}\)\*\{0,1\} Netlive.*/\1/p' | while read -r n; do efibootmgr -q -b "$n" -B; done
  efibootmgr -q -c -d "/dev/$disk" -p "$esp_num" -L "Netlive" -l "\\EFI\\$P\\systemd-bootx64.efi"
  new="$(efibootmgr | sed -n 's/^Boot\([0-9A-F]\{4\}\)\*\{0,1\} Netlive.*/\1/p' | head -n1)"
  if ((MAKE_DEFAULT)) || [[ -z "$order" ]]; then
    log "Netlive is now the first boot entry"
  else
    efibootmgr -q -o "${order},${new}"
    log "Added boot entry 'Netlive' after your existing ones — pick it from the firmware boot menu (often F12/F11/F8), or rerun with --make-default"
  fi
}

# ---------------------------------------------------------------- install
pick_disk() {
  local live_disk; live_disk="$(parent "$(findmnt -no SOURCE /run/live/medium 2>/dev/null || echo none)" 2>/dev/null || true)"
  echo "Disks:"
  lsblk -dpno NAME,SIZE,MODEL,TRAN -e 7,11 | grep -v "/dev/${live_disk:-none} " | sed 's/^/  /'
  read -r -p "Install to which disk (e.g. /dev/nvme0n1)? " DISK
}

free_block() {  # prints "<first-sector> <last-sector>" of the largest free block
  local f e; f="$(sgdisk -F "$1" 2>/dev/null | tail -n1)"; e="$(sgdisk -E "$1" 2>/dev/null | tail -n1)"
  echo "$f $e"
}

cmd_install() {
  local mode="" slot_size="" src=""
  while (($#)); do case "$1" in
    --disk) DISK="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    --slot-size) slot_size="$2"; shift 2 ;;
    --source) src="$2"; shift 2 ;;
    --make-default) MAKE_DEFAULT=1; shift ;;
    --both) BOTH=1; shift ;;
    --yes) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    *) die "unknown option $1 (see netlive-ab --help)" ;;
  esac; done
  need_root; need_uefi; need_tools; newwork
  for l in a b boot home; do partdev "$P-$l" >/dev/null && die "a netlive install already exists ($P-$l found); use 'netlive-ab update'"; done
  open_source "$src"

  [[ -n "${DISK:-}" ]] || pick_disk
  [[ -b "$DISK" && "$(lsblk -dno TYPE "$DISK")" == disk ]] || die "$DISK is not a whole disk"
  local disk; disk="$(basename "$DISK")"
  if findmnt -rno SOURCE | grep -q "^/dev/${disk}"; then
    [[ "$(parent "$(findmnt -no SOURCE /run/live/medium 2>/dev/null || true)" 2>/dev/null || true)" == "$disk" ]] \
      && die "$DISK is the live USB itself"
    die "$DISK has mounted partitions; unmount them first"
  fi
  if [[ -z "$mode" ]]; then
    lsblk -po NAME,SIZE,FSTYPE,LABEL "$DISK"
    read -r -p "Wipe the whole disk (w) or use free space next to existing partitions (f)? " m
    case "$m" in w*) mode=wipe ;; f*) mode=free ;; *) die "aborted" ;; esac
  fi
  [[ "$mode" == wipe || "$mode" == free ]] || die "--mode must be wipe or free"
  slot_size="${slot_size:-$(default_slot_size)}"

  local ss total first last avail need esp_new=0 pt
  ss="$(blockdev --getss "$DISK")"; total="$(blockdev --getsize64 "$DISK")"
  if [[ "$mode" == free ]]; then
    pt="$(blkid -p -s PTTYPE -o value "$DISK" 2>/dev/null || true)"
    [[ "$pt" == gpt ]] || die "$DISK has no GPT partition table (${pt:-none}); free-space install needs GPT — use --mode wipe or convert first"
    ESP_DEV="$(lsblk -prno NAME,PARTTYPE "$DISK" | awk 'tolower($2)=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"{print $1; exit}')"
    [[ -n "$ESP_DEV" ]] || esp_new=1
    read -r first last <<< "$(free_block "$DISK")"
    first=$(( (first + 2047) / 2048 * 2048 ))
    avail=$(( (last - first + 1) * ss )); ((avail < 0)) && avail=0
  else
    esp_new=1; first=2048; avail=$(( total - 4 * 1024 * 1024 ))
  fi
  need=$(( $(bytes "$BOOT_SIZE") + 2 * $(bytes "$slot_size") + $(bytes "$HOME_MIN") ))
  ((esp_new)) && need=$(( need + $(bytes "$ESP_SIZE") ))
  local home_size=$(( avail - need + $(bytes "$HOME_MIN") ))

  echo
  echo "Plan for $DISK ($(human "$total")), mode: $mode"
  ((esp_new)) && printf '  %-14s %8s  EFI system partition (new)\n' "$P-esp" "$ESP_SIZE" \
              || printf '  %-14s %8s  existing EFI partition %s (reused, untouched except /EFI/%s)\n' esp "-" "$ESP_DEV" "$P"
  printf '  %-14s %8s  kernels + boot menu\n' "$P-boot" "$BOOT_SIZE"
  printf '  %-14s %8s  system slot A (installed now)\n' "$P-a" "$slot_size"
  printf '  %-14s %8s  system slot B (%s)\n' "$P-b" "$slot_size" "$( ((BOTH)) && echo 'installed now' || echo 'filled by first update')"
  printf '  %-14s %8s  /home, shared by both slots\n' "$P-home" "$( ((home_size > 0)) && human "$home_size" || echo '-')"
  echo "  Needed: $(human "$need")   Available: $(human "$avail")"
  if ((avail < need)); then
    die "not enough free space. Free up $(human $((need - avail))) (e.g. shrink a partition with GParted), use --slot-size, or --mode wipe"
  fi
  ((DRY)) && { echo "(dry run — nothing changed)"; exit 0; }
  if [[ "$mode" == wipe ]]; then confirm "ALL DATA on $DISK will be erased."
  else confirm "New partitions will be created in free space on $DISK; existing ones are not modified."; fi

  # --- partition
  local s=$(( first )) n
  mkpart() {  # <label> <type> <bytes|rest>
    local sectors end
    if [[ "$3" == rest ]]; then end="$last"; else sectors=$(( $3 / ss )); end=$(( s + sectors - 1 )); fi
    sgdisk -n "0:$s:$end" -t "0:$2" -c "0:$1" "$DISK" >/dev/null
    s=$(( (end + 1 + 2047) / 2048 * 2048 ))
  }
  if [[ "$mode" == wipe ]]; then
    sgdisk --zap-all "$DISK" >/dev/null; sgdisk -o "$DISK" >/dev/null
    last="$(sgdisk -E "$DISK" | tail -n1)"
  fi
  ((esp_new)) && mkpart "$P-esp"  ef00 "$(bytes "$ESP_SIZE")"
  mkpart "$P-boot" ea00 "$(bytes "$BOOT_SIZE")"
  mkpart "$P-a"    8304 "$(bytes "$slot_size")"
  mkpart "$P-b"    8304 "$(bytes "$slot_size")"
  mkpart "$P-home" 8302 rest
  partprobe "$DISK"; udevadm settle
  for n in boot a b home; do partdev "$P-$n" >/dev/null || die "partition $P-$n did not appear"; done
  ((esp_new)) && { ESP_DEV="$(partdev "$P-esp")"; mkfs.vfat -F32 -n NETLIVEESP "$ESP_DEV" >/dev/null; }

  # --- filesystems
  mkfs.vfat -F32 -n NETLIVEBOOT "$(partdev "$P-boot")" >/dev/null
  mkfs.ext4 -F -q -L "$P-home" "$(partdev "$P-home")"
  mount "$(partdev "$P-boot")" "$WORK/boot"
  mount "$ESP_DEV" "$WORK/esp"

  write_slot a install
  log "Creating /home from the image"
  mount "$(partdev "$P-home")" "$WORK/home"
  rsync -aHAX "$WORK/target/home/" "$WORK/home/"
  umount "$WORK/home"; sync; umount "$WORK/target"
  if ((BOTH)); then write_slot b install; umount "$WORK/target" 2>/dev/null || true; fi

  install_bootloader "$disk"
  if [[ "$mode" == wipe ]]; then   # removable-media fallback path; nothing else lives on this disk
    mkdir -p "$WORK/esp/EFI/BOOT"; cp "$WORK/esp/EFI/$P/systemd-bootx64.efi" "$WORK/esp/EFI/BOOT/BOOTX64.EFI"
  fi
  sync
  echo
  log "Installed. Remove the USB and reboot. Later updates: sudo netlive-ab update <new.iso>"
  [[ -d /sys/firmware/efi/efivars ]] && od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | awk '{exit !($NF==1)}' \
    && warn "Secure Boot is ON — systemd-boot here is unsigned; disable Secure Boot in the firmware to boot Netlive"
  return 0
}

# ---------------------------------------------------------------- update / rollback / status
current_slot() {
  [[ -f /etc/netlive-slot ]] || die "this system was not installed by netlive-ab"
  cat /etc/netlive-slot
}

mount_boot() {
  ls /efi >/dev/null 2>&1 || true                       # trigger the automount
  ESP_DEV="$(findmnt -rno SOURCE /efi | grep '^/dev/' | tail -n1)"
  [[ -n "$ESP_DEV" ]] || die "cannot find the EFI partition (/efi)"
  mount "$(partdev "$P-boot")" "$WORK/boot"
}

cmd_update() {
  local src="${1:-}"; [[ -n "$src" ]] || die "usage: netlive-ab update <file.iso | https://…/file.iso>"
  need_root; need_uefi; need_tools; newwork
  # Be a good neighbour: lowest CPU and disk priority while the user works.
  renice -n 19 $$ >/dev/null; ionice -c3 -p $$ 2>/dev/null || true
  local cur other size; cur="$(current_slot)"; [[ "$cur" == a ]] && other=b || other=a
  mount_boot
  open_source "$src"
  size="$(blockdev --getsize64 "$(partdev "$P-$other")")"
  (( SRC_USED * 11 / 10 < size )) || die "image needs $(human "$SRC_USED") but slot ${other^^} is only $(human "$size")"
  log "Running slot ${cur^^}; updating slot ${other^^} in the background — keep working"
  write_slot "$other" update
  sync
  log "Done. Slot ${other^^} starts on your next reboot (whenever you like)."
  log "If it fails to boot $TRIES times, slot ${cur^^} comes back automatically. Or: sudo netlive-ab rollback"
}

cmd_rollback() {
  need_root; newwork
  local cur other f; cur="$(current_slot)"; [[ "$cur" == a ]] && other=b || other=a
  mount_boot
  compgen -G "$WORK/boot/loader/entries/$P-$other*.conf" >/dev/null || die "slot ${other^^} has no system to roll back to"
  for f in "$WORK/boot/loader/entries/$P-$cur"*.conf; do
    mv "$f" "$WORK/boot/loader/entries/$P-$cur+0-$TRIES.conf"     # mark current as bad
  done
  log "Next boot uses slot ${other^^}. Slot ${cur^^} stays in the boot menu if you need it."
}

cmd_bless() {
  need_root
  local slot f; slot="$(current_slot)"
  ls /boot >/dev/null 2>&1 || true                       # trigger the automount
  for f in /boot/loader/entries/"$P-$slot"+*.conf; do
    [[ -e "$f" ]] || continue
    mv "$f" "/boot/loader/entries/$P-$slot.conf"
    log "slot ${slot^^} marked as good"
  done
}

cmd_status() {
  local f cur; cur="$(cat /etc/netlive-slot 2>/dev/null || echo '?')"
  echo "Running slot: ${cur^^}"
  ls /boot >/dev/null 2>&1 || true
  for f in /boot/loader/entries/"$P"-*.conf; do
    [[ -e "$f" ]] || { echo "No boot entries found in /boot/loader/entries"; return; }
    local name state; name="$(basename "$f" .conf)"
    case "$name" in
      *+0-*) state="BAD (failed to boot, skipped)" ;;
      *+*)   local c="${name##*+}"; state="new, ${c%%-*} boot tries left" ;;
      *)     state="good" ;;
    esac
    printf '  %-26s %s\n' "$(sed -n 's/^title *//p' "$f")" "$state"
  done
  df -h / /home 2>/dev/null | sed 's/^/  /'
}

CMD="${1:-}"; shift || true
case "$CMD" in
  install)  cmd_install "$@" ;;
  update)   cmd_update "$@" ;;
  rollback) cmd_rollback ;;
  status)   cmd_status ;;
  bless)    cmd_bless ;;
  -h|--help|help|"") usage 0 ;;
  *) usage 1 ;;
esac
NETLIVE_AB_EMBEDDED
  chmod 0755 config/includes.chroot_after_packages/usr/local/bin/netlive-ab
fi

# Direct .deb installs (dependencies resolved by apt).
if ((${#DEB_URLS[@]})); then
  debdir=config/includes.chroot_after_packages/usr/local/src/.netlive-debs
  mkdir -p "${debdir}"
  for d in "${DEB_URLS[@]}"; do
    if [[ "${d}" == http* ]]; then
      curl -fsSL "${d}" -o "${debdir}/$(basename "${d%%\?*}")" || { echo "Cannot download ${d}" >&2; exit 1; }
    else
      cp "$(dirname "${SELF}")/${d#./}" "${debdir}/" || { echo "Cannot find ${d}" >&2; exit 1; }
    fi
  done
  cat > config/hooks/normal/0060-local-debs.hook.chroot <<'EOF'
#!/bin/sh
set -e
DEBIAN_FRONTEND=noninteractive apt-get install -y /usr/local/src/.netlive-debs/*.deb
rm -rf /usr/local/src/.netlive-debs
apt-get clean
EOF
  chmod +x config/hooks/normal/0060-local-debs.hook.chroot
fi

# Hyprland from backports (-t raises backports priority for this install only).
if [[ "${DESKTOP}" == hyprland ]]; then
  bp=""; [[ "${DIST}" == trixie ]] && bp="-t trixie-backports"
  cat > config/hooks/normal/0070-hyprland.hook.chroot <<EOF
#!/bin/sh
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ${bp} hyprland
# Nice-to-haves: skipped quietly if not available in this suite.
for p in xdg-desktop-portal-hyprland hyprpaper hyprlock hypridle; do
  apt-get install -y ${bp} "\$p" || echo "note: \$p not available, skipped"
done
apt-get clean
EOF
  chmod +x config/hooks/normal/0070-hyprland.hook.chroot
fi

# Working Hyprland + waybar defaults for every new user (copied from /etc/skel
# when the user is created in the 0100 hook, which runs after includes).
if [[ "${DESKTOP}" == hyprland ]]; then
  skel=config/includes.chroot_after_packages/etc/skel/.config
  mkdir -p "${skel}/hypr" "${skel}/waybar"
  cat > "${skel}/hypr/hyprland.conf" <<'EOF'
# Baked by mkiso.sh — edit freely (~/.config/hypr/hyprland.conf), reload with Super+Shift+R.
monitor = , preferred, auto, 1

$mod      = SUPER
$terminal = kitty
$fallback = foot
$menu     = wofi --show drun

env = XCURSOR_SIZE,24
env = QT_QPA_PLATFORM,wayland;xcb
env = GDK_BACKEND,wayland,x11

exec-once = waybar
exec-once = nm-applet --indicator

input {
    kb_layout = us
    follow_mouse = 1
    touchpad {
        natural_scroll = false
    }
}

general {
    gaps_in = 4
    gaps_out = 8
    border_size = 2
    col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
    col.inactive_border = rgba(595959aa)
    layout = dwindle
}

decoration {
    rounding = 6
    blur {
        enabled = false   # cheap in VMs; enable on real GPUs
    }
}

animations {
    enabled = true
}

dwindle {
    pseudotile = true
    preserve_split = true
}

cursor {
    no_hardware_cursors = true   # fixes invisible/flickering cursor in QEMU
}

misc {
    force_default_wallpaper = 0
    disable_hyprland_logo = true
    background_color = rgb(1e1e2e)
}

xwayland {
    force_zero_scaling = true
}

ecosystem {
    no_update_news = true
    no_donation_nag = true
}

# --- keys ---------------------------------------------------------------
bind = $mod, RETURN, exec, $terminal
bind = $mod SHIFT, RETURN, exec, $fallback
bind = $mod, Q, exec, $terminal
bind = $mod, D, exec, $menu
bind = $mod, C, killactive,
bind = $mod, F, fullscreen,
bind = $mod, V, togglefloating,
bind = $mod, P, pseudo,
bind = $mod, J, togglesplit,
bind = $mod SHIFT, R, exec, hyprctl reload
bind = $mod SHIFT, E, exit,
bind = $mod SHIFT, I, exec, $terminal -e install-system   # graphical installer

bind = $mod, left,  movefocus, l
bind = $mod, right, movefocus, r
bind = $mod, up,    movefocus, u
bind = $mod, down,  movefocus, d

bind = $mod, 1, workspace, 1
bind = $mod, 2, workspace, 2
bind = $mod, 3, workspace, 3
bind = $mod, 4, workspace, 4
bind = $mod, 5, workspace, 5
bind = $mod SHIFT, 1, movetoworkspace, 1
bind = $mod SHIFT, 2, movetoworkspace, 2
bind = $mod SHIFT, 3, movetoworkspace, 3
bind = $mod SHIFT, 4, movetoworkspace, 4
bind = $mod SHIFT, 5, movetoworkspace, 5

bindm = $mod, mouse:272, movewindow
bindm = $mod, mouse:273, resizewindow
EOF

  cat > "${skel}/waybar/config.jsonc" <<'EOF'
{
  "layer": "top",
  "position": "top",
  "height": 26,
  "modules-left": ["hyprland/workspaces"],
  "modules-center": ["clock"],
  "modules-right": ["network", "cpu", "memory", "tray"],
  "clock": { "format": "{:%a %d %b  %H:%M}" },
  "network": {
    "format-ethernet": "{ifname} {ipaddr}",
    "format-wifi": "{essid} {ipaddr}",
    "format-disconnected": "offline"
  },
  "cpu": { "format": "cpu {usage}%" },
  "memory": { "format": "mem {percentage}%" },
  "tray": { "spacing": 6 }
}
EOF
fi

# Desktop auto-login: LightDM for xfce, tty1 + compositor for sway/hyprland.
if [[ "${DESKTOP}" != none && "${DESKTOP_AUTOLOGIN}" == true ]]; then
  cat > config/hooks/normal/0110-desktop-login.hook.chroot <<EOF
#!/bin/sh
set -e
if [ '${DESKTOP}' = xfce ]; then
  mkdir -p /etc/lightdm/lightdm.conf.d
  printf '[Seat:*]\nautologin-user=${USER_NAME}\nautologin-session=xfce\n' > /etc/lightdm/lightdm.conf.d/50-autologin.conf
else
  mkdir -p /etc/systemd/system/getty@tty1.service.d
  printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin ${USER_NAME} --noclear %%I \$TERM\n' \
    > /etc/systemd/system/getty@tty1.service.d/autologin.conf
  if [ '${DESKTOP}' = sway ]; then
    # Software rendering fallback so sway also starts inside VMs without GPU passthrough.
    start='export WLR_RENDERER_ALLOW_SOFTWARE=1 WLR_NO_HARDWARE_CURSORS=1; exec sway'
  else
    start='if command -v start-hyprland >/dev/null; then exec start-hyprland; else exec Hyprland; fi'
  fi
  {
    echo '[ -f ~/.profile ] && . ~/.profile   # keep Debian defaults (PATH, .bashrc)'
    echo 'if [ "\$(tty)" = /dev/tty1 ] && [ -z "\$WAYLAND_DISPLAY" ]; then'
    echo "  \$start"
    echo 'fi'
  } >> /home/${USER_NAME}/.bash_profile
  chown ${USER_NAME}:${USER_NAME} /home/${USER_NAME}/.bash_profile
fi
EOF
  chmod +x config/hooks/normal/0110-desktop-login.hook.chroot
fi

# Create the user at build time.
HASH="$(openssl passwd -6 "${USER_PASS}")"
cat > config/hooks/normal/0100-user.hook.chroot <<EOF
#!/bin/sh
set -e
echo '${HOST}' > /etc/hostname
id -u '${USER_NAME}' >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo '${USER_NAME}'
usermod -p '${HASH}' '${USER_NAME}'
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
EOF
chmod +x config/hooks/normal/0100-user.hook.chroot

# Exact Zig version, fetched via ziglang.org's release index and sha256-verified.
if [[ -n "${ZIG_VERSION}" ]]; then
  case "${ARCH}" in amd64) zarch=x86_64-linux ;; arm64) zarch=aarch64-linux ;; esac
  cat > config/hooks/normal/0280-zig.hook.chroot <<EOF
#!/bin/bash
set -euo pipefail
read -r url sum < <(curl -fsSL https://ziglang.org/download/index.json | python3 -c '
import json, sys
idx = json.load(sys.stdin)
rel = idx.get("${ZIG_VERSION}", {}).get("${zarch}")
if not rel:
    sys.exit("Zig ${ZIG_VERSION} for ${zarch} is not on ziglang.org/download (check ZIG_VERSION)")
print(rel["tarball"], rel["shasum"])')
curl -fsSL "\$url" -o /tmp/zig.tar.xz
echo "\$sum  /tmp/zig.tar.xz" | sha256sum -c -
rm -rf /opt/zig && mkdir -p /opt/zig
tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1
ln -sfn /opt/zig/zig /usr/local/bin/zig
rm -f /tmp/zig.tar.xz
echo "zig \$(/usr/local/bin/zig version) installed"
EOF
  chmod +x config/hooks/normal/0280-zig.hook.chroot
fi

# Source builds: stage manifest, build commands and local sources, then one
# generic hook fetches, builds and installs each entry to /usr/local.
if ((${#SOURCE_BUILDS[@]})); then
  stage=config/includes.chroot_after_packages/usr/local/src/.netlive-build
  mkdir -p "${stage}"
  : > "${stage}/builds.list"
  for b in "${SOURCE_BUILDS[@]}"; do
    IFS='|' read -r s_name s_src s_ref s_cmd <<< "${b}"
    [[ "${s_name}" =~ ^[A-Za-z0-9._-]+$ && -n "${s_src}" ]] \
      || { echo "Bad SOURCE_BUILDS entry (need name|source|ref|command): ${b}" >&2; exit 1; }
    if [[ "${s_src}" != *://* && "${s_src}" != git@* ]]; then
      local_dir="$(dirname "${SELF}")/${s_src#./}"
      [[ -d "${local_dir}" ]] || { echo "SOURCE_BUILDS ${s_name}: directory ${s_src} not found" >&2; exit 1; }
      mkdir -p "${stage}/${s_name}.local"
      cp -a "${local_dir}/." "${stage}/${s_name}.local/"
      s_src=local
    fi
    printf '%s|%s|%s\n' "${s_name}" "${s_src}" "${s_ref}" >> "${stage}/builds.list"
    printf '%s\n' "${s_cmd}" > "${stage}/${s_name}.cmd"
  done

  cat > config/hooks/normal/0300-source-builds.hook.chroot <<'EOF'
#!/bin/bash
set -euo pipefail
stage=/usr/local/src/.netlive-build
work=/usr/local/src/.netlive-work
export CARGO_HOME=/tmp/cargo GOPATH=/tmp/go GOCACHE=/tmp/go-cache DEBIAN_FRONTEND=noninteractive
export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache
# Toolchains installed earlier by brew (0200) or npm (0250) are usable here.
export PATH="/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:${PATH}"
jobs="$(nproc)"

autobuild() {
  if [ -f autogen.sh ] && [ ! -f configure ]; then sh ./autogen.sh; fi
  if [ -f configure ]; then
    ./configure --prefix=/usr/local && make -j"${jobs}" && make install
  elif [ -f CMakeLists.txt ]; then
    cmake -B _build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
    cmake --build _build -j"${jobs}" && cmake --install _build
  elif [ -f meson.build ]; then
    meson setup _build --prefix=/usr/local --buildtype=release && meson install -C _build
  elif [ -f Cargo.toml ]; then
    cargo install --locked --path . --root /usr/local
  elif [ -f go.mod ]; then
    GOBIN=/usr/local/bin go install ./...
  elif [ -f build.zig ]; then
    zig build -Doptimize=ReleaseSafe --prefix /usr/local
  elif [ -f Makefile ] || [ -f makefile ]; then
    make -j"${jobs}" && make install PREFIX=/usr/local
  else
    echo "netlive: cannot detect build system — set a build command" >&2; return 1
  fi
}

while IFS='|' read -r name src ref; do
  [ -n "${name}" ] || continue
  echo "==> source build: ${name} (${src}${ref:+ @ ${ref}})"
  dir="${work}/${name}"
  rm -rf "${dir}"; mkdir -p "${dir}"
  case "${src}" in
    local) cp -a "${stage}/${name}.local/." "${dir}/" ;;
    *.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.bz2|*.tbz2|*.tar.zst|*.tar)
      curl -fsSL "${src}" -o "${dir}.tar"
      tar -xaf "${dir}.tar" -C "${dir}" --strip-components=1
      rm -f "${dir}.tar" ;;
    *)
      git clone --recursive "${src}" "${dir}"
      if [ -n "${ref}" ]; then git -C "${dir}" checkout -q "${ref}" && git -C "${dir}" submodule update --init --recursive; fi ;;
  esac
  cmd="$(cat "${stage}/${name}.cmd")"
  if [ -n "${cmd}" ]; then (cd "${dir}" && bash -euo pipefail -c "${cmd}"); else (cd "${dir}" && autobuild); fi
  echo "==> ${name} installed"
done < "${stage}/builds.list"

rm -rf "${stage}" "${work}" /tmp/cargo /tmp/go /tmp/go-cache /tmp/zig-cache
ldconfig
EOF
  chmod +x config/hooks/normal/0300-source-builds.hook.chroot
fi

# npm global packages (each installed separately; failures are reported, not fatal).
if ((${#NPM_PACKAGES[@]})); then
  cat > config/hooks/normal/0250-npm.hook.chroot <<EOF
#!/bin/bash
set -uo pipefail
failed=()
for p in ${NPM_PACKAGES[*]}; do
  npm install -g --prefix /usr/local --no-fund --no-audit "\$p" || failed+=("\$p")
done
npm cache clean --force >/dev/null 2>&1 || true
rm -rf /root/.npm
if ((\${#failed[@]})); then echo "WARNING: npm could not install: \${failed[*]} — skipped" >&2; fi
exit 0
EOF
  chmod +x config/hooks/normal/0250-npm.hook.chroot
fi

# Install Homebrew + formulae as the default user (brew refuses to run as root).
if ((${#BREW_PACKAGES[@]})); then
  cat > config/hooks/normal/0200-brew.hook.chroot <<EOF
#!/bin/bash
set -euo pipefail
U='${USER_NAME}'
P=/home/linuxbrew/.linuxbrew
B=(runuser -u "\$U" -- env HOME="/home/\$U" HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1)
mkdir -p "\$P/bin"
[ -d "\$P/Homebrew/.git" ] || git clone https://github.com/Homebrew/brew "\$P/Homebrew"
ln -sfn ../Homebrew/bin/brew "\$P/bin/brew"
chown -R "\$U:\$U" /home/linuxbrew
failed=()
for f in ${BREW_PACKAGES[*]}; do
  "\${B[@]}" "\$P/bin/brew" install "\$f" || failed+=("\$f")
done
"\${B[@]}" "\$P/bin/brew" cleanup --prune=all -s
rm -rf "/home/\$U/.cache/Homebrew"
echo 'eval "\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' > /etc/profile.d/brew.sh
if ((\${#failed[@]})); then
  echo "WARNING: brew could not install: \${failed[*]} (macOS-only casks or no Linux build) — skipped" >&2
fi
EOF
  chmod +x config/hooks/normal/0200-brew.hook.chroot
fi

lb build 2>&1 | tee build.log

ISO="${NAME}-${ARCH}.hybrid.iso"
[[ -f "${ISO}" ]] || { echo "Build failed — see ${WORK}/build.log" >&2; exit 1; }
if [[ "${AB_INSTALLER}" == true ]]; then
  [[ -x chroot/usr/local/bin/netlive-ab ]] || { echo "Build problem: netlive-ab is missing from the image" >&2; exit 1; }
  echo "Verified: netlive-ab is inside the image (run: sudo netlive-ab install)"
fi
OUT="${NAME}-$(date +%Y%m%d)-${ARCH}.iso"
mv "${ISO}" "../${OUT}"
cd .. && sha256sum "${OUT}" > "${OUT}.sha256"
echo "Done: ${OUT}"
