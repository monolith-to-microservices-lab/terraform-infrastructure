# Drift detection

**Drift** é qualquer diferença entre a infraestrutura real e o que o Terraform
registrou no state, causada por mudança **fora** do Terraform (console, CLI, outro
script, autoscaling).

## Três perguntas, três comandos

| Pergunta | Comando | O que compara | Altera algo? |
|---|---|---|---|
| O que foi alterado fora do Terraform? | `terraform plan -refresh-only` | infra real × **state** | não (nem infra, nem state, sem apply) |
| O que o Terraform faria agora? | `terraform plan` | **configuração** (.tf/.tfvars) × state atualizado com a infra real | não |
| Registrar a realidade no state | `terraform apply <plano -refresh-only salvo>` | – | só o state, e só depois de revisar |

`terraform plan` também faz refresh, mas mistura duas coisas: o que mudou lá fora e
o que ele quer mudar para voltar à configuração. O `-refresh-only` isola a primeira.

**Nunca** use `terraform refresh`. O comando está deprecated porque grava o state
sem mostrar nada e sem pedir confirmação.

## Uso

```powershell
./scripts/drift-check.ps1 -Environment dev     # exit 0 = sem drift, 2 = drift, 1 = erro
```

- CI: workflow `terraform-drift` (manual; o `schedule` está pronto e comentado).
- Linux/CI: `scripts/drift-check.sh dev`.

## Decidindo o que fazer com um drift

1. **A mudança manual está errada** (alguém "consertou" no console): rode `scripts/plan.ps1`. O plan propõe voltar ao configurado. Revise e rode `scripts/apply.ps1`.
2. **A mudança manual está certa**: edite o `.tf`/`env.auto.tfvars` para refletir a mudança num PR. O CI mostra o plan com 0 changes contra a infra real. Faça merge e apply.
3. **Só registrar no state** (raro: atributo que o Terraform não controla): `terraform apply plans/dev-drift-<timestamp>.tfplan`.

A regra é: drift nunca é aceito automaticamente.

## Drifts esperados (não são incidentes)

| Recurso | Por quê | Mitigação |
|---|---|---|
| `aws_ecs_service.desired_count` das APIs | o autoscaling subiu tasks | `min_capacity = desired_count`: o Terraform nunca derruba abaixo do configurado. Aplicar no pico reduz ao valor do `.tfvars`, e o autoscaling volta a subir |
| `aws_instance.ami` (NAT, platform host) | AMI nova publicada | `ignore_changes = [ami]`: o patch é deliberado (`-replace`) |

## Teste de drift (procedimento)

> **Status: PENDENTE.** Precisa de pelo menos um recurso aplicado e de credenciais AWS,
> que não estavam disponíveis nesta execução. O procedimento abaixo é o que será usado.

Recurso escolhido: a retenção do log group `/ecs/mtm-dev-user-service-api`. Mudar a
retenção não é destrutivo, é reversível, não afeta tráfego e custa centavos.

1. **Baseline** (já aplicado pelo Terraform, retenção 7):
   ```powershell
   ./scripts/drift-check.ps1   # esperado: NO DRIFT, exit 0
   ```
2. **Alteração manual fora do Terraform:**
   ```powershell
   aws logs put-retention-policy --log-group-name /ecs/mtm-dev-user-service-api --retention-in-days 14
   ```
3. **Detecção:**
   ```powershell
   ./scripts/drift-check.ps1   # esperado: exit 2
   ```
   Saída esperada:
   ```text
   Note: Objects have changed outside of Terraform
     # module.compute.module.http_service["user-service-api"].aws_cloudwatch_log_group.this has changed
     ~ resource "aws_cloudwatch_log_group" "this" {
         ~ retention_in_days = 7 -> 14
       }
   ```
4. **Não aceitar automaticamente.** Decisão (padrão do lab): **restaurar**.
   ```powershell
   ./scripts/plan.ps1          # esperado: 0 to add, 1 to change, 0 to destroy (14 -> 7)
   ./scripts/apply.ps1         # aplica o plano revisado
   ./scripts/drift-check.ps1   # esperado: NO DRIFT
   ```
   Alternativa (adotar): mudar `log_retention_days = 14` em `env.auto.tfvars` num PR. Aí o plan mostra 0 changes para esse recurso.
5. Registrar o resultado real (saídas e exit codes) nesta seção.
