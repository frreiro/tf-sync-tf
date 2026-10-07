# Terraform Sync

Automatiza sincronização linha a linha de um projeto terraform entre 5 locais, com dry-run obrigatório, confirmação Terraform-style, e opcional terraform apply automatizado.

## Visão Geral
- **5 locais**: arquitetura (repo de arquitetura) + dev, qa, preprod, prod (repo de ambientes)
- **Controle manual**: escolha origem/destino a cada execução
- **Máscara inteligente**: ignora bucket/key dentro de `backend "s3"` e `terraform_remote_state.config` (cada ambiente tem os seus)
- **Todas as linhas**: diffs completos (sem truncar), output estilo Terraform
- **Confirmação**: `--apply` pede "yes" antes de alterar

## Uso

```bash
cd <pasta-deste-projeto>

# Dry-run: mostra plano sem alterar
./sync.sh --from dev --to qa --dry-run
./sync.sh --from dev --to arquitetura --dry-run

# Apply: pergunta confirmação e aplica
./sync.sh --from dev --to qa --apply

# Apply + Terraform: sync + terraform plan/apply (com credenciais saml2aws)
./sync.sh --from dev --to qa --apply --terraform
./sync.sh --from dev --to all --apply --terraform
```

## Fluxo com Terraform Apply

Quando usar `--terraform`:
```bash
./sync.sh --from dev --to qa --apply --terraform
```

O script:
1. Executa sync (copia arquivos via rsync)
2. Para cada ambiente alterado:
   - Exporta credenciais AWS via `saml2aws script` (obtém tokens temporários)
   - Roda `terraform init` na pasta
   - Seleciona/cria workspace do ambiente
   - Mostra `terraform plan`
   - Pede confirmação (yes/no)
   - Aplica com `terraform apply` se aprovado
   - Limpa credenciais antes do próximo ambiente

**Notas:**
- Terraform é executado na pasta do ambiente (ex: `$qa/`)
- Credenciais são limpas entre ambientes para evitar conflitos
- Se houver múltiplos ambientes alterados, o processo itera sobre cada um
- Confirmação é necessária para cada `terraform apply`

## Fluxo Recomendado

1. **Dry-run primeiro sempre**:
   ```bash
   ./sync.sh --from dev --to qa
   ```
   Valide cada diferença (TODOS os arquivos, TODAS as linhas).

2. **Aplica se validado**:
   ```bash
   ./sync.sh --from dev --to qa --apply
   ```
   - Copia tudo de origem para destino (`rsync --delete`)
   - Remove arquivos que só existem em destino
   - Preserva bucket/key originais do destino (não sobrescreve config terraform state)

3. **Commit em cada repo**: manual (script não faz commit/push)
   ```bash
   cd /repo/destino
   git add .
   git commit -m "sync: dev → qa"
   git push
   ```

## O que é Sincronizado

**Tudo**, exceto `.terraform/` (cache de providers e state lock):
- Todos os arquivos `.tf` (main, variables, data, locals, etc.)
- `.terraform.lock.hcl` (**sincronizado**, versionado de propósito)
- Todos os arquivos em subpastas (modules, iam, policies, etc.)

### Ignorados Especificamente
- Diretório `.terraform/` inteiro (inclui locks e plugins)
- **Linhas específicas** dentro de arquivos `.tf`:
  - `backend "s3"`: linhas `bucket = "..."` e `key = "..."` (cada ambiente tem sua conta/bucket)
  - `data "terraform_remote_state"`: linhas `bucket = "..."` e `key = "..."` dentro do bloco `config = {...}`
  - Qualquer outra linha em qualquer arquivo **é sincronizada** (isso é importante)

## Saída do Dry-run

```
════════════════════════════════════════════════════════════════════════════════
SYNC: dev → qa
════════════════════════════════════════════════════════════════════════════════
Contagens: Origem=61 | Destino=60

────────────────────────────────────────────────────────────────────────────────
Diferenças detalhadas (bucket/key em .tf ignorados na avaliação):
────────────────────────────────────────────────────────────────────────────────

[DIFF] 00-common/main.tf (bucket/key da origem → destino, ignorando banco)
+resource "aws_cloudwatch_log_group" "eventbridge" {
+  name              = "/aws/vendedlogs/events/event-bus/my-bus"

[CREATE] 99-events/locals.tf
[REMOVE] 99-events/old-file.tf
```

- **[DIFF]**: arquivo existe nos dois, tem diferenças (mostra com `diff -u`)
- **[CREATE]**: arquivo novo (só em origem)
- **[REMOVE]**: arquivo velho (só em destino, será deletado)
- Contagens: valide que nenhum arquivo foi esquecido

## Configuração

O `sync.conf` é **local e não versionado** (está no `.gitignore`). Na primeira vez, crie-o na raiz do projeto seguindo o modelo completo em [SETUP.md](SETUP.md#criar-o-syncconf-obrigatório). Ele precisa definir:
- O array `ENVS` com os nomes dos ambientes, e uma variável de mesmo nome para cada um com o caminho absoluto na sua máquina.
- O array `IGNORE` (obrigatório, pode ser vazio) com padrões estilo rsync.

Edite `sync.conf` se mudar os caminhos (especialmente arquitetura):

```bash
# Arquitetura: pode ser movida; edite apenas a linha abaixo
arquitetura="/caminho/para/<repo-arquitetura>/.../<projeto>"

# Ambientes no repo de ambientes (não mude sem motivo)
dev="/caminho/para/<repo-ambientes>/.../dev/.../<projeto>"
qa="/caminho/para/<repo-ambientes>/.../qa/.../<projeto>"
...
```

## Importante

1. **TODOS os arquivos**: contagens de origem/destino aparecem no dry-run — confira que nenhum foi ignorado.
2. **TODAS as linhas**: diff completo (linha a linha), não resumido — valide tudo.
3. **Bucket/key preservados**: ao aplicar com `--apply`, o valor original do destino é mantido (sua config de state não é alterada).
4. **Sem commit automático**: revise e commit manualmente em cada repo.
5. **Preprod/Prod futuros**: listados em `sync.conf`, pulados automaticamente se não existirem.

## Troubleshooting

**Q: Dry-run mostra diferentes, mas apliquei e continua mostrando diferenças?**
A: Provavelmente não foi restaurado corretamente o bucket/key. Verifique manualmente em `providers.tf` e `data.tf`.

**Q: Posso forçar a mudança de direção (e.g., qa → dev)?**
A: Sim, `--from qa --to dev` funciona normalmente. O "origem" é explícito a cada vez.

**Q: E se eu deletar um arquivo em origem e quiser deletar em destino também?**
A: O `--apply` faz isso automaticamente (rsync `--delete`). Verifique no dry-run a lista `[REMOVE]`.

---

Última atualização: 2026-09-30  
Repos: repo de arquitetura + repo de ambientes
