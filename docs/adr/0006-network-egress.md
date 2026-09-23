# ADR 0006: Rede e egress (NAT)

- Status: aceito
- Data: 2026-09-23

## Context

Workloads privados precisam de saída HTTPS para ECR (pull de imagens), Secrets Manager,
CloudWatch Logs, SSM, X-Ray e registries públicos (Docker Hub e quay.io para Kafka,
Connect e Collector). Os bancos não precisam de saída nenhuma. ALB e RDS exigem subnets
em pelo menos 2 AZs.

## Decision

- VPC `10.20.0.0/16`, 2 AZs, três camadas de /24: **public** (ALB, NAT), **private** (tasks e platform host, saída via NAT) e **data** (RDS, **sem rota default**).
- Egress configurável por `egress_mode`:
  - `nat_instance` (padrão em dev): `t4g.nano` AL2023 com iptables MASQUERADE, `source_dest_check = false`, SSM em vez de SSH e auto-recover por alarme;
  - `nat_gateway`: NAT Gateway gerenciado, para cenários mais próximos de produção. Um `check` do Terraform avisa quando dev usa NAT Gateway.
- **Gateway endpoint S3** (gratuito): as camadas das imagens do ECR vêm do S3, então a maior parte do tráfego de pull não passa pelo NAT.
- Uma única tabela de rotas privada, ou seja, um único NAT para as 2 AZs.
- Tasks **sem IP público** (`assign_public_ip = false`).
- Default security group da VPC sem nenhuma regra.

## Alternatives

| Opção | Custo/mês | Contras |
|---|---|---|
| **NAT instance** | ~US$ 3,70 (t4g.nano + disco) + US$ 3,65 (IPv4 público) | ponto único de falha; patching por sua conta; banda limitada (suficiente para o lab) |
| NAT Gateway (1 AZ) | ~US$ 32,85 + US$ 0,045/GB | nenhum operacional; é o padrão de produção |
| NAT Gateway por AZ | ~US$ 66 + dados | só se justifica com HA real |
| Interface endpoints (ECR api/dkr, logs, secretsmanager, ssm, ssmmessages, ec2messages, xray) sem NAT | ~US$ 7,30 por endpoint por AZ → **US$ 100+** | mais caro que o NAT e ainda não cobre Docker Hub/quay.io |
| Tasks em subnet pública com IP público | US$ 3,65 por task (~US$ 30) | cada task exposta na internet (mitigado só por SG); anti-padrão |

## Consequences

- Se a NAT instance cair, novos pulls de imagem, leituras de secret e envio de logs falham (tasks já rodando continuam servindo tráfego). Há auto-recover para falha de hardware; para falha de software (iptables), o caminho é substituir a instância (`-replace`).
- Trocar `egress_mode` é uma mudança de rota: gera um plan com substituição explícita e visível, e deve ser feito numa janela.
- Os achados do Trivy AWS-0104 (egress 443 para `0.0.0.0/0`) foram aceitos: os endpoints públicos da AWS não têm CIDR estável, e a alternativa (interface endpoints) custa ~25× mais.

## Cost considerations

Diferença de ~US$ 29/mês entre NAT instance e NAT Gateway, o que para este lab é
~20% do total. Os endereços IPv4 públicos (ALB ×2 + NAT) custam ~US$ 11/mês.
