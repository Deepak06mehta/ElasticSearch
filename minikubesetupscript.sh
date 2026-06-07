minikube stop
minikube delete --all --purge

minikube start \
  --driver=podman \
  --nodes=2 \
  --cpus=6 \
  --memory=10240 \
  --disk-size=50g \
  --kubernetes-version=v1.35.1

minikube addons enable metrics-server
minikube addons enable dashboard
minikube addons enable ingress
minikube addons enable storage-provisioner
minikube addons enable default-storageclass

kubectl get nodes
kubectl get pods -A
kubectl top nodes