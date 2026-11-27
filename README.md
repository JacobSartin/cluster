# cluster

Flux configuration for the main Talos Kubernetes cluster.

## Layout

- [`clusters/main/flux-entry/`](clusters/main/flux-entry/): root Flux Kustomizations.
- [`clusters/main/kubernetes/`](clusters/main/kubernetes/): workloads and cluster services.
- [`clusters/main/components/`](clusters/main/components/): reusable Kustomize components.
- [`repositories/`](repositories/): chart and Git sources.
- [`scripts/`](scripts/): maintenance and recovery tools.
- [Renovate presets](.github/renovate/README.md): dependency update configuration.

## Bootstrap

Talos ships this cluster without a CNI or kube-proxy, so no pod starts until
Cilium runs. Provision the source and SOPS credentials, then install these
charts in order, each under its HelmRelease's name and namespace and with the
version and values declared here:

1. `prometheus-operator-crds`
   ([`observability/prometheus-operator-crds/`](clusters/main/kubernetes/observability/prometheus-operator-crds/)):
   Cilium and `flux-operator` create ServiceMonitors.
2. `cilium` ([`kube-system/cilium/`](clusters/main/kubernetes/kube-system/cilium/)),
   with `${PODNET}` in its values replaced by the pod subnet.
3. `flux-operator` and `flux-instance`
   ([`flux-system/`](clusters/main/kubernetes/flux-system/)).

The FluxInstance reconciles `clusters/main/flux-entry/`, and Flux adopts the
four releases.

### Ordering

A Kustomization fails as a whole when it applies a kind whose CRD is missing,
so each one depends on the Kustomizations that provide what it needs to apply
and to start:

- the CRDs of the kinds it applies or its charts render, and the namespaces it
  writes to;
- its storage (`longhorn`), load-balancer addresses (`metallb-config`,
  `metallb-pools`), secret stores and admission webhooks.

A provider sets `wait: true` when dependents need its controller or webhook.
`traefik-internal` checks only its CRDs, so a Traefik fault does not hold back
the Kustomizations that use its Middleware. Keep custom resources out of the
Kustomization whose HelmRelease installs their CRD, and out of the root.

Deleting the FluxInstance uninstalls the Flux controllers.

## Local tooling

Run `mise install` to install the pinned tools and configure the Git hooks.
The pre-commit hook encrypts staged SOPS files, rejects plaintext values in
encrypted ones, formats staged YAML with
[`homelab-fmt`](https://github.com/JacobSartin/homelab-fmt), and scans staged
changes with Gitleaks.

```sh
homelab-fmt
homelab-fmt --check
```

In VS Code, oxfmt and the Run on Save extension format YAML on save. Make
mise's shims available on `PATH`.

The SOPS diff driver shows each `*.sops.yaml` decrypted, with `#! sops` after
every value that is encrypted in Git; a hunk header names the nearest one. A
file without sops metadata, or a plaintext data value, is flagged instead. The
driver needs a decryption key in the environment. Use
`git diff --no-textconv` to view ciphertext.

## Validation

Pull requests use the shared
[`homelab-ci`](https://github.com/JacobSartin/homelab-ci) workflow to render
manifests and charts, validate schemas, and check changed container images.
Review the rendered diff before merging.

## Documentation

Keep documentation suitable for a public repository. Comment only on
non-obvious constraints; keep credential procedures and sensitive operational
details in private documentation. Preserve schema and automation annotations.
