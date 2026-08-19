# MyK8s

A Flask app that tells a joke and names the pod that served it, used to learn Kubernetes
deployment mechanics. The `(Served by: ...)` line in each response is the pod's hostname,
which makes replica scheduling and load balancing visible from a browser.

    app.py           the Flask app -- one route, five jokes
    Dockerfile       two-stage build; gunicorn serves the app in the runtime image
    build.ps1        wraps `docker build` with the district TLS/DNS workarounds
    deployment.yaml  2 replicas of myk8s:dev
    service.yaml     type: LoadBalancer, port 80 -> targetPort 8080

## Running locally

    .\build.ps1                                      # produces myk8s:dev
    kubectl apply -f deployment.yaml -f service.yaml
    kubectl get pods -l app=myk8s -o wide

Then open a tunnel and leave it running:

    kubectl port-forward svc/myk8s-service 8080:80

and in a second terminal:

    curl.exe http://localhost:8080/

`build.ps1` exists because the district network breaks container builds two ways -- TLS
interception and IPv4-less DNS answers. Its header comment explains both; read that before
changing anything about how the image is built.

## Why port-forward, and not the NodePort

`service.yaml` declares `type: LoadBalancer`, so `kubectl get svc` shows
`EXTERNAL-IP: <pending>` permanently, and the allocated NodePort is not reachable from
Windows. Neither is a misconfiguration. Both follow from how this cluster is built.

Docker Desktop provisions Kubernetes through kind, which runs each node as a container
inside the Docker Desktop VM -- the node's own `providerID` reads
`kind://docker/desktop/desktop-control-plane`. So there are two boundaries between a
NodePort and the Windows host, and nothing bridges the outer one:

    Windows                                  <- nothing listening on the NodePort
    +- Docker Desktop VM
       +- container "desktop-control-plane"   <- node, 172.18.0.3, unroutable from Windows
       +- container "desktop-worker"          <- node, 172.18.0.2, NodePort listens HERE

Measured on this cluster: `curl localhost:<nodePort>` from inside `desktop-worker` returns
HTTP 200, while the same port on Windows has no listener and the node IP answers nothing.
kind publishes host ports only when the cluster is created with `extraPortMappings`, and
this one was not. The node containers are also absent from `docker ps` -- Docker Desktop
keeps them in an internal context -- so a port cannot be published after the fact either.

`EXTERNAL-IP: <pending>` is the same gap seen from above: `type: LoadBalancer` waits for a
cloud controller to assign an external address, and there is none here. The NodePort still
gets allocated, which is why a port number appears at all.

`kubectl port-forward` sidesteps both boundaries by listening on Windows directly and
tunnelling through the API server. It is also what you would use against a real remote
cluster, so it is not a throwaway habit.

Two things it will not do. It binds one pod for the life of the tunnel, so the
`(Served by: ...)` hostname never changes no matter how many replicas exist -- to see the
Service actually load balance, hit it from inside the cluster:

    kubectl exec deploy/myk8s-deployment -- python -c "
    import urllib.request
    for _ in range(8):
        print(urllib.request.urlopen('http://myk8s-service/').read().decode().splitlines()[1])
    "

That execs into a pod that is already running rather than starting a throwaway `curl`
container, because this cluster cannot pull images -- see below. It reaches the Service by
name over cluster DNS, and both pod hostnames show up across eight requests.

And it holds the terminal; `Forwarding from 127.0.0.1:8080 -> 8080` means it is working,
not hung.

## Traps worth remembering

**`8080:80`, not `8080:8080`.** For `svc/...` the right-hand port is the Service's `port`
(80), not its `targetPort`. Using 8080 fails with `Service myk8s-service does not have a
service port 8080`. kubectl then reports `-> 8080` because it resolved 80 through to the
targetPort, which reads like an echo of what you typed but is not. Forwarding to a
`pod/...` instead does take `8080:8080`, since pods have no port-80 indirection.

