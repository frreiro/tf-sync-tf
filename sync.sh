#!/bin/bash
set -uo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly CONF="$SCRIPT_DIR/sync.conf"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m'

[[ -f "$CONF" ]] || { echo -e "${RED}ERRO: $CONF não encontrado${NC}"; exit 1; }
source "$CONF"
[[ -v IGNORE[@] ]] || { echo -e "${RED}ERRO: IGNORE não definido em $CONF${NC}"; exit 1; }
[[ -v ENVS[@] ]] || { echo -e "${RED}ERRO: ENVS não definido em $CONF${NC}"; exit 1; }
for env in "${ENVS[@]}"; do
  [[ -v $env ]] || { echo -e "${RED}ERRO: caminho de '$env' (listado em ENVS) não definido em $CONF${NC}"; exit 1; }
done

declare -g -A ALTERED_FOLDERS  # estrutura: env:folder → caminho completo (ex: qa:03-bff=/path/to/qa/03-bff)

die() { echo -e "${RED}ERRO: $*${NC}" >&2; exit 1; }
info() { echo -e "${BLUE}INFO: $*${NC}"; }

usage() { cat <<EOF
Uso: $0 --from <env> --to <env|all> (--dry-run | --apply) [--terraform]
Ambientes: ${ENVS[*]}
EOF
exit 0
}

valid_env() {
  local env
  for env in "${ENVS[@]}"; do [[ "$1" == "$env" ]] && return 0; done
  return 1
}

get_path() {
  valid_env "$1" || die "Ambiente desconhecido: $1"
  echo "${!1}"
}

