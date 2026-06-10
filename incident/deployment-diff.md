# Mudanca Recente

Trecho simplificado da mudanca aplicada no deploy `1.7.0`:

```diff
 spec:
-  replicas: 2
+  replicas: 1
   strategy:
     rollingUpdate:
-      maxUnavailable: 0
-      maxSurge: 1
+      maxUnavailable: 1
+      maxSurge: 0
   containers:
     - name: reservation-api
       env:
+        - name: HEALTH_LATENCY_MS
+          value: "1200"
+        - name: UPSTREAM_DELAY_MS
+          value: "900"
+        - name: UPSTREAM_TIMEOUT_MS
+          value: "800"
       livenessProbe:
         httpGet:
           path: /healthz
         timeoutSeconds: 1
+        failureThreshold: 1
       readinessProbe:
         httpGet:
-          path: /readyz
+          path: /healthz
         timeoutSeconds: 1
+        failureThreshold: 1
```
