# Evidências de Testes Locais

> Execução real em **2026-06-17**, ambiente: Windows + Docker 28.5.1 + kind v0.24.0 +
> Terraform 1.9.5 + k6 v0.54.0 + Python 3.13. Autor: Christopher Amaral.
>
> Restrições respeitadas: **sem `terraform apply`**, sem recurso AWS real, sem credenciais.

---

## 1. Testes da API (pytest)

```text
$ PYTHONPATH=. pytest app/tests -q
.....                                                                    [100%]
5 passed in 3.57s
```

Cobre, entre outros, o teste que garante **métrica com route-template (sem PII)** —
`test_metrics_use_route_template_instead_of_reservation_id`.

---

## 2. API local via Docker — estado saudável

```text
$ docker compose up --build -d   # imagem reservation-api:local

$ curl /healthz   -> {"status":"ok"}
$ curl /readyz    -> {"status":"ready"}
$ curl /reservations/abc123 -> {"reservation_id":"abc123","status":"confirmed","upstream_delay_ms":120}

$ curl /metrics (amostra):
reservation_api_http_requests_total{method="GET",path="/healthz",status="200"} 1.0
reservation_api_http_requests_total{method="GET",path="/readyz",status="200"} 1.0
reservation_api_http_requests_total{method="GET",path="/reservations/{reservation_id}",status="200"} 1.0
```

> Note `path="/reservations/{reservation_id}"` — o ID real **não** entra na métrica
> (sem vazamento de PII e sem explosão de cardinalidade).

---

## 3. Reprodução do incidente (env do deploy 1.7.0)

```text
$ docker run -d -p 8001:8000 \
    -e UPSTREAM_DELAY_MS=900 -e UPSTREAM_TIMEOUT_MS=800 -e HEALTH_LATENCY_MS=1200 \
    reservation-api:local

$ curl /reservations/abc123
HTTP STATUS: 504 (GatewayTimeout)        # delay 900 > timeout 800

$ curl /healthz  (latência medida)
Latencia /healthz: 1236 ms               # > timeout de probe (1000ms) -> probe mataria o pod
```

Confirma a causa raiz: timeout de upstream invertido (504) + `/healthz` mais lento que a probe.

---

## 4. Terraform (validar, sem aplicar)

```text
$ terraform fmt -check -recursive
fmt OK (sem mudancas)

$ terraform init -backend=false
Terraform has been successfully initialized!   # providers aws + tls baixados

$ terraform validate
Success! The configuration is valid.
```

---

## 5. Kubernetes em kind — pós-correção

```text
$ kind create cluster --name seazone-sre-challenge        # OK
$ kind load docker-image reservation-api:local            # OK
$ kubectl apply -f k8s/
namespace/seazone-challenge created
deployment.apps/reservation-api created
horizontalpodautoscaler.autoscaling/reservation-api created
poddisruptionbudget.policy/reservation-api created
service/reservation-api created

$ kubectl -n seazone-challenge wait --for=condition=ready pod -l app.kubernetes.io/name=reservation-api --timeout=120s
pod/reservation-api-6c46d5f64c-47sqv condition met
pod/reservation-api-6c46d5f64c-5nlsb condition met
pod/reservation-api-6c46d5f64c-95jrf condition met

$ kubectl -n seazone-challenge get deploy,po,hpa,pdb
NAME                              READY   UP-TO-DATE   AVAILABLE
deployment.apps/reservation-api   3/3     3            3

NAME                                   READY   STATUS    RESTARTS   AGE
pod/reservation-api-6c46d5f64c-47sqv   1/1     Running   0          13s
pod/reservation-api-6c46d5f64c-5nlsb   1/1     Running   0          13s
pod/reservation-api-6c46d5f64c-95jrf   1/1     Running   0          13s

NAME (PDB)                                   MIN AVAILABLE   ALLOWED DISRUPTIONS
poddisruptionbudget.policy/reservation-api   2               1
```

**3/3 Ready, 0 restarts** — contra os 7 restarts e `Ready=False` do incidente.

---

## 6. HPA funcionando (com metrics-server)

