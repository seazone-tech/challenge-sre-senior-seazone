# Runbook — reservation-api

> Autor: Christopher Amaral | Servico: reservation-api | Namespace: `seazone-challenge`
> Princípio: **DETECTAR → MITIGAR → RESOLVER → DOCUMENTAR** (estanca o sangramento primeiro, investiga depois).

Este runbook e referenciado pelos alertas (`runbook_url` em [`slo/prometheus-rules.yaml`](../slo/prometheus-rules.yaml)).

---

## Alerta: `ReservationApiErrorBudgetFastBurn` (critical / page)

### Detectar
```bash
kubectl -n seazone-challenge get deploy,po,hpa
kubectl -n seazone-challenge get events --sort-by=.lastTimestamp | tail -20
```

### Mitigar (imediato)
```bash
# 1. Houve deploy recente? Essa e a causa mais provavel (foi a do 1.7.0).
kubectl -n seazone-challenge rollout history deploy/reservation-api

# 2. Rollback para a revisao estavel anterior — CRITERIO OBJETIVO: se burn rate > 14.4x
#    apos um deploy, faca rollback primeiro, investigue depois.
kubectl -n seazone-challenge rollout undo deploy/reservation-api

# 3. Confirme recuperacao
kubectl -n seazone-challenge rollout status deploy/reservation-api
```

### Resolver (causa raiz — tabela do incidente 1.7.0)

| Sintoma | Causa provavel | Verificacao | Correcao |
| --- | --- | --- | --- |
| `context deadline exceeded` na liveness; restarts | `/healthz` mais lento que o timeout da probe | `kubectl describe pod` → eventos Unhealthy | Aumentar `timeoutSeconds`/`failureThreshold`; remover latencia artificial (`HEALTH_LATENCY_MS`) |
| 100% de 504 em `/reservations` | `UPSTREAM_DELAY_MS` > `UPSTREAM_TIMEOUT_MS` | `kubectl describe pod` → env | Garantir `DELAY` < `TIMEOUT` |
| HPA `FailedGetResourceMetric` | falta `requests.cpu` | `kubectl describe hpa` | Definir `resources.requests` |
| Pod `Ready=False` permanente | readiness apontando p/ endpoint lento | comparar probe vs endpoint | Readiness em `/readyz` |
| 5xx durante rollout | `maxUnavailable>0` + 1 replica | `kubectl get deploy -o yaml` | `maxUnavailable:0/maxSurge:1` + replicas>=3 + PDB |

### Documentar
Abrir post-mortem (blameless), registrar consumo de error budget e, se esgotado, acionar
a politica de congelamento de deploy (ver [`slo/slo.md`](../slo/slo.md)).

---

## Alerta: `ReservationApiErrorBudgetSlowBurn` (warning / ticket)

Degradacao sustentada, sem urgencia de page. Investigar em horario comercial:
```bash
# Latencia por percentil
kubectl -n seazone-challenge port-forward svc/reservation-api 8080:80
# em outro terminal: curl -s localhost:8080/metrics | grep duration_seconds
```
Causas comuns: dependencia upstream degradada, saturacao de CPU (ver HPA), vazamento lento.

---

## Alerta: `ReservationApiPodRestarting`

```bash
kubectl -n seazone-challenge logs -l app.kubernetes.io/name=reservation-api --previous --tail=50
kubectl -n seazone-challenge describe pod -l app.kubernetes.io/name=reservation-api | grep -A15 Events
```
- `OOMKilled` → revisar `resources.limits.memory`.
- Probe falhando → revisar probes (ver tabela acima).

---

## Validacao pos-correcao

```bash
make k8s-status
kubectl -n seazone-challenge wait --for=condition=ready pod \
  -l app.kubernetes.io/name=reservation-api --timeout=120s
# Carga: confirma SLO sob trafego
k6 run loadtest/k6-script.js
```
