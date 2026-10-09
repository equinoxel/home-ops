# SonarQube

SonarQube Community Build running at [https://sonar.laurivan.com](https://sonar.laurivan.com) (and [https://sonarqube.laurivan.com](https://sonarqube.laurivan.com)).

## Architecture

```mermaid
graph LR
    subgraph Internal
        User["User / Browser"]
    end

    subgraph "Cluster (development namespace)"
        Gateway["Envoy Internal Gateway<br/>(sonar.laurivan.com)"]
        SonarQube["SonarQube Pod<br/>(UID 1000)"]
        PVC["PVC: sonarqube<br/>(10Gi, OpenEBS hostpath)"]
    end

    subgraph "Cluster (database namespace)"
        CNPG["CloudNative-PG<br/>(postgres-cluster)"]
        CertManager["cert-manager<br/>(mTLS client cert)"]
    end

    subgraph Backup
        VolSync["VolSync<br/>(Local + S3 backups)"]
    end

    User -->|HTTPS| Gateway
    Gateway -->|HTTP :9000| SonarQube
    SonarQube -->|mTLS / PKCS8 DER| CNPG
    CertManager -.->|Issues cert| SonarQube
    SonarQube --> PVC
    PVC -.-> VolSync
```

## Overview

- **Namespace**: `development`
- **Chart**: `bjw-s/app-template` v5.0.1
- **Database**: CloudNative-PG PostgreSQL (`postgres-cluster`) in `database` namespace
  - Authenticates via mTLS client certificates (`cert clientcert=verify-full`)
  - Private key converted to PKCS#8 DER at pod startup for pgjdbc compatibility
- **Persistence**:
  - `sonarqube` PVC (10Gi, `openebs-hostpath`) mounted at `/opt/sonarqube/data` and `/opt/sonarqube/extensions`
  - Backed up via VolSync (local and S3 replication)
- **Ingress**:
  - Gateway API `HTTPRoute` via `envoy-internal`
  - Hostnames: `sonar.laurivan.com`, `sonarqube.laurivan.com`
  - Homepage dashboard integration
