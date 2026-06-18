# SLI, SLO e Error Budget — reservation-api

> Autor: Christopher Amaral | Stack-alvo: Prometheus + Alertmanager + Grafana

## TL;DR

Dois SLIs (disponibilidade e latencia) medidos a partir das metricas que a propria API
ja expoe em `/metrics`. Um SLO formal de disponibilidade com error budget e alertas por
**burn rate multi-janela** — o padrao do Google SRE Workbook, que evita tanto alarme-fadiga
quanto deteccao tardia.

---

## Por que estes SLIs

A API ja instrumenta dois sinais perfeitos para SLI (em `app/main.py`):

- `reservation_api_http_requests_total{method,path,status}` — Counter por status HTTP.
- `reservation_api_http_request_duration_seconds` — Histogram de latencia.

Ambos usam o **template da rota** (`/reservations/{reservation_id}`), nao o ID real — o
que evita explosao de cardinalidade **e** vazamento de PII no metric store. O `test_app.py`
ja garante isso (`test_metrics_use_route_template_instead_of_reservation_id`).

---

## SLI 1 — Disponibilidade (request success rate)

| Campo | Valor |
| --- | --- |
| **SLI** | `requests nao-5xx / total de requests` no caminho `/reservations/{reservation_id}` |
| **Janela** | 30 dias rolling |
| **SLO (objetivo)** | **99,5%** |
| **Error budget** | 0,5% = **~3h36min/mes** de indisponibilidade tolerada |
| **Racional** | API de consulta de reservas e user-facing mas tem retry no cliente; 99,5% equilibra confiabilidade e velocidade de entrega. 99,9% exigiria multi-AZ + remocao de toda fonte de SPOF e reduziria muito o budget para mudancas. |

Durante o incidente o 5xx chegou a **8,2%** (`alerts.md`) — ~16x o threshold. Um unico
incidente desses por mes consumiria mais de 100% do budget mensal, o que dispararia
congelamento de deploy (politica de error budget).

## SLI 2 — Latencia (request latency)

| Campo | Valor |
| --- | --- |
| **SLI** | `% de requests com latencia < 300ms` (a partir do histogram) |
| **Janela** | 28 dias rolling |
| **SLO (objetivo)** | **95%** dos requests < 300ms |
| **Racional** | p95 saudavel pre-incidente era ~280ms (`metrics-snapshot.csv`). 300ms preserva a experiencia atual com margem. No incidente o p95 foi a 3100ms. |

---

## Politica de Error Budget

- **Budget saudavel (> 0):** time pode lancar livremente.
- **Budget esgotado (<= 0):** congela features; so entram correcoes de confiabilidade
  ate o budget se recuperar. (Mesma logica do "rollback sem criterio" que faltou no
  incidente — agora o gatilho e objetivo, nao subjetivo.)

---

## Como instrumentar e alertar (burn rate multi-janela)

Em vez de alertar "5xx > 2%", alertamos sobre a **velocidade de consumo do budget**. Isso
captura tanto o incidente catastrofico (queima rapida) quanto a degradacao lenta (queima
lenta) sem inundar o on-call. Regras prontas em [`prometheus-rules.yaml`](./prometheus-rules.yaml):

| Alerta | Janelas | Burn rate | Severidade | Significado |
| --- | --- | --- | --- | --- |
| `FastBurn` | 5m **e** 1h | > 14,4x | page (critical) | Consome o budget de 30d em ~2 dias — incidente agudo (foi o caso do 1.7.0) |
| `SlowBurn` | 30m **e** 6h | > 6x | ticket (warning) | Degradacao sustentada — investigar no horario comercial |

> **Ponto importante:** o alerta exige as DUAS janelas simultaneas (curta confirma que
> ainda esta acontecendo agora; longa filtra ruido). Isso resolve direto a falha de
> observabilidade citada em `alerts.md`: os alertas originais nao tinham versao, runbook
> nem dashboard. As regras aqui incluem `annotations` com `summary`, `runbook_url` e
> `dashboard`.

### Dashboard

[`grafana-dashboard.json`](./grafana-dashboard.json) traz 4 paineis: RPS por status, taxa
de 5xx, p95/p99 de latencia e budget de erro consumido na janela. Importavel direto no
Grafana (datasource Prometheus).

### Coleta

- Com **Prometheus Operator**: aplicar [`servicemonitor.yaml`](./servicemonitor.yaml).
- Sem operator: as annotations `prometheus.io/scrape` no Deployment ja permitem scrape
  via service discovery classico.
