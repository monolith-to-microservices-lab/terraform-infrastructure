# Runbook: CDC no RDS (Debezium)

Configuração de **runtime** que o Terraform deliberadamente não faz
([ADR 0002](../adr/0002-kafka-platform.md)). As identidades do lab são preservadas:
`legacy-cdc-connector`, `legacy_cdc_slot`, `legacy_cdc_publication`,
`legacy.public.users`, `legacy.public.sales`.

Pré-condições: o dev foi aplicado, `services_enabled = true`, e o monolith-api já subiu
uma vez (o Alembic criou `users` e `sales` no legado).

## 1. Túnel até o RDS legado (sem bastion, sem IP público)

O platform host já tem acesso ao legado (é o caminho do Debezium). O SSM encaminha a
porta a partir do seu laptop (precisa do
[Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)):

```powershell
$host_id = terraform -chdir=environments/dev output -raw platform_host_instance_id
$legacy  = (terraform -chdir=environments/dev output -json database_endpoints | ConvertFrom-Json).legacy.address
aws ssm start-session --target $host_id `
  --document-name AWS-StartPortForwardingSessionToRemoteHost `
  --parameters "host=$legacy,portNumber=5432,localPortNumber=15432"
```

## 2. Credenciais (sem copiar para arquivos)

```powershell
$arns = terraform -chdir=environments/dev output -json secret_arns | ConvertFrom-Json
$admin = aws secretsmanager get-secret-value --secret-id $arns.legacy_db --query SecretString --output text | ConvertFrom-Json
$dbz   = aws secretsmanager get-secret-value --secret-id $arns.legacy_debezium --query SecretString --output text | ConvertFrom-Json
$env:PGPASSWORD = $admin.password
```

## 3. Objetos de CDC no legado (idempotente)

Equivalente RDS do `cdc-infrastructure/postgres/enable-cdc.sh`. A diferença é
`GRANT rds_replication` em vez do atributo `REPLICATION`, que não é concedível no RDS.

Salve como `$env:TEMP\cdc-bootstrap.sql` (fora do repositório; o arquivo não contém segredo):

```sql
SHOW rds.logical_replication;   -- deve ser 'on'
SHOW wal_level;                 -- deve ser 'logical'

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'debezium') THEN
    CREATE ROLE debezium WITH LOGIN;
  END IF;
END $$;
ALTER ROLE debezium WITH LOGIN PASSWORD :'dbz_pass';
GRANT rds_replication TO debezium;
GRANT CONNECT ON DATABASE monolith TO debezium;
GRANT USAGE ON SCHEMA public TO debezium;
GRANT SELECT ON TABLE public.users, public.sales TO debezium;

ALTER TABLE public.users REPLICA IDENTITY FULL;
ALTER TABLE public.sales REPLICA IDENTITY FULL;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'legacy_cdc_publication') THEN
    CREATE PUBLICATION legacy_cdc_publication FOR TABLE public.users, public.sales;
  END IF;
END $$;

SELECT pg_create_logical_replication_slot('legacy_cdc_slot', 'pgoutput')
WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'legacy_cdc_slot');
```

A senha entra como variável do psql, não no arquivo:

```powershell
psql "host=localhost port=15432 dbname=monolith user=postgres sslmode=require" `
  -v ON_ERROR_STOP=1 -v dbz_pass="$($dbz.password)" -f "$env:TEMP\cdc-bootstrap.sql"
```

## 4. Registrar o conector

Túnel para o Connect REST (porta 8083 no próprio host):

```powershell
aws ssm start-session --target $host_id --document-name AWS-StartPortForwardingSession `
  --parameters "portNumber=8083,localPortNumber=18083"
```

Config (mesma do lab, com host do RDS, TLS e a senha resolvida **dentro** do worker):

```json
{
  "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
  "tasks.max": "1",
  "database.hostname": "${env:LEGACY_DB_HOST}",
  "database.port": "5432",
  "database.user": "${env:DEBEZIUM_DB_USER}",
  "database.password": "${env:DEBEZIUM_DB_PASSWORD}",
  "database.dbname": "${env:LEGACY_DB_NAME}",
  "database.sslmode": "require",
  "topic.prefix": "legacy",
  "table.include.list": "public.users,public.sales",
  "plugin.name": "pgoutput",
  "slot.name": "legacy_cdc_slot",
  "publication.name": "legacy_cdc_publication",
  "publication.autocreate.mode": "disabled",
  "snapshot.mode": "no_data",
  "tombstones.on.delete": "true",
  "heartbeat.interval.ms": "10000",
  "key.converter": "org.apache.kafka.connect.json.JsonConverter",
  "key.converter.schemas.enable": "false",
  "value.converter": "org.apache.kafka.connect.json.JsonConverter",
  "value.converter.schemas.enable": "false"
}
```

```powershell
Invoke-RestMethod -Method Put -Uri http://localhost:18083/connectors/legacy-cdc-connector/config `
  -ContentType 'application/json' -InFile connector-config.json
Invoke-RestMethod http://localhost:18083/connectors/legacy-cdc-connector/status
```

`PUT .../config` é idempotente: cria ou atualiza, nunca duplica e nunca força um novo
snapshot. O arquivo não contém segredo nenhum.

## 5. Verificar

- `status`: conector e task `RUNNING`.
- Métrica CloudWatch `OldestReplicationSlotLag` do legado estável/baixa.
- Crie um usuário pelo monólito (`POST http://<alb>/users`) e confira no user-service (`GET http://<alb>:8001/users/<id>`).
- Logs: `/ecs/mtm-dev-user-service-cdc` mostra `topic/partition/offset`.

## Rotação da senha do Debezium

1. `debezium_password_version` +1 em `env.auto.tfvars` → plan/apply (novo valor no secret, nunca no state).
2. Repita o `ALTER ROLE debezium ... PASSWORD` do passo 3.
3. Force um novo deployment do serviço Connect (`aws ecs update-service --force-new-deployment`) para reler o secret.
