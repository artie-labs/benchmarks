KUBE_CONTEXT ?= <use your context from kubeconfig, e.g. arn:aws:eks:us-east-1:111222333:cluster/my-eks-cluster>

.PHONY: strimzi_operator
strimzi_operator:
	helm --kube-context $(KUBE_CONTEXT) upgrade \
		 strimzi oci://quay.io/strimzi-helm/strimzi-kafka-operator \
		 -f strimzi/strimzi.yaml \
		 --rollback-on-failure \
		 --install \
		 --create-namespace \
		 --namespace strimzi-operator \
		 --version 0.47.0

.PHONY: kafka
kafka:
	kubectl --context $(KUBE_CONTEXT) apply -f strimzi/user_operator.yaml && \
	kubectl --context $(KUBE_CONTEXT) apply -f strimzi/kafka_cluster.yaml && \
	kubectl --context $(KUBE_CONTEXT) apply -f strimzi/kafka_node_pool_broker.yaml && \
	kubectl --context $(KUBE_CONTEXT) apply -f strimzi/kafka_node_pool_controller.yaml && \
	kubectl --context $(KUBE_CONTEXT) apply -f strimzi/kafka_exporter_service.yaml # since the service's selector is based on the Kafka Exporter Pod's label, we need to apply the service after the Kafka Exporter Pod is created

.PHONY: kafka_secret
kafka_secret:
	kubectl --context $(KUBE_CONTEXT) create secret generic kafka-secret -n kafka --from-literal=KAFKA_SCRAM_PASSWORD=$$(openssl rand -base64 24)

.PHONY: kafka_connector_secrets
kafka_connector_secrets:
	kubectl --context $(KUBE_CONTEXT) apply -f secrets/postgres-credentials.yaml && \
	kubectl --context $(KUBE_CONTEXT) apply -f secrets/snowflake-credentials.yaml

.PHONY: kafka_connect
kafka_connect:
	kubectl --context $(KUBE_CONTEXT) apply -f strimzi/kafka_connect.yaml