**`curl.exe`, not `curl`.** In PowerShell `curl` is an alias for `Invoke-WebRequest`, which
turns a plain connection refusal into a wall of `WebCmdletWebResponseException`.

**Both pods land on `desktop-worker`.** `desktop-control-plane` carries a
`node-role.kubernetes.io/control-plane:NoSchedule` taint, so it takes no workload. Scaling
`replicas` up schedules everything onto the single worker.

**This cluster cannot pull external images.** Docker Desktop points the node's containerd
at a local registry mirror that currently answers 500, so any pod whose image is not already
on the node fails:

    failed to resolve reference "docker.io/curlimages/curl:latest": unexpected status from
    HEAD request to http://registry-mirror:1273/v2/... : 500 Internal Server Error

`myk8s:dev` works only because Docker Desktop shares its image store with the kind nodes, so
a local `docker build` lands in the node's containerd (`crictl images` inside the node lists
`docker.io/library/myk8s:dev`), and `imagePullPolicy: IfNotPresent` stops the kubelet from
consulting the registry at all. On a stock kind cluster this would additionally need
`kind load docker-image myk8s:dev`. Anything
pulled from Docker Hub -- a debug container, an ingress controller, a Helm chart's images --
will sit in `ImagePullBackOff`. Debug with the app's own image, or with `kubectl exec` into a
running pod, until the mirror is fixed.

**Scale by editing the file, not `kubectl scale`.** An imperative scale leaves
`deployment.yaml` claiming the old count, and the next `kubectl apply` silently reverts it.

## What would change on AKS

Nothing about `app.py`, the Dockerfile, or the shape of the manifests -- that portability is
the point. What changes is the image reference, the pull credentials, and the production
concerns this repo currently skips. Placeholders below are marked `<...>`.

Push the image to a registry the cluster can read. Building in Azure avoids pushing layers
over the district connection:

    az acr create -n <registry> -g <resource-group> --sku Basic
    az acr build -r <registry> -t myk8s:1.0 .

Grant the cluster pull rights. Skipping this is the usual cause of `ImagePullBackOff`:

    az aks update -n <cluster> -g <resource-group> --attach-acr <registry>

Then point `deployment.yaml` at the registry and **delete the `imagePullPolicy` line**:

    image: <registry>.azurecr.io/myk8s:1.0

`imagePullPolicy: IfNotPresent` is here so kind uses the locally built `myk8s:dev` instead
of trying to pull it. On AKS it means "if anything with this tag is already cached on the
node, do not check the registry" -- so republishing a tag can leave pods serving stale code.
Use immutable version tags and let the default policy apply. Never `:latest`.

Also build for amd64 (`docker build --platform linux/amd64`) if the build host is ARM; AKS
node pools are amd64 by default and a mismatch fails at runtime with `exec format error`.

`service.yaml` then works as written: `type: LoadBalancer` provisions a real Azure load
balancer and `EXTERNAL-IP` resolves within about a minute. No port-forward needed.

Real deployments do all of the above from CI rather than a workstation -- a pipeline
triggered by a push to `main`, so every deploy traces to a commit and does not depend on
anyone's laptop being logged in.

## Known gaps

Deliberate, because they are not needed to learn scheduling and networking -- but all three
are required before anything like this carries traffic:

- **No `resources` requests/limits.** Both pods are BestEffort: the scheduler places them
  blind and they are first to be evicted under node pressure. Sizing note for later --
  gunicorn's workers are forked, so their RSS figures double-count the shared interpreter.
  Summing them over-provisions by more than half.
- **No readiness or liveness probe.** Without a readiness probe the Service adds a pod to
  its endpoints the moment the container starts, before gunicorn has booted its workers, so
  a rolling update briefly routes traffic to a pod that will refuse the connection.
- **No Ingress.** A `LoadBalancer` per Service does not scale past a handful; real clusters
  put one ingress controller at the edge and route by hostname and path, terminating TLS
  there. `kubectl get ingressclass` is empty here, so an Ingress object would sit inert --
  and installing a controller is blocked by the image-pull problem above, since every
  controller ships as a Docker Hub image.
