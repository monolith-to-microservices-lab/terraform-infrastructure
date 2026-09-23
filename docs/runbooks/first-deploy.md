# Runbook: primeiro deploy do dev

Ordem pensada para que cada passo seja revisável e nada rode antes de existir.

| # | Passo | Comando | Cria custo? |
|---|---|---|---|
| 0 | Pré-requisitos | `winget install Hashicorp.Terraform Amazon.AWSCLI` · `aws configure sso` / `aws sso login` | não |
| 1 | Confirmar identidade | `aws sts get-caller-identity` | não |
| 2 | Inventariar a conta | `./scripts/discover-aws.ps1 -Region us-east-1` → decidir cada linha de [existing-resources.md](../existing-resources.md) | não |
| 3 | Bootstrap do state | `cp bootstrap/terraform.tfvars.example bootstrap/terraform.tfvars` · `./scripts/bootstrap.ps1` (plan → revisão → `yes`) | centavos (S3) |
| 4 | Configurar dev | `cp environments/dev/terraform.tfvars.example environments/dev/terraform.tfvars` (região, **seu IP /32**, boundary do passo 3) | não |
| 5 | Validar | `./scripts/validate.ps1` | não |
| 6 | Plan | `./scripts/plan.ps1 -Environment dev` → esperado **~239 to add, 0 to change, 0 to destroy** | não |
| 7 | **CHECKPOINT** | revisar arquitetura, recursos, custo ([cost-estimate.md](../cost-estimate.md)) e riscos | – |
| 8 | Apply da fundação | `./scripts/apply.ps1 -Environment dev` (`services_enabled = false`: serviços ECS com 0 tasks) | **sim, ~US$ 114/mês** |
| 9 | Publicar imagens | ver abaixo | ECR (centavos) |
| 10 | Ligar os serviços | `services_enabled = true` em `env.auto.tfvars` (PR) → plan mostra só `desired_count 0 → 1` → apply | +~US$ 14/mês |
| 11 | CDC | [cdc-bootstrap.md](cdc-bootstrap.md) | – |
| 12 | Verificar | `./scripts/drift-check.ps1` (sem drift) · `./scripts/state-info.ps1 -Outputs` · `curl http://<alb>:8001/health` | – |

## Passo 9: publicar as imagens no ECR

As tags são imutáveis e precisam bater com `image_tags` em `env.auto.tfvars` (`0.1.0`).

```powershell
$region = 'us-east-1'
$urls = (terraform -chdir=environments/dev output -json ecr_repository_urls | ConvertFrom-Json)
$registry = $urls.'user-service'.Split('/')[0]
aws ecr get-login-password --region $region | docker login --username AWS --password-stdin $registry

docker build -t "$($urls.'monolith-api'):0.1.0"  ..\monolito-microservice\backend
docker build -t "$($urls.'user-service'):0.1.0"  ..\user-service
docker build -t "$($urls.'sales-service'):0.1.0" ..\sales-service
docker push "$($urls.'monolith-api'):0.1.0"
docker push "$($urls.'user-service'):0.1.0"
docker push "$($urls.'sales-service'):0.1.0"
```

(Próxima fase: um workflow de build/push com OIDC em cada repositório de serviço.)

## Deploy de uma nova versão

1. Push da imagem com uma tag nova (ex.: `0.1.1`).
2. PR mudando `image_tags` → o plan mostra a nova task definition e o update do serviço.
3. Apply → o ECS faz rolling deploy com circuit breaker e rollback automático.

## Mudança de capacidade (ex.: desired_count 2 → 3)

Edite `api_sizing["user-service-api"].desired_count` em `env.auto.tfvars` num PR. O plan
mostra exatamente:

```text
~ resource "aws_ecs_service" "this" {
    ~ desired_count = 2 -> 3
  }
~ resource "aws_appautoscaling_target" "this" {
    ~ min_capacity = 2 -> 3
  }
Plan: 0 to add, 2 to change, 0 to destroy.
```

(Este fluxo é validado offline pelo teste `desired_count_change_is_visible_in_plan`.)
