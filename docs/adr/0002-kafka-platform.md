# ADR 0002: Plataforma Kafka e Kafka Connect/Debezium

- Status: aceito
- Data: 2026-09-23

## Context

O lab usa Kafka 3.9.1 KRaft (1 nó, RF=1), Kafka Connect com Debezium 3.1 e o
conector `legacy-cdc-connector` (pgoutput, slot `legacy_cdc_slot`, publication
`legacy_cdc_publication`, `snapshot.mode=no_data`). Dois consumers
(`user-service-cdc`, `sales-service-cdc`) usam confluent-kafka com commit manual.
A observabilidade atual lê métricas do Kafka (kafka-exporter), do status do Connect e do JMX do Debezium.

## Decision

1. **Kafka self-hosted** com a mesma imagem (`apache/kafka:3.9.1`) e a mesma configuração KRaft do lab, como serviço ECS no platform host ([ADR 0001](0001-compute-platform.md)), com dados em EBS persistente.
2. **Kafka Connect self-hosted** com a mesma imagem (`quay.io/debezium/connect:3.1`), no mesmo host.
3. **Separação explícita de responsabilidades:**

| Terraform (provisionamento) | Runbook (runtime) |
|---|---|
| container, rede, disco, DNS `kafka.mtm-dev.internal` | tópicos `legacy.public.*` (auto-criados pelo Debezium) |
| serviço Connect, `EnvVarConfigProvider`, secret do usuário `debezium` injetado como env | registro/atualização do conector via REST (`PUT /connectors/<name>/config`, idempotente) |
| RDS legado com `rds.logical_replication=1` e `max_slot_wal_keep_size` | role `debezium`, publication, slot, `REPLICA IDENTITY FULL` |

O Terraform **não** gerencia o conector nem os tópicos. Seria preciso um provider
Kafka/Connect com acesso de rede ao broker privado a partir de onde o Terraform
roda (laptop, runner do GitHub). Isso obrigaria a abrir a rede ou manter um
runner dentro da VPC. Além disso, o conector tem estado próprio (offsets em
`_connect_offsets`) que não deve ser recriado por um `apply`. O procedimento
idempotente já existente (`register-connector.sh`) continua valendo, rodando via
SSM port forwarding ([runbooks/cdc-bootstrap.md](../runbooks/cdc-bootstrap.md)).

A senha do Debezium não trafega no payload REST: a config do conector usa
`"database.password": "${env:DEBEZIUM_DB_PASSWORD}"`, resolvida dentro do worker.

## Alternatives

| Opção | Custo aproximado | Compatibilidade Debezium | Operabilidade | Observabilidade | Veredito |
|---|---|---|---|---|---|
| **Kafka + Connect no platform host (ECS/EC2)** | incluído no host (~US$ 34/mês) | idêntica ao lab | você opera (upgrade, disco) | exporters atuais funcionam sem mudança | **escolhido** |
| Amazon MSK provisionado + MSK Connect | ~US$ 67/mês (2× kafka.t3.small, mínimo de 2 AZs) + ~US$ 80/mês (1 MCU) + storage ≈ **US$ 150/mês** | Debezium como plugin customizado; ok | gerenciado; broker upgrades pela AWS | métricas no CloudWatch/Prometheus aberto (open monitoring) | não: ~4–5× o custo para um único fluxo de CDC de lab |
| MSK Serverless | **~US$ 550/mês** (US$ 0,75/h por cluster) + partições | exige IAM auth (SASL), o consumer confluent-kafka precisaria de mudanças | zero operação | limitada | não |
| Kafka em Fargate | ~US$ 20/mês | ok | **sem disco persistente**: perder tópicos e `_connect_offsets` a cada restart | ok | não |
| Redpanda | similar ao self-hosted | compatível com a API Kafka | outro produto a aprender | diferente dos dashboards atuais | não: não há necessidade que justifique trocar a tecnologia do lab |

## Consequences

- 1 broker, RF=1: perder o volume EBS significa perder tópicos e offsets. Mitigações: `prevent_destroy` no volume, EBS criptografado. Snapshots via AWS Backup/DLM ficam como próximo passo. Como os dados de negócio continuam no legado, o slot pode ser recriado e os consumers ressincronizados com a migration-tool.
- Tópicos com 1 partição (`kafka_default_partitions = 1`) mantêm a mesma semântica de ordenação do lab e limitam os consumers a 1 task (validação no Terraform).
- Para ir a MSK no futuro, basta trocar `KAFKA_BOOTSTRAP_SERVERS` (output) e mover o Connect. As aplicações não mudam.

## Cost considerations

Self-hosted ≈ US$ 0 incremental sobre o platform host, contra ≈ US$ 150/mês
(MSK + MSK Connect) ou ≈ US$ 550/mês (MSK Serverless).
