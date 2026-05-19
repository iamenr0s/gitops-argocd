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
