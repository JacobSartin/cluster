<#
.SYNOPSIS
Recover a scratch CNPG Cluster and compare its row counts with the live database.

.DESCRIPTION
The scratch Cluster does not write to the archive. Removed on exit unless -Keep
is supplied. Requires administrative cluster access.

.EXAMPLE
./scripts/cnpg-restore-test.ps1 -Namespace example -Cluster example-postgres
#>
param(
    [Parameter(Mandatory)][string]$Namespace,
    [Parameter(Mandatory)][string]$Cluster,
    [switch]$Keep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$name = "$Cluster-restore-test"
$plugin = 'barman-cloud.cloudnative-pg.io'

$source = kubectl get clusters.postgresql.cnpg.io $Cluster -n $Namespace -o json | ConvertFrom-Json
$archiver = $source.spec.plugins | Where-Object { $_.name -eq $plugin -and $_.PSObject.Properties['isWALArchiver'] -and $_.isWALArchiver }
$recovery = $source.spec.bootstrap.recovery
if (-not $archiver) { throw "$Namespace/$Cluster has no $plugin WAL archiver" }
$serverName = if ($archiver.parameters.PSObject.Properties['serverName']) { $archiver.parameters.serverName } else { $Cluster }

$primary = $source.status.currentPrimary
# Archive the current WAL segment before recovery.
$segment = kubectl exec -n $Namespace $primary -c postgres -- psql -tAc 'select pg_walfile_name(pg_switch_wal())'
Write-Host "Waiting for $primary to archive $segment"
$deadline = (Get-Date).AddMinutes(3)
do {
    Start-Sleep -Seconds 5
    $archived = kubectl exec -n $Namespace $primary -c postgres -- psql -tAc 'select last_archived_wal from pg_stat_archiver'
} until ($archived -ge $segment -or (Get-Date) -gt $deadline)
if ($archived -lt $segment) { throw "$primary has not archived $segment after 3 minutes (last archived: $archived)" }

try {
    Write-Host "Recovering $Namespace/$name from ObjectStore $($archiver.parameters.barmanObjectName), server $serverName"
    @{
        apiVersion = 'postgresql.cnpg.io/v1'; kind = 'Cluster'
        metadata   = @{ name = $name; namespace = $Namespace }
        spec       = @{
            instances        = 1
            imageCatalogRef  = $source.spec.imageCatalogRef
            storage          = @{ size = $source.spec.storage.size }
            bootstrap        = @{ recovery = @{ source = 'origin'; database = $recovery.database; owner = $recovery.owner } }
            externalClusters = @(@{
                    name   = 'origin'
                    plugin = @{
                        name       = $plugin
                        parameters = @{ barmanObjectName = $archiver.parameters.barmanObjectName; serverName = $serverName }
                    }
                })
        }
    } | ConvertTo-Json -Depth 20 | kubectl apply -f -

    $deadline = (Get-Date).AddMinutes(30)
    do {
        Start-Sleep -Seconds 10
        $ready = kubectl get clusters.postgresql.cnpg.io $name -n $Namespace -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
        $failed = @(kubectl get pods -n $Namespace -l "cnpg.io/cluster=$name" -o jsonpath='{range .items[?(@.status.phase=="Failed")]}{.metadata.name}{"\n"}{end}' | Where-Object { $_ })
        if ($failed) {
            kubectl logs -n $Namespace $failed[0] --all-containers --tail=20
            throw "Recovery pod $($failed[0]) failed; see its log above"
        }
    } until ($ready -eq 'True' -or (Get-Date) -gt $deadline)
    if ($ready -ne 'True') { throw "$name did not become ready within 30 minutes" }

    $query = @'
select format('%s.%s %s', table_schema, table_name,
  (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text)
from information_schema.tables
where table_type = 'BASE TABLE' and table_schema not in ('pg_catalog', 'information_schema')
order by 1
'@
    function Get-Counts([string]$Pod) {
        $counts = @{}
        kubectl exec -n $Namespace $Pod -c postgres -- psql -d $recovery.database -Atc $query |
            ForEach-Object { $table, $count = $_ -split ' ', 2; $counts[$table] = $count }
        $counts
    }
    $live = Get-Counts $source.status.currentPrimary
    $restored = Get-Counts "$name-1"
    @($live.Keys) + @($restored.Keys) | Sort-Object -Unique | ForEach-Object {
        [pscustomobject]@{
            Table    = $_
            Live     = $live[$_] ?? 'missing'
            Restored = $restored[$_] ?? 'missing'
        }
    } | Format-Table -AutoSize
    if ($restored.Count -eq 0) { throw 'The restored database has no tables' }
    Write-Host "Restore test finished for $Namespace/$Cluster; compare the counts above"
}
finally {
    if (-not $Keep) {
        kubectl delete clusters.postgresql.cnpg.io $name -n $Namespace --ignore-not-found=true --wait=false | Out-Null
    }
}
