#!/usr/bin/env bash
#
# Idempotent, fail-safe Btrfs volume management for Debian (existing Btrfs only).
# No mkfs/format/wipe paths — verifies TYPE=btrfs before any destructive operation.
#
# apt install btrfs-progs util-linux coreutils mount e2fsprogs
#   For ensure-full-stack also: grub-common grub-pc OR grub-efi, initramfs-tools
#
# Examples:
#   sudo ./btrfs-setup-debian13.sh ensure \
#     --uuid ab12cd34-.... \
#     --mountpoint /mnt/data \
#     --ssd
#
#   sudo ./btrfs-setup-debian13.sh ensure \
#     --device /dev/nvme0n1p3 \
#     --mountpoint /mnt/sys \
#     --mount-subvol @ \
#     --ensure-subvolumes "@,@home" \
#     --write-fstab
#
#   sudo ./btrfs-setup-debian13.sh status --mountpoint /mnt/data
#
# Discover current root disk, ensure @ /@home /@var /@log then mount (/ /home /var /var/log):
#   sudo ./btrfs-setup-debian13.sh ensure-os-layout --write-fstab --ssd-auto
#
# Detect firmware (EFI vs BIOS) and print matching grub-install hints:
#   ./btrfs-setup-debian13.sh detect-boot
#
# Btrfs @ /@home/@var/@log plus ext4 /boot (and ESP on UEFI): layout, fstab, grub cmdline, initramfs, grub-install:
#   sudo ./btrfs-setup-debian13.sh ensure-full-stack --ssd-auto
#
set -euo pipefail

readonly ME="${0##*/}"
DRY_RUN=0
WRITE_FSTAB=0
SSD=0
SSD_AUTO=0
ACCEPT_NONNULL_MOUNTS_CLI=0 # ensure-mount optional override
RELAX_ROOT_MOUNT_VERIFY=0
OS_ACCEPT_NONEMPTY=1
STRICT_MOUNTPOINT_LAYOUT=0
NOCOW_VARLOG_CLI=0         # ensure / ensure-subvolumes: apply chattr +C on @var,@log roots
SKIP_NOCOW_VARLOG_LAYOUT=0 # ensure-os-layout: do not touch CoW (+C vs default behaviour)
DEFAULT_OS_LAYOUT_RAW='@:/,@home:/home,@var:/var,@log:/var/log'
LAYOUT_SPEC_RAW=""

UUID="" # lowercase, no UUID= prefix
DEVICE=""
MOUNTPOINT=""
# Default mount opts (subvol appended separately):
MOUNT_OPTIONS=""
MOUNT_SUBVOL="" # btrfs option subvol=name (omit = filesystem default subvolume)
ENSURE_SUBVOLUMES_RAW="" # comma-separated top-level subvolume names
SKIP_BOOTLOADER_STACK=0 # ensure-full-stack: omit grub.d snippet, initramfs, update-grub, grub-install
SOURCE_CMD="ensure" # ensure|ensure-os-layout|ensure-full-stack|status|ensure-mount|ensure-subvolumes|ensure-fstab|detect-boot

readonly GRUB_SUBVOL_SNIPPET=/etc/default/grub.d/50-btrfs-setup-debian13-rootflags.cfg

STAGING_MOUNT="" # allocated in ensure_* with cleanup trap

die() { echo "$ME: error: $*" >&2; exit 1; }
log() { echo "$ME: $*"; }

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "run as root (sudo)"
}

have() { command -v "$1" >/dev/null 2>&1; }

ensure_deps_rw() {
  have btrfs || die "install btrfs-progs (btrfs CLI missing)"
  have mount || die "mount not found"
  have blkid || die "install util-linux (blkid)"
  have findmnt || die "install util-linux (findmnt)"
  have lsblk || die "install util-linux (lsblk)"
}

cleanup_staging() {
  [[ -z "${STAGING_MOUNT}" ]] && return 0
  if findmnt "${STAGING_MOUNT}" >/dev/null 2>&1; then
    run umount "${STAGING_MOUNT}" || die "failed to umount staging ${STAGING_MOUNT}"
  fi
  if [[ -n "${STAGING_MOUNT}" ]] && [[ -d "${STAGING_MOUNT}" ]]; then
    rmdir "${STAGING_MOUNT}" 2>/dev/null || true
  fi
}

validate_cross_command_flags_or_die() {
  local cmd="$1"

  case "${cmd}" in
    detect-boot)
      return 0
      ;;
    ensure-os-layout|ensure-full-stack)
      if [[ "${STRICT_MOUNTPOINT_LAYOUT}" -eq 1 ]]; then
        OS_ACCEPT_NONEMPTY=0
      fi
      [[ "${SKIP_NOCOW_VARLOG_LAYOUT}" -eq 1 ]] && [[ "${NOCOW_VARLOG_CLI}" -eq 1 ]] \
        && die "do not combine --nocow-var-log with --skip-nocow-var-log"
      return 0
      ;;
  esac

  [[ "${SKIP_BOOTLOADER_STACK}" -eq 1 ]] && [[ "${cmd}" != ensure-full-stack ]] \
    && die "--skip-bootloader is only valid with ensure-full-stack"

  [[ -z "${LAYOUT_SPEC_RAW}" ]] \
    || [[ "${cmd}" == ensure-os-layout || "${cmd}" == ensure-full-stack ]] \
    || die "--layout is only valid with ensure-os-layout or ensure-full-stack"
  [[ "${SSD_AUTO}" -eq 1 ]] \
    && [[ "${cmd}" != ensure-os-layout && "${cmd}" != ensure-full-stack ]] \
    && die "--ssd-auto is only valid with ensure-os-layout or ensure-full-stack"
  [[ "${RELAX_ROOT_MOUNT_VERIFY}" -eq 1 ]] \
    && [[ "${cmd}" != ensure-os-layout && "${cmd}" != ensure-full-stack ]] \
    && die "--relax-root-mount-verify is only valid with ensure-os-layout or ensure-full-stack"
  [[ "${STRICT_MOUNTPOINT_LAYOUT}" -eq 1 ]] \
    && [[ "${cmd}" != ensure-os-layout && "${cmd}" != ensure-full-stack ]] \
    && die "--strict-empty-mountpoints is only valid with ensure-os-layout or ensure-full-stack"
  [[ "${SKIP_NOCOW_VARLOG_LAYOUT}" -eq 1 ]] \
    && [[ "${cmd}" != ensure-os-layout && "${cmd}" != ensure-full-stack ]] \
    && die "--skip-nocow-var-log is only supported with ensure-os-layout or ensure-full-stack"
  [[ "${SKIP_NOCOW_VARLOG_LAYOUT}" -eq 1 ]] && [[ "${NOCOW_VARLOG_CLI}" -eq 1 ]] \
    && die "use only one of --nocow-var-log / --skip-nocow-var-log"
  [[ "${NOCOW_VARLOG_CLI}" -eq 1 ]] && [[ "${cmd}" != ensure && "${cmd}" != ensure-subvolumes ]] \
    && die "--nocow-var-log is only supported with ensure or ensure-subvolumes"
}

