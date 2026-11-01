# P2 — Data Pipeline Walkthrough (Azure)

P2 adds an ETL pipeline to your P1 infrastructure. You upload a CSV file with energy readings. Azure cleans it and writes the results. Teams tells you if it worked.

```text
upload CSV -> bronze/raw/ -> storage event -> Data Factory pipeline -> Mapping Data Flow
                                                  |                       |-> silver/ (clean Parquet)
                                                  |                       '-> gold/   (JSON files)
                                                  '-> Logic App -> Teams card (SUCCEEDED / FAILED)
```

| Zone | Container | Content |
|---|---|---|
| bronze | `bronze` | Raw upload. You never change it |
| silver | `silver` | Clean, typed Parquet: `energy_readings/` |
| gold | `gold` | Small JSON files for the backend: `daily_energy_by_device.json`, `energy_by_location.json`, `latest_readings.json` |

Follow the steps in order. Use the same placeholders as in the P1 walkthrough (`<LastName>_<FirstName>`, `<github-user>`, `<initials>`).

**Time:** about 60 minutes. **Do not edit anything in the Data Factory portal.** The portal is for watching only. Terraform owns every resource and overwrites portal edits at the next apply.

---

## Step 1 — Get the P2 code into your Infra repository

Your Infra repository was created from a template, so it has no shared history with the course repository. Pull the P2 branch with `--allow-unrelated-histories`:

```bash
cd CC2026_<LastName>_<FirstName>_Infra
git remote add upstream https://github.com/agi1clj/CC2026_DS_Infra.git   # once
git fetch upstream
git pull upstream feature/p2-data-pipeline --allow-unrelated-histories --no-rebase
```

Fix merge conflicts if Git reports any (they are rare). Do not push yet.

## Step 2 — Run bootstrap again (new roles and providers)

P2 needs the resource providers `Microsoft.DataFactory`, `Microsoft.EventGrid` and `Microsoft.Logic`. It also needs two more roles that GitHub Actions may assign (Storage Blob Data Contributor and Reader).

```bash
az login
./bootstrap/bootstrap.sh --check
./bootstrap/bootstrap.sh
```

Bootstrap is safe to re-run. It rewrites `terraform/environments/dev/terraform.tfvars`. Do Step 3 **after** this step.

## Step 3 — Create the Teams webhook

The old "Incoming Webhook" connector of Teams is retired. Use a **Workflow** (Power Automate) instead.

1. In Teams, open a channel (a private channel in your own team is fine). Click **More options (…)** next to the channel name, then **Workflows**.
2. Pick the template **Send webhook alerts to a channel**. Name it, for example `cc2026-p2`. Select the team and the channel. Click **Add workflow**.
3. Copy the **webhook URL** that Teams shows at the end. You can find it later in **Power Automate → My flows → your flow → trigger "When a Teams webhook request is received"**.

If the template is not offered, build the flow from blank in Power Automate: trigger **When a Teams webhook request is received** (who can trigger: *Anyone*), action **Post card in a chat or channel** (post as *Flow bot*, to your channel, Adaptive Card = the card from the trigger body: `triggerBody()?['attachments']?[0]?['content']`).

Test the URL with one command. A card with the text "hello" must appear in the channel:

```bash
curl -i -X POST -H "Content-Type: application/json" \
  -d '{"type":"message","attachments":[{"contentType":"application/vnd.microsoft.card.adaptive","content":{"type":"AdaptiveCard","version":"1.4","$schema":"http://adaptivecards.io/schemas/adaptive-card.json","body":[{"type":"TextBlock","text":"hello from CC2026"}]}}]}' \
  "<webhook-url>"
```

`202 Accepted` means that Power Automate got the request. The message can take some seconds.

Store the URL in two places. It is a **secret**: never commit it.

```bash
gh secret set TEAMS_WEBHOOK_URL --repo <github-user>/CC2026_<LastName>_<FirstName>_Infra   # paste the URL
echo 'teams_webhook_url = "<webhook-url>"' >> terraform/environments/dev/terraform.tfvars   # git-ignored
```

**Your university tenant may block Workflows or external HTTP triggers.** Then ask your instructor, or create the flow in a personal Microsoft account and a personal channel. Without a URL the pipeline still works. The Logic App then sends no card.

## Step 4 — Get the dataset

The repository has two small files in `data/`: `energy_sample.csv` (1 day) and `energy_invalid.csv` (broken on purpose). Generate the full file (about 530 000 rows, 32 MB, same for every student):

```bash
python3 scripts/generate_dataset.py --out data
head -3 data/energy_readings.csv
```

Columns: `device_id,timestamp,temperature,humidity,kwh,location`. About 1% of the rows are dirty: duplicates, empty or negative `kwh`, humidity above 100, temperature `-999`. Silver removes them.

## Step 5 — Deploy with the terraform workflow

Commit and push to `main`, then run *Actions → terraform → Run workflow*. Untick **apply** first to read the plan.

```bash
git push origin HEAD:main
```

The plan adds: storage account, three containers, Data Factory (linked service, datasets, data flow, pipeline `pl-energy-etl`, trigger), Logic App and role assignments. It must also set `STORAGE_ACCOUNT_URL` and `GOLD_CONTAINER` on the backend Web App.

If bootstrap printed `CI_CAN_ASSIGN_ROLES=false`, the workflow stops before apply because the plan creates role assignments. Apply once from your laptop, then use the workflow again:

