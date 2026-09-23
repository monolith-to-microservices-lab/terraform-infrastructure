# Terraform state: operação e recuperação

| Stack | Backend | Chave | Lock |
|---|---|---|---|
| `bootstrap/` | **local** (`bootstrap/terraform.tfstate`, git-ignored) | – | arquivo local |
| `environments/dev` | S3 `mtm-tfstate-<account>-<region>` | `dev/terraform.tfstate` | `dev/terraform.tfstate.tflock` (S3 nativo) |

## Inspeção (somente leitura)

```powershell
./scripts/state-info.ps1                                        # terraform state list
./scripts/state-info.ps1 -Address module.db_legacy.aws_db_instance.this   # terraform state show
./scripts/state-info.ps1 -Outputs                               # terraform output -json
./scripts/state-info.ps1 -Versions                              # versões do objeto no S3
```

Comandos que **alteram** o state (`state mv`, `state rm`, `state push`, `force-unlock`)
não têm script de propósito. Use só com motivo explícito e depois de um backup:

```powershell
terraform state pull > backup-$(Get-Date -Format yyyyMMdd-HHmmss).tfstate   # arquivo git-ignored
```

Para refatorações (renomear recurso/módulo), prefira blocos `moved {}` no código:
eles aparecem no plan e são revisados em PR.

## Recuperar uma versão anterior do state

Cenário: um apply ruim, ou state corrompido/sobrescrito.

1. **Pare**: ninguém roda plan/apply nesse ambiente.
2. Liste as versões:
   ```powershell
   ./scripts/state-info.ps1 -Versions
   ```
3. Baixe a versão boa e inspecione:
   ```powershell
   aws s3api get-object --bucket <bucket> --key dev/terraform.tfstate --version-id <VersionId> good.tfstate
   ```
   Confirme `serial` e `lineage` e que os recursos esperados estão lá.
4. Restaure-a como versão atual (cópia da versão sobre a chave; o histórico é preservado):
   ```powershell
   aws s3api copy-object --bucket <bucket> --key dev/terraform.tfstate `
     --copy-source "<bucket>/dev/terraform.tfstate?versionId=<VersionId>"
   ```
5. `./scripts/drift-check.ps1` mostra o que difere entre o state restaurado e a realidade. Resolva cada item conforme [drift-detection.md](drift-detection.md).

As versões antigas ficam 90 dias (mínimo de 30, validado no bootstrap).

## Lock preso

Sintoma: `Error acquiring the state lock` com um `ID`. Antes de liberar,
**confirme que nenhum plan/apply está rodando** (terminal, CI). Só então:

```powershell
cd environments/dev; terraform force-unlock <ID>
```

## Migrar o state do bootstrap para o S3 (opcional)

Depois que o bucket existir, o state do bootstrap pode morar nele:

1. Adicione em `bootstrap/versions.tf`: `backend "s3" { key = "bootstrap/terraform.tfstate", encrypt = true, use_lockfile = true }`.
2. `terraform init -migrate-state -backend-config=../environments/dev/backend.hcl`.
3. Confirme com `terraform state list` e apague o `terraform.tfstate` local.

Trade-off: o bucket passa a guardar o state que o descreve. Se o bucket for perdido,
esse state vai junto (a recuperação é por `import`).