usage() {
  cat <<EOF
Manage existing Btrfs volumes (no formatting). Commands are intended to be idempotent.

Commands:
  ensure              Resolve device, optionally create top-level subvolumes, mount, fstab line
  ensure-os-layout   Discover BTRFS from '/', ensure @,@home,@var,@log then mount (/ … /var/log)
  status              Show filesystem usage + subvolume list (requires reachable mount or temp mount)
  ensure-mount        Ensure mountpoint is mounted correctly (requires --uuid or --device)
  ensure-subvolumes   Ensure top-level subvolumes exist (staging mount at fs root)
  ensure-fstab        Ensure /etc/fstab has a compatible line for this UUID + mountpoint
  ensure-full-stack   ensure-os-layout (always writes btrfs fstab) + ext4 /boot [/boot/efi] + grub + initramfs
  detect-boot         Print whether this session booted via UEFI or legacy BIOS + grub-install hints

Options:
  --uuid UUID              Filesystem UUID (no UUID= prefix)
  --device DEV             Partition or member disk (validated as btrfs via blkid)
  --mountpoint PATH        Target directory (dirs created automatically)
  --mount-options OPTS      Comma-separated options (defaults below if omitted)
  --ssd                    Expand defaults with ssd,discard=async
  --mount-subvol NAME       Add subvol=NAME into mount opts (omit for default subvolume)
  --ensure-subvolumes CSV   Top-level subs to ensure (e.g. @,@home), via staging fs-root mount
  --write-fstab            Append fstab ONLY if no conflicting line exists; skip if duplicate ok
  --dry-run                Print intended actions/commands
  --ssd-auto               With ensure-os-layout: if / is ROTATIONAL=0, add ssd,discard=async
  --layout CSV             Override subvol→path pairs (see below)
  --strict-empty-mountpoints  ensure-os-layout: refuse non-empty dirs on /home /var /var/log
  --relax-root-mount-verify   Do not insist / matches subvol=@ + derived options exactly
  --accept-nonempty-mounts    ensure-mount: allow masking a non-empty mount directory (risky)
  --nocow-var-log             After @var,@log subs exist or are created set chattr +C (ensure / ensure-subvolumes)
  --skip-nocow-var-log        ensure-os-layout / ensure-full-stack: skip chattr +C on @var and @log
  --skip-bootloader           ensure-full-stack only: btrfs layout + fstab only (no grub.d / initramfs / grub-install)

ensure-os-layout:
  Defaults --layout to '${DEFAULT_OS_LAYOUT_RAW}' (mount order respects / before /home /var before /var/log).
  Reads filesystem UUID from the live root mount /. Use --uuid or --device to override discovery.
  By default applies chattr +C on '@var' and '@log' tops (nocow/new data avoids CoW, better for databases/logs).
  Only names '@var' and '@log' receive +C; customise mount names in --layout → set +C yourself if needed.
  By default allows non-empty /home,/var,/var/log overlays; use --strict-empty-mountpoints to refuse instead.

ensure-full-stack:
  Requires '/' btrfs, separate '/boot' ext3/ext4 (kernels not on btrfs). If this session booted with UEFI,
  '/boot/efi' must be mounted vfat.
  Runs the default layout (@, @home, @var, @log), appends btrfs + /boot (+ ESP) fstab lines, writes
  ${GRUB_SUBVOL_SNIPPET} so GRUB_CMDLINE_LINUX gains rootflags=subvol=@,... from live '/', then
  update-initramfs -u -k all, update-grub, and grub-install (EFI vs BIOS detected like detect-boot).

detect-boot:
  Reports BOOT_FIRMWARE=uefi|bios from the running kernel (/sys/firmware/efi).
  Prints example grub-install for separate /boot: UEFI uses --efi-directory=/boot/efi; BIOS uses the whole disk
  hosting /boot (or / if /boot is not a mountpoint). Does not modify the system.

Defaults for --mount-options when omitted:
  defaults,noatime,compress=zstd:3[,ssd,discard=async if --ssd]

Typical @ layout (create subvolume then mount it):
  $ME ensure --uuid ... --mountpoint /mnt/sys --mount-subvol @ \\
    --ensure-subvolumes @ --write-fstab --ssd

Fail-safes:
  - Abort if blkid FS type for resolved device != btrfs.
  - Refuse non-empty mount directories before first overlay (unless ensure-os-layout default, ensure-mount --accept-nonempty-mounts).
  - Refuse if mountpoint busy with wrong UUID or btrfs options vs desired (--relax-root-mount-verify relaxes checks only for the '/' step).
  - Refuse inconsistent /etc/fstab duplicates for the same mountpoint.
EOF
}

run() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    local a
    printf '+ '
    for a in "$@"; do
      printf '%q ' "$a"
    done
    printf '\n'
    return 0
  fi
  "$@"
}

lc_uuid() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

normalize_mount_opts_list() {
  printf '%s' "$1" | tr ',' '\n' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d' \
    | LC_ALL=C sort \
    | paste -sd, -
}

# Options the kernel lists but that are redundant or irrelevant when comparing our fstab/remount
# string to findmnt(8) output (avoids false "mismatch" on /).
canonicalize_btrfs_opts_for_compare() {
  printf '%s' "$1" | tr ',' '\n' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d' \
    | grep -Ev '^(seclabel|rw|defaults)$' \
    | grep -Ev '^subvolid=' \
    | LC_ALL=C sort \
    | paste -sd, -
}

default_mount_opts() {
  local mo="defaults,noatime,compress=zstd:3"
  [[ "${SSD}" -eq 1 ]] && mo+=",ssd,discard=async"
  printf '%s' "$mo"
}

compose_mount_opts() {
  local base="$1"
  local sub="$2"
  if [[ -n "${sub}" ]]; then
    if [[ "${base}" == *"subvol="* ]]; then
      die "--mount-options already contains subvol=; conflict with --mount-subvol"
    fi
    base+=",subvol=${sub}"
  fi
  printf '%s' "${base}"
}

resolve_dev_from_uuid_or_die() {
  local uuid_l
  uuid_l="$(lc_uuid "$1")"
  local dev
  dev="$(blkid -U "${uuid_l}" 2>/dev/null || true)"
  [[ -n "${dev}" ]] || die "no block device carries UUID ${uuid_l} (kernel/blkid unreachable?)"
  [[ -b "${dev}" ]] || die "blkid mapped UUID ${uuid_l} to non-block ${dev}"
  printf '%s\n' "${dev}"
}

filesystem_uuid_from_device() {
  local dev="$1"
  local uuid_raw
  uuid_raw="$(blkid -p -u filesystem -o value -s UUID "${dev}" 2>/dev/null \
    || blkid -p -o value -s UUID "${dev}" 2>/dev/null \
    || true)"
  [[ -n "${uuid_raw}" ]] || die "cannot read filesystem UUID from ${dev}"
  lc_uuid "${uuid_raw}"
}

