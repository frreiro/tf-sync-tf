# ⚠️ OBRIGATÓRIO: Regras de Sincronização

## 1. TODOS os arquivos devem ser considerados (EXTREMA IMPORTÂNCIA)
- Exclusões definidas em `IGNORE` do `sync.conf` (fonte da verdade — leia o arquivo, não assuma a lista).
- Ignorados **não aparecem** no plano, **não são copiados**, **não são removidos**.
- Cada execução mostra: **Ignorados: N padrão(ões) (lista)** + **Plan: X to add, Y to change, Z to destroy, W unchanged.**
- Soma (X+Y+Z+W) deve bater com contagem de arquivos que **não estão** em `IGNORE`.
- Se não bater = arquivo foi perdido → ERRO CRÍTICO, aborte.

## 2. TODAS as linhas devem ser validadas (TODAS AS LINHAS)
- Diffs **completos** (sem truncar, sem resumir).
- Linha a linha, contexto completo (`diff -u`).
- Exceção **APENAS** para bucket/key dentro de blocos específicos (mascarados):
  - `backend "s3" { ... bucket = ... key = ... }`
  - `data "terraform_remote_state" { ... config = { ... bucket = ... key = ... } }`
  - Qualquer `bucket =` **fora** desses blocos (ex: recurso S3) é sincronizado (não ignorado).
  - Qualquer outra linha: sincronizada sempre.

## Decisões de Sincronização
- **Origem padrão agora: dev** (tem alterações não replicadas ainda).
- **Origem final: arquitetura** (após estabilizar em dev→qa→prod).
- **Origem explícita**: `./sync.sh --from <origem> --to <destino>|all`
- **Dry-run é obrigatório antes de `--apply`**: padrão sem flag.
- **Flag `--terraform`** (opcional): após sync, executa `terraform init/plan/apply` em cada ambiente alterado com credenciais via `s2al <env>`.

## Caminhos
- Use como referência **apenas** os caminhos definidos em `sync.conf` (uma variável por ambiente listado em `ENVS`).
- **Nunca** hardcode caminhos, nomes de projeto ou ambientes nos scripts nem na documentação — tudo vem do `sync.conf`.
- Mover uma pasta ou adicionar ambiente? Edite `sync.conf` apenas.

## Repositórios
- **Arquitetura**: repo próprio (separado dos ambientes).
- **Ambientes** (dev/qa/preprod/prod): todos no mesmo repo.

## Ignorados
- Definidos em `sync.conf`, array `IGNORE`.
- Não copiam, não removem, não aparecem no plano.
- Para personalizar: edite `IGNORE` em `sync.conf`.
- Linhas `bucket = "..."` e `key = "..."` em `backend "s3"` e `terraform_remote_state.config` são mascaradas na comparação (valores do destino preservados ao copiar).

## Workflow
1. **Dry-run**: `./sync.sh --from <origem> --to <destino> --dry-run`
   - Mostra **Ignorados: N padrão(ões)** + contagens + diffs completos (linha por linha).
   - Valide cada diferença manualmente.
   - Se OK, prossiga.
2. **Aplicar**: `./sync.sh --from <origem> --to <destino> --apply`
   - Pergunta confirmação ("yes" para prosseguir).
   - `rsync -a --delete` com exclusão dos padrões em `IGNORE`.
   - Bucket/key do destino são preservados (reaplica valores originais em data.tf).
   - Pós-apply: re-testa diffs — deve estar limpo (zero diferenças).
   - Se houver diferenças novas → ERRO, investigue.
3. **Commit**: Manual em cada repo (o script não commita).

## Ambientes ainda não criados
- Listados em `ENVS` do `sync.conf`, pulados automaticamente se a pasta não existir ("SKIP: <env> não existe").

## Invariantes
- Espelho exato: tudo que está em origem vai para destino (inclusive arquivos novos).
- Arquivos só no destino → reportados e **removidos** (espelho). Confirme explicitamente antes de `--apply`.
- Binários: comparados com `cmp` (não diff).
- `.terraform.lock.hcl` e demais arquivos: sincronizados ou não conforme o `IGNORE` do `sync.conf`.

---

**Última atualização**: 2026-10-07  
**Criado para**: sincronizar um projeto terraform entre os ambientes definidos em `sync.conf`.
