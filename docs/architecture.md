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
            subgraph plan["App Service Plan Linux B1"]
                fe[Frontend Web App :8080]
                be[Backend Web App :8000]
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
        subgraph asp["«node» App Service Plan – Linux B1 (1 instance)"]
            bewa["«executionEnvironment» Web App cc2026-api-…<br/>container :8000"]
            fewa["«executionEnvironment» Web App cc2026-ui-…<br/>container :8080"]
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
    AP->>AZ: push backend/frontend :sha and :latest (Web Apps not there yet)
    S->>TF: CREATE_WEB_APPS=true, Run workflow
    TF->>AZ: check :latest images exist, apply: plan, identity, AcrPull, Web Apps
    S->>AP: re-run workflows (and every later push)
    AP->>AZ: set image :sha, poll /health and /version.txt
```

## Ownership

| Concern | Owner |
|---|---|
| State storage, GitHub Actions managed identity, its role assignments, GitHub variables | `bootstrap.sh` (once) |
| Resource group, ACR, plan, identity + AcrPull, Web Apps, app settings, ports, TLS | Terraform |
| Which image tag runs | Apps workflows (Terraform ignores `docker_image_name` only) |
