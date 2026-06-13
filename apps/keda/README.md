# KEDA

Event-driven autoscaler. Used by `apps/pageindex-mcp/worker-scaledobject.yaml`
to scale the PageIndex worker 1↔2 on arq queue depth.

## Install (one-time, cluster-scoped)

    kubectl apply -f apps/keda/namespace.yaml
    helm repo add kedacore https://kedacore.github.io/charts
    helm repo update
    # Latest stable. To pin: `helm search repo kedacore/keda --versions`, then add --version <x.y.z>.
    helm install keda kedacore/keda --namespace keda

## Verify

    kubectl get pods -n keda
    kubectl get crd | grep keda.sh   # scaledobjects.keda.sh must exist

## Uninstall

    helm uninstall keda -n keda
