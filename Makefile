APP_IMAGE ?= reservation-api:local
KIND_CLUSTER ?= seazone-sre-challenge

.PHONY: test docker-build docker-run kind-create kind-load k8s-apply k8s-status terraform-validate clean

test:
	PYTHONPATH=. pytest app/tests -q

docker-build:
	docker build -t $(APP_IMAGE) .

docker-run:
	docker compose up --build

kind-create:
	kind create cluster --name $(KIND_CLUSTER)

kind-load: docker-build
	kind load docker-image $(APP_IMAGE) --name $(KIND_CLUSTER)

k8s-apply:
	kubectl apply -f k8s/

k8s-status:
	kubectl -n seazone-challenge get deploy,po,svc,hpa

terraform-validate:
	cd infra/terraform && terraform fmt -check && terraform init -backend=false && terraform validate

clean:
	docker compose down --remove-orphans
