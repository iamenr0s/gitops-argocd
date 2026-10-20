# Rook Ceph

Rook-managed Ceph cluster using the raw disk `/dev/sdb` on worker01-03 only (`storage.nodes` in `rook-ceph-cluster-values.yml`).

## Files

- `application.yml` — `rook-ceph` operator (wave 0, CRDs + CSI operator bundled)
- `rook-ceph-cluster-controller.yml` — `rook-ceph-cluster` CephCluster, pools, storage classes (wave 1)
- `ceph-csi-drivers-controller.yml` — `ceph-csi-drivers` RBD/CephFS drivers (wave 1)
- `dashboard-lb.yml` — LoadBalancer Service for the Ceph dashboard (HTTPS, 8443)
- `ingress.yml` — Traefik Ingress + cert-manager certificate (`letsencrypt-production`) at https://rook.apps.k8s.enros.me (preferred access; Traefik re-encrypts to the dashboard over HTTPS via `serverstransport.yml`)
- `serverstransport.yml` — Traefik ServersTransport (skips verify of the dashboard's self-signed cert)

## Prerequisites

`/dev/sdb` on each node must be an empty raw disk (no partitions, filesystem or LVM signatures); OSDs are only created on `sdb`.

## Deploy

If `bootstrap/application.yml` is applied, merging to `main` deploys all three apps. Otherwise apply the Applications by hand, in order:

```bash
kubectl apply -f rook/application.yml                       # operator + CRDs (wave 0)
kubectl -n rook-ceph rollout status deploy/rook-ceph-operator
kubectl apply -f rook/rook-ceph-cluster-controller.yml \
              -f rook/ceph-csi-drivers-controller.yml      # CephCluster, pools, StorageClasses, dashboard LB/ingress, CSI drivers (wave 1)
```

The cluster app is what creates the Ceph cluster and consumes `/dev/sdb` on worker01-03, so check the disks first. Allow 10-15 minutes for the mons, mgrs and OSDs to come up.

## Dashboard

```bash
kubectl -n rook-ceph get svc rook-ceph-mgr-dashboard-lb   # EXTERNAL-IP, https://<ip>:8443
kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath='{.data.password}' | base64 -d   # user: admin
```

## Verification

```bash
kubectl -n rook-ceph get cephcluster
kubectl -n rook-ceph get pods -l app=rook-ceph-osd
```

## Troubleshooting

- No OSDs: check `kubectl -n rook-ceph logs -l app=rook-ceph-osd-prepare`; wipe the disk with `sgdisk --zap-all /dev/sdb` if it has old signatures.
- Dashboard service has no endpoints: the selector targets the active mgr (`mgr_role=active`); wait for the mgr to become active.
