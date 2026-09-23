# terraform-infrastructure

**Monolith → Microservices Migration Lab: Infrastructure as Code (Terraform + AWS)**

Parte da organization [`monolith-to-microservices-lab`](https://github.com/monolith-to-microservices-lab).
Os demais componentes vivem em repositórios independentes (não é um monorepo e não há submodules):

| Repositório | Papel |
|---|---|
| `monolito-microservice` | aplicação monolítica original (API + banco legado) |
| `user-service` | microsserviço de usuários (API + consumer CDC) |
| `sales-service` | microsserviço de vendas (API + consumer CDC) |
| `migration-tool` | migração inicial (snapshot) legado → serviços |
| `cdc-infrastructure` | Kafka + Debezium (CDC do legado) |
| `observability-infrastructure` | Prometheus, Grafana, Loki, Tempo, OTel Collector |
| `migration-e2e-tests` | testes end-to-end e de falha |
| **`terraform-infrastructure`** | **este repositório: a infraestrutura AWS de todos eles** |

> **Status:** configuração pronta e validada (fmt, validate, 10 testes offline, tflint,
> trivy). **Nenhum recurso AWS foi criado ainda.** O primeiro `apply` depende de
> revisão (veja [Checkpoint](#checkpoint-antes-do-primeiro-apply)).

## Documentação

| Documento | Conteúdo |
|---|---|
| [docs/current-state.md](docs/current-state.md) | auditoria do lab: componentes, portas, bancos, CDC, achados |
| [docs/aws-architecture.md](docs/aws-architecture.md) | arquitetura AWS proposta (Mermaid), redes, SGs, autoscaling |
| [docs/adr/](docs/adr/) | decisões: compute, Kafka, bancos, observabilidade, state, egress |
| [docs/cost-estimate.md](docs/cost-estimate.md) | custo por componente (low/medium/high) e alternativas descartadas |
| [docs/drift-detection.md](docs/drift-detection.md) | drift, `plan` × `plan -refresh-only`, procedimento de teste |
| [docs/import-strategy.md](docs/import-strategy.md) | como incorporar recursos já existentes |
| [docs/state-management.md](docs/state-management.md) | inspeção, recuperação de versões, lock |
| [docs/security-scan.md](docs/security-scan.md) | ferramentas, achados corrigidos e riscos aceitos |
| [docs/naming.md](docs/naming.md) | convenção de nomes e tags |
| [docs/runbooks/](docs/runbooks/) | primeiro deploy; CDC no RDS |

## Estrutura

```text
terraform-infrastructure/
├── bootstrap/            # state bucket, OIDC do GitHub, permissions boundary, budget (state LOCAL)
├── modules/
│   ├── networking/       # VPC, subnets public/private/data, NAT instance|gateway, S3 endpoint
│   ├── security/         # security groups por workload (mínimo acesso)
│   ├── registry/         # ECR (1 repo por imagem)
│   ├── database/         # RDS PostgreSQL + parameter group + secret (senha write-only)
│   ├── ecs-cluster/      # cluster ECS + Cloud Map (DNS interno)
│   ├── ecs-service/      # bloco reutilizável: task def + serviço + logs + IAM + autoscaling
│   ├── messaging/        # platform host (EC2 + EBS) + Kafka + Kafka Connect/Debezium
│   ├── compute/          # ALB + APIs e consumers CDC em Fargate
│   └── observability/    # OTel Collector, SNS, alarmes CloudWatch
├── environments/
│   └── dev/              # root module do ambiente dev (staging/prod: environments/README.md)
│       ├── env.auto.tfvars          # estado desejado VERSIONADO (tamanhos, contagens, flags)
│       ├── terraform.tfvars.example # valores pessoais (região, seu IP) -> terraform.tfvars (ignorado)
│       ├── backend.hcl.example      # bucket/região do state -> backend.hcl (ignorado)
│       └── tests/                   # terraform test com provider mockado (plan offline)
├── scripts/              # PowerShell: bootstrap, init, validate, plan, apply, drift-check, state-info, discover-aws
├── .github/workflows/    # terraform-ci (PR), terraform-apply (manual), terraform-drift (manual/cron)
└── docs/
```

## Setup

| Ferramenta | Versão | Instalação (Windows) |
|---|---|---|
| Terraform | **1.16.x** (`required_version >= 1.11, < 2.0`) | `winget install Hashicorp.Terraform` |
| AWS CLI | v2 | `winget install Amazon.AWSCLI` |
| Session Manager plugin | – | só para acessar RDS/Connect ([runbook](docs/runbooks/cdc-bootstrap.md)) |
| Docker | – | opcional: os scripts usam `hashicorp/terraform:1.16.4` quando o terraform não está instalado |

Providers (travados em `.terraform.lock.hcl`, com hashes para Windows/Linux/macOS):
`hashicorp/aws ~> 6.60` (6.66.0) e `hashicorp/random ~> 3.7` (3.9.1).

**Credenciais:** use um perfil do AWS CLI, de preferência IAM Identity Center (SSO).
Nunca coloque chaves em `.tf`, `.tfvars` ou `.env` deste repositório.

```powershell
aws configure sso --profile mtm-admin      # uma vez
aws sso login --profile mtm-admin
$env:AWS_PROFILE = 'mtm-admin'
aws sts get-caller-identity                 # confirme a conta ANTES de qualquer plan
```

**Região:** não há padrão silencioso: `aws_region` é obrigatória em `terraform.tfvars`.
O exemplo usa `us-east-1` (a mais barata; veja o [custo](docs/cost-estimate.md)).

## Bootstrap (remote state)

O bucket que guarda o state não pode guardar o próprio state antes de existir. Por isso
`bootstrap/` usa **state local** (git-ignored) e cria:

- bucket S3 `mtm-tfstate-<account>-<region>`: versionado, criptografado (SSE-S3), Block Public Access, TLS obrigatório, protegido contra delete, versões antigas mantidas por 90 dias;
- roles OIDC do GitHub (plan/apply) e o permissions boundary `mtm-workload-boundary`;
- budget mensal (opcional).

```powershell
Copy-Item bootstrap/terraform.tfvars.example bootstrap/terraform.tfvars   # edite aws_region
./scripts/bootstrap.ps1        # plan -> revisão -> 'yes' -> apply; gera environments/dev/backend.hcl
```

**Locking:** `use_lockfile = true` (lock nativo do S3, objeto `.tflock`). Não há DynamoDB,
porque esse mecanismo está deprecated. Detalhes em [ADR 0005](docs/adr/0005-terraform-state.md).

## Init

```powershell
Copy-Item environments/dev/terraform.tfvars.example environments/dev/terraform.tfvars   # região, seu IP/32
./scripts/init.ps1 -Environment dev
# equivale a: cd environments/dev; terraform init -backend-config=backend.hcl
```

## Validate

```powershell
./scripts/validate.ps1
```

Roda sem credenciais AWS:

1. `terraform fmt -check -recursive`
2. `terraform init -backend=false` + `terraform validate` (bootstrap e dev)
3. `terraform test`: plan completo com **provider AWS mockado**, que prova as validações (CDC > partições, `0.0.0.0/0`, `:latest`, tamanhos Fargate) e o fluxo `desired_count`
4. `tflint` (ruleset AWS) e `trivy config` (segurança)

## Plan

```powershell
./scripts/plan.ps1 -Environment dev
```

Faz init, depois `terraform plan -detailed-exitcode -out=plans/dev-<timestamp>.tfplan`,
e imprime o resumo **add/change/destroy/import**, listando cada destroy/replace.
O plano salvo fica em `environments/dev/plans/` (git-ignored). **Nunca aplica.**

Exit codes (`-detailed-exitcode`, usados também no CI):

| Código | Significado |
|---|---|
| `0` | sem mudanças |
| `1` | erro |
| `2` | há mudanças (plano salvo) |

Para mudar a infraestrutura, edite `environments/dev/env.auto.tfvars` (versionado).
Por exemplo, `desired_count` de 2 para 3 gera `~ desired_count = 2 -> 3` e
`Plan: 0 to add, 2 to change, 0 to destroy`.

## Apply

```powershell
./scripts/apply.ps1 -Environment dev                       # usa o plano salvo mais recente
./scripts/apply.ps1 -Environment dev -PlanFile plans/dev-20260923-101500.tfplan
```

- Aplica **somente um plano salvo e revisado**: `terraform apply <plano>`, sem `-auto-approve`.
- Recusa planos com destroy, a menos que você passe `-AllowDestroy`.
- Pede para digitar o nome do ambiente.
- O próprio Terraform rejeita um plano "stale" (se o state mudou depois do plan).

Fluxo: `plan -> revisão -> apply <plano salvo>`.

## Drift

```powershell
./scripts/drift-check.ps1 -Environment dev     # 0 = sem drift, 2 = drift, 1 = erro
```

### `terraform plan` × `terraform plan -refresh-only`

| | `terraform plan` | `terraform plan -refresh-only` |
|---|---|---|
| Pergunta | "O que o Terraform faria agora?" | "O que mudou lá fora?" |
| Compara | **configuração desejada** + state + infraestrutura real | infraestrutura real × **state** |
| Mostra | o que seria criado/alterado/destruído para a infra voltar a bater com o código | mudanças observadas na infraestrutura, para sincronizar o state |
| Propõe alterar a infra real? | sim (se aplicado) | **nunca** |
| Aplicar o plano faz | cria/altera/destrói recursos | só atualiza o state |

`terraform refresh` **não é usado**: está deprecated e grava o state sem revisão.
Um drift nunca é aceito automaticamente. Você decide entre reverter (plan/apply) e
adotar (editar o código). Procedimento e teste em [docs/drift-detection.md](docs/drift-detection.md).

## State

```powershell
./scripts/state-info.ps1                                            # terraform state list
./scripts/state-info.ps1 -Address module.db_legacy.aws_db_instance.this   # terraform state show
./scripts/state-info.ps1 -Outputs                                   # terraform output -json
./scripts/state-info.ps1 -Versions                                  # versões do state no S3
```

`terraform output -json` alimenta o CI e, no futuro, a suíte E2E (endpoints do ALB,
endpoints de banco, bootstrap do Kafka, nomes de serviços). O `tfstate` pode conter
dados sensíveis, mas **as senhas não estão nele**: elas usam atributos write-only.
Recuperação de versões: [docs/state-management.md](docs/state-management.md).

## Import

Nada existente é recriado às cegas: `discover -> map -> plan import -> review -> import`.

```powershell
./scripts/discover-aws.ps1 -Region us-east-1   # read-only; gera docs/existing-resources.md
```

Depois, blocos `import {}` em `environments/dev/imports.tf`, revisados no plan
(`N to import, 0 to change, 0 to destroy`). Guia: [docs/import-strategy.md](docs/import-strategy.md).

## Destroy

Não existe script de destroy, de propósito. Os riscos:

- **Os bancos têm `prevent_destroy`** e `deletion_protection`. `terraform destroy` falha enquanto eles existirem. Destruir dados exige 3 passos explícitos: remover `prevent_destroy` do módulo, `db_deletion_protection = false` + apply, e só então destroy (o RDS ainda gera snapshot final).
- **O volume do Kafka** (`aws_ebs_volume.data`) e **o bucket de state** também têm `prevent_destroy`.
- Destruir o dev apaga tópicos, offsets e o estado do Connect. Recriar exige o [runbook de CDC](docs/runbooks/cdc-bootstrap.md) e a resincronização via migration-tool.

Para **economizar** sem destruir: `services_enabled = false`, parar os RDS (até 7 dias) e
parar o platform host. Sobram ~US$ 45/mês (veja o [custo](docs/cost-estimate.md)).

Se for mesmo destruir: `terraform plan -destroy -out=plans/destroy.tfplan`, revisar e
então `terraform apply plans/destroy.tfplan`. **Sempre com autorização explícita.**

## CI (GitHub Actions)

| Workflow | Gatilho | O que faz |
|---|---|---|
| `terraform-ci` | PR, push em `main` | fmt, validate, testes offline, tflint, trivy; depois `plan -detailed-exitcode` via OIDC (read-only) e comentário no PR. **Nunca aplica** |
| `terraform-apply` | `workflow_dispatch` (manual, só `main`) | plan (salvo no bucket **privado** de state) → aprovação do GitHub Environment `dev` → apply do plano salvo; bloqueia destroy sem `allow_destroy` |
| `terraform-drift` | manual (cron pronto, comentado) | `plan -refresh-only -detailed-exitcode`; falha o job se houver drift; nunca aplica |

**Autenticação: OIDC, sem access keys no GitHub.** Os roles vêm do bootstrap:
`mtm-gha-terraform-plan` (PRs e `main`) e `mtm-gha-terraform-apply` (somente jobs no
Environment `dev`, que deve exigir reviewers).

Variáveis do repositório (Settings → Secrets and variables → Actions → **Variables**):
`AWS_REGION`, `TF_STATE_BUCKET`, `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN`,
`TF_PERMISSIONS_BOUNDARY_ARN`, `TF_ALLOWED_INGRESS_CIDRS` (JSON, ex. `["203.0.113.10/32"]`).
O job de plan fica desativado até elas existirem, então o CI estático funciona desde já.

**Repositório público:** logs e artifacts são visíveis para qualquer pessoa. O CI
publica só contagens e endereços de recursos. O plano completo nunca vai para log nem
para artifact (o `terraform-apply` guarda o `.tfplan` no bucket de state).

## Checkpoint antes do primeiro apply

Nada será aplicado sem apresentar: arquitetura ([docs/aws-architecture.md](docs/aws-architecture.md)),
recursos a criar (plan), resumo `X to add / Y to change / Z to destroy`, custo estimado
([docs/cost-estimate.md](docs/cost-estimate.md)) e riscos. Sequência completa em
[docs/runbooks/first-deploy.md](docs/runbooks/first-deploy.md).

## Segurança (resumo)

- Nunca commitar: `*.tfstate*`, `.terraform/`, `*.tfplan`, `terraform.tfvars`, `backend.hcl`, `.env*`, `*.pem`, `*.key` (todos no `.gitignore`).
- Senhas geradas pelo Terraform, enviadas por atributos **write-only**: nunca no plan nem no state; ficam no Secrets Manager (`mtm/dev/*`).
- Security groups por workload; bancos em subnets sem rota para a internet; ALB aceita só `allowed_ingress_cidrs`; `/internal/*` → 403 e `/metrics` → 404 no ALB.
- IAM: execution role por serviço (só os próprios secrets), permissions boundary obrigatório, sem `AdministratorAccess` em workloads, sem SSH (SSM/ECS Exec).