mask_tf() {
  awk '
  /^[[:space:]]*backend "s3" \{|^[[:space:]]*config = \{/ { in_block = 1; brace = 1 }
  in_block && /{/ { brace++ }
  in_block && /}/ { brace--; if (brace == 0) in_block = 0 }
  in_block && /^[[:space:]]*(bucket|key)[[:space:]]*=/ { print "    # MASKED"; next }
  { print }
  ' "$1"
}

sync_pair() {
  local from=$1 to=$2 do_apply=$3
  local src=$(get_path "$from")
  local dst=$(get_path "$to")

  [[ -d "$src" ]] || die "Origem não existe: $src"
  [[ -d "$dst" ]] || { info "SKIP: $to não existe"; return 0; }

  # Build rsync args
  local -a excludes=()
  for pattern in "${IGNORE[@]}"; do
    excludes+=("--exclude=$pattern")
  done
  local -a rsync_args=(-rlcD --delete --itemize-changes --out-format='%i %n' "${excludes[@]}")

  echo ""
  echo "════════════════════════════════════════════════════════════════════════════════"
  echo "Plan: $from → $to"
  echo "════════════════════════════════════════════════════════════════════════════════"

  # Run rsync dry-run and capture output
  local rsync_output
  rsync_output=$(rsync "${rsync_args[@]}" --dry-run "$src/" "$dst/" 2>&1 || true)

  # Count files with the same IGNORE excludes rsync uses (regular files only)
  local src_files=$(rsync -r --list-only "${excludes[@]}" "$src/" | grep -c '^-')
  local dst_files=$(rsync -r --list-only "${excludes[@]}" "$dst/" | grep -c '^-')

  echo ""

  # Count ignores
  local ignored_list=""
  [[ ${#IGNORE[@]} -gt 0 ]] && ignored_list="$(IFS=,; echo "${IGNORE[*]}")"
  echo "Arquivo(s): origem=$src_files, destino=$dst_files"
  echo "Ignorados: ${#IGNORE[@]} padrão(ões) ($ignored_list)"
  echo ""

  # First pass: detect "only bucket/key" changes (masked diff is empty)
  local -A only_bucket
  while IFS= read -r line; do
    [[ "$line" =~ ^'>f' ]] || continue
    local file="${line:12}"
    [[ -f "$src/$file" && -f "$dst/$file" ]] || continue

    local masked_diff=$(diff -u <(mask_tf "$dst/$file") <(mask_tf "$src/$file") 2>/dev/null || true)
    [[ -z "$masked_diff" ]] && only_bucket["$file"]=1
  done <<< "$rsync_output"

  # Second pass: display and count
  local creates=0 changes=0 removes=0 listed=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ ^'>f' ]]; then
      local flags="${line:1:10}"
      local file="${line:12}"

      if [[ "$flags" == "f+++++++++" ]]; then
        echo -e "${GREEN}+ $file${NC}"
        # Rastreia pasta (ex: 03-bff/main.tf → 03-bff/)
        local folder=$(dirname "$file" | xargs)  # xargs trimma espaços
        [[ "$folder" != "." ]] && ALTERED_FOLDERS["$to:$folder"]="$(echo "$dst/$folder" | xargs)"
        ((creates++))
        ((listed++))
      elif [[ "$flags" =~ c ]]; then
        # Skip if it's only bucket/key
        if [[ ${only_bucket["$file"]:-0} -eq 1 ]]; then
          : # silence
        else
          echo -e "${MAGENTA}~ $file${NC}"
          diff -u <(mask_tf "$dst/$file") <(mask_tf "$src/$file") 2>/dev/null | tail -n +4 || true
          echo ""
          # Rastreia pasta
          local folder=$(dirname "$file" | xargs)  # xargs trimma espaços
          [[ "$folder" != "." ]] && ALTERED_FOLDERS["$to:$folder"]="$(echo "$dst/$folder" | xargs)"
          ((changes++))
        fi
        ((listed++))
      fi
    elif [[ "$line" =~ ^\*deleting ]]; then
      local file="${line:11}"
      echo -e "${RED}- $file${NC}"
      # Rastreia pasta
      local folder=$(dirname "$file")
      [[ "$folder" != "." ]] && ALTERED_FOLDERS["$to:$folder"]="$dst/$folder"
      ((removes++))
      ((listed++))
    fi
  done <<< "$rsync_output"

  # Unchanged = files in origin - (creates + changes + removes)
  local total_unique=$((src_files - creates - changes - removes))
  [[ $total_unique -lt 0 ]] && total_unique=0

  echo ""
  echo "────────────────────────────────────────────────────────────────────────────────"
  echo "Plan: $creates to add, $changes to change, $removes to destroy, $total_unique unchanged."
  echo ""

  # Apply
  if [[ $do_apply -eq 1 ]]; then
    if [[ $((creates + changes + removes)) -eq 0 ]]; then
      echo -e "${GREEN}No changes. Infrastructure is up-to-date.${NC}"
      return 0
    fi

    echo -e "${YELLOW}Do you want to apply these changes to ${BLUE}$to${YELLOW}?${NC}"
    echo "  Only 'yes' will be accepted to approve."
    read -r -p "Enter a value: " response

    if [[ "$response" != "yes" ]]; then
      echo -e "${YELLOW}Apply cancelled.${NC}"
      return 0
    fi

    echo ""
    echo "Aplicando..."

    # Build rsync args for apply (exclude "only bucket/key" files)
    local -a rsync_apply=("${rsync_args[@]}")
    for file in "${!only_bucket[@]}"; do
      rsync_apply+=("--exclude=/$file")
    done

    rsync "${rsync_apply[@]}" "$src/" "$dst/" 2>&1 | grep -E ">|<|\*" || true

    echo -e "${GREEN}✓ Apply completo${NC}"
  fi
}

main() {
  local from to mode do_apply=0 do_terraform=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) from="$2"; shift 2 ;;
      --to) to="$2"; shift 2 ;;
      --dry-run) mode="dry-run"; shift ;;
      --apply) mode="apply"; do_apply=1; shift ;;
      --terraform) do_terraform=1; shift ;;
      --help) usage ;;
      *) die "Opção: $1" ;;
    esac
  done

  [[ -n "${from:-}" ]] || die "--from obrigatório"
  [[ -n "${to:-}" ]] || die "--to obrigatório"
  [[ -n "${mode:-}" ]] || die "--dry-run ou --apply obrigatório"
  valid_env "$from" || die "Origem inválida"
  [[ "$to" == "all" ]] || valid_env "$to" || die "Destino inválido"

  if [[ "$to" == "all" ]]; then
    for env in "${ENVS[@]}"; do
      [[ "$env" != "$from" ]] && sync_pair "$from" "$env" "$do_apply"
    done
  else
    sync_pair "$from" "$to" "$do_apply"
  fi

  # Executa terraform se --terraform foi passado e houve alterações
  if [[ $do_terraform -eq 1 ]]; then
    set +u
    if [[ ${#ALTERED_FOLDERS[@]} -gt 0 ]]; then
      set -u
      source "$SCRIPT_DIR/terraform.sh"
      terraform_main ALTERED_FOLDERS
    fi
    set -u
  fi
}

main "$@"
