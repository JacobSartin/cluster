<#
.SYNOPSIS
Restore a VolSync snapshot into a scratch PVC and check for readable files.

.DESCRIPTION
Uses the configured recovery mover identity. -Keep retains the scratch PVC.
Requires administrative cluster access.

.EXAMPLE
./scripts/volsync-restore-test.ps1 -Namespace example -ReplicationSource example-data
#>
param(
    [Parameter(Mandatory)][string]$Namespace,
    [Parameter(Mandatory)][string]$ReplicationSource,
    [switch]$Keep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$name = "$ReplicationSource-restore-test"
$trigger = "restore-test-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$image = 'docker.io/library/busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e'

$rs = kubectl get replicationsource $ReplicationSource -n $Namespace -o json | ConvertFrom-Json
$restic = $rs.spec.restic
$sourcePvc = kubectl get pvc $rs.spec.sourcePVC -n $Namespace -o json | ConvertFrom-Json
$capacity = $sourcePvc.spec.resources.requests.storage
$storageClass = if ($restic.PSObject.Properties['storageClassName']) { $restic.storageClassName } else { $sourcePvc.spec.storageClassName }
# Use the recovery mover's identity to match restore permissions.
$recovery = (kubectl get replicationdestination -n $Namespace -o json | ConvertFrom-Json).items | Where-Object {
    $_.metadata.name -ne $name -and $_.spec.PSObject.Properties['restic'] -and
    $_.spec.restic.repository -eq $restic.repository -and $_.spec.restic.PSObject.Properties['moverSecurityContext']
} | Select-Object -First 1
$mover = if ($recovery) { $recovery.spec.restic.moverSecurityContext } else { $restic.PSObject.Properties['moverSecurityContext']?.Value }
if (-not $restic.repository -or -not $mover -or -not $mover.PSObject.Properties['runAsUser']) {
    throw "Could not read the repository or mover identity from $Namespace/$ReplicationSource"
}

$destination = @{
    repository           = $restic.repository
    destinationPVC       = $name
    copyMethod           = 'Direct'
    cacheCapacity        = if ($restic.PSObject.Properties['cacheCapacity']) { $restic.cacheCapacity } else { '1Gi' }
    moverSecurityContext = $mover
}
if ($restic.PSObject.Properties['cacheStorageClassName']) { $destination.cacheStorageClassName = $restic.cacheStorageClassName }

try {
    @{
        apiVersion = 'v1'; kind = 'List'
        items      = @(
            @{
                apiVersion = 'v1'; kind = 'PersistentVolumeClaim'
                metadata   = @{ name = $name; namespace = $Namespace }
                spec       = @{
                    accessModes      = @('ReadWriteOnce')
                    storageClassName = $storageClass
                    resources        = @{ requests = @{ storage = $capacity } }
                }
            }
            @{
                apiVersion = 'volsync.backube/v1alpha1'; kind = 'ReplicationDestination'
                metadata   = @{ name = $name; namespace = $Namespace }
                spec       = @{ trigger = @{ manual = $trigger }; restic = $destination }
            }
        )
    } | ConvertTo-Json -Depth 20 | kubectl apply -f -

    Write-Host "Restoring the newest snapshot of $Namespace/$ReplicationSource into PVC $name"
    $deadline = (Get-Date).AddHours(1)
    do {
        Start-Sleep -Seconds 10
        $synced = kubectl get replicationdestination $name -n $Namespace -o jsonpath='{.status.lastManualSync}'
    } until ($synced -eq $trigger -or (Get-Date) -gt $deadline)
    $result = kubectl get replicationdestination $name -n $Namespace -o jsonpath='{.status.latestMoverStatus.result}'
    kubectl get replicationdestination $name -n $Namespace -o jsonpath='{.status.latestMoverStatus.logs}'
    if ($result -ne 'Successful') { throw "Restore did not succeed (result: $(if ($result) { $result } else { 'none within 1 hour' }))" }

    @{
        apiVersion = 'v1'; kind = 'Pod'
        metadata   = @{ name = $name; namespace = $Namespace }
        spec       = @{
            restartPolicy   = 'Never'
            securityContext = @{
                runAsUser = $mover.runAsUser
                runAsGroup = if ($mover.PSObject.Properties['runAsGroup']) { $mover.runAsGroup } else { $mover.runAsUser }
                runAsNonRoot = $mover.runAsUser -ne 0
                seccompProfile = @{ type = 'RuntimeDefault' }
            }
            containers      = @(@{
                    name            = 'inspect'
                    image           = $image
                    command         = @('/bin/sh', '-c')
                    args            = @(@'
echo "restored size: $(du -sh /restore | cut -f1)"
echo "restored files: $(find /restore -type f | wc -l)"
echo "top-level entries:"; ls -la /restore
test "$(find /restore -type f | head -n1)" != ""
'@)
                    securityContext = @{
                        allowPrivilegeEscalation = $false; readOnlyRootFilesystem = $true
                        capabilities = @{ drop = @('ALL') }
                    }
                    volumeMounts    = @(@{ name = 'restore'; mountPath = '/restore'; readOnly = $true })
                })
            volumes         = @(@{ name = 'restore'; persistentVolumeClaim = @{ claimName = $name; readOnly = $true } })
        }
    } | ConvertTo-Json -Depth 20 | kubectl apply -f -

    $deadline = (Get-Date).AddMinutes(10)
    do {
        Start-Sleep -Seconds 5
        $phase = kubectl get pod $name -n $Namespace -o jsonpath='{.status.phase}'
    } until ($phase -in 'Succeeded', 'Failed' -or (Get-Date) -gt $deadline)
    kubectl logs "pod/$name" -n $Namespace
    if ($phase -ne 'Succeeded') { throw 'The restored volume is empty or unreadable' }
    Write-Host "Restore test passed for $Namespace/$ReplicationSource"
}
finally {
    kubectl delete pod $name -n $Namespace --ignore-not-found=true --wait=false | Out-Null
    kubectl delete replicationdestination $name -n $Namespace --ignore-not-found=true | Out-Null
    if (-not $Keep) { kubectl delete pvc $name -n $Namespace --ignore-not-found=true --wait=false | Out-Null }
}
