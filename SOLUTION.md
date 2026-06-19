# Solucao Do Desafio

## Resumo Executivo

O servico `reservation-api` ficou instavel logo apos o deploy da versao `1.7.0`.
A degradacao (p95 de ~280ms para >2400ms, 5xx de 0.3% para 8%+, pod em
CrashLoopBackOff) comecou exatamente no deploy e a versao anterior `1.6.4`
estava saudavel. A causa raiz foi **configuracao**, nao infraestrutura nem pico
de trafego: o deploy alterou probes, variaveis de ambiente e a estrategia de
rollout de forma inconsistente.

Foram corrigidos os manifests de Kubernetes (probes, requests/limits, rollout,
readiness no endpoint correto e variaveis de ambiente coerentes) e o HPA. Apos
as correcoes o deployment fica `2/2 Ready` sem restarts, todos os endpoints
respondem `200` e o HPA passa a coletar metricas (`cpu: 7%/65%`).

Risco remanescente: a aplicacao continua dependente de um upstream simulado;
em producao seria necessario circuit breaker/retry com budget e observabilidade
real (metricas, tracing e alertas com contexto).

## Diagnostico Do Incidente

**Linha do tempo (evidencias em `incident/`)**
- 09:42 deploy `1.7.0`.
- 09:46 primeiro alerta de latencia p95.
- 09:48 5xx sobe de 1% para 8%; pod deixa de ficar Ready.
- 09:51-09:53 falhas repetidas de liveness; pod entra em ciclo de restart.
- 10:02 rollback cogitado, sem criterio documentado.
- 10:11 estabiliza apos reducao manual de trafego (mitigacao fragil).

**Sintomas observados**
- p95 ate ~3100ms, 5xx ate 11.6%, `pod_ready=0`, `pod_restarts=7`
  (`metrics-snapshot.csv`).
- Eventos: `Liveness/Readiness probe failed: context deadline exceeded`,
  `Killing ... failed liveness probe`, `CrashLoopBackOff`.

**Causa raiz (4 defeitos do deploy `1.7.0`, ver `deployment-diff.md`)**
1. **Liveness se autodestroi**: `HEALTH_LATENCY_MS=1200` faz `/healthz`
   responder em ~1,2s, mas a probe tem `timeoutSeconds=1` e
   `failureThreshold=1`. Toda checagem estoura e uma unica falha mata o
   container -> CrashLoopBackOff.
2. **Readiness no endpoint errado**: mudou de `/readyz` para `/healthz` (lento),
   entao o pod nunca fica Ready e sai do Endpoints do Service.
3. **Timeout menor que a latencia da dependencia**: `UPSTREAM_DELAY_MS=900` >
   `UPSTREAM_TIMEOUT_MS=800`, e `/reservations/{id}` passa a retornar `504`.
4. **Rollout sem rede de protecao**: `replicas: 1` com `maxUnavailable: 1` e
   `maxSurge: 0` -> qualquer restart/rollout causa indisponibilidade total.

**Fatores contribuintes**
- Sem `requests`/`limits`: risco de QoS/eviction e HPA quebrado
  (`missing request for cpu`, `cpu: <unknown>/90%`).
- HPA com alvo de 90% (reage tarde).
- Alertas sem versao do deploy, runbook ou dashboard -> rollback sem criterio.

**Como confirmei/descartei hipoteses**
- Descartei infra/trafego: o RPS caiu durante o incidente e a degradacao
  coincide exatamente com a troca de versao (`1.6.4`->`1.7.0`).
- Confirmei (1) e (2) pelos eventos do kubelet e por `lastState` do container
  (`exitCode 0 / Completed` = shutdown gracioso; quem mata e o kubelet).
- Confirmei (3) pelos logs (`reservation lookup timed out`, delay 900/timeout
  800) e pela leitura de `app/main.py`.
- Reproduzi tudo localmente no kind antes de corrigir.

## Mitigacao E Prevencao

