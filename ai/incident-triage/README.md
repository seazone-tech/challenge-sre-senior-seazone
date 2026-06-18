# AI para reducao de toil — Agente de Triagem de Incidente

> Protótipo funcional. Autor: Christopher Amaral.

## O toil que isso elimina

Hoje, quando o pager toca às 3h, o on-call abre **6+ fontes** (alerta, `kubectl events`,
`describe pod`, logs, métricas, diff do deploy), correlaciona tudo na cabeça e só então
forma uma hipótese. Isso é **toil**: repetitivo, manual, sob pressão, propenso a erro — e
foi exatamente o que atrasou o incidente do `1.7.0` (a `timeline.md` mostra rollback
"considerado" só às 10:02, 20 min após o primeiro alerta).

O agente faz a primeira passada de correlação em segundos e entrega uma **triagem
estruturada**: causa raiz provável, evidência que a sustenta, mitigação sugerida e nível
de confiança — para o humano decidir mais rápido.

## Como rodar

```bash
# Offline, sem custo e sem API (recomendado para avaliar — não vaza nada):
python triage.py --evidence ../../incident --dry-run

# Com o Claude (precisa ANTHROPIC_API_KEY no ambiente):
pip install -r requirements.txt
export ANTHROPIC_API_KEY=...      # nunca commitar
python triage.py --evidence ../../incident
```

## Decisões de design (defensáveis no follow-up)

| Preocupação | Como tratei |
| --- | --- |
| **Quais dados** | Só as evidências de `incident/` (logs, events, describe, métricas, diff, alertas). Nada de banco de produção. |
| **Vazamento de PII/segredos** | `redact()` roda **antes** de qualquer envio: mascara `reservation_id`, IPs, emails e segredos. Privacy by design — o mesmo princípio das métricas com route-template (sem ID no Prometheus). |
| **Alucinação** | O system prompt proíbe inventar dados e **exige citação da evidência**. Além disso, uma **heurística offline rule-based** roda em paralelo como baseline — divergência grande entre LLM e heurística é sinal de alerta. |
| **Humano no loop** | O agente **só sugere**. Nunca executa rollback nem toca no cluster. `requer_revisao_humana` é sempre `true`. |
| **Custo/modelo** | Sonnet por padrão (custo/qualidade); Opus para casos difíceis. `--dry-run` tem custo zero. |

## Como provaria valor (métricas)

- **MTTR** (tempo até mitigação) antes/depois — meta: reduzir a janela de ~20 min do incidente.
- **% de triagens com causa raiz correta** (validada no post-mortem).
- **Horas de toil economizadas** no on-call por mês.
- **Taxa de falso-positivo** da sugestão (rejeitadas pelo humano).

## Evolução natural

Empacotar como **MCP server** ("incident-context") que o Claude Code consome, plugado no
Alertmanager (dispara no `FastBurn`), postando a triagem num canal de Slack com botões
*aprovar rollback / descartar* — mantendo o humano no loop. Alinhado à plataforma de IA
interna da Seazone (LiteLLM Hub / MCP Hub / AI Portal).
