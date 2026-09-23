# Ambientes

| Ambiente | Status | State key |
|---|---|---|
| `dev` | implementado | `dev/terraform.tfstate` |
| `staging` | **não criado** (estrutura preparada) | `staging/terraform.tfstate` |
| `prod` | **não criado** | `prod/terraform.tfstate` |

Cada ambiente é um **root module** fino que só compõe `../../modules/*`. Ambientes são
isolados por diretório e por state key, **não** por `terraform workspace`. Assim o
backend, as variáveis e as permissões de CI ficam explícitos por ambiente.

## Criar um novo ambiente (ex.: staging)

1. Copie `dev/` para `staging/`, sem `.terraform/`, `plans/`, `backend.hcl` nem `terraform.tfvars`.
2. Em `backend.tf`: `key = "staging/terraform.tfstate"`.
3. Em `env.auto.tfvars`: `environment = "staging"`, outro `vpc_cidr` (ex.: `10.30.0.0/16`), dimensionamento e flags (`egress_mode = "nat_gateway"`, `fargate_capacity_provider = "FARGATE"`, `db_backup_retention_days = 7`, ...).
4. No bootstrap: `ci_environments = ["dev", "staging"]` e crie o GitHub Environment `staging` com reviewers.
5. Adicione `staging` às opções do workflow `terraform-apply.yml`.

Os módulos não mudam: tudo que varia por ambiente é variável.
