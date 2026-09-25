# GitHub Actions Labs

This repository contains GitHub Actions examples and the source-controlled configuration for a repository-scoped self-hosted runner on Kubernetes. The runner is managed by Actions Runner Controller (ARC) and is available to `lingarajkar/github-action-labs` with the `github-action-labs` label.

No command in this repository deploys resources automatically. Review and run the commands below from your own terminal when you are ready.

## Repository layout

| Path | Purpose |
| --- | --- |
| `.github/workflows/` | GitHub Actions workflows that run on the self-hosted runner. |
| `docker/runner/Dockerfile` | Custom GitHub Actions runner image. |
| `deploy/arc-controller/values.yaml` | Helm values for the ARC controller. |
| `deploy/arc-runner/` | Helm chart that creates the repository runner. |
| `.env` | Local-only GitHub PAT source. This file is ignored by Git. |

## Prerequisites

1. A Kubernetes cluster and a `kubectl` context pointing at it.
2. Helm 3.
3. Docker with permission to push to GitHub Container Registry (GHCR).
4. A GitHub fine-grained personal access token restricted to `lingarajkar/github-action-labs` with **Administration: Read and write** permission.
5. Permission to create Kubernetes namespaces, secrets, and Helm releases.

Check the local tools and cluster context before continuing:

```bash
kubectl config current-context
kubectl get nodes
helm version --short
docker version --format '{{.Server.Version}}'
```

## 1. Store the GitHub token locally

Keep the PAT out of Git and Kubernetes manifests. Create or update `.env` locally:

```bash
printf 'GITHUB_PAT=%s\n' 'replace-with-your-token' > .env
chmod 600 .env
```

Load it only in the terminal session that needs it:

```bash
set -a
. ./.env
set +a
test -n "$GITHUB_PAT"
```

The `.env` file is ignored by Git. Do not add the PAT to Helm values, workflow files, Dockerfiles, or commits.

## 2. Build and publish the runner image

The runner image extends `summerwind/actions-runner` with `ca-certificates`, `curl`, and `git`.

Authenticate Docker to GHCR, then build and publish the image:

```bash
printf '%s' "$GITHUB_PAT" | docker login ghcr.io -u lingarajkar --password-stdin

docker build \
	--tag ghcr.io/lingarajkar/github-action-labs-runner:v1.0.0 \
	docker/runner

docker push ghcr.io/lingarajkar/github-action-labs-runner:v1.0.0
```

The chart is pinned to `v1.0.0` in `deploy/arc-runner/values.yaml`. For every image change, publish a new tag and update `runner.image.tag` before upgrading the runner chart.

### Publish with GitHub Actions

`.github/workflows/publish-runner-image.yaml` publishes the same image to GHCR using the repository `GITHUB_TOKEN`; no personal access token is stored in GitHub Actions secrets. It deliberately uses GitHub-hosted `ubuntu-latest` so the first runner image can be published before the self-hosted runner exists.

To publish a release image, create and push a new version tag. The tag becomes the image tag:

```bash
git tag v1.0.1
git push origin v1.0.1
```

Alternatively, run **Publish runner image** from the GitHub Actions tab and enter an unused version such as `v1.0.1`. After it succeeds, update `runner.image.tag` in `deploy/arc-runner/values.yaml` to the same version before upgrading the runner chart.

## 3. Add the ARC Helm repository

```bash
helm repo add actions-runner-controller \
	https://actions-runner-controller.github.io/actions-runner-controller
helm repo add jetstack https://charts.jetstack.io
helm repo update
```

Validate the repository runner chart before installation:

```bash
helm lint deploy/arc-runner
helm template github-action-labs-runner deploy/arc-runner
```

## 4. Install cert-manager

ARC requires cert-manager to provide the `Certificate` and `Issuer` resources used for its serving certificate. Helm creates the `cert-manager` namespace and installs the CRDs from the tracked values file.

```bash
helm upgrade --install cert-manager jetstack/cert-manager \
	--namespace cert-manager \
	--create-namespace \
	--values deploy/cert-manager/values.yaml \
	--wait
```

Verify cert-manager is ready before installing ARC:

```bash
kubectl get pods --namespace cert-manager
kubectl get crd certificates.cert-manager.io issuers.cert-manager.io
```

## 5. Install Actions Runner Controller

Helm creates the `arc-systems` namespace and the `controller-manager` secret. The PAT is passed from the current shell using `--set-file`; it is not written to a values file.

```bash
helm upgrade --install arc \
	actions-runner-controller/actions-runner-controller \
	--namespace arc-systems \
	--create-namespace \
	--values deploy/arc-controller/values.yaml \
	--set-file authSecret.github_token=<(printf '%s' "$GITHUB_PAT") \
	--wait
```

If a previous setup created `controller-manager` with `kubectl`, delete that old secret before running this command. Helm will recreate it with the current PAT and its required ownership metadata:

```bash
kubectl delete secret controller-manager --namespace arc-systems
```

Verify the secret exists without displaying its value:

```bash
kubectl get secret controller-manager --namespace arc-systems
```

Check that the controller is ready:

```bash
kubectl get pods --namespace arc-systems
helm list --namespace arc-systems
```

## 6. Install the repository runner

The custom runner image is private in GHCR. Create the `ghcr-pull` secret from a token with package read access before installing the chart:

```bash
kubectl create secret docker-registry ghcr-pull \
	--namespace arc-runners \
	--docker-server=ghcr.io \
	--docker-username=lingarajkar \
	--docker-password="$GITHUB_PAT" \
	--dry-run=client -o yaml | kubectl apply -f -
```

The secret is referenced by `runner.imagePullSecrets` in `deploy/arc-runner/values.yaml` and is not stored in Git.

```bash
helm upgrade --install github-action-labs-runner \
	deploy/arc-runner \
	--namespace arc-runners \
	--create-namespace \
	--wait
```

The chart creates a `RunnerDeployment` named `github-action-labs` for `lingarajkar/github-action-labs`.

Verify the runner resources and registration:

```bash
kubectl get runnerdeployments --namespace arc-runners
kubectl get runners --namespace arc-runners
kubectl get pods --namespace arc-runners
```

GitHub also lists the runner under **Settings** > **Actions** > **Runners** for this repository.

## 7. Run the workflows

The workflows in `.github/workflows/` use this label:

```yaml
runs-on: github-action-labs
```

Push a change to `main` or run either workflow manually from the GitHub Actions tab. While a job is executing, inspect the runner pod:

```bash
kubectl get pods --namespace arc-runners --watch
kubectl logs --namespace arc-systems deployment/arc-actions-runner-controller
```

## 8. Maintain the runner

Update `deploy/arc-runner/values.yaml` to change the repository, image, runner label, or steady-state runner count. Apply a reviewed change with:

```bash
helm lint deploy/arc-runner
helm upgrade github-action-labs-runner deploy/arc-runner \
	--namespace arc-runners \
	--wait
```

Before updating the controller chart, review available versions:

```bash
helm search repo actions-runner-controller/actions-runner-controller --versions
```

## 9. Remove runner resources

To remove the repository runner but retain the cluster and ARC controller:

```bash
helm uninstall github-action-labs-runner --namespace arc-runners
```

To remove ARC as well, first remove the repository runner, then run:

```bash
helm uninstall arc --namespace arc-systems
kubectl delete namespace arc-runners arc-systems
```

Deleting the namespaces removes the controller secret. It does not delete Kubernetes nodes or the cluster itself.
