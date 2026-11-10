# Architecture – CC2026 Infrastructure

These diagrams show only what the code creates.

## Conceptual architecture

```mermaid
flowchart TB
    student([Student])
    browser([User browser])

    subgraph github["GitHub"]
        apps[Apps repository<br/>backend.yml, frontend.yml]
        infra[Infra repository<br/>terraform.yml]
    end

    subgraph sub["Azure subscription"]
        subgraph staterg["rg-cc2026-&lt;initials&gt;-tfstate"]
            sa[(Storage account<br/>tfstate / dev.tfstate)]
            app[GitHub Actions managed identity<br/>federated credentials: Apps main, Infra main]
        end
        subgraph apprg["rg-cc2026-&lt;initials&gt;-dev"]
            acr[(Container registry Basic)]
            uami[User-assigned identity]
            subgraph plan["Container Apps environment"]
                fe[Frontend container app :8080]
                be[Backend container app :8000]
            end
        end
    end

    student -- "bootstrap.sh (az, gh)" --> sa & app
    infra -- "OIDC" --> app
    apps -- "OIDC" --> app
    infra -- "terraform plan/apply" --> apprg
    infra -- "state read/write/lock" --> sa
    apps -- "docker push" --> acr
    apps -- "set image tag" --> fe & be
    uami -- "AcrPull" --> acr
    fe & be -- "pull as" --> uami
    browser -- HTTPS --> fe
    browser -- "HTTPS /api/data (CORS)" --> be
```

## UML deployment diagram

Mermaid has no native UML deployment diagram, so nodes and artifacts are drawn with UML stereotypes.

```mermaid
flowchart LR
    subgraph runner["«device» GitHub-hosted runner (ubuntu-latest)"]
        tf["«executionEnvironment» Terraform 1.16 + azurerm 5.9"]
        dockercli["«executionEnvironment» Docker CLI + Azure CLI"]
    end

    subgraph azure["«node» Microsoft Azure (one region)"]
        subgraph storage["«node» Storage account (Standard_LRS)"]
            statefile["«artifact» dev.tfstate"]
        end
        subgraph registry["«node» Container registry (Basic)"]
            images["«artifact» backend:&lt;sha&gt;<br/>«artifact» frontend:&lt;sha&gt;"]
        end
        subgraph asp["«node» Container Apps environment (Consumption)"]
            bewa["«executionEnvironment» Container app cc2026-api-…<br/>container :8000"]
            fewa["«executionEnvironment» Container app cc2026-ui-…<br/>container :8080"]
        end
    end

    subgraph client["«device» Client computer"]
        browser["«executionEnvironment» Browser<br/>React SPA"]
    end

    tf -- "HTTPS (Entra ID token)" --> statefile
    tf -- "ARM API" --> asp
    dockercli -- "HTTPS docker push" --> images
    images -- "pull (managed identity)" --> bewa & fewa
    browser -- "HTTPS 443" --> fewa
    browser -- "HTTPS 443 REST/JSON" --> bewa
```

## CI/CD and first-deployment flow

```mermaid
sequenceDiagram
    actor S as Student
    participant B as bootstrap.sh
    participant TF as Infra: terraform.yml
    participant AP as Apps: backend.yml / frontend.yml
    participant AZ as Azure

    S->>B: az login, gh auth login, ./bootstrap/bootstrap.sh
    B->>AZ: state storage, managed identity, federated credentials, roles
    B->>S: GitHub variables set (CREATE_WEB_APPS=false)
    S->>TF: Run workflow
    TF->>AZ: apply: resource group + ACR
    S->>AP: push to main
    AP->>AZ: push backend/frontend :sha and :latest (container apps not there yet)
    S->>TF: CREATE_WEB_APPS=true, Run workflow
    TF->>AZ: check :latest images exist, apply: environment, identity, AcrPull, container apps
    S->>AP: re-run workflows (and every later push)
    AP->>AZ: set image :sha, poll /health and /version.txt
```

## Part 2: data pipeline

```mermaid
flowchart LR
    admin([Student])
    subgraph lake["Storage account (ADLS Gen2, no shared keys)"]
        bronze[(bronze/raw)]
        silver[(silver/energy_readings<br/>silver/rejected)]
        staging[(gold/_staging)]
        hist[(gold/by-timestamp/&lt;run&gt;)]
        latest[(gold/latest)]
    end
    subgraph adf["Data Factory pl-energy-etl (managed identity, Contributor)"]
        flow[Mapping data flow]
        copy[Copy: JSON arrays]
    end
    logic[Logic App]
    teams([Teams channel])
    subgraph web["Web Apps (P1)"]
        be[Backend<br/>managed identity, Reader]
        fe[Frontend]
    end

    admin -- "upload CSV" --> bronze
    bronze -- "BlobCreated (Event Grid)" --> adf
    flow -- "reads" --> bronze
    flow -- "writes" --> silver & staging
    staging --> copy --> hist & latest
    adf -- "status (HTTP)" --> logic -- "Adaptive Card" --> teams
    be -- "reads" --> latest
    fe -- "HTTPS /api" --> be
```

Each run overwrites silver and `gold/latest/`. `gold/by-timestamp/` keeps one folder per run. The backend reads only `gold/latest/`.

## Ownership

| Concern | Owner |
|---|---|
| State storage, GitHub Actions managed identity, its role assignments, GitHub variables | `bootstrap.sh` (once) |
| Resource group, ACR, environment, identity + AcrPull, container apps, app settings, ports, TLS | Terraform |
| Which image tag runs | Apps workflows (Terraform ignores the image only) |
| P2: storage, Data Factory (data flow, pipeline, trigger), Logic App, their roles | Terraform (never edit in the portal) |
| P2: the CSV in `bronze/raw/` | The student (portal upload) |
