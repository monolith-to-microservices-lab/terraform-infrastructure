# ADR 0001: Plataforma de compute

- Status: aceito
- Data: 2026-09-23

## Context

Workloads encontrados na auditoria ([current-state.md](../current-state.md)):

- 3 APIs HTTP stateless (FastAPI): monolith-api, user-service-api, sales-service-api.
- 2 consumers CDC sem HTTP (`python -m app.cdc`), que usam a mesma imagem das APIs.
- Kafka (KRaft) e Kafka Connect/Debezium: JVM, **stateful**, e o Kafka precisa de disco persistente.
- OTel Collector.

Prioridades declaradas: arquitetura realista, baixo custo, simplicidade operacional e aprendizado DevOps.

## Decision

**Amazon ECS** como orquestrador único, com dois tipos de capacidade:

1. **Fargate** (capacity provider `FARGATE_SPOT` em dev) para as APIs e os consumers CDC.
2. **ECS on EC2** com um único "platform host" (`t3.medium`, ECS-optimized AL2023) para Kafka, Kafka Connect e OTel Collector. Os dados do Kafka ficam num volume EBS **separado da instância** (`prevent_destroy`), montado em `/data`. A instância pode ser substituída (AMI nova, user_data novo) sem perder tópicos, offsets ou o estado do Connect.

Tudo é descrito como task definitions e serviços ECS no Terraform, e fica visível no state e no plan.

## Alternatives

| Opção | Custo base (us-east-1) | Prós | Contras | Veredito |
|---|---|---|---|---|
| **ECS Fargate** | ~US$ 9/mês por task 0.25 vCPU/0.5 GB (~US$ 3 em Spot) | zero servidores, IAM por task, integra com ALB/Cloud Map | sem disco persistente de verdade (EBS gerenciado pelo ECS é descartado ao parar a task; EFS não é suportado pelo Kafka) | **sim, para stateless** |
| **ECS on EC2** | ~US$ 30/mês (t3.medium) para vários containers | disco EBS persistente, vários JVMs num host só | patching de AMI, capacidade manual | **sim, para stateful** |
| **EKS** | **US$ 73/mês só de control plane** + nós | padrão de mercado, ecossistema K8s | dobra o custo do lab antes de rodar qualquer coisa; add-ons (LB controller, EBS CSI, IRSA) viram trabalho antes do objetivo | não: Kubernetes não é o objeto de estudo desta fase |
| **EC2 + docker compose** | ~US$ 30–60/mês | reaproveita os compose files | o estado desejado fica fora do Terraform (containers "escondidos"); sem rolling deploy, sem health check integrado ao ALB | não: fere "Terraform como fonte da verdade" |

## Consequences

- Kafka, Connect e OTel usam `network_mode = host` no platform host: portas fixas e deploy "stop-then-start" (`minimum_healthy_percent = 0`). Um restart do Kafka interrompe o CDC por segundos, igual ao lab local.
- O platform host é ponto único de falha do plano CDC. Há mitigação: alarme de `StatusCheckFailed_System` com ação `ec2:recover` (mesma instância, mesmo IP, mesmos volumes) e o `max_slot_wal_keep_size` no legado limita o WAL acumulado.
- Containers em `host` network conseguem alcançar o IMDS da instância. Por isso o role da instância só tem as políticas do agente ECS e do SSM, e o boundary impede ampliar isso.
- Fargate Spot pode interromper tasks (aviso de 2 min). As APIs têm drenagem de 20s. Os consumers usam commit manual pós-transação, então o reprocessamento é seguro. Para demos longas, use `fargate_capacity_provider = "FARGATE"`.
- Migrar para EKS no futuro reaproveita imagens, secrets, RDS e rede. Só o módulo `compute` mudaria.

## Cost considerations

Fargate (5 tasks, Spot) ~US$ 14/mês + platform host ~US$ 34/mês (instância + EBS) contra
~US$ 73 só do control plane do EKS. Veja [cost-estimate.md](../cost-estimate.md).
