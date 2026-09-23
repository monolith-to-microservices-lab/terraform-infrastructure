# Importação de recursos existentes

Regra: **nada que já existe na conta é recriado automaticamente**. Antes do primeiro
apply de cada stack, a conta é inventariada.

## Fluxo

```text
discover -> map -> plan import -> review -> import -> clean up
```

1. **Discover.** Rode `./scripts/discover-aws.ps1 -Region <região>`. Ele só faz Describe/List, procurando tag `Project=monolith-to-microservices-lab`, prefixo `mtm-` / `mtm/`, o bucket `mtm-tfstate-*`, os roles `mtm-*` e o OIDC provider do GitHub. O resultado vai para [existing-resources.md](existing-resources.md).
2. **Map.** Para cada linha, decida:

   | Ação | Quando |
   |---|---|
   | **IMPORT** | o recurso é o mesmo que o código descreve e deve passar a ser gerenciado |
   | **KEEP UNMANAGED** | existe, é usado, mas pertence a outro dono ou processo (ex.: OIDC provider compartilhado com outros repositórios; use `existing_github_oidc_provider_arn`) |
   | **CREATE NEW** | não existe, ou o existente é lixo de teste que será apagado à mão |
   | **IGNORE** | não tem relação com o lab (falso positivo do filtro por nome) |

3. **Plan import.** Adicione um bloco `import` em `environments/dev/imports.tf` (ou `bootstrap/imports.tf`):
   ```hcl
   import {
     to = module.registry.aws_ecr_repository.this["user-service"]
     id = "mtm/user-service"
   }
   ```
   Se ainda não houver código para o recurso, `terraform plan -generate-config-out=generated.tf` gera um rascunho para revisar e mover para o módulo certo.
4. **Review.** `./scripts/plan.ps1` precisa mostrar `N to import, 0 to add, 0 to change, 0 to destroy` para esse recurso. Qualquer `change` significa que o código diverge da realidade: ajuste o código, não a infra. Um `destroy`/`replace` num recurso importado é **bloqueante**.
5. **Import.** `./scripts/apply.ps1` aplica o plano revisado (os import blocks são aplicados como parte do apply).
6. **Clean up.** Remova o bloco `import` no mesmo PR ou no seguinte. O recurso já está no state.

## Por que blocos `import` e não `terraform import`

- Ficam versionados e revisados em PR.
- Aparecem no **plan** antes de acontecer (o `terraform import` da CLI grava direto no state, sem plano).
- Funcionam no CI com o mesmo fluxo de revisão.

## Casos previstos

| Recurso | Situação provável | Ação |
|---|---|---|
| OIDC provider `token.actions.githubusercontent.com` | pode já existir (1 por conta) | `existing_github_oidc_provider_arn` (KEEP UNMANAGED) ou import para `aws_iam_openid_connect_provider.github[0]` |
| Bucket de state (bootstrap) | se o state local do bootstrap for perdido | `import { to = aws_s3_bucket.state, id = "<bucket>" }` + os sub-recursos (versioning, encryption, public access block, policy, lifecycle) |
| Service-linked roles (ECS, ELB, RDS) | criados automaticamente pela AWS | IGNORE (não são gerenciados pelo Terraform) |
