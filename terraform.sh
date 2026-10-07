#!/bin/bash
# Credenciais AWS + Terraform init/plan/apply para cada ambiente alterado
set -uo pipefail

# Cores já definidas em sync.sh quando sourced; defini aqui só se executado direto
if [[ -z "${RED:-}" ]]; then
  readonly RED='\033[0;31m'
  readonly GREEN='\033[0;32m'
  readonly YELLOW='\033[0;33m'
  readonly BLUE='\033[0;34m'
  readonly NC='\033[0m'
fi

die() { echo -e "${RED}ERRO: $*${NC}" >&2; exit 1; }

clear_aws_creds() {
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE 2>/dev/null || true
}

export_s2al_creds() {
  local env=$1
  local creds_output

  clear_aws_creds
  echo -e "${BLUE}Exportando credenciais via saml2aws para $env...${NC}"

  # saml2aws script retorna: export AWS_ACCESS_KEY_ID=... export AWS_SECRET_ACCESS_KEY=...
  creds_output=$(saml2aws script --idp-account "$env" --profile "$env" --skip-prompt --disable-keychain 2>&1)
  local exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    # Verifica se erro é de credenciais expiradas
    if echo "$creds_output" | grep -q "credentials have expired"; then
      echo -e "${YELLOW}⚠ Credenciais expiradas. Renovando...${NC}"
      saml2aws login --idp-account "$env" --profile "$env" --disable-keychain || die "Falha ao renovar credenciais para $env"

      # Tenta novamente após renovação
      creds_output=$(saml2aws script --idp-account "$env" --profile "$env" --skip-prompt --disable-keychain 2>&1)
      exit_code=$?

      if [[ $exit_code -ne 0 ]]; then
        echo "Debug saml2aws output após renovação:"
        echo "$creds_output"
        die "Falha ao obter credenciais para $env após renovação"
      fi
    else
      echo "Debug saml2aws output:"
      echo "$creds_output"
      die "Falha ao obter credenciais para $env (exit code: $exit_code)"
    fi
  fi

  [[ -z "$creds_output" ]] && die "saml2aws script retornou vazio para $env"

  eval "$creds_output" || die "Falha ao exportar credenciais para $env"
  export AWS_PROFILE="$env"

  [[ -z "${AWS_ACCESS_KEY_ID:-}" ]] && die "saml2aws não retornou AWS_ACCESS_KEY_ID para $env"
  echo -e "${GREEN}✓ Credenciais exportadas para $env${NC}"
}

terraform_apply() {
  local env=$1 folder=$2

  [[ -d "$folder" ]] || die "Pasta não existe: $folder"

  # Verifica se há arquivos .tf nesta pasta ou subpastas (até 2 níveis)
  if ! find "$folder" -maxdepth 2 -name "*.tf" -type f 2>/dev/null | grep -q .; then
    echo -e "${YELLOW}⚠ Nenhum arquivo .tf encontrado em $folder${NC}"
    echo -e "${YELLOW}Pulando terraform para esta pasta${NC}"
    return 0
  fi

  cd "$folder" || die "Não consegui acessar $folder"

  echo ""
  echo -e "${BLUE}Executando terraform...${NC}"

  terraform init -upgrade=false || die "terraform init falhou"

  terraform workspace select "$env" 2>/dev/null || terraform workspace new "$env" || die "Falha ao selecionar workspace"

  echo ""
  echo -e "${BLUE}Terraform Plan:${NC}"
  terraform plan -out=tfplan || die "terraform plan falhou"

  echo ""
  read -r -p "Aplicar alterações? (yes/no): " response

  if [[ "$response" == "yes" ]]; then
    echo -e "${YELLOW}Aplicando...${NC}"
    terraform apply tfplan || die "terraform apply falhou"
    echo -e "${GREEN}✓ Apply concluído${NC}"
  else
    echo -e "${YELLOW}Apply cancelado${NC}"
  fi

  # Remove tfplan em qualquer caso
  rm -f tfplan

  cd - >/dev/null
}

terraform_main() {
  local -n folders_ref=$1

  [[ ${#folders_ref[@]} -eq 0 ]] && { echo "Nenhuma pasta alterada"; return 0; }

  # Agrupa por ambiente
  declare -A envs_set
  for key in "${!folders_ref[@]}"; do
    local env="${key%%:*}"
    envs_set["$env"]=1
  done

  local env_count=${#envs_set[@]}
  local folder_count=${#folders_ref[@]}

  echo ""
  echo "════════════════════════════════════════════════════════════════════════════════"
  echo "TERRAFORM: Aplicando alterações em $folder_count pasta(s) em $env_count ambiente(s)"
  echo "════════════════════════════════════════════════════════════════════════════════"

  local total=0
  for env_folder_key in "${!folders_ref[@]}"; do
    ((total++))
    local env="${env_folder_key%%:*}"
    local folder="${env_folder_key##*:}"
    local folder_path="${folders_ref[$env_folder_key]}"

    echo ""
    echo "════════════════════════════════════════════════════════════════════════════════"
    echo "[$total/$folder_count] Terraform: $env / $folder"
    echo "════════════════════════════════════════════════════════════════════════════════"

    export_s2al_creds "$env"
    terraform_apply "$env" "$folder_path"
    clear_aws_creds
  done

  echo ""
  echo -e "${GREEN}✓ Terraform finalizado para todas as pastas${NC}"

  # Cleanup: remove todos os tfplan files das pastas alteradas
  echo -e "${BLUE}Limpando arquivos tfplan...${NC}"
  for env_folder_key in "${!folders_ref[@]}"; do
    local folder_path="${folders_ref[$env_folder_key]}"
    rm -f "$folder_path/tfplan" 2>/dev/null || true
  done
}
