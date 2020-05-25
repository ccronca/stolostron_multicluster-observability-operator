#!/bin/bash
# Copyright (c) 2020 Red Hat, Inc.

export WAIT_TIMEOUT=${WAIT_TIMEOUT:-5m}
export KUBECONFIG=$HOME/.kube/kind-config-hub
kubectl config set-context --current --namespace open-cluster-management

wait_for_popup() {
    n=1
    while true
    do
        entity=`kubectl get $1 $2 | grep -v Name | awk '{ print $1 }'`
        if [[ ! -z $entity ]]; then
            return
        fi
        if [[ $n -ge 10 ]]; then
            exit 1
        fi
        n=$((n+1))
        echo "Retrying in 10s..."
        sleep 10
    done
}

run_test_readiness() {
    echo "Test to ensure all critical pods are running"

    MULTICLUSTER_MONITORING_CR_NAME="monitoring"

    MULTICLUSTER_MONITORING_DEPLOYMENTS="multicluster-monitoring-operator"
    GRAFANA_DEPLOYMENTS="grafana"
    MINIO_DEPLOYMENTS="minio"

    OBSERVATORIUM_DEPLOYMENTS="$MULTICLUSTER_MONITORING_CR_NAME-observatorium-observatorium-api $MULTICLUSTER_MONITORING_CR_NAME-observatorium-observatorium-api-thanos-query $MULTICLUSTER_MONITORING_CR_NAME-observatorium-cortex-query-frontend $MULTICLUSTER_MONITORING_CR_NAME-observatorium-thanos-query $MULTICLUSTER_MONITORING_CR_NAME-observatorium-thanos-receive-controller"

    OBSERVATORIUM_STATEFULSET="$MULTICLUSTER_MONITORING_CR_NAME-observatorium-thanos-compact $MULTICLUSTER_MONITORING_CR_NAME-observatorium-thanos-receive-default $MULTICLUSTER_MONITORING_CR_NAME-observatorium-thanos-rule $MULTICLUSTER_MONITORING_CR_NAME-observatorium-thanos-store-memcached $MULTICLUSTER_MONITORING_CR_NAME-observatorium-thanos-store-shard-0"

    for depl in ${MULTICLUSTER_MONITORING_DEPLOYMENTS}; do
        if ! kubectl -n open-cluster-management rollout status deployments $depl --timeout=$WAIT_TIMEOUT; then 
            echo "$depl is not ready after $WAIT_TIMEOUT"
            exit 1
        fi
    done

    echo "wait for operator is ready for reconciling..."

    for depl in ${MINIO_DEPLOYMENTS}; do
        wait_for_popup "deployments" $depl
        if ! kubectl -n open-cluster-management rollout status deployments $depl --timeout=$WAIT_TIMEOUT; then 
            echo "$depl is not ready after $WAIT_TIMEOUT"
            exit 1
        fi
    done


    for depl in ${OBSERVATORIUM_DEPLOYMENTS}; do
        wait_for_popup "deployments" $depl
        if ! kubectl -n open-cluster-management rollout status deployments $depl --timeout=$WAIT_TIMEOUT; then 
            echo "$depl is not ready after $WAIT_TIMEOUT"
            exit 1
        fi
    done


    for depl in ${OBSERVATORIUM_STATEFULSET}; do
        wait_for_popup "statefulset" $depl
        if ! kubectl -n open-cluster-management rollout status statefulset $depl --timeout=$WAIT_TIMEOUT; then 
            echo "$depl is not ready after $WAIT_TIMEOUT"
            exit 1
        fi
    done

    for depl in ${GRAFANA_DEPLOYMENTS}; do
        wait_for_popup "deployments" $depl
        if ! kubectl -n open-cluster-management rollout status deployments $depl --timeout=$WAIT_TIMEOUT; then 
            echo "$depl is not ready after $WAIT_TIMEOUT"
            exit 1
        fi
    done
}

# test grafana replicas changes
run_test_scale_grafana() {
    kubectl patch MultiClusterMonitoring monitoring --patch '{"spec":{"grafana":{"replicas":2}}}' --type=merge

    n=1
    while true
    do
        # check there are 2 grafana pods here
        replicas=`kubectl get deployment grafana | grep -v AVAILABLE | awk '{ print $4 }'`
        if [[ $replicas -eq 2 ]]; then
            echo "grafana replicas is update to 2 successfully."
            break
        fi
        if [[ $n -ge 10 ]]; then
            echo "grafana replicas changes test is failed."
            exit 1
        fi
        n=$((n+1))
        echo "Retrying in 10s..."
        sleep 10
    done
}

run_test_teardown() {
    kubectl delete -n open-cluster-management MultiClusterMonitoring monitoring
    kubectl delete -n open-cluster-management deployment/grafana-test
    kubectl delete -n open-cluster-management service/grafana-test
    kubectl delete -n open-cluster-management -f deploy/
    target_count="0"
    timeout=$true
    interval=0
    intervals=600
    while [ $interval -ne $intervals ]; do
      echo "Waiting for cleaning"
      count=$(kubectl -n open-cluster-management get all | wc -l)
      if [ "$count" = "$target_count" ]; then
        echo NS count is now: $count
	    timeout=$false
	    break
	  fi
	  sleep 5
	  interval=$((interval+5))
    done

    if [ $timeout ]; then
      echo "Timeout waiting for namespace to be empty"
      exit 1
    fi
}

run_test_reconciling() {
    kubectl patch MultiClusterMonitoring monitoring --patch '{"spec":{"observatorium":{"compact":{"retentionResolutionRaw":"14d"}}}}' --type=merge

    n=1
    while true
    do
        # check the changes were applied into observatorium
        retention=`kubectl get observatorium monitoring-observatorium -ojsonpath='{.spec.compact.retentionResolutionRaw}'`
        if [[ $retention == '14d' ]]; then
            echo "Change retentionResolutionRaw to 14d successfully."
            break
        fi
        if [[ $n -ge 5 ]]; then
            echo "Change retentionResolutionRaw is failed."
            exit 1
        fi
        n=$((n+1))
        echo "Retrying in 2s..."
        sleep 2
    done
}

run_test_access_grafana() {
    n=1
    while true
    do
        RESULT=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: grafana.local" -H "X-Forwarded-User: test" http://127.0.0.1/)
        if [ "$RESULT" -eq "200"  ]; then
            echo "grafana can be accessible."
            break
        fi
        if [ $n -ge 5 ]; then
            exit 1
        fi
        n=$((n+1))
        echo "Retrying in 10s..."
        sleep 10
    done
    
}

run_test_access_grafana_dashboard() {
    RESULT=$(curl -s -H "Host: grafana.local" -H "X-Forwarded-User: test"  http://127.0.0.1/api/search?folderIds=1 | jq '. | length')
    if [ "$RESULT" -eq 10  ]; then
        echo "There are 10 dashboards in default folder."
    else
        echo "The dashboard number is not equal to 10 in default folder."
        exit 1
    fi
}

run_test_readiness
run_test_reconciling
run_test_scale_grafana
run_test_access_grafana
run_test_access_grafana_dashboard
run_test_teardown