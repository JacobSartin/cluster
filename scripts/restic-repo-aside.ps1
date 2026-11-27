<#
.SYNOPSIS
Inspect, move aside, or purge an S3 Restic repository.

.DESCRIPTION
Actions: size reports object counts; move moves the repository to an -old path;
purge deletes that copy. Bucket-root repositories use <bucket>/restic-old.
Run move only after updating the repository password. Requires administrative
cluster access.

.EXAMPLE
./scripts/restic-repo-aside.ps1 -Namespace example -Secret example-backup -Action size
#>
param(
    [Parameter(Mandatory)][string]$Namespace,
    [Parameter(Mandatory)][string]$Secret,
    [Parameter(Mandatory)][ValidateSet('size', 'move', 'purge')][string]$Action
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$job = "restic-repo-aside-$Action"
$image = 'docker.io/rclone/rclone:1.75.2@sha256:2687085f718d3c628f7fdfb77c52a1d344332aed543110bb88088f2c70d43eb5'

$script = @'
repo="${RESTIC_REPOSITORY#s3:}"
scheme="${repo%%://*}"
rest="${repo#*://}"
host="${rest%%/*}"
path="${rest#*/}"
path="${path%/}"
export RCLONE_S3_ENV_AUTH=true RCLONE_S3_ENDPOINT="$scheme://$host" RCLONE_S3_NO_CHECK_BUCKET=true
case "$host" in
  *.r2.cloudflarestorage.com) export RCLONE_S3_PROVIDER=Cloudflare RCLONE_S3_REGION=auto ;;
  *) export RCLONE_S3_PROVIDER=Other RCLONE_S3_REGION=us-east-1 RCLONE_S3_FORCE_PATH_STYLE=true ;;
esac
set --
case "$path" in
  */*) old="$path-old" ;;
  *)
    old="$path/restic-old"
    set -- --include /config --include "/keys/**" --include "/data/**" \
      --include "/index/**" --include "/snapshots/**" --include "/locks/**"
    ;;
esac
echo "repository: $path ($host); moved-aside copy: $old"
case "$ACTION" in
  size)
    echo "repository:"; rclone size ":s3:$path" "$@"
    echo "moved-aside copy:"; rclone size ":s3:$old" || true
    ;;
  move)
    if rclone lsf ":s3:$old" --max-depth 1 | grep -q .; then
      echo "$old already holds objects; purge it first" >&2
      exit 1
    fi
    rclone move ":s3:$path" ":s3:$old" "$@" --stats-one-line --stats 30s -v
    echo "after the move:"; rclone size ":s3:$path" "$@"; rclone size ":s3:$old"
    ;;
  purge)
    rclone purge ":s3:$old" -v
    ;;
esac
'@

function SecretEnv([string]$Name) {
    @{ name = $Name; valueFrom = @{ secretKeyRef = @{ name = $Secret; key = $Name } } }
}

kubectl get secret $Secret -n $Namespace -o name | Out-Null

kubectl delete job $job -n $Namespace --ignore-not-found=true
@{
    apiVersion = 'batch/v1'
    kind       = 'Job'
    metadata   = @{ name = $job; namespace = $Namespace }
    spec       = @{
        ttlSecondsAfterFinished = 3600
        backoffLimit            = 0
        template                = @{
            spec = @{
                restartPolicy   = 'Never'
                securityContext = @{
                    runAsUser = 568; runAsGroup = 568; runAsNonRoot = $true
                    seccompProfile = @{ type = 'RuntimeDefault' }
                }
                containers      = @(@{
                        name            = 'rclone'
                        image           = $image
                        command         = @('/bin/sh', '-ec')
                        args            = @($script)
                        env             = @(
                            @{ name = 'ACTION'; value = $Action }
                            @{ name = 'HOME'; value = '/tmp' }
                            @{ name = 'RCLONE_CONFIG'; value = '/tmp/rclone.conf' }
                            (SecretEnv 'RESTIC_REPOSITORY')
                            (SecretEnv 'AWS_ACCESS_KEY_ID')
                            (SecretEnv 'AWS_SECRET_ACCESS_KEY')
                        )
                        securityContext = @{
                            allowPrivilegeEscalation = $false; readOnlyRootFilesystem = $true
                            capabilities = @{ drop = @('ALL') }
                        }
                        volumeMounts    = @(@{ name = 'tmp'; mountPath = '/tmp' })
                        resources       = @{ requests = @{ cpu = '50m'; memory = '128Mi' }; limits = @{ memory = '512Mi' } }
                    })
                volumes         = @(@{ name = 'tmp'; emptyDir = @{} })
            }
        }
    }
} | ConvertTo-Json -Depth 20 | kubectl apply -f -

# Detect failed Jobs without waiting for the success timeout.
$deadline = (Get-Date).AddHours(2)
while ((Get-Date) -lt $deadline) {
    $status = kubectl get job $job -n $Namespace -o jsonpath='{.status.succeeded}/{.status.failed}'
    if ($status -like '1/*') {
        kubectl logs -n $Namespace "job/$job"
        return
    }
    if ($status -like '*/1') {
        try { kubectl logs -n $Namespace "job/$job" } catch { }
        throw "job/$job in $Namespace failed"
    }
    Start-Sleep -Seconds 10
}
throw "job/$job in $Namespace did not finish within 2 hours"
