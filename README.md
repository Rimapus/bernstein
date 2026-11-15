<h1 align="center">Bernstein</h1>

<p align="center">
  <strong>A voting application on a kubeadm cluster, provisioned with Ansible and observed with Prometheus, Grafana and Loki.</strong>
</p>

Flask poll -> Redis -> Java worker -> PostgreSQL -> Node result. Ansible
provisions a private registry and the cluster; Kubernetes runs the application.

## Layout

- `ansible/` - registry, cluster, ingress, monitoring and logging.
- `kubernetes/` - Kustomize resources for the application.
- `scripts/` - secret and deployment helpers.
- `tests/` - smoke, chaos and k6 tests.
- `poll-application/` - supplied application source and Dockerfiles, unchanged.

## Prerequisites

- Four Debian 13 hosts: one control plane, two workers, one registry.
- SSH as `kube` with passwordless sudo and the key in
  `ansible/inventory/hosts.ini`.
- Ansible 2.15+, `kubectl`, `make` and `git` on the operator.
- Docker with buildx on the build host; Docker on the machine running
  `make load`.
- `.env` at the repository root, mode `600`.

```sh
ansible-galaxy collection install -r ansible/requirements.yaml
```

## Configuration

```sh
cp .env.example .env
chmod 600 .env
```

| Variable | Used by | Notes |
|---|---|---|
| `REGISTRY_ADMIN_PASSWORD` | zot | administration account |
| `REGISTRY_PUSHER_PASSWORD` | image builds | push access |
| `REGISTRY_PULLER_PASSWORD` | cluster pulls | read-only account |
| `REDIS_PASSWORD` | poll, worker | `openssl rand -hex 32` |
| `POSTGRES_DB` | worker, result | default `poll` |
| `POSTGRES_USER` | worker, result | default `poll` |
| `POSTGRES_PASSWORD` | worker, result | `openssl rand -hex 32` |
| `GRAFANA_ADMIN_PASSWORD` | monitoring | `openssl rand -hex 32` |

`.env` is never committed; all password values are required. If the hosts or the
build machine are outside the cluster network, update `registry_allowed_cidrs`
in `ansible/roles/registry/defaults/main.yaml` before `make infra`.

## Deploy on a fresh cluster

1. Provision:

   ```sh
   make infra
   export KUBECONFIG=~/.kube/bernstein.conf
   ```

   This installs zot, the kubeadm cluster, Calico and the `local-path`
   StorageClass, and writes the admin kubeconfig.

2. Build and push the images on the control plane (it has Docker, buildx, the
   registry CA and the `pusher` login), from a clone of the repository:

   ```sh
   make images TAG=<tag>
   ```

   Any build host works if it trusts `/etc/docker/certs.d/<registry-host>:5000/`
   and is logged in as `pusher`. Use a unique tag for every build: the
   deployments use `imagePullPolicy: IfNotPresent`, so a reused tag is not
   pulled again. `TAG` defaults to `git describe --always --dirty`; pass an
   explicit value.

3. Deploy from the operator machine:

   ```sh
   make up TAG=<tag>
   ```

   `make up` creates the namespace, secrets and pull secret, applies the stack,
   waits for the rollouts, installs ingress-nginx and applies the Ingress
   resources. It does not install metrics-server; run `make metrics` once per
   cluster if you want the HPAs to scale.

On an existing cluster with images already pushed, `make deploy TAG=<tag>` does
the application part and `make ingress` the external part. The Makefile reads
the registry and ingress addresses from `ansible/inventory/hosts.ini`; override
with `make REGISTRY=<host>:<port> INGRESS_IP=<ip>`.

## Access

The ingress is exposed on `INGRESS_IP`, the first worker in the inventory:

- `https://poll.bernstein.local`
- `https://result.bernstein.local`

Add both names to `/etc/hosts`, or use `curl --resolve`. The ingress uses a
private CA written to `~/.kube/bernstein-ingress-ca.crt` by `make ingress`;
browsers must trust it. The CA is written on the machine that runs
`make ingress`; copy it or pass `CACERT=/path/to/ca.crt` when running tests from
another host.

Verify the deployment:

```sh
make smoke
```

## Updates

`make deploy` renders the stack with the requested tag, so a source change is a
normal rolling update:

