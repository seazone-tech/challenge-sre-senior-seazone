# Alertas Simulados

## APIHighLatency

- Severidade: warning
- Servico: reservation-api
- Janela: 5 minutos
- Mensagem: p95 HTTP latency above threshold
- Valor observado: 2.4s
- Threshold: 1.0s

## APIFiveXXRate

- Severidade: critical
- Servico: reservation-api
- Janela: 5 minutos
- Mensagem: HTTP 5xx rate above threshold
- Valor observado: 8.2%
- Threshold: 2.0%

## KubernetesPodRestarts

- Severidade: warning
- Servico: reservation-api
- Janela: 10 minutos
- Mensagem: pod restart count increased
- Valor observado: 7 restarts
- Threshold: 3 restarts

Observacao: os alertas nao incluem versao do deploy, mudanca recente, runbook ou link para dashboard.
