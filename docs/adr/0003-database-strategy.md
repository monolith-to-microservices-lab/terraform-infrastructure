# ADR 0003: Estratégia de bancos de dados e segredos

- Status: aceito
- Data: 2026-09-23

## Context

Três PostgreSQL 16 no lab: legacy (`monolith`, fonte da verdade e origem do CDC),
`user_service` e `sales`. O legado precisa de logical decoding (`wal_level=logical`),
slot de replicação, publication e conectividade com o Debezium. A regra de posse
do lab diz que cada serviço é o único escritor do seu banco.

## Decision

- **3 instâncias RDS PostgreSQL 16** `db.t4g.micro`, single-AZ, gp3 20 GiB (autoscaling até 50 GiB), criptografadas, `publicly_accessible = false`, em subnets de dados **sem rota para a internet**.
- **Legado:** parameter group com `rds.logical_replication = 1` (o equivalente RDS de `wal_level=logical`, que também ajusta `max_wal_senders`/`max_replication_slots`), `max_slot_wal_keep_size = 4096` MB e `rds.force_ssl = 1`.
- **Proteção de dados em 3 camadas:** `lifecycle { prevent_destroy = true }` (Terraform), `deletion_protection = true` (API da AWS) e `skip_final_snapshot = false` (snapshot final se algum dia for destruído). Backups automáticos de 3 dias (PITR), gratuitos até o tamanho do banco.
- **Segredos:** senha gerada por `ephemeral "random_password"` e enviada por **atributos write-only** (`password_wo` no RDS, `secret_string_wo` no Secrets Manager). A senha **nunca** aparece no plan nem no `terraform.tfstate`. Rotação: incrementar `db_password_version`.
- O secret de cada banco (`mtm/dev/<db>`) contém `host`, `port`, `dbname`, `username`, `password` e `database_url` (já com o driver certo: psycopg3 ou psycopg2). O ECS injeta só a chave `database_url` como `DATABASE_URL`, porque as aplicações leem exatamente essa variável e não foi preciso mudar código.
- Cada serviço ECS tem seu próprio execution role, com permissão **somente** nos secrets que ele referencia.
- IAM database authentication habilitada (gratuita), para uso futuro de tokens de curta duração por operadores.

### Compatibilidade com Debezium (verificada)

| Requisito | Local | RDS |
|---|---|---|
| `wal_level=logical` | flag `-c` no compose | `rds.logical_replication=1` (parameter group) |
| usuário de replicação | `CREATE ROLE ... REPLICATION` | `GRANT rds_replication TO debezium` (o atributo REPLICATION não é concedível no RDS) |
| publication / slot | `enable-cdc.sh` via `docker exec` | mesmo SQL via SSM port forwarding ([runbook](../runbooks/cdc-bootstrap.md)) |
| TLS | desabilitado | obrigatório (`rds.force_ssl=1`): psycopg usa `sslmode=prefer`; no Debezium, `database.sslmode=require` |
| conectividade | rede Docker | SG do RDS legado aceita somente o SG do platform host e o do monolith-api |

## Alternatives

| Opção | Custo (3 bancos) | Prós | Contras | Veredito |
|---|---|---|---|---|
| **3× RDS single-AZ t4g.micro** | ~US$ 42/mês | gerenciado, backups/PITR, logical replication suportada, métricas de slot no CloudWatch | custo fixo mesmo ocioso (dá para parar por até 7 dias) | **escolhido** |
| 1 RDS com 3 databases | ~US$ 14/mês | 3× mais barato | viola o isolamento por serviço (falha, carga e manutenção compartilhadas); o 2º e 3º database exigiriam SQL fora do Terraform | não, mas é a primeira alavanca se o custo apertar |
| RDS Multi-AZ | ~US$ 84/mês | failover automático | dobra o custo sem ganho de aprendizado nesta fase | não em dev |
| Postgres em container (Fargate/EC2) | ~US$ 0–10/mês incremental | igual ao lab | sem backup/PITR; disco persistente volta ao problema do Kafka; você vira DBA | não |
| Aurora Serverless v2 | mínimo 0,5 ACU ≈ US$ 44/mês **por cluster** | escala | mais caro que t4g.micro para carga de lab | não |

**Secrets Manager × SSM Parameter Store:** Parameter Store SecureString é gratuito,
mas o Secrets Manager (US$ 0,40/secret/mês, US$ 1,60 no total) tem rotação nativa
e injeção de chaves JSON individuais no ECS (`<arn>:database_url::`). Os dois suportam
valores write-only. Pelo valor educacional e pela rotação, escolhi o Secrets Manager.

## Consequences

- `terraform destroy` **falha** em dev enquanto os bancos existirem, e isso é intencional. Destruir exige remover `prevent_destroy`, desligar `db_deletion_protection` e aplicar antes (veja o README, seção Destroy).
- `max_slot_wal_keep_size` troca "disco cheio no legado" por "slot invalidado" quando o Debezium fica parado por muito tempo. Nesse caso o conector precisa de um novo slot, e os dados perdidos no stream são recuperados pela migration-tool (reconciliação). É o trade-off correto: o legado é a fonte da verdade.
- As aplicações conectam como usuário master de cada instância (igual ao lab). O próximo passo é criar um role de aplicação sem privilégios de `rds_superuser`.
- O legado começa **vazio** na AWS: o monólito cria o schema com Alembic no primeiro start. A migração dos dados locais (pg_dump/restore) é um passo de runtime.

## Cost considerations

~US$ 11,68/mês por instância + ~US$ 2,30 de storage gp3 → ~US$ 42/mês. Parar as
instâncias quando não estiver usando economiza ~US$ 35/mês; o storage continua sendo
cobrado, e o RDS religa sozinho depois de 7 dias.