require_btrfs_on_device_or_die() {
  local dev="$1"
  local typ
  typ="$(blkid -p -o value -s TYPE "${dev}" 2>/dev/null || true)"
  [[ "${typ}" == "btrfs" ]] || die "${dev}: expected TYPE=btrfs, got '${typ}'"
}

mutually_resolve_uuid_dev() {
  if [[ -n "${UUID}" && -n "${DEVICE}" ]]; then
    die "use only one of --uuid / --device"
  fi

  local dev="" uuid_l=""
  if [[ -n "${UUID}" ]]; then
    uuid_l="$(lc_uuid "${UUID}")"
    dev="$(resolve_dev_from_uuid_or_die "${uuid_l}")"
    require_btrfs_on_device_or_die "${dev}"
    local seen
    seen="$(filesystem_uuid_from_device "${dev}")"
    [[ "${seen}" == "${uuid_l}" ]] || die "resolved device mismatch (blkid mismatch bug?)"
    printf '%s|%s\n' "${uuid_l}" "${dev}"
    return 0
  fi

  if [[ -n "${DEVICE}" ]]; then
    [[ -b "${DEVICE}" ]] || die "not a block device: ${DEVICE}"
    require_btrfs_on_device_or_die "${DEVICE}"
    uuid_l="$(filesystem_uuid_from_device "${DEVICE}")"
    printf '%s|%s\n' "${uuid_l}" "${DEVICE}"
    return 0
  fi

  die "provide --uuid or --device"
}

strip_btrfs_vol_anchor_opts() {
  printf '%s' "$1" \
    | tr ',' '\n' \
    | sed '/^$/d' \
    | grep -Ev '^(subvol|subvolid)=' \
    | LC_ALL=C sort \
    | paste -sd,
}