**Mudancas feitas no repositorio**
- `k8s/deployment.yaml`:
  - `replicas: 1 -> 2`; `maxUnavailable: 1 -> 0`; `maxSurge: 0 -> 1`.
  - `HEALTH_LATENCY_MS: 1200 -> 0`; `UPSTREAM_DELAY_MS: 900 -> 120`;
    `UPSTREAM_TIMEOUT_MS: 800 -> 1000` (timeout > delay).
  - `readinessProbe` de volta para `/readyz`.
  - liveness/readiness com `timeoutSeconds: 2` e `failureThreshold: 3`;
    `startupProbe` adicionada para proteger o boot.
  - `resources.requests` 50m/64Mi e `limits` 250m/128Mi;
    `terminationGracePeriodSeconds: 30`.
- `k8s/hpa.yaml`: `minReplicas: 2`, `maxReplicas: 5`,
  `averageUtilization: 65`, `behavior.scaleDown.stabilizationWindowSeconds: 300`.

**Justificativa das probes/recursos**
- Liveness reinicia so em falha real (3 falhas em ~30s), evitando matar por
  lentidao transitoria; readiness usa `/readyz` (leve) e tira o pod do balanceto
  sem reinicia-lo; startup cobre o cold start.
- Requests baixos refletem o consumo medido (~3m CPU / ~36Mi) e habilitam o HPA;
  limits dao teto previsivel sem estrangular picos curtos.

**Mitigacao imediata**
- Rollback para `1.6.4` seria a acao mais rapida em producao; aqui a correcao de
  configuracao ja restaura o servico (`rollout` sem indisponibilidade graças a
  `maxSurge: 1`/`maxUnavailable: 0`).

**Prevencao de medio prazo**
- Gate de CI validando probes vs latencia dos endpoints e `timeout > delay`.
- Politica de `requests/limits` obrigatorios (OPA/Kyverno).
- Alertas com contexto (versao, runbook, dashboard) e criterio de rollback
  automatico por error budget.

**Fora de escopo por causa do time-box**
- Circuit breaker/retry no codigo, PodDisruptionBudget, NetworkPolicy, testes de
  carga formais e dashboards completos (esbocados na secao de opcionais).

## SLI, SLO E Error Budget

**SLI 1 - Disponibilidade (sucesso de requisicoes)**
- Definicao: proporcao de respostas nao-5xx em `/reservations`.
- `sum(rate(reservation_api_http_requests_total{status!~"5.."}[5m]))
   / sum(rate(reservation_api_http_requests_total[5m]))`.

**SLI 2 - Latencia**
- Definicao: proporcao de requisicoes com latencia < 1s (p95 como referencia),
  via `reservation_api_http_request_duration_seconds`.

**SLO**
- Disponibilidade: **99.5%** das requisicoes nao-5xx em janela **rolling de 30
  dias**.
- Latencia: **p95 < 1s** na mesma janela.

**Error budget**
- 99.5% em 30 dias = **0.5%** de orcamento de erro (~3h36 de "mau servico"/mes).
- Politica: ao consumir 50% do budget, congelar mudancas nao essenciais; ao
  esgotar, rollback automatico e foco em confiabilidade.

**Como instrumentar e alertar**
- A app ja expoe `/metrics` (Prometheus). Coletar via ServiceMonitor.
- Alertas multi-window/multi-burn-rate (ex.: fast-burn 2% do budget em 1h;
  slow-burn em 6h) com link de runbook e versao do deploy no payload.

## Proposta Para AWS/EKS

O Terraform em `infra/terraform` representa a arquitetura-alvo (VPC, subnets
publicas/privadas, IAM da control plane e `aws_eks_cluster`). Validado com
`terraform fmt`, `terraform init -backend=false` e `terraform validate`
(Success), sem `apply` e sem recursos reais.

**Cluster e node groups**
- EKS gerenciado; managed node groups em subnets privadas, multi-AZ, com
  autoscaling (Cluster Autoscaler ou Karpenter). Considerar nodes Spot para
  workloads tolerantes e On-Demand para baseline.