```bash
cd terraform/environments/dev
terraform init -backend-config=backend.hcl
terraform apply      # review, then type yes
terraform output
cd ../../..
```

## Step 6 — Give yourself access to the data

Shared keys are disabled on the storage account. Your login needs a data role to upload and read blobs:

```bash
cd terraform/environments/dev
STORAGE=$(terraform output -raw storage_account_name)
cd ../../..
az role assignment create \
  --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --role "Storage Blob Data Contributor" \
  --scope "$(az storage account show --name "$STORAGE" --query id -o tsv)"
```

Wait 2–5 minutes for the role to take effect.

## Step 7 — Upload the dataset and start the pipeline

```bash
az storage blob upload --auth-mode login --account-name "$STORAGE" \
  --container-name bronze --name raw/energy_readings.csv \
  --file data/energy_readings.csv --overwrite
```

`terraform output upload_command` prints the same command. The upload raises a *BlobCreated* event. The trigger starts `pl-energy-etl`.

## Step 8 — Watch the run in Data Factory

Azure portal → your Data Factory (`terraform output data_factory_name`) → **Launch studio → Monitor → Pipeline runs**. You should see `pl-energy-etl` as *In progress*, then *Succeeded*. Open the run to see the activity **Run data flow** and the row counts per sink.

The first data flow run starts a Spark cluster. This takes about 5 minutes. Do not start a second run in the meantime.

## Step 9 — Check silver and gold

```bash
az storage blob list --auth-mode login --account-name "$STORAGE" --container-name silver --prefix energy_readings/ --output table
az storage blob list --auth-mode login --account-name "$STORAGE" --container-name gold --output table
az storage blob download --auth-mode login --account-name "$STORAGE" --container-name gold \
  --name energy_by_location.json --file /tmp/energy_by_location.json && cat /tmp/energy_by_location.json
```

Gold must contain three JSON files (JSON arrays). The full dataset gives 1825 records in `daily_energy_by_device.json` and 5 records in `energy_by_location.json`.

## Step 10 — See the SUCCEEDED card in Teams

Your channel shows the card **CC2026 P2 pipeline SUCCEEDED** with file name, run ID, time, rows written and a link to the run.

## Step 11 — Make a run fail on purpose

`energy_invalid.csv` has no `kwh` column. The data flow checks the schema of the source and stops.

```bash
az storage blob upload --auth-mode login --account-name "$STORAGE" \
  --container-name bronze --name raw/energy_invalid.csv \
  --file data/energy_invalid.csv --overwrite
```

Monitor shows the run as *Failed*. Teams shows **CC2026 P2 pipeline FAILED** with the error message. Silver and gold keep the data of the last good run. Each run reads only the file that started it.

## Step 12 — Change a cleaning rule

All cleaning rules are in one versioned file: `terraform/modules/data-factory/dataflow/energy_etl.dfs`. Find the transformation `CleanRows`. Change the temperature limit from `60` to `30`. Commit, push to `main` and run the terraform workflow. Upload `energy_readings.csv` again (Step 7) and compare the row counts in Monitor.

```bash
git commit -am "feat(data-factory): tighten the temperature limit" && git push origin HEAD:main
```

Change the limit back when you are done. Never fix things in the portal.

## Step 13 — Next: Apps challenge

The backend now has read access to `gold` and the settings `STORAGE_ACCOUNT_URL` and `GOLD_CONTAINER=gold`. Go to the Apps repository and follow `docs/p2-challenge.md`. You read the gold files in the backend and show charts in the frontend.

## Cost

| Item | Cost |
|---|---|
| Data flow run (General Purpose, 8 cores, cold start included) | about €0.3 per run |
| Storage, Logic App, Data Factory when idle | cents per month |

Do not upload the big file in a loop. **Delete nothing until the final evaluation** (P3 and the final project use the same infrastructure).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Plan or apply: `MissingSubscriptionRegistration` for `Microsoft.EventGrid`, `Microsoft.DataFactory` or `Microsoft.Logic` | Provider not registered | Re-run `bootstrap.sh`, or `az provider register --namespace Microsoft.EventGrid --wait` |
| Workflow stops: plan creates role assignments | `CI_CAN_ASSIGN_ROLES=false` | Run `terraform apply` locally (Step 5) |
| Upload works but no pipeline run | Wrong blob path or extension; trigger not started; event delayed | Upload to `raw/<name>.csv` in container `bronze`. Check *Manage → Triggers*: status *Started*. Wait 1–2 minutes |
| `403 AuthorizationPermissionMismatch` on upload or download | No data role, or role not active yet | Step 6; wait 5 minutes; use `--auth-mode login`, never `--account-key` |
| Teams: curl shows 202 but no message | Flow failed or wrong flow type | Power Automate → My flows → run history. Make sure the flow posts to a channel |
| Pipeline succeeded but no card | Empty `teams_webhook_url`, or Logic App run failed | Check `TEAMS_WEBHOOK_URL`. Portal → Logic App → *Runs history* |
| Run *Failed* with a schema error on a good file | CSV header differs from the six column names | Compare with `head -1 data/energy_readings.csv` |
| First run takes 5 minutes | Spark cluster cold start | Normal. Wait |
| Data flow fails to start: no quota or region error | Student subscription limits | Tell your instructor with the error text |
| Portal edit disappeared | Terraform overwrote it | Edit the files in this repository instead |
