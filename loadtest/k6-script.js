// Teste de carga k6 para o reservation-api.
//
// POR QUE: um SLO so vale se for provado sob carga. Este script valida que, DEPOIS das
// correcoes, o servico sustenta o SLO (5xx < 0.5%, p95 < 300ms) — e serve para reproduzir
// a degradacao do incidente injetando os envs ruins (UPSTREAM_DELAY_MS > TIMEOUT_MS).
//
// Uso:
//   1) API local:   docker compose up --build
//   2) Carga:        k6 run loadtest/k6-script.js
//   3) Reproduzir incidente: rode a API com UPSTREAM_DELAY_MS=900 UPSTREAM_TIMEOUT_MS=800
//      e rode o k6 de novo — os thresholds abaixo vao FALHAR (5xx explode), provando o SLI.
//
// BASE_URL configuravel: k6 run -e BASE_URL=http://localhost:8000 loadtest/k6-script.js

import http from "k6/http";
import { check, sleep } from "k6";

const BASE_URL = __ENV.BASE_URL || "http://localhost:8000";

export const options = {
  scenarios: {
    // Rampa: aquece, sobe a 50 VUs, sustenta, desce. Exercita o HPA em cenario EKS real.
    ramp: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "30s", target: 20 },
        { duration: "1m", target: 50 },
        { duration: "1m", target: 50 },
        { duration: "30s", target: 0 },
      ],
    },
  },
  // Thresholds = o SLO codificado. Se violar, o k6 sai com codigo != 0 (gate de CI).
  thresholds: {
    http_req_failed: ["rate<0.005"], // SLO disponibilidade: < 0.5% de erro
    http_req_duration: ["p(95)<300"], // SLO latencia: p95 < 300ms
  },
};

export default function () {
  const id = `rsv_${Math.floor(Math.random() * 100000)}`;

  const res = http.get(`${BASE_URL}/reservations/${id}`);
  check(res, {
    "status 200": (r) => r.status === 200,
    "tem reservation_id": (r) => r.body && r.body.includes("reservation_id"),
  });

  // Probe de health para refletir o trafego real do balanceador.
  http.get(`${BASE_URL}/healthz`);

  sleep(1);
}
