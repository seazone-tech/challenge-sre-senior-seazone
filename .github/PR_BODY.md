# SRE Senior Challenge — reservation-api reliability fix

Solução do desafio técnico de Especialista de SRE. Resposta principal: [`SOLUTION.md`](SOLUTION.md).

## TL;DR

O deploy `1.7.0` introduziu **5 regressões simultâneas**. Corrigi o caminho de
confiabilidade no Kubernetes, defini SLO com error budget + alertas por burn rate,
endureci o Terraform-alvo e adicionei diferenciais (CI, k6, runbook, IA para toil).

## Causa raiz (resumo)

| # | Regressão | Efeito |
| --- | --- | --- |
| 1 | `/healthz` lento (1,2s) vs liveness `timeout=1s/failureThreshold=1` | restart loop |
| 2 | readiness movida `/readyz` → `/healthz` (lenta) | `Ready=False` |
| 3 | `UPSTREAM_DELAY_MS=900` > `UPSTREAM_TIMEOUT_MS=800` | 100% de 504 |
| 4 | sem `requests/limits` | HPA quebrado |
| 5 | `replicas 2→1` + rollout sem surge | SPOF + downtime |

## O que mudou

- **`k8s/`** — probes corretas, `requests/limits`, `replicas:3`, rollout zero-downtime,
  `securityContext`, graceful shutdown, topology spread, **HPA** corrigido, **PDB**.
- **`slo/`** — SLO + error budget, PrometheusRule (burn rate), dashboard Grafana, ServiceMonitor.
- **`infra/terraform/`** — IRSA, KMS, endpoint privado + público restrito (era `0.0.0.0/0`),
  logs de control plane, managed node group. `fmt`/`init -backend=false`/`validate` OK.
- **`.github/workflows/ci.yml`** — pytest, kubeconform, terraform validate, Trivy/Checkov/tflint.
- **`loadtest/k6-script.js`** — prova o SLO sob carga.
- **`docs/runbook-reservation-api.md`** — referenciado pelos alertas.
- **`ai/incident-triage/`** — protótipo de triagem com redação de PII e humano no loop.

## Restrições respeitadas

- ❌ Sem `terraform apply` / sem recurso AWS real.
- ❌ Sem credenciais, dados reais ou PII.
- ✅ Parte prática roda local com Docker + kind.

## Como validar

Ver a seção **Como Validar** do [`SOLUTION.md`](SOLUTION.md). Evidências reais em [`evidencias/`](evidencias/) e [`docs/evidencias-testes.md`](docs/evidencias-testes.md).

## Referência

Prior art do padrão GitOps + ArgoCD + Terraform proposto na seção AWS/EKS: lab pessoal de Platform Engineering [chris-platform](https://github.com/chris-amaral/chris-platform).