infer_rotational_disk_from_fs_source_maybe() {
  local src="$1" dev=""
  [[ -z "${src}" ]] && return 1

  if [[ "${src}" == UUID=* ]]; then
    dev="$(blkid -U "$(lc_uuid "${src#UUID=}")" 2>/dev/null || true)"
  elif [[ "${src}" == /dev/* ]]; then
    dev="$(readlink -f "${src}")"
  else
    return 1
  fi

  [[ -b "${dev:-}" ]] || return 1
  lsblk --nodeps -n -ro ROTA "${dev}" 2>/dev/null | grep -Fxq '0'
}

discover_live_root_btrfs_uuid_or_die() {
  local fst=""
  fst="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
  [[ "${fst}" == btrfs ]] || die "'/' is fstype '${fst}', not btrfs (cannot auto-discover layout)"

  local raw=""
  raw="$(findmnt -n -o UUID / 2>/dev/null || true)"
  [[ -n "${raw}" ]] || die "'/' btrfs mount lacks a UUID (unexpected)"
  lc_uuid "${raw}"
}

declare -gA _LAYOUT_SUB_BY_MP

declare -ga _LAYOUT_MPS_SORTED

parse_layout_into_sorted_arrays_or_die() {
  local raw="$1"

  unset _LAYOUT_SUB_BY_MP
  unset _LAYOUT_MPS_SORTED
  declare -gA _LAYOUT_SUB_BY_MP
  declare -ga _LAYOUT_MPS_SORTED

  local -a chunks=()
  local chunk sub mp_rest mp

  IFS=',' read -r -a chunks <<<"${raw}"

  [[ "${#chunks[@]}" -gt 0 ]] || die "--layout produced no pairs"

  for chunk in "${chunks[@]}"; do
    chunk="$(printf '%s' "${chunk}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "${chunk}" ]] || continue
    printf '%s' "${chunk}" | grep -q ':' \
      || die "invalid layout token '${chunk}' (expected subvolume:mountpoint)"

    sub="${chunk%%:*}"
    mp_rest="${chunk#*:}"
    [[ -n "${sub}" ]] || die "empty subvolume in '${chunk}'"

    mp="${mp_rest}"
    [[ -n "${mp}" ]] || mp=/
    [[ "${mp}" == /* ]] || die "mountpoint '${mp}' must be absolute"

    [[ ! -v "_LAYOUT_SUB_BY_MP[$mp]" ]] \
      || die "duplicate layout path '${mp}'"

    _LAYOUT_SUB_BY_MP["${mp}"]="${sub}"
  done

  mapfile -t _LAYOUT_MPS_SORTED < <(
    for k in "${!_LAYOUT_SUB_BY_MP[@]}"; do
      printf '%s\n' "${k}"
    done | LC_ALL=C sort -u
  )

  [[ "${#_LAYOUT_MPS_SORTED[@]}" -gt 0 ]] || die "internal: empty layout targets"
}

layout_unique_subvolume_csv() {
  printf '%s\n' "${_LAYOUT_SUB_BY_MP[@]}" | LC_ALL=C sort -u | paste -sd,
}

mount_source_spec() {
  local uuid="$1"
  printf 'UUID=%s' "${uuid}"
}

mount_nonempty_dir_conflict() {
  local mp="$1"
  [[ -d "${mp}" ]] || return 1
  shopt -s nullglob dotglob
  local entries=( "${mp}"/* )
  shopt -u nullglob dotglob
  [[ ${#entries[@]} -eq 0 ]] && return 1
  for e in "${entries[@]}"; do
    local base="${e##*/}"
    [[ "${base}" == lost+found ]] && continue
    return 0
  done
  return 1
}

_fstab_pick_record_fields_or_die() {
  local uuid="$1" mnt="$2" want_opts_full="$3"
  [[ -f /etc/fstab ]] || die "/etc/fstab missing"

  local -a lines
  mapfile -t lines < <(awk -v m="$mnt" '!/^#/ && NF >= 6 && $2 == m {
      print $1 "\t" $3 "\t" $4
    }' /etc/fstab)

  [[ "${#lines[@]}" -eq 0 ]] && return 2
  [[ "${#lines[@]}" -eq 1 ]] \
    || die "fstab: multiple entries declare mountpoint '${mnt}' — fix manually (${#lines[@]} hits)"

  IFS=$'\t' read -r fstab_src fstype fstab_opts <<<"${lines[0]}"
  [[ -n "${fstab_src}" && -n "${fstype}" && -n "${fstab_opts}" ]] \
    || die "fstab: failed to parse existing line for '${mnt}'"

  local want_field wanted_n got_n

  [[ "${fstype}" == btrfs ]] \
    || die "fstab: ${mnt} is '${fstype}' in fstab — expected btrfs"

  want_field="$(mount_source_spec "${uuid}")"

  [[ "${fstab_src}" == "${want_field}" ]] \
    || die "fstab: ${mnt} uses source '${fstab_src}', wanted '${want_field}'"

  wanted_n="$(normalize_mount_opts_list "${want_opts_full}")"
  got_n="$(normalize_mount_opts_list "${fstab_opts}")"

  [[ "${got_n}" == "${wanted_n}" ]] \
    || die "fstab: ${mnt} options differ from desired (normalized compare)
  fstab: ${fstab_opts}
  wanted: ${want_opts_full}"

  return 0
}

fstab_conflict_check_or_die() {
  local uuid="$1" mnt="$2" want_opts_full="$3"

  if _fstab_pick_record_fields_or_die "${uuid}" "${mnt}" "${want_opts_full}"; then
    return 0
  fi

  local rc=$?

  [[ "${rc}" -eq 2 ]] && return 0
  die "fstab_conflict_check_or_die: unexpected rc=${rc}"
}

fstab_already_ok() {
  local uuid="$1" mnt="$2" want_opts_full="$3"

  if _fstab_pick_record_fields_or_die "${uuid}" "${mnt}" "${want_opts_full}"; then
    return 0
  fi

  local rc=$?

  [[ "${rc}" -eq 2 ]] && return 1
  die "fstab_already_ok: unexpected rc=${rc}"
}

fstab_append_idempotent_or_die() {
  local uuid="$1" mnt="$2" opts="$3"

  fstab_already_ok "${uuid}" "${mnt}" "${opts}" && { log "fstab entry already satisfies ${mnt}"; return 0; }

  fstab_conflict_check_or_die "${uuid}" "${mnt}" "${opts}"

  local line="UUID=${uuid} ${mnt} btrfs ${opts} 0 0"
  local bak="/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    run cp -a /etc/fstab "${bak}"
    log "would append to /etc/fstab:"
    printf '%s\n' "${line}"
    return 0
  fi

  cp -a /etc/fstab "${bak}"
  log "fstab backed up to ${bak}"
  printf '%s\n' "${line}" >> /etc/fstab
  log "fstab appended: ${line}"
}

_fstab_pick_generic_record_fields_or_die() {
  local mnt="$1" want_src="$2" want_fstype="$3" want_opts_full="$4"
  [[ -f /etc/fstab ]] || die "/etc/fstab missing"

  local -a lines
  mapfile -t lines < <(awk -v m="$mnt" '!/^#/ && NF >= 6 && $2 == m {
      print $1 "\t" $3 "\t" $4
    }' /etc/fstab)

  [[ "${#lines[@]}" -eq 0 ]] && return 2
  [[ "${#lines[@]}" -eq 1 ]] \
    || die "fstab: multiple entries declare mountpoint '${mnt}' — fix manually (${#lines[@]} hits)"

  IFS=$'\t' read -r fstab_src fstype fstab_opts <<<"${lines[0]}"
  [[ -n "${fstab_src}" && -n "${fstype}" && -n "${fstab_opts}" ]] \
    || die "fstab: failed to parse existing line for '${mnt}'"

  [[ "${fstype}" == "${want_fstype}" ]] \
    || die "fstab: ${mnt} is type '${fstype}' in fstab — expected '${want_fstype}'"

  [[ "${fstab_src}" == "${want_src}" ]] \
    || die "fstab: ${mnt} uses source '${fstab_src}', wanted '${want_src}'"

  local wanted_n got_n
  wanted_n="$(normalize_mount_opts_list "${want_opts_full}")"
  got_n="$(normalize_mount_opts_list "${fstab_opts}")"

  [[ "${got_n}" == "${wanted_n}" ]] \
    || die "fstab: ${mnt} options differ from desired (normalized compare)
  fstab: ${fstab_opts}
  wanted: ${want_opts_full}"

  return 0
}

_fstab_generic_conflict_resolved_or_die() {
  local uuid_lc="$1" mnt="$2" fstype="$3" want_opts="$4"
  local want_src="UUID=${uuid_lc}"

  if _fstab_pick_generic_record_fields_or_die "${mnt}" "${want_src}" "${fstype}" "${want_opts}"; then
    return 0
  fi
  local rc=$?
  [[ "${rc}" -eq 2 ]] && return 0
  die "_fstab_generic_conflict_resolved_or_die: unexpected rc=${rc}"
}

fstab_generic_already_ok() {
  local uuid_lc="$1" mnt="$2" fstype="$3" want_opts="$4"
  local want_src="UUID=${uuid_lc}"
  if _fstab_pick_generic_record_fields_or_die "${mnt}" "${want_src}" "${fstype}" "${want_opts}"; then
    return 0
  fi
  local rc=$?
  [[ "${rc}" -eq 2 ]] && return 1
  die "fstab_generic_already_ok: unexpected rc=${rc}"
}

fstab_append_generic_idempotent_or_die() {
  local uuid_lc="$1" mnt="$2" fstype="$3" opts="$4" dump_pass="$5" fsck_pass="$6"
  uuid_lc="$(lc_uuid "${uuid_lc}")"

  fstab_generic_already_ok "${uuid_lc}" "${mnt}" "${fstype}" "${opts}" \
    && { log "fstab entry already satisfies ${mnt}"; return 0; }

  _fstab_generic_conflict_resolved_or_die "${uuid_lc}" "${mnt}" "${fstype}" "${opts}"

  local line="UUID=${uuid_lc} ${mnt} ${fstype} ${opts} ${dump_pass} ${fsck_pass}"
  local bak="/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    run cp -a /etc/fstab "${bak}"
    log "would append to /etc/fstab:"
    printf '%s\n' "${line}"
    return 0
  fi

  cp -a /etc/fstab "${bak}"
  log "fstab backed up to ${bak}"
  printf '%s\n' "${line}" >> /etc/fstab
  log "fstab appended: ${line}"
}

fstab_sync_live_mount_or_die() {
  local mp="$1" dump_pass="$2" fsck_pass="$3"
  local uuid fst opts
  uuid="$(findmnt -n -o UUID "${mp}" 2>/dev/null || true)"
  fst="$(findmnt -n -o FSTYPE "${mp}" 2>/dev/null || true)"
  opts="$(findmnt -n -o OPTIONS "${mp}" 2>/dev/null || true)"
  [[ -n "${uuid}" && -n "${fst}" ]] || die "${mp}: cannot read UUID/FSTYPE from findmnt"
  opts="$(normalize_mount_opts_list "${opts}")"
  fstab_append_generic_idempotent_or_die "${uuid}" "${mp}" "${fst}" "${opts}" "${dump_pass}" "${fsck_pass}"
}

verify_btrfs_mount_uuid_or_die() {
  local uuid="$1" mp="$2"
  local cur_fst cur_uid cur_uid_lc

  cur_fst="$(findmnt -n -o FSTYPE "${mp}" 2>/dev/null || true)"
  [[ -n "${cur_fst}" ]] || die "${mp}: not mounted (expected btrfs)"
  [[ "${cur_fst}" == btrfs ]] || die "${mp}: mounted as ${cur_fst}"

  cur_uid="$(findmnt -n -o UUID "${mp}" || true)"
  [[ -z "${cur_uid}" ]] && die "${mp}: findmnt UUID empty"
  cur_uid_lc="$(lc_uuid "${cur_uid}")"
  [[ "${cur_uid_lc}" == "${uuid}" ]] \
    || die "${mp}: btrfs UUID mismatch (mounted ${cur_uid_lc}, wanted ${uuid})"
}

btrfs_mount_options_match_p() {
  local mp="$1" want_opts_full="$2"
  local cur_opts got want
  cur_opts="$(findmnt -n -o OPTIONS "${mp}" 2>/dev/null || true)"
  [[ -n "${cur_opts}" ]] || return 1
  got="$(canonicalize_btrfs_opts_for_compare "${cur_opts}")"
  want="$(canonicalize_btrfs_opts_for_compare "${want_opts_full}")"
  [[ "${got}" == "${want}" ]]
}

verify_mount_correct_or_die() {
  local uuid="$1" mp="$2" want_opts_full="$3"

  verify_btrfs_mount_uuid_or_die "${uuid}" "${mp}"

  local cur_opts got wanted
  cur_opts="$(findmnt -n -o OPTIONS "${mp}" || die "${mp}: findmnt OPTIONS empty")"
  got="$(canonicalize_btrfs_opts_for_compare "${cur_opts}")"
  wanted="$(canonicalize_btrfs_opts_for_compare "${want_opts_full}")"

  [[ "${got}" == "${wanted}" ]] \
    || die "${mp}: mount options mismatch (normalized)
  mounted: ${cur_opts}
  desired: ${want_opts_full}"
}

staging_prepare_or_die() {
  local uuid="$1"
  need_root

  export STAGING_MOUNT
  STAGING_MOUNT="$(mktemp -d /run/user/0/"${ME}".XXXXXX 2>/dev/null || mktemp -d /tmp/"${ME}".XXXXXX)"

  trap cleanup_staging EXIT

  local spec
  spec="$(mount_source_spec "${uuid}")"

  local msg="staging mount ${spec} at ${STAGING_MOUNT} with rw,subvol=/"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    run mkdir -p "${STAGING_MOUNT}"
    run mount -t btrfs -o defaults,subvol=/ "${spec}" "${STAGING_MOUNT}"
    log "dry-run staging: (${msg}); subvolume existence checks may be inaccurate without a real mount"
    return 0
  fi

  if ! run mount -t btrfs -o defaults,subvol=/ "${spec}" "${STAGING_MOUNT}"; then
    die "failed staging mount (${msg}). Is ${spec} btrfs and available?"
  fi
}

staging_rw_remount_if_needed_or_die() {
  [[ "${DRY_RUN}" -eq 1 ]] && return 0

  local ro
  ro="$(findmnt -n -o OPTIONS "${STAGING_MOUNT}" | tr ',' '\n' | grep -c '^ro$' || true)"
  if [[ "${ro}" -gt 0 ]]; then
    run mount -o remount,rw "${STAGING_MOUNT}" || die "could not rw remount staging"
  fi
}

path_is_btrfs_subvolume() {
  local staging="$1" name="$2"
  local rel="${name#/}"

  btrfs subvolume show "${staging}/${rel}" >/dev/null 2>&1
}

dir_has_linux_nocow_attr() {
  local d="$1" attrs=""
  attrs="$(lsattr -d "${d}" 2>/dev/null | awk '{print $1}' || true)"
  [[ "$attrs" == *C* ]]
}

maybe_chattr_plus_C_on_top_level_sv() {
  local sv="$1" nocow_mode="$2" target=""

  [[ "${nocow_mode}" == varlog ]] || return 0
  [[ "${sv}" == @var || "${sv}" == @log ]] || return 0

  target="${STAGING_MOUNT}/${sv}"
  have chattr || die "install e2fsprogs (chattr missing); needed for --nocow-var-log / ensure-os-layout CoW tweak"
  have lsattr || die "install e2fsprogs (lsattr missing)"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    run chattr +C "${target}"
    return 0
  fi

  [[ -d "${target}" ]] || die "internal: expected directory ${target} before chattr +C"

  if dir_has_linux_nocow_attr "${target}"; then
    log "nocow: ${sv} root already has +C (CoW off for new data under this tree)"
    return 0
  fi

  log "nocow: chattr +C on ${target} (disables CoW for new files; existing extents unchanged)"
  run chattr +C "${target}"
}

ensure_top_level_subvolumes_via_staging() {
  local uuid="$1"
  local nocow_mode="${2:-none}"

  staging_prepare_or_die "${uuid}"
  staging_rw_remount_if_needed_or_die

  IFS=',' read -r -a subs <<< "$(printf '%s' "${ENSURE_SUBVOLUMES_RAW}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ ${#subs[@]} -ge 1 ]] || return 0

  local sv
  for sv in "${subs[@]}"; do
    sv="$(printf '%s' "${sv}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "${sv}" ]] || continue
    [[ "${sv}" != /* ]] || die "--ensure-subvolumes expects top-level names (no slashes): '${sv}'"

    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "+ btrfs subvolume show '${STAGING_MOUNT}/${sv}' || btrfs subvolume create '${STAGING_MOUNT}/${sv}'"
      maybe_chattr_plus_C_on_top_level_sv "${sv}" "${nocow_mode}"
      continue
    fi

    if path_is_btrfs_subvolume "${STAGING_MOUNT}" "${sv}"; then
      log "subvolume '${sv}' already exists"
    elif [[ -e "${STAGING_MOUNT}/${sv}" ]]; then
      die "path '${sv}' exists on fs root but is not a btrfs subvolume — refusing to overwrite"
    else
      log "creating subvolume '${sv}'"
      run btrfs subvolume create "${STAGING_MOUNT}/${sv}"
    fi

    maybe_chattr_plus_C_on_top_level_sv "${sv}" "${nocow_mode}"
  done
}

normalize_input_flags() {
  if [[ -z "${MOUNT_OPTIONS}" ]]; then
    MOUNT_OPTIONS="$(default_mount_opts)"
  else
    if [[ "${SSD}" -eq 1 ]] && [[ "${MOUNT_OPTIONS}" != *discard=async* ]]; then
      MOUNT_OPTIONS+=",ssd,discard=async"
    fi
  fi
}

ensure_mount_operation() {
  local uuid="$1" mp="$2" opts_full="$3"
  local accept_nonempty="${4:-0}"

  need_root

  local cur_fst cur_uid cur_uid_lc
  if findmnt "${mp}" >/dev/null 2>&1; then
    verify_btrfs_mount_uuid_or_die "${uuid}" "${mp}"

    if btrfs_mount_options_match_p "${mp}" "${opts_full}"; then
      log "already mounted OK: $(mount_source_spec "${uuid}") -> ${mp}"
      return 0
    fi

    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "dry-run: would remount ${mp} with btrfs options: ${opts_full}"
      return 0
    fi

    log "${mp}: remounting to apply desired btrfs options"
    run mount -o "remount,${opts_full}" "${mp}" \
      || die "remount failed for ${mp} (check dmesg; for '/' during subvol migration try --relax-root-mount-verify)"
    verify_mount_correct_or_die "${uuid}" "${mp}" "${opts_full}"
    log "remounted OK: $(mount_source_spec "${uuid}") -> ${mp}"
    return 0
  fi

  [[ -e "${mp}" ]] && [[ ! -d "${mp}" ]] && die "${mp}: exists and not a directory"
  mkdir -p "${mp}"

  if mount_nonempty_dir_conflict "${mp}"; then
    if [[ "${accept_nonempty}" -eq 1 ]]; then
      log "warning: ${mp} is non-empty — mounting will hide existing files until unmounted"
    else
      die "${mp}: mountpoint is non-empty — refusing to mask existing files (clear the directory, or use --accept-nonempty-mounts / ensure-os-layout without --strict-empty-mountpoints)"
    fi
  fi

  local spec
  spec="$(mount_source_spec "${uuid}")"

  log "mounting ${spec} -> ${mp}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    run mount -t btrfs -o "${opts_full}" "${spec}" "${mp}"
    log "dry-run: skipped post-mount verification (nothing mounted)"
    return 0
  fi

  run mount -t btrfs -o "${opts_full}" "${spec}" "${mp}" || die "mount failed (${spec})"
  verify_mount_correct_or_die "${uuid}" "${mp}" "${opts_full}"
}

handle_ensure_mount_cmd() {
  local resolved uuid dev mp opts_final
  resolved="$(mutually_resolve_uuid_dev)"
  uuid="${resolved%%|*}"
  dev="${resolved#*|}"

  normalize_input_flags
  [[ -n "${MOUNTPOINT}" ]] || die "--mountpoint required"

  opts_final="$(compose_mount_opts "${MOUNT_OPTIONS}" "${MOUNT_SUBVOL}")"
  ensure_deps_rw
  require_btrfs_on_device_or_die "${dev}"

  ensure_mount_operation "${uuid}" "${MOUNTPOINT}" "${opts_final}" "${ACCEPT_NONNULL_MOUNTS_CLI}"

  if [[ "${WRITE_FSTAB}" -eq 1 ]]; then
    fstab_append_idempotent_or_die "${uuid}" "${MOUNTPOINT}" "${opts_final}"
  fi
}

handle_subvol_cmd() {
  need_root

  local resolved uuid
  resolved="$(mutually_resolve_uuid_dev)"
  uuid="${resolved%%|*}"

  ensure_deps_rw
  [[ -n "${ENSURE_SUBVOLUMES_RAW}" ]] || die "--ensure-subvolumes required"

  local nv_mode="none"
  [[ "${NOCOW_VARLOG_CLI}" -eq 1 ]] && nv_mode="varlog"
  ensure_top_level_subvolumes_via_staging "${uuid}" "${nv_mode}"
}

handle_fstab_only_cmd() {
  local resolved uuid dev opts_final
  resolved="$(mutually_resolve_uuid_dev)"
  uuid="${resolved%%|*}"

  normalize_input_flags
  [[ -n "${MOUNTPOINT}" ]] || die "--mountpoint required"

  opts_final="$(compose_mount_opts "${MOUNT_OPTIONS}" "${MOUNT_SUBVOL}")"
  need_root
  ensure_deps_rw

  fstab_append_idempotent_or_die "${uuid}" "${MOUNTPOINT}" "${opts_final}"
}

handle_full_ensure_cmd() {
  local resolved uuid dev opts_final
  resolved="$(mutually_resolve_uuid_dev)"
  uuid="${resolved%%|*}"
  dev="${resolved#*|}"

  normalize_input_flags
  [[ -n "${MOUNTPOINT}" ]] || die "--mountpoint required"

  opts_final="$(compose_mount_opts "${MOUNT_OPTIONS}" "${MOUNT_SUBVOL}")"
  ensure_deps_rw
  require_btrfs_on_device_or_die "${dev}"

  if [[ -n "${ENSURE_SUBVOLUMES_RAW}" ]]; then
    trap cleanup_staging EXIT
    STAGING_MOUNT=""
    local nv_mode="none"
    [[ "${NOCOW_VARLOG_CLI}" -eq 1 ]] && nv_mode="varlog"
    ensure_top_level_subvolumes_via_staging "${uuid}" "${nv_mode}"
    cleanup_staging
    trap - EXIT
    STAGING_MOUNT=""
  fi

  ensure_mount_operation "${uuid}" "${MOUNTPOINT}" "${opts_final}"

  if [[ "${WRITE_FSTAB}" -eq 1 ]]; then
    fstab_append_idempotent_or_die "${uuid}" "${MOUNTPOINT}" "${opts_final}"
  fi
}

ensure_os_layout_execute_or_die() {
  local uuid dev resolved stripped base_eff Lay src_live sub mp opts accept_nl fst_t cid

  if [[ -n "${UUID}" || -n "${DEVICE}" ]]; then
    resolved="$(mutually_resolve_uuid_dev)"
    uuid="${resolved%%|*}"
    dev="${resolved#*|}"
  else
    uuid="$(discover_live_root_btrfs_uuid_or_die)"
    dev="$(resolve_dev_from_uuid_or_die "${uuid}")"
  fi

  require_btrfs_on_device_or_die "${dev}"

  src_live="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  if [[ "${SSD_AUTO}" -eq 1 ]] && [[ "${SSD}" -eq 0 ]]; then
    if infer_rotational_disk_from_fs_source_maybe "${src_live}"; then
      SSD=1
      log "ssd-auto: ${src_live} has ROTATIONAL=0 — enabling ssd,discard=async"
    fi
  fi

  if [[ -z "${MOUNT_OPTIONS}" ]]; then
    stripped="$(strip_btrfs_vol_anchor_opts "$(findmnt -n -o OPTIONS / 2>/dev/null || printf '%s' 'defaults')")"
    [[ -z "${stripped}" ]] && stripped="defaults"
    MOUNT_OPTIONS="${stripped}"
  fi

  normalize_input_flags
  base_eff="${MOUNT_OPTIONS}"

  Lay="${LAYOUT_SPEC_RAW}"
  [[ -z "${Lay}" ]] && Lay="${DEFAULT_OS_LAYOUT_RAW}"

  parse_layout_into_sorted_arrays_or_die "${Lay}"
  ENSURE_SUBVOLUMES_RAW="$(layout_unique_subvolume_csv)"

  trap cleanup_staging EXIT
  STAGING_MOUNT=""
  local nv_mode="varlog"
  [[ "${SKIP_NOCOW_VARLOG_LAYOUT}" -eq 1 ]] && nv_mode="none"
  ensure_top_level_subvolumes_via_staging "${uuid}" "${nv_mode}"
  cleanup_staging
  trap - EXIT
  STAGING_MOUNT=""

  log "using filesystem UUID=${uuid} (device ${dev})"

  for mp in "${_LAYOUT_MPS_SORTED[@]}"; do
    sub="${_LAYOUT_SUB_BY_MP[$mp]}"
    opts="$(compose_mount_opts "${base_eff}" "${sub}")"

    accept_nl=0
    if [[ "${mp}" != / ]] && [[ "${OS_ACCEPT_NONEMPTY}" -eq 1 ]]; then
      accept_nl=1
    fi

    if [[ "${mp}" == / ]] && findmnt / >/dev/null 2>&1 && [[ "${RELAX_ROOT_MOUNT_VERIFY}" -eq 1 ]]; then
      fst_t="$(findmnt -n -o FSTYPE /)"
      [[ "${fst_t}" == btrfs ]] || die "'/' is mounted as '${fst_t}', not btrfs"
      cid="$(lc_uuid "$(findmnt -n -o UUID /)")"
      [[ "${cid}" == "${uuid}" ]] || die "'/' UUID ${cid} does not match target ${uuid}"
      log "warning: / — skipping strict mount-option check (--relax-root-mount-verify); verify subvol=${sub} matches your boot setup"
    else
      ensure_mount_operation "${uuid}" "${mp}" "${opts}" "${accept_nl}"
    fi

    if [[ "${WRITE_FSTAB}" -eq 1 ]]; then
      fstab_append_idempotent_or_die "${uuid}" "${mp}" "${opts}"
    fi
  done
}

handle_ensure_os_layout_cmd() {
  need_root
  ensure_deps_rw
  ensure_os_layout_execute_or_die
}

status_cmd_mount_from_uuid() {
  local uuid="$1" mp=""
  mp="$(findmnt -S "$(mount_source_spec "${uuid}")" -n -o TARGET 2>/dev/null | head -n1)" || mp=""

  if [[ -z "${mp}" ]]; then
    if [[ "$(id -u)" -eq 0 ]]; then
      staging_prepare_or_die "${uuid}"
      mp="${STAGING_MOUNT}"
    else
      die "UUID ${uuid}: not mounted; run status as root for temporary read-root mount — or specify --mountpoint"
    fi
  fi

  echo "== btrfs filesystem df ${mp}"
  btrfs filesystem df "${mp}"

  echo
  echo "== btrfs subvolume list ${mp}"
  btrfs subvolume list -a "${mp}" || true

  cleanup_staging
  trap - EXIT
  STAGING_MOUNT=""
}

handle_status_cmd() {
  ensure_deps_rw
  local uuid="" mp=""
  if [[ -n "${MOUNTPOINT}" ]]; then
    [[ "$(id -u)" -eq 0 ]] || die "${MOUNTPOINT}: status requires root (use sudo)"
    uuid="$(lc_uuid "$(findmnt -n -o UUID "${MOUNTPOINT}" 2>/dev/null || true)")"
    [[ -n "${uuid}" ]] || die "${MOUNTPOINT}: not a mountpoint or not btrfs"
    verify_mount_correct_or_die "${uuid}" "${MOUNTPOINT}" "$(findmnt -n -o OPTIONS "${MOUNTPOINT}")"
    echo "== btrfs filesystem df ${MOUNTPOINT}"
    btrfs filesystem df "${MOUNTPOINT}"
    echo
    echo "== btrfs subvolume list ${MOUNTPOINT}"
    btrfs subvolume list -a "${MOUNTPOINT}"
    return 0
  fi

  if [[ -n "${UUID}" || -n "${DEVICE}" ]]; then
    local resolved
    resolved="$(mutually_resolve_uuid_dev)"
    uuid="${resolved%%|*}"
    status_cmd_mount_from_uuid "${uuid}"
    return 0
  fi

  die "status needs --mountpoint or --uuid/--device"
}

# Strip optional btrfs subvol suffix from findmnt SOURCE, e.g. /dev/nvme0n1p2[/@] -> /dev/nvme0n1p2
strip_findmnt_source_suffix() {
  printf '%s' "$1" | sed 's/\[[^]]*\]$//'
}

resolve_mount_source_to_block_or_die() {
  local raw="$1" part=""
  raw="$(strip_findmnt_source_suffix "${raw}")"

  if [[ "${raw}" == UUID=* ]]; then
    part="$(blkid -U "$(lc_uuid "${raw#UUID=}")" 2>/dev/null || true)"
  elif [[ "${raw}" == PARTUUID=* ]]; then
    part="$(blkid -t "PARTUUID=${raw#PARTUUID=}" -o device 2>/dev/null | head -n1)"
  elif [[ "${raw}" == LABEL=* ]]; then
    part="$(blkid -L "${raw#LABEL=}" 2>/dev/null || true)"
  else
    part="$(readlink -f "${raw}" 2>/dev/null || true)"
  fi

  [[ -n "${part}" && -b "${part}" ]] || die "cannot resolve block device from mount source '${1}'"
  printf '%s\n' "${part}"
}

whole_disk_for_partition_or_die() {
  local part="$1" disk=""
  disk="$(lsblk -ndo PKNAME -p "${part}" 2>/dev/null || true)"
  [[ -n "${disk}" && -b "${disk}" ]] \
    || die "cannot derive whole-disk device from partition ${part} (lsblk PKNAME)"
  printf '%s\n' "${disk}"
}

detect_boot_firmware() {
  if [[ -d /sys/firmware/efi ]]; then
    printf 'uefi\n'
  else
    printf 'bios\n'
  fi
}

grub_efi_target_from_uname() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'x86_64-efi\n' ;;
    aarch64|arm64) printf 'arm64-efi\n' ;;
    i386|i686) printf 'i386-efi\n' ;;
    *) printf 'x86_64-efi\n' ;; # best-effort default
  esac
}

run_grub_install_for_current_boot_or_die() {
  local firmware efi_tgt mp src part disk
  firmware="$(detect_boot_firmware)"
  efi_tgt="$(grub_efi_target_from_uname)"
  case "${firmware}" in
    uefi)
      findmnt /boot/efi >/dev/null 2>&1 || die "grub-install: /boot/efi not mounted (UEFI)"
      log "grub-install: UEFI --target=${efi_tgt}"
      run grub-install --target="${efi_tgt}" --efi-directory=/boot/efi --boot-directory=/boot
      ;;
    bios)
      mp="/boot"
      findmnt "${mp}" >/dev/null 2>&1 || mp="/"
      src="$(findmnt -n -o SOURCE "${mp}" 2>/dev/null || true)"
      [[ -n "${src}" ]] || die "grub-install: cannot read findmnt SOURCE for ${mp}"
      part="$(resolve_mount_source_to_block_or_die "${src}")"
      disk="$(whole_disk_for_partition_or_die "${part}")"
      log "grub-install: BIOS disk ${disk}"
      run grub-install --target=i386-pc --boot-directory=/boot "${disk}"
      ;;
  esac
}

verify_full_stack_mount_topology_or_die() {
  local rootfst bootfst effst
  rootfst="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
  [[ "${rootfst}" == btrfs ]] \
    || die "ensure-full-stack: '/' must be btrfs (got '${rootfst}')"

  findmnt /boot >/dev/null 2>&1 || die "ensure-full-stack: /boot must be mounted"
  bootfst="$(findmnt -n -o FSTYPE /boot)"
  case "${bootfst}" in
    ext3|ext4) ;;
    *) die "ensure-full-stack: /boot must be ext3/ext4 (got '${bootfst}'); keep kernels off btrfs" ;;
  esac

  if [[ "$(detect_boot_firmware)" == uefi ]]; then
    findmnt /boot/efi >/dev/null 2>&1 \
      || die "ensure-full-stack: UEFI session requires /boot/efi mounted (vfat ESP)"
    effst="$(findmnt -n -o FSTYPE /boot/efi)"
    [[ "${effst}" == vfat ]] \
      || die "ensure-full-stack: /boot/efi must be vfat (got '${effst}')"
  fi
}

ensure_grub_d_is_sourced_or_die() {
  [[ -f /etc/default/grub ]] || die "/etc/default/grub missing"
  grep -q '/etc/default/grub\.d' /etc/default/grub \
    || die "/etc/default/grub must source /etc/default/grub.d/*.cfg (standard Debian grub-common pattern)"
}

write_grub_subvol_snippet_or_die() {
  ensure_grub_d_is_sourced_or_die
  local content
  content='# Managed by btrfs-setup-debian13.sh (ensure-full-stack)
# Append rootflags=subvol=@,... from live / when not already in GRUB_CMDLINE_LINUX
if ! echo " ${GRUB_CMDLINE_LINUX} " | grep -qE "(^|[[:space:]])(rootflags=.*subvol=@|subvol=@)(,|$|[[:space:]])"; then
  _bt_rf="$(findmnt -n -o OPTIONS / 2>/dev/null | tr "," "\n" | grep -Ev "^(subvol|subvolid)=" | sed "/^$/d" | paste -sd, -)"
  [ -z "${_bt_rf}" ] && _bt_rf="defaults"
  GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX} rootflags=subvol=@,${_bt_rf}"
fi
'
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "would write ${GRUB_SUBVOL_SNIPPET}:"
    printf '%s\n' "${content}"
    return 0
  fi
  mkdir -p /etc/default/grub.d
  printf '%s\n' "${content}" > "${GRUB_SUBVOL_SNIPPET}"
  log "wrote ${GRUB_SUBVOL_SNIPPET}"
}

handle_ensure_full_stack_cmd() {
  need_root
  ensure_deps_rw
  verify_full_stack_mount_topology_or_die

  [[ "${DRY_RUN}" -eq 1 ]] \
    && log "dry-run: btrfs mounts/subvolumes may be skipped (see ensure + dry-run behaviour)"

  local prev_write
  prev_write="${WRITE_FSTAB}"
  WRITE_FSTAB=1
  ensure_os_layout_execute_or_die
  WRITE_FSTAB="${prev_write}"

  log "fstab: sync /boot"
  fstab_sync_live_mount_or_die /boot 0 2

  if [[ "$(detect_boot_firmware)" == uefi ]]; then
    log "fstab: sync /boot/efi"
    fstab_sync_live_mount_or_die /boot/efi 0 1
  fi

  if [[ "${SKIP_BOOTLOADER_STACK}" -eq 1 ]]; then
    log "skip bootloader steps (--skip-bootloader)"
    return 0
  fi

  write_grub_subvol_snippet_or_die

  have update-initramfs || die "install initramfs-tools (update-initramfs)"
  have update-grub || die "install grub-common (update-grub)"
  have grub-install || die "install grub-pc or grub-efi (grub-install)"

  log "running update-initramfs -u -k all"
  run update-initramfs -u -k all

  log "running update-grub"
  run update-grub

  log "running grub-install"
  run_grub_install_for_current_boot_or_die

  log "ensure-full-stack: finished (reboot to verify boot)"
}

handle_detect_boot_cmd() {
  have findmnt || die "install util-linux (findmnt)"
  have lsblk || die "install util-linux (lsblk)"
  have blkid || die "install util-linux (blkid)"

  local firmware efi_tgt mp src part disk
  firmware="$(detect_boot_firmware)"
  efi_tgt="$(grub_efi_target_from_uname)"

  printf 'BOOT_FIRMWARE=%s\n' "${firmware}"
  case "${firmware}" in
    uefi)
      printf 'GRUB_EFI_TARGET=%s\n' "${efi_tgt}"
      echo
      echo "This session was started by UEFI (kernel exposes firmware under /sys/firmware/efi)."
      echo "Example (separate /boot + ESP at /boot/efi):"
      printf '  sudo grub-install --target=%s --efi-directory=/boot/efi --boot-directory=/boot\n' "${efi_tgt}"
      ;;
    bios)
      echo
      echo "This session was started in legacy BIOS mode (/sys/firmware/efi absent)."
      mp="/boot"
      findmnt "${mp}" >/dev/null 2>&1 || mp="/"
      src="$(findmnt -n -o SOURCE "${mp}" 2>/dev/null || true)"
      [[ -n "${src}" ]] || die "cannot read findmnt SOURCE for ${mp}"
      part="$(resolve_mount_source_to_block_or_die "${src}")"
      disk="$(whole_disk_for_partition_or_die "${part}")"
      printf 'GRUB_BIOS_DISK=%s\n' "${disk}"
      echo
      echo "Example (kernels on /boot, GRUB core to MBR/GPT BIOS boot partition on this disk):"
      printf '  sudo grub-install --target=i386-pc --boot-directory=/boot %q\n' "${disk}"
      ;;
  esac
}

main() {
  [[ "$#" -ge 1 ]] || { usage; exit 1; }
  SOURCE_CMD="$1"
  shift || true

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --uuid) UUID="${2:?}"; shift 2 ;;
      --device) DEVICE="${2:?}"; shift 2 ;;
      --mountpoint) MOUNTPOINT="${2:?}"; shift 2 ;;
      --mount-options) MOUNT_OPTIONS="${2:?}"; shift 2 ;;
      --ssd) SSD=1; shift ;;
      --ssd-auto) SSD_AUTO=1; shift ;;
      --mount-subvol) MOUNT_SUBVOL="${2:?}"; shift 2 ;;
      --ensure-subvolumes) ENSURE_SUBVOLUMES_RAW="${2:?}"; shift 2 ;;
      --layout) LAYOUT_SPEC_RAW="${2:?}"; shift 2 ;;
      --strict-empty-mountpoints) STRICT_MOUNTPOINT_LAYOUT=1; shift ;;
      --relax-root-mount-verify) RELAX_ROOT_MOUNT_VERIFY=1; shift ;;
      --accept-nonempty-mounts) ACCEPT_NONNULL_MOUNTS_CLI=1; shift ;;
      --nocow-var-log) NOCOW_VARLOG_CLI=1; shift ;;
      --skip-nocow-var-log) SKIP_NOCOW_VARLOG_LAYOUT=1; shift ;;
      --skip-bootloader) SKIP_BOOTLOADER_STACK=1; shift ;;
      --write-fstab) WRITE_FSTAB=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done

  validate_cross_command_flags_or_die "${SOURCE_CMD}"

  case "${SOURCE_CMD}" in
    ensure) handle_full_ensure_cmd ;;
    ensure-os-layout) handle_ensure_os_layout_cmd ;;
    ensure-full-stack) handle_ensure_full_stack_cmd ;;
    ensure-mount) handle_ensure_mount_cmd ;;
    ensure-subvolumes) handle_subvol_cmd ;;
    ensure-fstab) handle_fstab_only_cmd ;;
    status) handle_status_cmd ;;
    detect-boot) handle_detect_boot_cmd ;;
    *)
      usage
      die "unknown command: ${SOURCE_CMD}"
      ;;
  esac
}

main "$@"
