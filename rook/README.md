# Rook Ceph

Rook-managed Ceph cluster with OSDs on worker02 and worker03 only (pools are replicated with size 2, failure domain host). Each OSD sits on an LVM logical volume `/dev/ceph-<node>/osd` that fills a USB disk (see [OSD disks](#osd-disks-lvm-on-usb)) — see `storage.nodes` in `rook-ceph-cluster-values.yml`.

## Files

- `application.yml` — `rook-ceph` operator (wave 0, CRDs + CSI operator bundled)
- `rook-ceph-cluster-controller.yml` — `rook-ceph-cluster` CephCluster, pools, storage classes (wave 1)
- `ceph-csi-drivers-controller.yml` — `ceph-csi-drivers` RBD/CephFS drivers (wave 1)
- `rook-ceph-ingress-controller.yml` — `rook-ceph-ingress` (wave 2): Traefik ingress, kept separate because it needs Traefik and cert-manager installed
- `dashboard-lb.yml` — LoadBalancer Service for the Ceph dashboard (HTTPS, 8443)
- `ingress/ingress.yml` — Traefik Ingress + cert-manager certificate (`letsencrypt-production`) at https://rook.apps.k8s.enros.me (preferred access; Traefik re-encrypts to the dashboard over HTTPS via `ingress/serverstransport.yml`)
- `ingress/serverstransport.yml` — Traefik ServersTransport (skips verify of the dashboard's self-signed cert)

## Prerequisites

Each storage node needs its LV `/dev/ceph-<node>/osd` created first (see below); OSDs are only created on the devices named in `storage.nodes`.

## OSD disks (LVM on USB)

The OSD disks are USB-attached. `ceph-volume` rejects USB devices (`id_bus`) and Rook has no setting to override it, so each disk is wrapped in an LVM logical volume and Rook is pointed at `/dev/ceph-<node>/osd` instead. The nodes run Talos (no SSH, no LVM tooling on the host), so the LVM metadata is created from a privileged pod pinned to the node. `rook-ceph` is PSA-privileged, so the pod is admitted.

| Node | Disk | VG / LV |
|------|------|---------|
| ctpl03 | `sda` | `ceph-ctpl03/osd` (created, not used - see below) |
| worker01 | `sda` | `ceph-worker01/osd` (created, not used - see below) |
| worker02 | `sdb` | `ceph-worker02/osd` |
| worker03 | `sda` | `ceph-worker03/osd` |

Run per node (`NODE=ctpl03|worker01|worker03`, `DISK=/dev/sda`; worker02 used `/dev/sdb`). **This destroys everything on the disk.**

```bash
NODE=ctpl03; DISK=/dev/sda

# 1. Privileged pod on the node with the host /dev mounted. Public DNS because
#    cluster DNS failed to resolve the Alpine mirrors (apk "DNS lookup error").
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: lvm-$NODE, namespace: rook-ceph}
spec:
  nodeName: $NODE
  hostPID: true
  restartPolicy: Never
  dnsPolicy: None
  dnsConfig: {nameservers: ["1.1.1.1"]}
  containers:
    - name: lvm
      image: alpine:3.20
      command: ["sleep", "3600"]
      securityContext: {privileged: true}
      volumeMounts: [{name: dev, mountPath: /dev}]
  volumes: [{name: dev, hostPath: {path: /dev}}]
EOF
kubectl -n rook-ceph wait --for=condition=Ready pod/lvm-$NODE --timeout=180s

# 2. Tooling, then confirm the by-id link from storage.nodes maps to $DISK and the disk is blank
kubectl -n rook-ceph exec lvm-$NODE -- apk add --no-cache lvm2 sgdisk lsblk blkid
kubectl -n rook-ceph exec lvm-$NODE -- sh -c "ls -l /dev/disk/by-id | grep usb; lsblk $DISK; blkid $DISK*; pvs; vgs"

# 3. Wipe and build PV -> VG -> LV (whole disk) and create the device nodes
kubectl -n rook-ceph exec lvm-$NODE -- sh -c "
  sgdisk --zap-all $DISK && wipefs -a $DISK &&
  pvcreate -ff -y $DISK &&
  vgcreate ceph-$NODE $DISK &&
  lvcreate -y -l 100%FREE -n osd ceph-$NODE &&
  vgchange -ay ceph-$NODE && vgmknodes ceph-$NODE &&
  ls -l /dev/ceph-$NODE/ && lvs"

# 4. Remove the pod; the device-mapper device stays on the host
kubectl -n rook-ceph delete pod lvm-$NODE
```

ctpl03, worker01 and worker03 were done this way on 2026-10-21 (all three disks were already blank, so no extra `dd` wipe was needed; each LV is ~974.6 GiB). worker02 was done earlier the same way. Then set `devices: [{name: /dev/ceph-<node>/osd}]` per node in `rook-ceph-cluster-values.yml` and restart the operator so it re-runs the osd-prepare jobs:

```bash
kubectl -n rook-ceph rollout restart deploy/rook-ceph-operator
kubectl -n rook-ceph get pods -l app=rook-ceph-osd -o wide
```

**ctpl03 and worker01 are not in `storage.nodes`.** Their OSD pods (4Gi request each) stayed `Pending` with `Insufficient memory`: worker01 has ~2.9 GiB allocatable (~0.5 GiB free) and ctpl03 ~1.46 GiB (~0.5 GiB free). Their LVs exist but are unused; re-add the nodes only once they have the memory (or after lowering the OSD `resources`). Because only two hosts carry OSDs, every pool uses `replicated.size: 2` (the object store data pool is replicated, not erasure coded, since EC 2+1 needs three hosts).

**The workers are CPU-bound** (worker02/03: ~3.3 of 3.75 CPU requested), so the CephFS MDS runs as a single daemon (`activeStandby: false`) requesting 250m CPU / 1Gi memory instead of the 1 CPU / 4Gi default, which could not schedule.

**Adding more disks to worker02/worker03:** repeat the procedure above for the new disk with a distinct VG/LV name (e.g. `ceph-worker02-b/osd`) and add it to that node's `devices` list.

**Reboot persistence is unverified.** Talos does not run `vgchange -ay` at boot. Rook's OSD pod runs `ceph-volume lvm activate`, which should re-activate the LV, but test it: `talosctl reboot --nodes <ip>`, then confirm that node's OSD returns to `up`.

## Deploy

If `bootstrap/application.yml` is applied, merging to `main` deploys all three apps. Otherwise apply the Applications by hand, in order:

```bash
kubectl apply -f rook/application.yml                       # operator + CRDs (wave 0)
kubectl -n rook-ceph rollout status deploy/rook-ceph-operator
kubectl apply -f rook/rook-ceph-cluster-controller.yml \
              -f rook/ceph-csi-drivers-controller.yml      # CephCluster, pools, StorageClasses, dashboard LB, CSI drivers (wave 1)
kubectl apply -f rook/rook-ceph-ingress-controller.yml    # Traefik ingress (wave 2) - only once Traefik + cert-manager are installed
```

The cluster app is what creates the Ceph cluster and consumes the disks listed in `storage.nodes`, so check the disks first. Allow 10-15 minutes for the mons, mgrs and OSDs to come up.

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

- No OSDs: check `kubectl -n rook-ceph logs -l app=rook-ceph-osd-prepare`. A rejection reason `["id_bus"]` means the disk is USB: use the LVM procedure above. For old signatures (GPT headers, exfat), run `sgdisk --zap-all` and `wipefs -a` from the privileged pod.
- Dashboard service has no endpoints: the selector targets the active mgr (`mgr_role=active`); wait for the mgr to become active.
- Pods rejected with `violates PodSecurity "baseline:latest"`: the cluster enforces PSA baseline by default, but Ceph needs privileged pods. `application.yml` labels the `rook-ceph` namespace `pod-security.kubernetes.io/enforce: privileged` via `managedNamespaceMetadata`; if you created the Application before this was added, re-apply `rook/application.yml`.