**Rede**
- Subnets privadas para os nodes + NAT Gateway por AZ; ALB/NLB via AWS Load
  Balancer Controller. Endpoint do cluster preferencialmente privado (o TF atual
  usa `endpoint_public_access` com `0.0.0.0/0` - endurecer para producao).

**IAM e IRSA**
- Habilitar OIDC provider e usar IRSA por ServiceAccount (least privilege) em vez
  de credenciais no pod. Roles separadas para controller, autoscaler e a app.

**Secrets**
- AWS Secrets Manager ou SSM Parameter Store + External Secrets Operator, ou CSI
  Secrets Store; nunca secrets em manifesto/imagem.

**Observabilidade**
- Prometheus (AMP) + Grafana (AMG) para metricas/SLO, OpenTelemetry para tracing,
  CloudWatch/Loki para logs. Dashboards de SLO e alertas por burn-rate.

**Deploy, rollback e CI/CD**
- GitOps (Argo CD) com a imagem versionada; rollout progressivo (Argo Rollouts:
  canary/blue-green) e rollback automatico por SLO/error budget. CI: lint,
  testes, build, scan de imagem e validacao dos manifests/Terraform.

**Custos e riscos**
- Custos: NAT Gateways, control plane EKS, nodes e LBs sao os principais; mitigar
  com Spot, rightsizing (HPA/requests) e consolidacao via Karpenter.
- Riscos: endpoint publico aberto, ausencia de NAT/IRSA e de node group no TF
  atual (apenas exemplo) - tratar antes de produtizar.

## AI Para Reducao De Toil

**Toil alvo**: triagem inicial de incidentes do `reservation-api` (correlacionar
deploy recente, eventos do k8s, logs e metricas) e rascunho de runbook/postmortem.

**Dados usados**: eventos do cluster, logs estruturados da app, metricas
Prometheus e o diff do ultimo deploy - exatamente os artefatos de `incident/`.

**Como evitar vazamento de dados sensiveis**
- Redacao/anonimizacao de PII e segredos antes de enviar ao modelo; usar modelo
  em VPC/privado (Bedrock) com retencao zero; allowlist de campos.

**Validar qualidade e alucinacoes**
- A IA so sugere; toda hipotese vem com a evidencia citada (linha de log/evento).
- Avaliacao offline contra incidentes historicos rotulados; bloquear acoes
  automaticas sem confianca minima.

**Humano no loop**
- A IA propoe causa raiz e rascunho de mitigacao; o on-call aprova qualquer acao
  (rollback, scale). Nenhuma mudanca em producao sem aprovacao humana.

**Metricas que provam valor**
- Reducao de MTTA/MTTR, tempo de redacao de postmortem, % de diagnosticos
  corretos sugeridos e numero de paginacoes evitadas.

## Como Validar

```bash
# Testes da API
python3 -m venv .venv && . .venv/bin/activate
pip install -r app/requirements.txt
PYTHONPATH=. pytest app/tests -q

# Build e cluster local
docker build -t reservation-api:local .
kind create cluster --name seazone-sre-challenge
kind load docker-image reservation-api:local --name seazone-sre-challenge

# metrics-server (HPA no kind)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deployment metrics-server --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# Deploy e validacao
kubectl apply -f k8s/
kubectl -n seazone-challenge rollout status deployment/reservation-api
kubectl -n seazone-challenge get deploy,po,hpa
kubectl -n seazone-challenge top pods

# Endpoints (esperado 200 em todos)
kubectl -n seazone-challenge port-forward svc/reservation-api 18080:80 &
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:18080/healthz
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:18080/readyz
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:18080/reservations/rsv_1
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:18080/metrics

# Terraform (sem apply)
cd infra/terraform && terraform fmt -check && terraform init -backend=false && terraform validate
```

**Resultado esperado**: deployment `2/2 Ready` sem restarts, HPA com metricas
(`cpu: <valor>/65%`), todos os endpoints `200` e Terraform `Success`.
