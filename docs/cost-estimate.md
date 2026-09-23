# Estimativa de custo (dev)

Preços on-demand públicos de **us-east-1**, 730 h/mês, sem free tier e sem impostos.
É uma ordem de grandeza, não uma cotação. Confira no
[AWS Pricing Calculator](https://calculator.aws/) antes do primeiro apply, e
lembre que **sa-east-1 (São Paulo) é ~40–60% mais cara** na maioria destes itens.

Classificação: **low** < US$ 5/mês · **medium** US$ 5–25 · **high** > US$ 25.

## O que este plano cria

| Componente | Configuração | US$/mês | Classe | Observação |
|---|---|---:|---|---|
| RDS PostgreSQL ×3 | db.t4g.micro single-AZ + 20 GiB gp3 cada | ~42 | **high** | maior item; pode ser parado por até 7 dias |
| Platform host | EC2 t3.medium (credits `standard`) + 30 GiB root + 20 GiB dados | ~34 | **high** | Kafka + Connect + OTel |
| Fargate (5 tasks) | 0.25 vCPU / 0.5 GB cada, **Spot** | ~14 | medium | on-demand ≈ 45; zero enquanto `services_enabled = false` |
| ALB | 1 ALB, ~0,5 LCU | ~18 | medium | cobra por hora mesmo sem tráfego |
| IPv4 públicos | ALB (2) + NAT (1), US$ 0,005/h cada | ~11 | medium | custo "invisível" desde 2024 |
| NAT instance | t4g.nano + 8 GiB | ~4 | low | NAT Gateway seria ~33 + US$ 0,045/GB |
| Secrets Manager | 4 secrets | ~1,60 | low | |
| CloudWatch Logs | ~2 GB ingest/mês, retenção 7 dias | ~1 | low | cresce com LOG_LEVEL=DEBUG |
| CloudWatch alarms | 10–12 alarmes padrão | ~1 | low | |
| Cloud Map / Route 53 privada | 1 zona + ~8 instâncias | ~1,30 | low | |
| ECR | poucos GB | < 0,50 | low | lifecycle policy limita o crescimento |
| S3 (state) | MBs + versões | < 0,10 | low | |
| X-Ray | < 100k traces/mês | 0 | low | depois, US$ 5 por milhão |
| Transferência de dados | tráfego de lab | ~0–2 | low | cross-AZ US$ 0,01/GB; internet 100 GB/mês grátis |
| **Total (padrão do repo: Fargate Spot)** | | **≈ US$ 128/mês** | | ≈ US$ 0,18/h ≈ US$ 4,20/dia |
| Total com Fargate on-demand | | ≈ US$ 159/mês | | |
| Primeiro apply (`services_enabled = false`) | sem tasks Fargate | ≈ US$ 114/mês | | |

### Lab "estacionado"

Com os RDS parados, o host parado e os serviços em 0, sobra ~**US$ 45/mês**: ALB, IPv4,
NAT e storage de RDS/EBS. Para chegar a ~US$ 0 é preciso destruir (veja o README, seção
Destroy); os bancos estão protegidos de propósito.

## Serviços caros avaliados e **não** usados

| Serviço | Custo que teria | Classe | Decisão |
|---|---:|---|---|
| NAT Gateway | +~US$ 29/mês (vs NAT instance) + US$ 0,045/GB | high | disponível via `egress_mode = "nat_gateway"` ([ADR 0006](adr/0006-network-egress.md)) |
| EKS | US$ 73/mês só o control plane | high | não ([ADR 0001](adr/0001-compute-platform.md)) |
| MSK provisionado + MSK Connect | ~US$ 150/mês | high | não ([ADR 0002](adr/0002-kafka-platform.md)) |
| MSK Serverless | ~US$ 550/mês | high | não |
| RDS Multi-AZ | +US$ 42/mês | high | não em dev |
| Aurora Serverless v2 | ≥ US$ 44/mês por cluster | high | não |
| OpenSearch | ≥ US$ 26/mês | high | não |
| Amazon Managed Prometheus | ~US$ 70/mês no volume do lab | high | não ([ADR 0004](adr/0004-observability-strategy.md)) |
| Amazon Managed Grafana | US$ 9 por editor/mês | medium | não |
| Container Insights | ~US$ 0,30 por métrica (cresce com as tasks) | medium | desligado |
| Interface VPC endpoints | ~US$ 7,30 por endpoint por AZ | high (somando) | não |
| KMS CMKs | US$ 1 por chave/mês | low | não (chaves gerenciadas pela AWS) |

## Guard rails de custo implementados

- **AWS Budget** mensal no bootstrap (padrão US$ 150), com alertas em 80% do real e 100% do previsto. Ativa quando `budget_alert_emails` é preenchido.
- `credit_specification = standard` nas instâncias T: sem cobrança surpresa de "unlimited".
- `max_allocated_storage = 50` no RDS: um slot preso não vira disco infinito.
- `max_slot_wal_keep_size` no legado e o alarme `OldestReplicationSlotLag`.
- ECR lifecycle (mantém 15 tags, expira untagged em 7 dias); logs com retenção de 7 dias.
- Validações: `0.0.0.0/0` exige opt-in; `check` avisa sobre NAT Gateway em dev.
- `services_enabled = false` no primeiro apply: nenhuma task Fargate roda antes de existirem imagens.
