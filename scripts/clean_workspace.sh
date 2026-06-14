#!/bin/bash
# Clean EDA tool residuals and archive obsolete EH2 sign-off outputs.
#
# Default mode removes root/syn lock and session leftovers, archives loose
# build logs plus historical run directories, trims coverage backups, and moves
# old diagnostic documents into stable locations.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

shopt -s nullglob

DRY_RUN=0
ARCHIVE_ONLY=0
ALL=0
LCK_ONLY=0

BUILD_ARCHIVE_STAMP="$(date +%Y%m%d)"
BUILD_ARCHIVE_BACKING_DIR=".scratch/r5_build_archive_${BUILD_ARCHIVE_STAMP}"
BUILD_ARCHIVE_LINK="build/archive_signoffs_${BUILD_ARCHIVE_STAMP}"
BUILD_ARCHIVE_READY=0

BUILD_PRESERVE_BASENAMES=(
  r3b_final
  r4a_final
  nightly
  cov.vdb
  cov
  simv
  simv.daidir
  simv.vdb
  simv_compliance
  simv_compliance.daidir
  libcosim.so
  spike_objs
  csrc
  compile.log
  compliance_tb_compile.log
  archive_signoffs_*
)

usage() {
  cat <<'USAGE'
Usage: bash scripts/clean_workspace.sh [--dry-run] [--archive-only] [--all] [--lck-only]

  --dry-run       Print actions without removing or moving files.
  --archive-only  Only archive historical sign-off/docs; do not delete tool files.
  --all           Also remove existing archive_signoffs links and backing archives.
  --lck-only      Remove only Formality lock/session files from root and syn/.
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --archive-only) ARCHIVE_ONLY=1 ;;
    --all) ALL=1 ;;
    --lck-only) LCK_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $arg" >&2; usage; exit 2 ;;
  esac
done

say() {
  echo "$@"
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run]'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  else
    "$@"
  fi
}

build_entry_is_preserved() {
  local base="$1"
  local keep
  for keep in "${BUILD_PRESERVE_BASENAMES[@]}"; do
    case "$base" in
      $keep) return 0 ;;
    esac
  done
  return 1
}

ensure_build_archive() {
  if [[ "$BUILD_ARCHIVE_READY" == "1" ]]; then
    return
  fi

  if [[ "$ALL" == "1" ]]; then
    say "  --all: removing existing archive links and backing archives"
    remove_paths "archive links" build/archive_signoffs_*
    remove_paths "archive backing directories" .scratch/r5_build_archive_*
  fi

  if [[ "$DRY_RUN" == "0" ]]; then
    mkdir -p build "$BUILD_ARCHIVE_BACKING_DIR"
    if [[ ! -e "$BUILD_ARCHIVE_LINK" && ! -L "$BUILD_ARCHIVE_LINK" ]]; then
      ln -s "../${BUILD_ARCHIVE_BACKING_DIR}" "$BUILD_ARCHIVE_LINK"
    fi
  else
    say "[dry-run] mkdir -p build $BUILD_ARCHIVE_BACKING_DIR"
    say "[dry-run] ln -s ../$BUILD_ARCHIVE_BACKING_DIR $BUILD_ARCHIVE_LINK"
  fi

  BUILD_ARCHIVE_READY=1
}

count_existing() {
  local n=0
  local item
  for item in "$@"; do
    [[ -e "$item" || -L "$item" ]] && n=$((n + 1))
  done
  echo "$n"
}

remove_paths() {
  local kind="$1"
  shift
  local existing=()
  local p
  for p in "$@"; do
    [[ -e "$p" || -L "$p" ]] && existing+=("$p")
  done
  if [[ "${#existing[@]}" -eq 0 ]]; then
    say "  no ${kind} found"
    return
  fi
  say "  removing ${#existing[@]} ${kind}"
  run rm -rf -- "${existing[@]}"
}

archive_dir() {
  local src="$1"
  local archive_dir="$2"
  if [[ ! -d "$src" ]]; then
    return
  fi
  run mkdir -p "$archive_dir"
  say "  archive $src -> $archive_dir/"
  run mv "$src" "$archive_dir/"
}

archive_file() {
  local src="$1"
  local archive_dir="$2"
  if [[ ! -f "$src" ]]; then
    return
  fi
  run mkdir -p "$archive_dir"
  say "  archive $src -> $archive_dir/"
  run mv "$src" "$archive_dir/"
}

move_file_to_dir() {
  local src="$1"
  local dst="$2"
  if [[ ! -f "$src" ]]; then
    return
  fi
  run mkdir -p "$dst"
  say "  move $src -> $dst/"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] git mv %q %q/ || mv %q %q/\n' "$src" "$dst" "$src" "$dst"
  else
    git mv "$src" "$dst/" 2>/dev/null || mv "$src" "$dst/"
  fi
}

clean_root_locks() {
  local root_lck=(fm_shell_command*.lck formality*.lck)
  local root_fss=(*.fss)
  if [[ "$ARCHIVE_ONLY" == "1" ]]; then
    say "=== 1. 根目录 EDA 锁文件：archive-only 跳过删除 ==="
    return
  fi
  say "=== 1. 根目录 EDA 锁文件 ==="
  remove_paths "root .lck files" "${root_lck[@]:-}"
  remove_paths "root .fss session files" "${root_fss[@]:-}"
  if [[ "$LCK_ONLY" == "0" ]]; then
    remove_paths "root formal/DC residual files" formalverifier.log eh2_pkg.pvk
  fi
  say "  root lck remaining: $(count_existing ./*.lck)"
}

