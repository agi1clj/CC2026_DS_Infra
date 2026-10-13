# P1 — Student Deployment Walkthrough

Follow the steps in order. Replace these placeholders everywhere:

| Placeholder | Example |
|---|---|
| `<LastName>_<FirstName>` | `Popescu_Ana` |
| `<github-user>` | `ana-popescu` |
| `<initials>` | `ap` (2–5 lowercase letters; the reference uses `agi`) |

**Tools to install first:** Git, Docker Desktop, Azure CLI (`az`), GitHub CLI (`gh`), Terraform ≥ 1.14. On Windows, use WSL2 (Ubuntu) for the bash scripts.

---

## Step 1 — Create the repositories

On GitHub, create two **private**, empty repositories (no README):

- `CC2026_<LastName>_<FirstName>_Apps`
- `CC2026_<LastName>_<FirstName>_Infra`

In each repository: *Settings → Collaborators → Add people → `agi1clj`*.

Or with the GitHub CLI:

```bash
gh repo create CC2026_<LastName>_<FirstName>_Apps  --private
gh repo create CC2026_<LastName>_<FirstName>_Infra --private
gh api -X PUT repos/<github-user>/CC2026_<LastName>_<FirstName>_Apps/collaborators/agi1clj
gh api -X PUT repos/<github-user>/CC2026_<LastName>_<FirstName>_Infra/collaborators/agi1clj
```

## Step 2 — Clone the repositories and add the starter code

```bash
git clone https://github.com/<github-user>/CC2026_<LastName>_<FirstName>_Apps.git
git clone https://github.com/<github-user>/CC2026_<LastName>_<FirstName>_Infra.git
```

Copy the reference files (from `CC2026_DS_Apps` and `CC2026_DS_Infra`, provided by the instructor) into your two folders. Then commit:

```bash
cd CC2026_<LastName>_<FirstName>_Apps
git add . && git commit -m "Add P1 applications" && git push -u origin main
cd ../CC2026_<LastName>_<FirstName>_Infra
git add . && git commit -m "Add P1 infrastructure" && git push -u origin main
```

Pushing the Apps repository already starts its workflows. The *test/build* jobs run; the *deploy* jobs are skipped until `bootstrap.sh` has configured Azure (Step 6).

## Step 3 — Run locally

```bash
cd CC2026_<LastName>_<FirstName>_Apps
docker compose up --build
```

Open:
- http://localhost:3000 – the dashboard shows a table of measurements; try the *Device* filter
- http://localhost:8000/api/data – raw JSON
- http://localhost:8000/docs – interactive API docs; try `GET /api/data/{device_id}` with `device-001` and `device-999`

Stop with `Ctrl+C`, then `docker compose down`.

## Step 4 — Understand the Docker setup

- **Dockerfile**: a recipe that builds an image: base OS + runtime + your code + start command.
- **Image**: the built, read-only package (e.g. `backend:3f2a9c1`). The same image runs on your laptop and in Azure.
- **Container**: a running instance of an image, with its own processes and network.
- **Docker Compose**: starts several containers together from one file (`docker-compose.yml`), with a shared network.
- **Ports**: `"3000:8080"` means *host port 3000 → container port 8080*. The backend listens on 8000, Nginx (frontend) on 8080. In Azure, App Service receives HTTPS on 443 and forwards it to the port given by `WEBSITES_PORT`.

## Step 5 — Authenticate to Azure and GitHub

```bash
az login                     # pick the subscription you will use (Azure for Students is fine)
gh auth login                # GitHub.com → HTTPS → login with a web browser
```

## Step 6 — Bootstrap Azure

**6a. Check first (changes nothing):**

```bash
cd CC2026_<LastName>_<FirstName>_Infra
./bootstrap/bootstrap.sh --check
```

It answers, for *your* subscription and tenant:

| Check | What a problem means | What to do |
|---|---|---|
| Allowed regions (Azure for Students policy) | You picked a blocked region | Pick one from the list it prints |
| Linux App Service B1 available in the region | No capacity/offer there | Pick another allowed region |
| Users may register applications | University tenant blocks it | Instructor-assisted setup (Infra README §8) |
| You are Owner / can assign roles | Bootstrap cannot grant roles | Ask the instructor |
| Owner is *constrained* (cannot delegate role management) | Not an error | You will create the Web Apps from your laptop in Step 7c |
| Resource providers registered | – | Bootstrap registers them |

You can also check by hand:

```bash
az account show --query "{name:name, id:id}"                       # which subscription
az policy assignment list --disable-scope-strict-match \
  --query "[].parameters.listOfAllowedLocations.value" -o json      # allowed regions
az role assignment list --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --include-inherited --query "[].{role:roleDefinitionName, condition:condition}" -o json
```

**6b. Run it:**

```bash
./bootstrap/bootstrap.sh
```

Answer the prompts (subscription, GitHub user, the two repository names, your initials, region: bootstrap shows the regions your Azure for Students subscription allows and proposes one).

What it creates:
- `rg-cc2026-<initials>-tfstate` with a storage account and a `tfstate` container: where Terraform keeps its state
- An Entra ID application `github-actions-cc2026-<initials>` with two federated credentials. GitHub Actions on `main` of your two repositories can sign in to Azure with it, without any password
- Role assignments for that identity (Contributor; AcrPull-only RBAC administration; state access) and state access for you
- GitHub repository variables in both repositories (*Settings → Secrets and variables → Actions → Variables*)
- `terraform/environments/dev/backend.hcl` and `terraform.tfvars` (git-ignored), and runs `terraform init`

