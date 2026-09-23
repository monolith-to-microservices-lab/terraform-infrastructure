# terraform-infrastructure

**Monolith → Microservices Migration Lab — Infrastructure as Code**

Este repositório é responsável pela Infrastructure as Code (IaC) do laboratório de migração Monolith → Microservices, usando **Terraform** para provisionar a infraestrutura na **AWS**.

> Status: repositório inicializado. Nenhum recurso AWS foi definido ainda.

## Organization

Este repositório faz parte da GitHub Organization
[`monolith-to-microservices-lab`](https://github.com/monolith-to-microservices-lab).

Os demais componentes do laboratório vivem em **repositórios independentes** (não é um monorepo e não há submodules):

| Repositório | Papel |
|---|---|
| `monolito-microservice` | Aplicação monolítica original |
| `user-service` | Microsserviço de usuários |
| `sales-service` | Microsserviço de vendas |
| `migration-tool` | Ferramenta de migração de dados |
| `cdc-infrastructure` | Infraestrutura de Change Data Capture |
| `observability-infrastructure` | Stack de observabilidade |
| `migration-e2e-tests` | Testes end-to-end da migração |
| `terraform-infrastructure` | Infrastructure as Code (este repositório) |

## Stack

- Terraform
- AWS

## Segurança

Nunca commitar neste repositório:

- arquivos de state (`terraform.tfstate`, `terraform.tfstate.backup`)
- diretórios `.terraform/`
- planos (`*.tfplan`)
- credenciais AWS (access keys / secret keys)
- arquivos `.env` reais
- chaves privadas (`*.pem`, `*.key`)

O `.gitignore` já cobre esses casos.