clean_syn_residuals() {
  local syn_lck=(syn/*.lck)
  local syn_fss=(syn/*.fss)
  local syn_logs=(syn/*.log syn/command.log)
  local syn_misc=(syn/default.svf syn/FM_WORK syn/FM_WORK1)
  if [[ "$ARCHIVE_ONLY" == "1" ]]; then
    say "=== 2. syn/ 工具残留：archive-only 跳过删除 ==="
    return
  fi
  say "=== 2. syn/ 工具残留 ==="
  remove_paths "syn .lck files" "${syn_lck[@]:-}"
  remove_paths "syn .fss session files" "${syn_fss[@]:-}"
  if [[ "$LCK_ONLY" == "0" ]]; then
    remove_paths "syn logs" "${syn_logs[@]:-}"
    remove_paths "syn work residuals" "${syn_misc[@]:-}"
  fi
  say "  syn lck remaining: $(count_existing syn/*.lck)"
}

clean_build_loose() {
  if [[ "$ARCHIVE_ONLY" == "1" || "$LCK_ONLY" == "1" ]]; then
    say "=== 3. build/ 散落文件：当前模式跳过 ==="
    return
  fi
  say "=== 3. build/ 散落文件 ==="
  if [[ -d build ]]; then
    say "  loose build/*.log files are archived in the build archive stage"
    remove_paths "coverage vdb backups" build/cov.vdb.backup_* build/cov.vdb.pre_*
  else
    say "  build/ not found"
  fi
}

archive_signoffs() {
  if [[ "$LCK_ONLY" == "1" ]]; then
    say "=== 4. build/ 历史 sign-off 子目录：lck-only 跳过 ==="
    return
  fi

  say "=== 4. build/ 历史 sign-off 子目录 ==="
  ensure_build_archive

  local candidates=()
  local d base
  for d in build/r*_final build/r3b_html_gate build/sf_* build/signoff* build/final_signoff*; do
    [[ -d "$d" || -L "$d" ]] || continue
    base="$(basename "$d")"
    build_entry_is_preserved "$base" && continue
    candidates+=("$d")
  done

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    say "  no historical sign-off directories found"
    return
  fi

  for d in "${candidates[@]}"; do
    archive_dir "$d" "$BUILD_ARCHIVE_BACKING_DIR"
  done
}

legacy_run_dir_should_archive() {
  local base="$1"

  case "$base" in
    r*_final|r3b_html_gate|sf_*|signoff*|final_signoff*)
      return 1
      ;;
    verify_*|verify2_*|verify3_*|verify4_*|verify5_*|verify6_*|verify7_*|verify8_*)
      return 0
      ;;
    sweep_*|issue12_*|cosim_*|dryrun_*|finalcheck_*|final_*|t4_*|t7_*|post_unlock*)
      return 0
      ;;
    csr_unit_*|dret_*|test_directed*|r2a_*|r2b_*|r2c_*|r2d_*|r3b_*|r3c_*|r3d_*)
      return 0
      ;;
    r5_*|cov_*|smoke)
      return 0
      ;;
  esac

  return 1
}

archive_legacy_runs() {
  if [[ "$LCK_ONLY" == "1" ]]; then
    say "=== 5. build/ 历史临时 run 与散落日志：lck-only 跳过 ==="
    return
  fi

  say "=== 5. build/ 历史临时 run 与散落日志 ==="
  if [[ ! -d build ]]; then
    say "  build/ not found"
    return
  fi

  ensure_build_archive

  local candidates=()
  local path base
  for path in build/*; do
    [[ -e "$path" || -L "$path" ]] || continue
    base="$(basename "$path")"
    build_entry_is_preserved "$base" && continue
    if [[ -d "$path" ]] && legacy_run_dir_should_archive "$base"; then
      candidates+=("$path")
    elif [[ -f "$path" && "$base" == *.log ]]; then
      candidates+=("$path")
    fi
  done

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    say "  no legacy runs or loose logs found"
    return
  fi

  for path in "${candidates[@]}"; do
    if [[ -d "$path" ]]; then
      archive_dir "$path" "$BUILD_ARCHIVE_BACKING_DIR"
    else
      archive_file "$path" "$BUILD_ARCHIVE_BACKING_DIR"
    fi
  done
}

archive_historical_docs() {
  if [[ "$LCK_ONLY" == "1" ]]; then
    say "=== 6. 历史诊断/快照文件归档：lck-only 跳过 ==="
    return
  fi
  say "=== 6. 历史诊断/快照文件归档 ==="
  local round0=".scratch/round0-archive"
  move_file_to_dir DEEPSEEK_RC4_PROMPTS.md "$round0"
  move_file_to_dir eh2-uvm-implementation-plan.md "$round0"
  move_file_to_dir PHASE1_PLAN.md "$round0"
  move_file_to_dir fsm_uncovered_states.md docs/r3b_diagnostics
}

report_sizes() {
  say "=== Clean complete ==="
  du -sh build/ syn/ 2>/dev/null || true
}

clean_root_locks
clean_syn_residuals
clean_build_loose
archive_signoffs
archive_legacy_runs
archive_historical_docs
report_sizes
