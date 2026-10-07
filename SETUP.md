# Setup Rápido

## O que foi criado

### Arquivos
1. **`sync.sh`** — Script principal (executável)
2. **`sync.conf`** — Mapa de caminhos + `IGNORE` (local, não versionado — veja abaixo)
3. **`CLAUDE.md`** — Regras obrigatórias (lembrete a cada prompt)
4. **`README.md`** — Documentação completa
5. **`SETUP.md`** — Este arquivo

## Criar o `sync.conf` (obrigatório)

O `sync.conf` **não é versionado** (está no `.gitignore`), pois contém caminhos absolutos da sua máquina. Crie-o na raiz do projeto antes do primeiro uso:

```bash
#!/bin/bash
# Mapa de ambientes → caminhos absolutos para o projeto
# Edite apenas os caminhos, nunca os nomes de chave (usados no sync.sh)

# Ambientes válidos (ordem usada em --to all). Cada um precisa de uma variável com o caminho abaixo.
ENVS=(arquitetura dev qa preprod prod)

arquitetura="/caminho/para/<repo-arquitetura>/.../<projeto>"
dev="/caminho/para/<repo-ambientes>/.../dev/.../<projeto>"
qa="/caminho/para/<repo-ambientes>/.../qa/.../<projeto>"
preprod="/caminho/para/<repo-ambientes>/.../preprod/.../<projeto>"
prod="/caminho/para/<repo-ambientes>/.../prod/.../<projeto>"

# Padrões ignorados (sintaxe rsync): não aparecem no plano, não são copiados nem removidos
IGNORE=(
  ".terraform/"
  ".terraform/*"
  ".terraform.lock.hcl"
)
```

Regras:

- **`ENVS`** lista os ambientes aceitos em `--from`/`--to` (e a ordem do `--to all`). Para cada nome em `ENVS` deve existir uma variável de mesmo nome com o caminho — o `sync.sh` aborta se faltar alguma.
- **Caminhos**: absolutos, apontando para a pasta do projeto de cada ambiente no clone local do repo. Ambientes cuja pasta não existe são pulados (`SKIP`).
- **`IGNORE`** é obrigatório (o `sync.sh` aborta se não estiver definido); pode ser vazio: `IGNORE=()`.
- Sintaxe dos padrões: `"dir/"` (diretório), `"nome"` (arquivo em qualquer nível), `"*.glob"`.

## Testes Rápidos

```bash
cd <pasta-deste-projeto>

# Teste 1: Dry-run dev → qa (mostra 1 create + 4 changes)
./sync.sh --from dev --to qa --dry-run

# Teste 2: Dry-run dev → arquitetura
./sync.sh --from dev --to arquitetura --dry-run

# Teste 3: Dry-run dev → all (pula preprod/prod)
./sync.sh --from dev --to all --dry-run

# Teste 4: Ajuda
./sync.sh --help
```

## Próximos Passos

### Usar de Verdade
1. Veja o dry-run de uma sincronização desejada
2. Valide TODAS as diferenças (linha a linha)
3. Execute com `--apply` (se tudo OK)
4. Commit manual em cada repo

### Exemplo Completo
```bash
# 1. Dry-run
./sync.sh --from dev --to qa

# 2. Valide os diffs (check cada [DIFF], [CREATE], [REMOVE])

# 3. Aplica (cria, atualiza, deleta arquivos; preserva bucket/key do destino)
./sync.sh --from dev --to qa --apply

# 4. Commit em qa
cd <caminho-de-qa>   # o mesmo definido em sync.conf
git add .
git commit -m "sync: dev → qa"
git push
```

## Características

✅ **TODOS os arquivos considerados** — contagens de origem/destino validadas  
✅ **TODAS as linhas** — diff completo, linha a linha, nenhuma resumida  
✅ **Bucket/key ignorados** — preserva config terraform state do destino  
✅ **Dry-run obrigatório** — padrão (use `--apply` para realmente aplicar)  
✅ **Origem explícita** — cada execução escolhe (--from/--to)  
✅ **Sem commit automático** — você revisa e commita  
✅ **Arquitetura móvel** — edite 1 linha em `sync.conf`  
✅ **Preprod/Prod futuros** — listados, pulados até criarem

## Regras Críticas (CLAUDE.md)

Sempre relembre:
1. **TODOS os arquivos** das pastas devem ser considerados
2. **TODAS as linhas** devem ser validadas

Veja `CLAUDE.md` para contexto completo a cada novo uso.

---

Pronto! Use `./sync.sh --from <origem> --to <destino>`.