```sh
TAG=$(git rev-parse --short HEAD)   # commit the change first
make images TAG="$TAG"
make deploy TAG="$TAG"
```

To watch a rollout, run a request loop in another terminal:

```sh
while sleep 0.2; do
  curl -fsS -o /dev/null https://poll.bernstein.local/ || echo "poll failed"
  curl -fsS -o /dev/null https://result.bernstein.local/ || echo "result failed"
done
```

Use the same `--resolve`/`--cacert` options as `make smoke` if needed. Poll and
Result use `maxSurge: 0`, `maxUnavailable: 1`, readiness probes, a `preStop`
delay, a PDB and a `DoNotSchedule` spread. Worker uses the same strategy without
a shutdown hook; Redis and PostgreSQL remain single replicas.

## Tests

```sh
make test    # smoke + Redis chaos
make load    # k6: 100 votes/s for 5 min, then 500 Socket.IO clients
```

`make test` deletes the Redis pod; run it on a test cluster. The load tests run
k6 in Docker and take several minutes.

Useful checks:

```sh
kubectl -n poll-app get pods,pdb,hpa
kubectl -n poll-app get events --sort-by=.lastTimestamp
kubectl -n ingress-nginx get pods
```

## Add-ons

Optional; `make up` does not install them. Run them after the application, in
this order:

```sh
make up TAG=<tag>   # application first
make metrics        # HPA metrics and kubectl top
make monitoring     # Prometheus, Grafana, alerts, dashboards
make logging        # Loki and log collection (requires monitoring)
```

| Target | Namespace | Adds |
|---|---|---|
| `make metrics` | `kube-system` | metrics-server for `kubectl top` and the HPAs |
| `make monitoring` | `monitoring`, `poll-app` | Prometheus, Grafana, Alertmanager, Redis/PostgreSQL exporters, alerts, **Poll application** dashboard |
| `make logging` | `logging`, `monitoring` | Loki, Alloy log collection, Loki datasource, **Poll application logs** dashboard |

Without `make metrics`, the HPAs show `<unknown>` and stay at minimum replicas.
Prometheus and Loki each keep 7 days of data on a 5Gi volume.

### Add-on UIs

Port-forward from another terminal, then open the URL on your machine:

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
```

| UI | URL | Notes |
|---|---|---|
| Grafana | <http://localhost:3000> | `admin`; password from `GRAFANA_ADMIN_PASSWORD` |
| Prometheus | <http://localhost:9090> | queries and scrape targets |
| Alertmanager | <http://localhost:9093> | firing alerts; no external receiver |

Read the Grafana password from the cluster if `.env` is not at hand:

```sh
kubectl -n monitoring get secret grafana-admin \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

Grafana contains the **Poll application** and **Poll application logs**
dashboards. Loki has no UI of its own: use Grafana → Explore → Loki. For the raw
API:

```sh
kubectl -n logging port-forward svc/loki 3100:3100
```

## Rebuild

This destroys the cluster and the local-path data. It is not a Make target. On
each Kubernetes node:

```sh
sudo kubeadm reset -f
sudo systemctl stop kubelet
sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni/net.d
sudo rm -rf /opt/local-path-provisioner
sudo reboot
```

Remove `~/.kube/bernstein.conf` on the operator, then run `make infra` again.
The registry host can stay in place; reimage it too for a clean registry.

## Notes and limitations

- Redis and PostgreSQL are single replicas on node-local `local-path` volumes;
  there is no HA or automatic failover.
- The worker removes a vote from Redis with `BLPOP` before writing it to
  PostgreSQL. A worker killed in that window can lose one vote; the application
  source is unchanged.
- Redis AOF uses `appendfsync everysec`; a host failure can lose up to one
  second of acknowledged votes.
- The supplied Result lockfile has two npm advisories (`body-parser`, `qs`).
  The application source is unchanged, so they are not patched here.
- zot runs outside Kubernetes; the cluster is kubeadm + Calico; ingress-nginx
  uses hostPort and a private CA. There is no cloud load balancer, cert-manager,
  GitOps controller or CI pipeline.

## Credits

See [CREDITS.md](CREDITS.md).

## Academic notice

EPITECH students: do not copy this code. Using it as your own work is cheating and can lead to disciplinary action.
