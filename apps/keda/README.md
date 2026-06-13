# KEDA

Event-driven autoscaler. Used by `apps/pageindex-mcp/worker-scaledobject.yaml`
to scale the PageIndex worker 1↔2 on arq queue depth.

## Install (one-time, cluster-scoped)

    kubectl apply -f apps/keda/namespace.yaml
    helm repo add kedacore https://kedacore.github.io/charts
    helm repo update
    helm install keda kedacore/keda --namespace keda --version 2.x

## Verify

    kubectl get pods -n keda
    kubectl get crd | grep keda.sh   # scaledobjects.keda.sh must exist

## Uninstall

    helm uninstall keda -n keda