```text
$ kubectl -n seazone-challenge top pods
NAME                               CPU(cores)   MEMORY(bytes)
reservation-api-6c46d5f64c-47sqv   2m           37Mi
reservation-api-6c46d5f64c-5nlsb   2m           37Mi
reservation-api-6c46d5f64c-95jrf   3m           37Mi

$ kubectl -n seazone-challenge get hpa
NAME              TARGETS                        MINPODS   MAXPODS   REPLICAS
reservation-api   cpu: 2%/70%, memory: 29%/80%   2         6         3

$ kubectl -n seazone-challenge describe hpa reservation-api  (Conditions)
ScalingActive   True   ValidMetricFound   the HPA was able to successfully calculate
                                          a replica count from cpu resource utilization
```

Elimina o erro do incidente `FailedGetResourceMetric: missing request for cpu`.

> Obs.: em kind o metrics-server precisa de `--kubelet-insecure-tls` (certs self-signed
> do kubelet). Em EKS isso é nativo e não se aplica.

---

## 7. Teste de carga k6 (prova o SLO)

```text
$ k6 run loadtest/k6-script.js
     scenarios: 1 scenario, 50 max VUs, 3m30s max duration

     ✓ status 200
     ✓ tem reservation_id

     checks.........................: 100.00% 10894 out of 10894
   ✓ http_req_duration..............: avg=63.82ms  p(95)=126.94ms  max=381.95ms
   ✓ http_req_failed................: 0.00%   0 out of 10894
     http_reqs......................: 10894   60.21/s
     iterations.....................: 5447
```

Thresholds (= SLO) **verdes**: `p95 < 300ms` e `http_req_failed < 0,5%`.

---

## 8. IA — agente de triagem (offline `--dry-run`)

```text
$ python triage.py --evidence ../../incident --dry-run

TRIAGEM DE INCIDENTE — reservation-api
Evidencias coletadas e REDIGIDAS: timeline.md, alerts.md, app-logs.jsonl, ...

[Heuristica offline — baseline rule-based]
  - Liveness probe estourando timeout -> restart loop (...).
  - Timeouts de upstream em /reservations -> 504 (...).
  - HPA sem metrica -> falta resources.requests.cpu no Deployment.
  - Reducao de replicas 2->1 introduzida no deploy -> SPOF.
```

A heurística (sem chamar API) já casa com as 4 falhas reais; a redação de PII roda antes
de qualquer envio.

---

## 9. Hardening — Trivy + Checkov + tflint

Executados localmente (pré-voo) e também no pipeline `ci.yml` (job `security-scan`),
que roda no GitHub Actions do fork em `main`/`feature/**`/`fix/**`.

Os achados foram **tratados** (não apenas reportados): cada um foi **corrigido** ou
**aceito com justificativa escrita** (Checkov `skip`/annotation e `.trivyignore`).

```text
$ tflint --chdir=infra/terraform
(sem issues — exit 0)

$ checkov -d . --framework terraform,kubernetes
terraform:  Passed 49, Failed 0, Skipped 3
kubernetes: Passed 88, Failed 0, Skipped 2

$ trivy config --severity HIGH,CRITICAL .
(0 findings — aceites documentados no .trivyignore)
```

**Corrigidos (ganhos reais):** VPC Flow Logs (`CKV2_AWS_11`), default SG travado
(`CKV2_AWS_12`), KMS key policy (`CKV2_AWS_64`), `automountServiceAccountToken: false`
(`CKV_K8S_38`) e NetworkPolicy default-deny (`CKV2_K8S_6`).

**Aceitos com justificativa (trade-offs da arquitetura-alvo):** endpoint público do EKS
restrito por CIDR (`CKV_AWS_39` / `AWS-0040`), subnets públicas com IP para o LB público
(`CKV_AWS_130` / `AWS-0164`), e `imagePullPolicy`/digest da imagem local do kind
(`CKV_K8S_15` / `CKV_K8S_43`).

Hardening efetivo aplicado nos manifests/IaC: `securityContext` (runAsNonRoot,
readOnlyRootFilesystem, drop ALL), KMS, IRSA, endpoint privado, logs de control plane,
flow logs, default SG travado e NetworkPolicy.

> **Evidência no GitHub Actions (fork):** a run do `CI - reservation-api` passou verde em
> todos os 5 jobs (pytest, docker build, kubeconform, terraform validate, **Trivy + Checkov**)
> na branch `fix/reservation-api-reliability`. O pipeline roda automaticamente em
> `main`/`feature/**`/`fix/**`. Ver aba **Actions** do fork.

---

## Limpeza do ambiente

```bash
docker compose down --remove-orphans
docker rm -f repro-incident 2>/dev/null || true
kind delete cluster --name seazone-sre-challenge
```
