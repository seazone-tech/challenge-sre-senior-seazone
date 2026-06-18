#!/usr/bin/env python3
"""Agente de triagem de incidente — reduz o toil de "ler 6 arquivos no meio da madrugada".

O que faz:
  1. Coleta as evidencias do incidente (logs, events, describe, metrics, alertas, diff).
  2. REDIGE PII/segredos ANTES de qualquer coisa sair do processo (reservation_id, IPs,
     emails, tokens) — privacy by design.
  3. Monta um prompt estruturado e pede ao Claude uma analise: causa raiz provavel,
     evidencia que sustenta, acao de mitigacao sugerida e nivel de confianca.
  4. Roda em modo --dry-run SEM chamar API nenhuma (offline): imprime o material
     redigido + uma heuristica baseada em regras, util para CI e para nao vazar dados.

Human-in-the-loop: o agente SO SUGERE. Nunca executa rollback nem toca no cluster.
A acao fica com o on-call, que aprova/descarta.

Uso:
  python triage.py --evidence ../../incident --dry-run     # offline, sem custo, sem API
  python triage.py --evidence ../../incident               # chama o Claude (precisa ANTHROPIC_API_KEY)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

# Modelo padrao: Claude Sonnet (bom custo/qualidade para triagem). Para casos dificeis,
# trocar por claude-opus-4-8. IDs validos em jan/2026: claude-sonnet-4-6, claude-opus-4-8.
DEFAULT_MODEL = "claude-sonnet-4-6"

# --------------------------------------------------------------------------------------
# 1) Redacao de PII/segredos — roda SEMPRE, inclusive no dry-run.
# --------------------------------------------------------------------------------------
REDACTIONS = [
    (re.compile(r"rsv_[A-Za-z0-9_]+"), "rsv_<REDACTED>"),          # IDs de reserva
    (re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b"), "<REDACTED_IP>"),   # IPs
    (re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+"), "<REDACTED_EMAIL>"),    # emails
    (re.compile(r"(?i)(authorization|token|secret|password|api[_-]?key)\s*[:=]\s*\S+"),
     r"\1=<REDACTED_SECRET>"),                                       # segredos
]


def redact(text: str) -> str:
    for pattern, repl in REDACTIONS:
        text = pattern.sub(repl, text)
    return text


# --------------------------------------------------------------------------------------
# 2) Coleta das evidencias.
# --------------------------------------------------------------------------------------
EVIDENCE_FILES = [
    "timeline.md",
    "alerts.md",
    "app-logs.jsonl",
    "kubectl-events.txt",
    "kubectl-describe-pod.txt",
    "metrics-snapshot.csv",
    "deployment-diff.md",
]


def collect(evidence_dir: Path) -> dict[str, str]:
    bundle: dict[str, str] = {}
    for name in EVIDENCE_FILES:
        path = evidence_dir / name
        if path.exists():
            bundle[name] = redact(path.read_text(encoding="utf-8"))
        else:
            print(f"[aviso] evidencia ausente: {name}", file=sys.stderr)
    return bundle


# --------------------------------------------------------------------------------------
# 3) Heuristica offline (rule-based) — funciona sem API, serve de baseline e de
#    "validacao de qualidade" para detectar alucinacao do LLM (compara os dois).
# --------------------------------------------------------------------------------------
def heuristic(bundle: dict[str, str]) -> list[str]:
    findings: list[str] = []
    blob = "\n".join(bundle.values())
    if "context deadline exceeded" in blob and "liveness" in blob.lower():
        findings.append("Liveness probe estourando timeout -> restart loop (provavel /healthz lento vs timeout da probe).")
    if "timed out" in blob and "upstream" in blob.lower():
        findings.append("Timeouts de upstream em /reservations -> 504 (verificar UPSTREAM_DELAY_MS vs UPSTREAM_TIMEOUT_MS).")
    if "missing request for cpu" in blob:
        findings.append("HPA sem metrica -> falta resources.requests.cpu no Deployment.")
    if "replicas" in blob and "-  replicas: 2" in blob:
        findings.append("Reducao de replicas 2->1 introduzida no deploy -> SPOF.")
    return findings or ["Nenhum padrao conhecido casou; encaminhar para analise humana."]


# --------------------------------------------------------------------------------------
# 4) Prompt + chamada ao Claude.
# --------------------------------------------------------------------------------------
SYSTEM_PROMPT = (
    "Voce e um SRE assistente de plantao. Recebe evidencias JA REDIGIDAS de um incidente "
    "Kubernetes e produz uma triagem. Regras rigidas:\n"
    "1. Baseie-se SOMENTE nas evidencias fornecidas. Se algo nao estiver nas evidencias, "
    "diga 'nao ha evidencia' — NUNCA invente metricas, logs ou nomes.\n"
    "2. Para cada conclusao, cite o arquivo/linha que a sustenta.\n"
    "3. Termine com um nivel de confianca (alta/media/baixa) e uma acao SUGERIDA, deixando "
    "explicito que a decisao final e do humano on-call.\n"
    "Responda em JSON com as chaves: causa_raiz_provavel, evidencias, fatores_contribuintes, "
    "mitigacao_sugerida, confianca, requer_revisao_humana (sempre true)."
)


def build_user_prompt(bundle: dict[str, str]) -> str:
    parts = ["Evidencias do incidente (redigidas):\n"]
    for name, content in bundle.items():
        parts.append(f"\n===== {name} =====\n{content}")
    return "".join(parts)


def call_claude(bundle: dict[str, str], model: str) -> str:
    try:
        from anthropic import Anthropic
    except ImportError:
        sys.exit("anthropic nao instalado. Rode: pip install -r requirements.txt  (ou use --dry-run)")

    client = Anthropic()  # le ANTHROPIC_API_KEY do ambiente
    resp = client.messages.create(
        model=model,
        max_tokens=1500,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": build_user_prompt(bundle)}],
    )
    return resp.content[0].text


# --------------------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(description="Triagem de incidente assistida por IA.")
    parser.add_argument("--evidence", default="../../incident", help="diretorio com as evidencias")
    parser.add_argument("--dry-run", action="store_true", help="offline: nao chama API, usa heuristica")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    args = parser.parse_args()

    bundle = collect(Path(args.evidence))
    if not bundle:
        sys.exit("Nenhuma evidencia encontrada.")

    print("=" * 70)
    print("TRIAGEM DE INCIDENTE — reservation-api")
    print(f"Evidencias coletadas e REDIGIDAS: {', '.join(bundle)}")
    print("=" * 70)

    print("\n[Heuristica offline — baseline rule-based]")
    for f in heuristic(bundle):
        print(f"  - {f}")

    if args.dry_run:
        print("\n[--dry-run] API nao foi chamada. Prompt que SERIA enviado (ja redigido):\n")
        print(build_user_prompt(bundle)[:1200] + "\n... [truncado]")
        print("\nLembrete: o agente apenas SUGERE. Rollback/acao = decisao do on-call.")
        return

    print(f"\n[Claude {args.model}] analisando...\n")
    result = call_claude(bundle, args.model)
    try:
        print(json.dumps(json.loads(result), indent=2, ensure_ascii=False))
    except json.JSONDecodeError:
        print(result)
    print("\n>>> REVISAO HUMANA OBRIGATORIA antes de qualquer acao no cluster. <<<")


if __name__ == "__main__":
    main()
