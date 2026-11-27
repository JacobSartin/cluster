#!/usr/bin/env bash

set -euo pipefail

NAMESPACE=minecraft
DEPLOYMENT=minecraft-java
SIDECAR=mcbackup
RESTIC_HOST=minecraft-java
RESTIC_TAG=world
POD_SELECTOR='app.kubernetes.io/instance=minecraft-java,app.kubernetes.io/controller=main'
JOB=minecraft-restic-restore

sidecar_restic() {
    kubectl exec -n "$NAMESPACE" "deploy/$DEPLOYMENT" -c "$SIDECAR" -- restic "$@"
}

list_snapshots() {
    sidecar_restic snapshots --host "$RESTIC_HOST" --tag "$RESTIC_TAG" --compact
}

SNAPSHOT_ID="${1:-}"
if [[ -z "$SNAPSHOT_ID" ]]; then
    echo "Usage: $0 <restic-snapshot-id|latest>" >&2
    echo >&2
    list_snapshots >&2
    exit 1
fi

if [[ "$SNAPSHOT_ID" == latest ]]; then
    SNAPSHOT_ID=$(sidecar_restic snapshots --host "$RESTIC_HOST" --tag "$RESTIC_TAG" --latest 1 --json \
        | sed -nE 's/.*"short_id":"([[:xdigit:]]{8})".*/\1/p' | head -n1)
    if [[ -z "$SNAPSHOT_ID" ]]; then
        echo "No snapshot found for host $RESTIC_HOST with tag $RESTIC_TAG" >&2
        exit 1
    fi
    echo "Latest snapshot is $SNAPSHOT_ID"
elif [[ ! "$SNAPSHOT_ID" =~ ^[[:xdigit:]]{8,64}$ ]]; then
    echo "Snapshot ID must be 'latest' or 8-64 hexadecimal characters" >&2
    exit 1
fi

# Verify the snapshot before stopping the server.
sidecar_restic cat snapshot "$SNAPSHOT_ID" >/dev/null

NAS_IP=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.volumes[?(@.name=="backups")].nfs.server}')
NAS_PATH=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.volumes[?(@.name=="backups")].nfs.path}')
PVC_NAME=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}')
BACKUP_IMAGE=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$SIDECAR\")].image}")
RUN_AS_USER=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.securityContext.runAsUser}')
RUN_AS_GROUP=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.securityContext.runAsGroup}')
if [[ -z "$NAS_IP" || -z "$NAS_PATH" || -z "$PVC_NAME" || -z "$BACKUP_IMAGE" || -z "$RUN_AS_USER" || -z "$RUN_AS_GROUP" ]]; then
    echo "Could not read the backup mount, data PVC, backup image or UID from the $DEPLOYMENT Deployment" >&2
    exit 1
fi

echo "Stopping Minecraft before restoring snapshot $SNAPSHOT_ID"
kubectl scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas=0
kubectl wait --for=delete pod -l "$POD_SELECTOR" -n "$NAMESPACE" --timeout=180s

kubectl delete job "$JOB" -n "$NAMESPACE" --ignore-not-found=true
cat <<MANIFEST | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
  namespace: $NAMESPACE
spec:
  ttlSecondsAfterFinished: 3600
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsUser: $RUN_AS_USER
        runAsGroup: $RUN_AS_GROUP
        fsGroup: $RUN_AS_GROUP
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: restore
          image: $BACKUP_IMAGE
          command: ["/bin/bash", "-ec"]
          args:
            - |
              restic restore "\$SNAPSHOT_ID" --target / --include /data --delete --verbose
              test -f /data/world/level.dat
              echo "Restored snapshot \$SNAPSHOT_ID; world/level.dat present"
          env:
            - name: SNAPSHOT_ID
              value: "$SNAPSHOT_ID"
            - name: RESTIC_REPOSITORY
              value: /backups/restic
            - name: RESTIC_CACHE_DIR
              value: /tmp/restic-cache
            - name: RESTIC_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: minecraft-java-restic
                  key: RESTIC_PASSWORD
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
          volumeMounts:
            - name: data
              mountPath: /data
            - name: backups
              mountPath: /backups
            - name: tmp
              mountPath: /tmp
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 2Gi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: $PVC_NAME
        - name: backups
          nfs:
            server: $NAS_IP
            path: $NAS_PATH
        - name: tmp
          emptyDir: {}
MANIFEST

if ! kubectl wait --for=condition=complete "job/$JOB" -n "$NAMESPACE" --timeout=30m; then
    kubectl logs -n "$NAMESPACE" "job/$JOB" || true
    echo "Restore failed; Minecraft remains stopped. Inspect job/$JOB before starting it:" >&2
    echo "  kubectl scale deployment $DEPLOYMENT -n $NAMESPACE --replicas=1" >&2
    exit 1
fi

kubectl logs -n "$NAMESPACE" "job/$JOB"
kubectl scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas=1
kubectl rollout status deployment "$DEPLOYMENT" -n "$NAMESPACE" --timeout=10m
