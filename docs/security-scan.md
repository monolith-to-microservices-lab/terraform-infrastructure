# Scanning de segurança e riscos aceitos

## Ferramentas (poucas, sem sobreposição)

| Ferramenta | Papel | Por que ela |
|---|---|---|
| `terraform validate` + `terraform test` | sintaxe, tipos, validações de variáveis, plan offline com provider mockado | nativo, sem dependência extra |
| **tflint** + ruleset AWS | erros que o `validate` não pega (tipos de instância inválidos, variáveis sem uso, convenções) | complementa o validate com conhecimento da API AWS |
| **Trivy** (`config`) | misconfigurações de segurança no IaC | o tfsec foi incorporado ao Trivy; o Trivy também faz scan de imagens (útil na próxima fase para o ECR) |

Checkov foi descartado por sobrepor ~90% das regras do Trivy e acrescentar outro runtime (Python).

Local: `./scripts/validate.ps1`. CI: job `static` do `terraform-ci.yml`.

## Achados corrigidos

| ID | Achado | Correção |
|---|---|---|
| AWS-0176 | RDS sem IAM authentication | `iam_database_authentication_enabled = true` (gratuito, não afeta a senha) |
| – | SNS com `alias/aws/sns` | **bug real**: CloudWatch Alarms não publica em tópico cifrado com a chave gerenciada pela AWS. A cifra foi removida (veja abaixo) |
| – | `count` dependente de ARNs desconhecidos no plan | detectado pelo `terraform test`; quebraria o **primeiro plan real**. Corrigido para depender de chaves/flags conhecidas |

## Riscos aceitos (ignores inline com justificativa)

| ID | Onde | Justificativa |
|---|---|---|
| AWS-0104 | egress 443 → `0.0.0.0/0` (workloads, host, NAT) | endpoints públicos da AWS não têm CIDR fixo; interface endpoints custariam ~US$ 100/mês ([ADR 0006](adr/0006-network-egress.md)) |
| AWS-0053 | ALB público | por design; o SG só aceita `allowed_ingress_cidrs` |
| AWS-0054 | listener HTTP | lab sem domínio; HTTPS é automático ao definir `certificate_arn` |
| AWS-0132 | state com SSE-S3 (sem CMK) | acesso controlado por IAM + bucket policy; CMK = custo + key policy ([ADR 0005](adr/0005-terraform-state.md)) |
| AWS-0136 / AWS-0095 | SNS de alarmes sem CMK | payload não sensível; a chave AWS-managed quebraria a entrega |
| AWS-0178 | VPC sem flow logs | disponível via `enable_flow_logs = true` (REJECT) |
| AWS-0342 | `iam:PassRole` no role de apply | restrito a `role/mtm-*` e a `ecs-tasks`/`ec2` via `iam:PassedToService` |

## Controles de IAM

- **Três identidades separadas:** operador humano (perfil SSO próprio, fora do Terraform), CI plan (`mtm-gha-terraform-plan`, ReadOnly + state) e CI apply (`mtm-gha-terraform-apply`, com escopo por serviço, só a partir do GitHub Environment `dev`).
- **Permissions boundary** `mtm-workload-boundary` em todos os roles de workload. O role de apply **só consegue criar roles que carreguem o boundary**, e tem Deny explícito para alterar o próprio boundary e os roles `mtm-gha-*`. Isso impede escalar privilégio criando um role admin.
- **Um execution role por serviço ECS**, com leitura apenas dos secrets que aquele serviço referencia.
- Nenhum `AdministratorAccess` em workloads; nenhuma access key permanente no GitHub (OIDC).
- Sem SSH/par de chaves; IMDSv2 obrigatório nas instâncias.
