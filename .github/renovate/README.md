# Renovate presets

`base.json5` loads shared presets from `base/`. Repository-specific rules live
in `cluster/` and are loaded by `../renovate.json5` after the base presets.
Keep `cluster/actions-runners.json5` after the chart grouping rules and
`cluster/prometheus-operator.json5` last.

## Chart schemas

Keep container images out of `repositories/oci/`; its dependencies are grouped
as charts. Add a `renovate-schema` marker immediately above a versioned values
schema to update it with its chart.

For an OCI chart, match the source URL without `oci://`:

```yaml
# renovate-schema: datasource=docker depName=quay.io/cilium/charts/cilium registryUrl=https://quay.io
# yaml-language-server: $schema=https://raw.githubusercontent.com/cilium/cilium/v1.20.1/install/kubernetes/cilium/values.schema.json
```

For an HTTP Helm chart, use its chart name and repository URL:

```yaml
# renovate-schema: datasource=helm depName=volsync registryUrl=https://backube.github.io/helm-charts
# yaml-language-server: $schema=https://raw.githubusercontent.com/backube/helm-charts/volsync-0.16.0/charts/volsync/values.schema.json
```

The schema must use the chart's version numbering. Unversioned or commit-pinned
URLs need separate rules. Verify the schema URL when adding a marker.

## Dashboard URLs

Place `renovate-dashboard` directly above a versioned GrafanaDashboard `url`.
Use the exporter's image to group the dashboard with its image updates:

```yaml
# renovate-dashboard: depName=ghcr.io/example/exporter datasource=docker
url: https://raw.githubusercontent.com/example/exporter/v1.2.3/grafana/dashboard.json
```

For a repository with prefixed tags, specify the versioning pattern:

```yaml
# renovate-dashboard: depName=kubernetes/ingress-nginx datasource=github-tags versioning=regex:^controller-v(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$
url: https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/grafana/dashboards/nginx.json
```

The source's versions must match the URL path segment being replaced.
Moving branch URLs have no version to track.

## Documentation URLs

Place `renovate-docs` directly above a comment containing a versioned link.
For a chart, copy its `renovate-schema` metadata, including `registryUrl`:

```yaml
# renovate-docs: datasource=docker depName=ghcr.io/home-operations/charts-mirror/longhorn registryUrl=https://ghcr.io
# https://longhorn.io/docs/1.13.0/maintenance/maintenance/#node-drain-policy-recommendations
```

For an image, use its package name without `registryUrl`. An optional
`versioning` field goes last. The manager replaces the first three-part
version in the path, preserving any prefix; minor-only links need separate
rules.

## PostgreSQL updates

`base/cloudnative-pg.json5` groups each Cluster's Postgres major with its
archive `serverName`. Merge major and Debian release updates separately:
a major upgrade requires both images to use the same Debian release.

## Other version markers

`base/version-markers.json5` tracks `# renovate: datasource=... depName=...`
markers followed by a version or schema URL. It does not match dashboard or
documentation markers.
