# Kadalu Storage

Deploys the Kadalu operator and storage pool configuration via Kustomize. Provides a GlusterFS-backed CSI storage class (`kadalu.kadalu-pool-replica3`) used by other apps.

## Structure

```
application.yml                  # ArgoCD Application — local kustomize path
kustomization.yml                # Includes operator manifest and kadalu-storage-generator.yml
kadalu-storage-generator.yml     # Storage pool configuration
```

## Deploy

Commit and push — Argo CD will sync to namespace `kadalu`.

## Verification

```bash
# Operator pods
kubectl -n kadalu get pods

# Storage class available
kubectl get sc

# Test PVC binding
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: kadalu-test
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: kadalu.kadalu-pool-replica3
  resources:
    requests:
      storage: 1Gi
EOF
kubectl get pvc kadalu-test
kubectl delete pvc kadalu-test
```

## Disk selection

No device path is hard-coded. The `kadalu-disk-discovery` DaemonSet (privileged) runs on every node (only the control-plane/master `NoSchedule` taints are tolerated; other taints keep the pod off) except nodes labelled `kadalu-storage-skip=true`. Exclude a node with `kubectl label node <n> kadalu-storage-skip=true`, include it again with `kubectl label node <n> kadalu-storage-skip-`. On each node it picks the first whole disk that is empty: no partitions, not held by LVM/md, and the first and last 1 MiB all zero. The result goes into the ConfigMap `kadalu-disk-discovery` under the node name (`none` if nothing qualifies); an existing entry is never changed. The `kadalu-storage-generator` Job waits until every such node has reported, then builds the `KadaluStorage` from the nodes that have a disk.

```bash
kubectl -n kadalu get cm kadalu-disk-discovery -o jsonpath='{.data}'
# to force a re-pick on a node (disk must be blank): remove its key, restart its pod
kubectl -n kadalu patch cm kadalu-disk-discovery --type merge -p '{"data":{"<node>":null}}'
kubectl -n kadalu delete pod -l app=kadalu-disk-discovery --field-selector spec.nodeName=<node>
```

The Job only runs on sync and the operator does not change devices of an existing `KadaluStorage`; after changing disks delete the `kadalustorage` and the Job, then re-sync.

## Notes

- Storage class name: `kadalu.kadalu-pool-replica3`
- Required by: harbor, influxdb, keycloak, mariadb, openldap, postgresql, posta

## Troubleshooting

- **Operator not ready**: ensure cluster nodes meet Kadalu requirements and GlusterFS brick paths are reachable.
- **PVC stuck Pending**: check Kadalu operator logs and storage pool health.

### Stale GlusterFS FUSE mount (`MountVolume.SetUp failed ... Exception calling application: [1]`)

**Symptom**: A pod is stuck with `FailedMount` and the Kadalu nodeplugin log shows:
```
Mountpoint /mnt/kadalu-pool-replica3 seems to have a stale mount, run 'umount /mnt/kadalu-pool-replica3' and try again.
```

**Cause**: After a node restart or nodeplugin pod restart, a leftover GlusterFS FUSE mount at `/mnt/kadalu-pool-replica3` inside the nodeplugin container blocks all new mounts on that node.

**Fix**: Identify which node the pod is scheduled on, find the nodeplugin on that node, and force-unmount:

```bash
# Find the failing pod's node
kubectl -n <namespace> get pods -o wide

# Find the nodeplugin on that node
kubectl -n kadalu get pods -o wide | grep nodeplugin

# Force-unmount the stale mount (replace pod name with the one on the failing node)
kubectl -n kadalu exec <kadalu-csi-nodeplugin-XXXXX> -c kadalu-nodeplugin -- umount -f /mnt/kadalu-pool-replica3
```

The kubelet will retry the mount automatically within ~2 minutes. If the pod remains stuck, delete it to trigger an immediate retry.

### Discovery reports `none` for a node whose disk "has been wiped" (fake-capacity USB disk)

**Symptom**: `kubectl -n kadalu get cm kadalu-disk-discovery -o jsonpath='{.data}'` shows `"<node>":"none"` for a node with a blank-looking disk. The generator Job then builds a `KadaluStorage` with fewer than 3 nodes, the operator logs `Invalid number of storage directories/devices specified`, and `kubectl get sc` shows no Kadalu class. Earlier, `mkfs.xfs` on the same disk failed about 260 GB in with metadata CRC errors.

**Cause**: The disk is a fake-capacity USB disk. It reports 1 TB but only has a small amount of real flash, and every region past that reads back as `0xFF`. A wipe cannot fix this: `talosctl wipe disk` zeroes the start of the disk and the rest still reads non-zero, so discovery (which requires the first and last 1 MiB to be all zero) correctly rejects it. Seen on worker01 `/dev/sda`.

**Diagnose** (read-only, run from the discovery pod on the node):

```bash
P=$(kubectl -n kadalu get pods -o wide | awk '/discovery/ && /<node>/{print $1}')
kubectl -n kadalu exec $P -- bash -c '
  s=$(cat /sys/block/sda/size)
  for o in 0 $((s/4096)) $((s/2048-1000)) $((s/2048-1)); do   # start, middle, near end, last MiB
    dd if=/host-dev/sda bs=1M count=1 skip=$o 2>/dev/null | od -An -tx1 | sort -u | head -2
  done'
```

A genuine wiped disk prints only `00` lines at every offset. A fake disk prints `ff ff ff ...` everywhere past the start. If only the start is zero, check that the wipe really ran (`talosctl wipe disk` is a fast wipe and leaves the tail alone, so also zero the last MiB with `dd` from a privileged pod).

**Fix**: replace the disk (or plug in a genuine blank one and unplug the fake one; discovery takes the first empty whole disk). Then:

```bash
# 1. drop the stale entry (an existing entry is never overwritten, even `none`)
kubectl -n kadalu patch cm kadalu-disk-discovery --type merge -p '{"data":{"<node>":null}}'
# 2. delete the pool built from too few nodes
kubectl -n kadalu delete kadalustorage kadalu-pool-replica3
# 3. restart discovery so the node records the new disk
kubectl -n kadalu rollout restart ds/kadalu-disk-discovery
# 4. recreate the generator Job (or: argocd app sync kadalu)
kubectl -n kadalu delete job kadalu-storage-generator
# 5. every Replica3 node should now show /dev/...; the Kadalu class should exist
kubectl -n kadalu get cm kadalu-disk-discovery -o jsonpath='{.data}'
kubectl get sc
```
