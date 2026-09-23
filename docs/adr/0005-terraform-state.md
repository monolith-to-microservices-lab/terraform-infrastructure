# ADR 0005: Terraform state (backend, locking, segurança)

- Status: aceito
- Data: 2026-09-23

## Context

O state é a memória do Terraform: sem ele o Terraform não sabe o que já existe, e
state corrompido ou perdido leva a recursos duplicados ou órfãos. O state também pode
conter dados sensíveis (atributos de recursos, endpoints). Estado local não serve
para CI nem para mais de um operador. Existe um problema de ovo e galinha: o bucket
do state não existe antes do primeiro `terraform apply`.

## Decision

1. **Stack `bootstrap/` com state local** (git-ignored). Ela cria:
   - bucket S3 `mtm-tfstate-<account_id>-<region>`: versionado, SSE-S3, Block Public Access (4/4), `BucketOwnerEnforced`, policy que nega transporte sem TLS e nega `s3:DeleteBucket`, lifecycle que mantém versões antigas por 90 dias (mínimo de 30, validado) e expira `ci-plans/` em 7 dias; `prevent_destroy`;
   - roles OIDC do GitHub (plan/apply) e o permissions boundary dos workloads;
   - budget mensal (opcional).
2. **Backend S3 por ambiente**, com configuração parcial:
   ```hcl
   backend "s3" {
     key          = "dev/terraform.tfstate"
     encrypt      = true
     use_lockfile = true
   }
   ```
   `bucket` e `region` vêm de `backend.hcl` (git-ignored, gerado pelo `scripts/bootstrap.ps1`) ou de `-backend-config` no CI. Nenhuma credencial fica no backend.
3. **Locking nativo do S3** (`use_lockfile = true`, Terraform ≥ 1.11): um objeto `dev/terraform.tfstate.tflock` criado com escrita condicional. **Sem tabela DynamoDB**, porque esse mecanismo está deprecated.
4. **Segredos fora do state:** senhas via atributos write-only (`password_wo`, `secret_string_wo`), então nem o state nem o plan carregam senhas.
5. **Acesso mínimo:** o role de plan do CI lê o state e só pode gravar/apagar o `.tflock`; o de apply escreve o state; nenhum deles pode apagar o bucket, mudar a policy ou desligar o versionamento (Deny explícito).

## Alternatives

| Opção | Por que não |
|---|---|
| State local commitado | vaza dados, conflita entre pessoas e máquinas, sem lock |
| S3 + DynamoDB lock | deprecated; uma tabela a mais para gerenciar |
| HCP Terraform / Terraform Cloud | ótimo, mas tira o aprendizado de backend/locking que é objetivo do lab |
| SSE-KMS com CMK | US$ 1/mês + gestão de key policy; o controle de acesso já é feito por IAM + bucket policy. Fica como evolução (os achados do Trivy AWS-0132 foram aceitos por isso) |
| Bootstrap via script (`aws s3api create-bucket`) | o bucket ficaria fora do Terraform, sem drift detection nem revisão por plan |

## Consequences

- O state do bootstrap fica **apenas na máquina de quem rodou**. Se ele se perder, o bucket continua existindo e pode ser recuperado com `import` (os IDs são determinísticos). Existe também a opção de migrar o state do bootstrap para o próprio bucket ([state-management.md](../state-management.md)).
- Recuperação de state corrompido: restaurar uma versão anterior do objeto (versionamento), conforme o procedimento em [state-management.md](../state-management.md).
- Um lock "preso" (processo morto) é visível como `.tflock` no bucket e é liberado com `terraform force-unlock <ID>`, **só** depois de confirmar que ninguém está aplicando.

## Cost considerations

S3 para alguns MB com versionamento: < US$ 0,10/mês. Sem DynamoDB, sem KMS CMK.
