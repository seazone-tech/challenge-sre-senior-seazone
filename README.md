# Desafio Tecnico SRE Senior - Seazone

Este repositorio contem um desafio tecnico para uma vaga de SRE Senior na Seazone.

O objetivo e avaliar como voce diagnostica um incidente, melhora confiabilidade em Kubernetes, raciocina sobre AWS/EKS e Terraform, comunica decisoes tecnicas e aplica AI para reduzir toil operacional.

## Tempo Esperado

Use um time-box de 8 a 12 horas focadas. Nao e esperado resolver todos os problemas possiveis. Priorizacao, trade-offs e clareza fazem parte da avaliacao.

## Restricoes Importantes

- Nenhuma credencial AWS ou Seazone sera fornecida.
- Nenhum acesso a contas AWS sera fornecido.
- Nao execute `terraform apply`.
- Nao crie recursos cloud reais.
- Nao use dados reais, credenciais ou informacoes privadas em ferramentas externas.
- A parte pratica deve rodar localmente com Docker e kind ou minikube.
- O Terraform representa uma arquitetura-alvo AWS/EKS e deve ser validado localmente.

## Stack

- Python/FastAPI.
- Docker e Docker Compose.
- Kubernetes local com kind ou minikube.
- Terraform para arquitetura-alvo AWS/EKS.

## Cenario

O servico ficticio `reservation-api` ficou instavel apos um deploy recente. Usuarios passaram a observar lentidao, erros intermitentes e indisponibilidade parcial na consulta de reservas.

Voce recebeu:

- API containerizada.
- Manifests Kubernetes com problemas intencionais.
- Terraform simplificado para uma arquitetura AWS/EKS.
- Evidencias simuladas em `incident/`.

## Core Obrigatorio

- Rodar a API localmente com Docker.
- Rodar ou validar os manifests em kind ou minikube.
- Diagnosticar o incidente a partir das evidencias fornecidas.
- Corrigir o caminho principal de confiabilidade em Kubernetes: probes, requests/limits, rollout e disponibilidade basica.
- Definir 1 ou 2 SLIs e pelo menos 1 SLO com janela, objetivo e error budget.
- Validar Terraform com `terraform fmt`, `terraform init -backend=false` e `terraform validate`.
- Entregar um `SOLUTION.md` com decisoes, trade-offs e proposta de AI para reducao de toil.

## Profundidade Opcional

- HPA mais completo.
- Teste de carga com k6 ou ferramenta equivalente.
- Hardening com trivy, checkov, tflint ou ferramenta equivalente.
- Pipeline CI/CD proposto ou esbocado.
- Dashboards, alertas ou runbooks mais detalhados.
- Prototipo simples da automacao com AI.

## Como Rodar Localmente

Instale Docker, kubectl, Terraform e kind ou minikube. O estado inicial contem problemas intencionais; e esperado observar falhas ou comportamento instavel antes das suas correcoes.

Rode os testes da API usando `venv` ou outro ambiente Python equivalente:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r app/requirements.txt
PYTHONPATH=. pytest app/tests -q
```

Rode a API com Docker:

```bash
docker compose up --build
```

Em outro terminal:

```bash
curl http://localhost:8000/healthz
curl http://localhost:8000/readyz
curl http://localhost:8000/metrics
```

Valide Terraform:

```bash
cd infra/terraform
terraform fmt
terraform init -backend=false
terraform validate
```

Exemplo com kind:

O estado inicial dos manifests Kubernetes e intencionalmente instavel. Pods sem Ready ou reinicios no primeiro teste fazem parte do material de diagnostico.

```bash
make kind-create
make kind-load
make k8s-apply
make k8s-status
```

## Definition Of Done

- A API sobe localmente via Docker.
- Os endpoints `/healthz`, `/readyz` e `/metrics` respondem localmente.
- Voce consegue aplicar ou validar os manifests em kind ou minikube.
- Os pods ficam em estado Ready em condicoes normais depois das suas correcoes.
- Probes, requests e limits estao justificados.
- O rollout tem comportamento coerente para evitar indisponibilidade desnecessaria.
- `terraform fmt`, `terraform init -backend=false` e `terraform validate` executam com sucesso, ou desvios estao explicados.
- `SOLUTION.md` inclui diagnostico, mitigacao, prevencao, SLO, proposta AWS/EKS e AI para reducao de toil.
- A entrega nao contem credenciais, dados reais ou dependencia de conta AWS.

## Entrega

O caminho preferido e fork + pull request neste repositorio. Branch ou arquivo compactado podem ser usados se forem combinados durante o processo seletivo.

Escreva sua resposta em portugues do Brasil, salvo combinacao previa em contrario.

Havera uma conversa tecnica de follow-up sobre as decisoes tomadas. Voce deve conseguir explicar e defender a solucao entregue.