Your answers are saved in `bootstrap/bootstrap.env` (not committed). **Renamed a repository?** Run `./bootstrap/bootstrap.sh` again: it detects the new name (or edit `APPS_REPO` / `INFRA_REPO` in that file) and moves the OIDC trust and the GitHub variables to it. GitHub Actions login fails until you do, because the trust is bound to the exact repository name.

If it stops with a permissions message, show the output to your instructor (README §8, *Instructor-assisted setup*).

## Step 7 — Deploy the initial infrastructure

A container Web App needs an image, but your registry does not exist yet. The first deployment is therefore done in two Terraform stages (README §11 explains why).

**7a. Registry only.** In the **Infra** repository on GitHub: *Actions → terraform → Run workflow → Run*. Bootstrap set `CREATE_WEB_APPS=false`, so this creates only the resource group and the container registry. Wait for the green check.

**7b. Publish the first images.** In the **Apps** repository: *Actions → backend → Run workflow*, then *Actions → frontend → Run workflow*. Both push their images to the registry. The deploy steps are skipped with the notice *"Web App … does not exist yet"*.

**7c. Create the Web Apps.**

```bash
gh variable set CREATE_WEB_APPS --body true --repo <github-user>/CC2026_<LastName>_<FirstName>_Infra
```

Run *Actions → terraform → Run workflow* again. It checks that both images exist, then creates the App Service Plan, the identity and the two Web Apps. The **Summary** tab shows `frontend_url` and `backend_url`.

If bootstrap printed *"GitHub Actions cannot create role assignments"*, create the Web Apps from your laptop instead (your own account may assign the AcrPull role):

```bash
cd terraform/environments/dev
terraform apply      # type yes after reviewing the plan
terraform output
```

## Step 8 — Deploy the applications

Re-run *backend* and *frontend* in the Apps repository (or push any change to `main`). Each run:

`test/build → OIDC login → docker build → push :<sha> → update Web App → wait until /health (or /version.txt) shows <sha>`

From now on, every push to `main` that changes `backend/` or `frontend/` deploys automatically.

## Step 9 — Verify the Azure resources

Azure portal → *Resource groups* → `rg-cc2026-<initials>-dev`. You should see: the container registry, the App Service Plan, two App Services and a managed identity. Or from the terminal:

```bash
az resource list --resource-group rg-cc2026-<initials>-dev --output table
az acr repository show-tags --name <acr-name> --repository backend --output table
az webapp list --resource-group rg-cc2026-<initials>-dev --query "[].{name:name, url:defaultHostName, state:state}" --output table
```

## Step 10 — Test the deployed applications

```bash
cd terraform/environments/dev
BACKEND=$(terraform output -raw backend_url)
FRONTEND=$(terraform output -raw frontend_url)

curl "$BACKEND/health"               # {"status":"ok", "version":"<commit sha>" ...}
curl "$BACKEND/api/data"             # JSON list
curl "$BACKEND/api/data/device-001"  # one device
curl -i "$BACKEND/api/data/nope"     # 404
curl "$FRONTEND/config.js"           # contains your backend URL
```

Open the frontend URL in a browser: the table must show the data. Open the browser's developer tools (F12 → *Network*) and look at the request to `…/api/data`: it goes directly to the backend over HTTPS.

## Step 11 — Inspect CI/CD

GitHub → *Actions* → open a **backend** run:
- **Trigger**: `push` on `main` (only when `backend/**` changed) or a manual run
- **Job `test`**: installs dependencies and runs pytest; on a pull request only this job runs
- **Job `deploy`** (`needs: test`): OIDC login, image build and push to ACR (tags `<sha>` and `latest`), Web App update, health verification
- **Runner**: `ubuntu-latest`, a fresh VM provided by GitHub for each job

Compare *build* (creating the image) with *release* (switching the Web App to that image). The `:<sha>` tag lets you tell exactly which commit is live.

## Step 12 — Review Terraform

```bash
cd terraform/environments/dev
terraform init -backend-config=backend.hcl   # downloads the provider, connects to the remote state
terraform fmt -check -recursive ../..        # checks formatting (no output = OK)
terraform validate                           # checks syntax and references
terraform plan                               # compares code with real resources; should say "No changes"
terraform output                             # prints names and URLs
```

Look at `locals.tf` (names, tags), `main.tf` (resource group + 2 modules), `modules/app-service/main.tf` (Web Apps, ports, CORS, identity).

## Step 13 — Cleanup

When the project has been graded:

```bash
cd CC2026_<LastName>_<FirstName>_Infra
./scripts/cleanup.sh
```

| What | Effect | When |
|---|---|---|
| Destroy application infrastructure (step 1 of the script) | Deletes `rg-cc2026-<initials>-dev`; **stops the costs** | After grading |
| Remove role assignments | The GitHub identity loses access to your subscription | Optional, step 2 |
| Delete the Entra application | Federated credentials disappear; workflows can no longer log in | Optional, step 2 |
| Delete the state storage | Removes `rg-cc2026-<initials>-tfstate`; only allowed when the state is empty | Optional, step 3 |

Each step shows what it will delete and asks you to type `yes`.

## Step 14 — Assignment submission

Submit:
- Links to your two **private** repositories (with `agi1clj` as collaborator)
- The working **frontend URL** and **backend URL** (`…/api/data`), also written in both READMEs (Apps README §13)
- The architecture diagrams (`docs/architecture.md` in both repositories: conceptual + UML deployment)
- The README documentation
- Evidence of successful GitHub Actions runs: links to green runs of `backend`, `frontend` and `terraform` (or screenshots of the *Actions* tab)

Be ready to explain: IaaS vs PaaS vs SaaS (App Service is PaaS), REST and HTTP status codes, workflow triggers / jobs / runners, build vs release, environment variables (`API_BASE_URL`, `CORS_ORIGINS`), and CI/CD.
