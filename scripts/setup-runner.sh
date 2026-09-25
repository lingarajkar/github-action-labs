#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ARC_CHART_VERSION="${ARC_CHART_VERSION:-0.23.7}"
GHCR_USERNAME="${GHCR_USERNAME:-lingarajkar}"
ARC_SYSTEM_NAMESPACE="arc-systems"
RUNNER_NAMESPACE="arc-runners"
ARC_RELEASE="arc"
RUNNER_RELEASE="github-action-labs-runner"
ARC_CHART_CACHE="$ROOT_DIR/.helm-cache/actions-runner-controller-${ARC_CHART_VERSION}.tgz"

cd "$ROOT_DIR"

for command in curl helm kubectl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$command" >&2
    exit 1
  fi
done

if [[ -z "${GITHUB_PAT:-}" && -f .env ]]; then
  set -a
  . ./.env
  set +a
fi

if [[ -z "${GITHUB_PAT:-}" ]]; then
  printf 'Set GITHUB_PAT or add it to .env before running this script.\n' >&2
  exit 1
fi

token_file=$(mktemp)
trap 'rm -f "$token_file"' EXIT
chmod 600 "$token_file"
printf '%s' "$GITHUB_PAT" > "$token_file"

mkdir -p "$(dirname "$ARC_CHART_CACHE")"
curl --fail --location --retry 5 --retry-all-errors \
  --connect-timeout 30 --max-time 600 \
  --output "$ARC_CHART_CACHE" \
  "https://github.com/actions/actions-runner-controller/releases/download/actions-runner-controller-${ARC_CHART_VERSION}/actions-runner-controller-${ARC_CHART_VERSION}.tgz"

helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update jetstack

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --values deploy/cert-manager/values.yaml \
  --wait

helm upgrade --install "$ARC_RELEASE" "$ARC_CHART_CACHE" \
  --namespace "$ARC_SYSTEM_NAMESPACE" \
  --create-namespace \
  --values deploy/arc-controller/values.yaml \
  --set-file authSecret.github_token="$token_file"

kubectl wait --for=condition=Ready \
  certificate/arc-actions-runner-controller-serving-cert \
  --namespace "$ARC_SYSTEM_NAMESPACE" \
  --timeout=2m
kubectl rollout restart deployment/arc-actions-runner-controller \
  --namespace "$ARC_SYSTEM_NAMESPACE"
kubectl rollout status deployment/arc-actions-runner-controller \
  --namespace "$ARC_SYSTEM_NAMESPACE" \
  --timeout=2m

if ! kubectl get namespace "$RUNNER_NAMESPACE" >/dev/null 2>&1; then
  helm upgrade --install "$RUNNER_RELEASE" deploy/arc-runner \
    --namespace "$RUNNER_NAMESPACE" \
    --create-namespace \
    --set runner.replicas=0
fi

kubectl create secret docker-registry ghcr-pull \
  --namespace "$RUNNER_NAMESPACE" \
  --docker-server=ghcr.io \
  --docker-username="$GHCR_USERNAME" \
  --docker-password="$GITHUB_PAT" \
  --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install "$RUNNER_RELEASE" deploy/arc-runner \
  --namespace "$RUNNER_NAMESPACE" \
  --create-namespace \
  --wait

kubectl get runnerdeployments,runners,pods --namespace "$RUNNER_NAMESPACE"