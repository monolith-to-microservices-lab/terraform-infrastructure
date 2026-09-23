# Convenção de nomes e tags

## Nomes

`<prefix>-<environment>-<component>`, com `prefix = mtm` (**m**onolith **t**o **m**icroservices).

| Tipo | Padrão | Exemplo |
|---|---|---|
| Recursos por ambiente | `mtm-<env>-<componente>` | `mtm-dev-legacy-pg`, `mtm-dev-alb`, `mtm-dev-user-service-cdc` |
| Serviço ECS / log group | `mtm-<env>-<workload>` / `/ecs/mtm-<env>-<workload>` | `/ecs/mtm-dev-sales-service-api` |
| IAM roles de workload | `mtm-<env>-<workload>-exec` / `-task` | `mtm-dev-kafka-connect-task` |
| Secrets | `mtm/<env>/<nome>` | `mtm/dev/legacy-db` |
| ECR (por imagem, sem ambiente) | `mtm/<imagem>` | `mtm/user-service` |
| DNS interno | `<serviço>.mtm-<env>.internal` | `kafka.mtm-dev.internal` |
| Contas/globais (bootstrap) | `mtm-<nome>` | `mtm-gha-terraform-plan`, `mtm-workload-boundary` |
| Bucket de state | `mtm-tfstate-<account_id>-<region>` | globalmente único e determinístico |

Validações: `name_prefix` tem 2–6 caracteres minúsculos (limites de 32 caracteres de
ALB e target group) e `environment ∈ {dev, staging, prod}`.

Nomes de workload iguais aos do lab: `monolith-api`, `user-service-api`,
`user-service-cdc`, `sales-service-api`, `sales-service-cdc`, `kafka`, `connect`,
`otel-collector`.

## Tags (default_tags do provider, aplicadas a tudo)

| Tag | Valor |
|---|---|
| `Project` | `monolith-to-microservices-lab` |
| `Environment` | `dev` (ou `shared` no bootstrap) |
| `ManagedBy` | `terraform` |
| `Repository` | `monolith-to-microservices-lab/terraform-infrastructure` |
| `Stack` | `environments/dev` ou `bootstrap` |
| `CostCenter` | `lab` |
| `Name` | nome do recurso (quando o tipo suporta) |

`Project` e `ManagedBy` são a base do `discover-aws.ps1` e do filtro de custo por
tag no Cost Explorer (ative as cost allocation tags no Billing).
