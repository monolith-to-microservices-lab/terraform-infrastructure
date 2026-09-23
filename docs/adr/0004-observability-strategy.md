# ADR 0004: Estratégia de observabilidade

- Status: aceito (fase 1); fase 2 proposta
- Data: 2026-09-23

## Context

Stack local: OpenTelemetry (SDK nas 5 aplicações, exportando OTLP gRPC para
`otel-collector:4317`), Prometheus (scrape de `/metrics` e de 6 exporters, 12 regras),
Grafana (7 dashboards), Loki + Promtail (logs via **docker.sock**) e Tempo (traces +
span-metrics). Parte disso não se transporta como está:

- Promtail depende do socket do Docker, e isso não existe em Fargate.
- Prometheus, Loki, Tempo e Grafana guardam estado em volumes, ou seja, também precisam de disco persistente.
- Os dashboards e configs vivem no repositório `observability-infrastructure`, e trazê-los exige um pipeline de build/config daquele repositório.

O valor educacional do stack precisa ser preservado, e o OpenTelemetry não pode ser removido.

## Decision

**Fase 1 (este plano): usar o que a AWS já entrega e manter o OTel intacto.**

| Sinal | Destino | Como |
|---|---|---|
| Logs de containers | **CloudWatch Logs** | driver `awslogs`, um log group por workload (`/ecs/mtm-dev-<workload>`), retenção de 7 dias; os logs JSON das aplicações ficam consultáveis com Logs Insights |
| Métricas de infraestrutura AWS | **CloudWatch** (gratuitas) | ALB, RDS, EC2 |
| Alarmes | CloudWatch → SNS (e-mail opcional) | ALB 5xx, target unhealthy por serviço, free storage de cada RDS, **`OldestReplicationSlotLag` no legado** (o mesmo sinal do dashboard `cdc-debezium-wal`), recover do platform host |
| Traces | **OTel Collector** (mesma distribuição e versão do lab) no platform host → **AWS X-Ray** | as apps continuam enviando OTLP para `otel-collector.mtm-dev.internal:4317`, sem mudança de código |
| Métricas de aplicação (`/metrics`) | *não coletadas na fase 1* | lacuna conhecida, resolvida na fase 2 |

**Fase 2 (proposta, não implementada):** Prometheus + Tempo + Grafana self-hosted no
platform host (ou num segundo host) com EBS, Prometheus usando `dns_sd_configs` sobre o
Cloud Map (os registros e as regras de SG **já existem**) e Grafana com as fontes
Prometheus, Tempo e **CloudWatch** (para logs, sem duplicar em Loki). O Collector troca
o exporter `awsxray` por `otlp/tempo`: uma mudança de config, não de aplicação. Esse é
justamente o valor do OTel.

## Alternatives

| Opção | Custo aproximado/mês | Prós | Contras |
|---|---|---|---|
| **CloudWatch + X-Ray (fase 1)** | ~US$ 2–5 | nativo, sem servidores, alarmes em métricas de RDS/ALB | perde temporariamente os dashboards do Grafana e as métricas de aplicação |
| Self-hosted completo já na fase 1 | +US$ 30 (host t3.medium extra) | paridade total com o lab | pipeline de configs/dashboards de outro repositório; Loki precisaria de FireLens (sidecar em cada task) |
| Amazon Managed Prometheus + Managed Grafana | AMP ~US$ 70 (≈3.000 séries a cada 10s ≈ 790M amostras/mês) + AMG US$ 9/editor | gerenciado | caro para o volume de um lab |
| Container Insights | ~US$ 0,30 por métrica customizada (cresce com o número de tasks) | métricas por task | duplica o que o Prometheus fará na fase 2; desligado (`container_insights = "disabled"`) |
| OpenSearch para logs | ≥ US$ 26 (t3.small.search) + EBS | busca full-text | caro e duplicaria o CloudWatch/Loki |

## Consequences

- O OTel Collector roda em `host` network no platform host (portas 4317/4318/13133). Se ele cair, as aplicações continuam funcionando, porque o exporter OTLP falha em background (comportamento já documentado no monólito).
- X-Ray aceita trace IDs W3C, então os spans do OTel chegam sem conversão nas aplicações.
- O alarme de slot lag cobre o risco operacional mais sério do CDC mesmo sem Prometheus.
- A E2E de observabilidade (que consulta Prometheus/Loki/Tempo) não roda contra a AWS até a fase 2.

## Cost considerations

Fase 1 ≈ US$ 1 (ingestão de ~2 GB de logs) + US$ 1 (alarmes) + X-Ray (100k traces/mês
grátis). Fase 2 adiciona o custo de EBS e, se necessário, um host dedicado (~US$ 30).
