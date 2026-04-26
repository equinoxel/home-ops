# ⛵ Cluster with Pis

This is my cluster's configuration.

## ✨ Features

A Kubernetes cluster deployed with [Talos Linux](https://github.com/siderolabs/talos) and an opinionated implementation of [Flux](https://github.com/fluxcd/flux2) using [GitHub](https://github.com/) as the Git provider, [sops](https://github.com/getsops/sops) to manage secrets and [cloudflared](https://github.com/cloudflare/cloudflared) to access applications external to your local network.

- **Required:** Some knowledge of [Containers](https://opencontainers.org/), [YAML](https://noyaml.com/), [Git](https://git-scm.com/), and a **Cloudflare account** with a **domain**.
- **Included components:** [flux](https://github.com/fluxcd/flux2), [cilium](https://github.com/cilium/cilium), [cert-manager](https://github.com/cert-manager/cert-manager), [spegel](https://github.com/spegel-org/spegel), [reloader](https://github.com/stakater/Reloader), [envoy-gateway](https://github.com/envoyproxy/gateway), [external-dns](https://github.com/kubernetes-sigs/external-dns) and [cloudflared](https://github.com/cloudflare/cloudflared).

**Other features include:**

- Dev env managed w/ [mise](https://mise.jdx.dev/)
- Workflow automation w/ [GitHub Actions](https://github.com/features/actions)
- Dependency automation w/ [Renovate](https://www.mend.io/renovate)
- Flux `HelmRelease` and `Kustomization` diffs w/ [flux-local](https://github.com/allenporter/flux-local)


## TODO

- [x] core cluster
- [/] database
    - [x] postgres
    - [x] mqtt (vernemq)
    - [ ] mysql
- [ ] communication
    - [ ] Laur's blog
    - [ ] Laura's blog
    - [ ] Other communication tools (TBD)
- [x] observability
    - [x] homepage (in default namespace)
    - [x] grafana
    - [x] prometheus
    - [x] keda
    - [-] gitops (headlamp - disabled because I have desktop install of it)
- [x] storage
    - [-] rook-ceph (disabled because talos runs off a single NVME drive per node)
    - [x] volsync
    - [x] snapshot-controller
    - [x] openebs
- [/] media
    - [ ] plex
    - [ ] tautulli (for plex)
    - [/] *rr (tbd)
    - [x] navidrome
    - [ ] subsonic
    - [ ] immich
    - [ ] book management (tbd kavita, grimmory...)
    - [ ] paperless
- [ ] smarthome
    - [ ] home assistant
    - [ ] mqtt, zigbee, z-wave
    - [ ] whisper
    - [ ] piper
    - [ ] gotortc
    - [ ] esphome
    - [ ] KNX integration (including metrics collection)
- [ ] others
    - [ ] atuin
    - [ ] ocis
    - [ ] thelounge
    - [ ] searxng (careful when using with AI - needs IP rotation)
    - [ ] publish k8s schemas (so I don't depend on tholinka.dev)
    - [ ] gatus
    - [ ] alert manager
    - [ ] json, smartctl, nut, blackbox exporter
    - [ ] kromgo
    - [ ] silence operator
    - [ ] slskd
    - [ ] shelfmark
    - [ ] victoria logs (not sure I need this if I have grafana)
    - [ ] dragonfly (db)
    - [ ] pihole?
    - [ ] frigate
    - [ ] unifi
    - [ ] kei
- [ ] Some AI stuff, but careful with local AI resources (need GPU)
- [ ] enable ipv6?
- [ ] games
    - [ ] minecraft
