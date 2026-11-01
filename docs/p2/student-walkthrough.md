# P2 — Data Pipeline Walkthrough (Azure)

P2 adds an ETL pipeline (extract, transform, load) to your P1 infrastructure. You upload a CSV file with energy readings. Azure cleans it and writes the results. Teams can show you if it worked.

**Time:** Lab 1 about 90 minutes. Lab 2 about 90 minutes. The data flow needs about 5 minutes to start on every run (Spark cold start). Plan for it.

**Prerequisites:** the P1 tools and the P1 shell (WSL2 on Windows: the `curl` block uses bash quotes). `gh` installed and logged in (`gh auth status`). Without `gh`, add the secret in the portal of GitHub: repository *Settings → Secrets and variables → Actions*.

```text
upload CSV -> bronze/raw/ -> storage event -> Data Factory pipeline -> Mapping Data Flow
                                                  |                       |-> silver/energy_readings/ (clean Parquet)
                                                  |                       |-> silver/rejected/ (bad rows + reason)
                                                  |                       '-> gold/by-timestamp/<run>/ (history)
                                                  |-> reject-ratio check -> Copy -> gold/latest/
                                                  '-> Logic App -> Teams card (SUCCEEDED / FAILED)
```

**Words you need:**
- **Entra**: Microsoft sign-in. Your login needs a storage role (keys are off).
- **Spark**: the engine that runs the data flow. It starts a cluster for each run.
- **Data Factory Studio**: the web UI of Data Factory. Use it to watch only.
- **Mapping Data Flow** (`.dfs` file): the transformation as a text script.
- **Stream**: the rows after one step. **Sink**: the step that writes a stream to storage.
- **Split**: a step that sends each row to one of two streams.
- **Parquet**: a typed binary table format. **Partition**: one slice of the data. One partition gives one output file.

| Zone | Container | Content |
|---|---|---|
| bronze | `bronze` | Raw upload. You never change it |
| silver | `silver` | `energy_readings/`: clean, typed Parquet. `rejected/rejected_rows.csv`: removed bad rows with a `reject_reason` |
| gold | `gold` | Small JSON files. Every run writes `by-timestamp/<yyyyMMddTHHmmssZ>/<file>.json` (history, never deleted). Then it copies them to `latest/`. The backend reads **only `gold/latest/`** |

### Medallion in one minute
The same reading travels through three layers. Each layer answers one question.

| Layer | Question it answers | One reading in this layer |
|---|---|---|
| Bronze | What did we receive? | `device-001,2025-11-01T00:00:00Z,20.81,57.53,0.0575,Office-A`: text, exactly as uploaded, bad rows included |
| Silver | Which rows can we trust? | The same reading with real types: `timestamp` is a timestamp, `kwh` is a number, one row per `device_id` + `timestamp`. Stored as Parquet in `silver/energy_readings/` |
| Gold | What does the dashboard ask? | 288 silver readings of one day become 1 record: `{"device_id":"device-001","location":"Office-A","date":"2025-11-01","total_kwh":18.419,"avg_temperature":21.09,"avg_humidity":55.02,"readings":288}` |

## What is provided and what you build
| Part | Who |
|---|---|
| Storage, Data Factory, trigger, pipeline, Teams notification, roles, silver, `silver/rejected/`, gold `daily_energy_by_device.json` and `latest_readings.json` (two worked examples) | **Provided** (Terraform) |
| Gold file `energy_by_location.json` | **You build it** (Lab 2) |

**Lab 1** (Steps 1 to 8): deploy, upload the file, watch the run, check the results. **Lab 2** (Steps 9 to 14): Teams, two red-card demos, your gold file. **Next** (Step 15): the Apps challenge. **Do not edit anything in the Data Factory portal.** Terraform overwrites portal edits.

# Lab 1 — Deploy and run the pipeline (about 90 minutes)

## Step 1 — Get the P2 code into your Infra repository

Your instructor opens a pull request (PR) in the course template repository and gives you the PR number. In your Infra repository, on `main`, apply it as a patch:

```bash
cd CC2026_<LastName>_<FirstName>_Infra
gh pr diff <PR-number> --repo agi1clj/CC2026_DS_Infra | git apply
git add -A && git commit -m "feat(p2): add the data pipeline"
```

`git apply` can report conflicts if you changed `README.md`, `.github/workflows/terraform.yml` or `bootstrap/bootstrap.sh`. Then ask your instructor. Do not force the patch.

## Step 2 — Run bootstrap again

P2 needs three more providers (`Microsoft.DataFactory`, `Microsoft.EventGrid`, `Microsoft.Logic`) and two more roles.

```bash
az login
./bootstrap/bootstrap.sh --check
./bootstrap/bootstrap.sh
```

## Step 3 — Get the dataset

`data/` holds small test files: `energy_sample.csv` (1 day), `energy_invalid.csv` and `energy_too_dirty.csv` (both broken on purpose, Step 11). Download `energy_readings.csv` from the course channel (Teams, Files) and save it as `data/energy_readings.csv`. It has 532,895 rows and 32 MB. Git ignores it. Check it: `wc -l` must show 532896 (header included) and `head` the column names.

```bash
wc -l data/energy_readings.csv && head -3 data/energy_readings.csv
```

Columns: `device_id,timestamp,temperature,humidity,kwh,location`. About 1% of the rows are dirty. The split `CleanRows` in the data flow sends rows with `kwh` empty or negative, `humidity` outside 0 to 100 or `temperature` outside -40 to 60 (for example `-999`) to `silver/rejected/` with a `reject_reason`. It keeps the first row of a duplicate (`device_id` + `timestamp`). The pipeline counts the other duplicates and writes nothing.

## Step 4 — Deploy with the terraform workflow

Two kinds of workflow runs exist:
- **After a push to `main`** a run starts by itself. It only checks the code (format, validate, tests). It does not touch Azure.
- **The manual run** deploys: *Actions → terraform → Run workflow*, branch `main`. Untick **apply** for a plan only (read it first). Tick **apply** to deploy. Use apply for the first deploy and after every change that must reach Azure.

Push, then run the manual workflow: first without apply, then with apply. The plan adds storage, Data Factory, the Logic App and roles.

```bash
git push origin HEAD:main
```

If bootstrap printed `CI_CAN_ASSIGN_ROLES=false`, the workflow stops before apply. Apply once from your laptop:

```bash
cd terraform/environments/dev
terraform init -backend-config=backend.hcl
terraform apply      # review, then type yes
terraform output
cd ../../..
```

## Step 5 — Give yourself access to the data (do this before the upload)

Shared keys are off. The portal and the CLI use your Entra login, which needs a data role. The role can take **5 minutes or more** to work. Start it now and read Step 6 while you wait. Use the **same terminal** for Steps 5 to 14 (`$STORAGE` is a shell variable).

```bash
cd terraform/environments/dev
terraform init -backend-config=backend.hcl   # skip if you did Step 4 locally
STORAGE=$(terraform output -raw storage_account_name)
cd ../../..
az role assignment create \
  --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --role "Storage Blob Data Contributor" \
  --scope "$(az storage account show --name "$STORAGE" --query id -o tsv)"
```

## Step 6 — Upload the full file (portal)

1. Portal → your storage account → **Data storage → Containers → `bronze` → Upload**.
2. Pick `data/energy_readings.csv`. Open **Advanced**. Set **Upload to folder** to `raw` (the portal creates the folder).
3. Click **Upload**.

The portal must use **Authentication method: Microsoft Entra user account** (switch link at the top of the container). The error "not authorized to perform this operation using this permission" means the role of Step 5 is not active yet. Wait and retry.

CLI alternative: `az storage blob upload --auth-mode login --account-name "$STORAGE" --container-name bronze --name raw/energy_readings.csv --file data/energy_readings.csv --overwrite`

## Step 7 — Watch the run (observe only)

Data Factory page (`terraform output data_factory_name`) → **Launch studio → Monitor**.

1. **Trigger runs**: the storage event trigger fired for your upload.
2. **Pipeline runs**: status *In progress*, then *Succeeded*. Wait about 5 minutes for the Spark start. Do not upload again meanwhile.
3. Click the run → **Activity runs**. Click the glasses icon of **Run data flow**: rows read, rows written per sink and duration. Expect 532,895 rows read and 525,600 in silver. The **Notify** activities call the Logic App that sends the Teams card. They work without a webhook.

The pipeline checks the data before it updates `gold/latest/`. If more than 10% of the rows read are rejected (parameter `maxRejectRatio`, default `0.10`), the run fails. Silver, `silver/rejected/` and `gold/by-timestamp/` are already written then. Only `gold/latest/` stays unchanged.

**Never edit anything in Studio.** Terraform overwrites it. Keep **Data flow debug OFF**.

## Step 8 — Check silver, rejected rows and gold

Portal → storage account → **Storage browser → Blob containers**. Open `silver/energy_readings/`, `silver/rejected/` (`rejected_rows.csv` ends with the column `reject_reason`), `gold/by-timestamp/` (one folder per run, like `20261101T093000Z/`) and `gold/latest/` (a copy of the newest run). The full dataset gives 1825 records in `daily_energy_by_device.json`.

# Lab 2 — Teams, red cards and your gold file (about 90 minutes)

## Step 9 — Create the Teams webhook

Teams is optional for the pipeline. You need it for the card screenshots. **Skip Steps 9 and 10 if your tenant blocks Workflows.** Everything else works. You then see no cards. Show the Logic App run history instead (portal → Logic App → *Runs history*). The grading accepts it.

The old "Incoming Webhook" connector is retired. Use a **Workflow** (Power Automate).

1. In Teams, open a standard channel in a team you own, for example General. Private channels may not work with Workflows. No team? Create one: **Teams → Join or create a team**. Click **More options (…) → Workflows**.
2. Pick **Send webhook alerts to a channel**. Name it `cc2026-p2`. Select team and channel. Click **Add workflow**.
3. Copy the **webhook URL**. Find it later in **Power Automate → My flows → your flow → trigger**.

No template? Build a blank flow: trigger **When a Teams webhook request is received** (*Anyone*), action **Post card in a chat or channel** (Adaptive Card = `triggerBody()?['attachments']?[0]?['content']`).

Test the URL. A card "hello from CC2026" must appear. `202 Accepted` means Power Automate got the request.

```bash
curl -i -X POST -H "Content-Type: application/json" \
  -d '{"type":"message","attachments":[{"contentType":"application/vnd.microsoft.card.adaptive","content":{"type":"AdaptiveCard","version":"1.4","$schema":"http://adaptivecards.io/schemas/adaptive-card.json","body":[{"type":"TextBlock","text":"hello from CC2026"}]}}]}' \
  "<webhook-url>"
```

## Step 10 — Add Teams to the pipeline and repeat the run

The URL is a **secret**. Store it like this:

1. **GitHub secret (required).** The terraform workflow reads it. The command prompts for the value, so the URL stays out of your shell history:
   ```bash
   gh secret set TEAMS_WEBHOOK_URL --repo <github-user>/CC2026_<LastName>_<FirstName>_Infra
   ```
2. **`terraform/environments/dev/teams.auto.tfvars` (ignored by Git).** Only needed when you run `terraform apply` on your own machine. Content: `teams_webhook_url = "<webhook-url>"`. Do not use `terraform.tfvars`: bootstrap rewrites it.
3. Never commit the URL. Never paste it in chat or in a README.
4. Run the manual **terraform** workflow again with **apply** ticked, so the Logic App gets the URL. Then upload the full file again (Step 6). This repeat run shows that uploads are **safe to repeat**: silver is overwritten, a new `gold/by-timestamp/` folder appears and `gold/latest/` shows the newest run. Teams shows **CC2026 P2 pipeline SUCCEEDED** with file name, run ID, a run link and the counts: rows read, silver, rejected and duplicates removed.

## Step 11 — Make runs fail on purpose

Upload each file like in Step 6 (container `bronze`, folder `raw`). Wait for the run to end before the next upload.

1. `data/energy_invalid.csv` has no `kwh` column. The data flow checks the source schema and stops. Teams shows a red **FAILED** card with the error.
2. `data/energy_too_dirty.csv` has half of the `kwh` values empty. The data flow succeeds, but more than 10% of the rows are rejected. The reject-ratio check fails. Teams shows **Too many rejected rows**. `gold/latest/` is unchanged.

In Monitor → **Pipeline runs** the red run has status *Failed*. Open it: the failed activity (**Run data flow** for file 1, **Check reject ratio** for file 2) shows the error message. The matching **Notify failed** activity succeeded: it sent the red card. Without Teams, look at the Logic App run history.

A different or small file that passes the check replaces silver and `gold/latest/`. Upload `energy_readings.csv` again to restore the normal state.

## Step 12 — Study the two finished examples

The whole data flow is one file: `terraform/modules/data-factory/dataflow/energy_etl.dfs` (`//` starts a comment). Read it once. Two provided gold files show two patterns.

**Aggregate pattern: `daily_energy_by_device.json`.**

```text
// input stream   transformation(settings)                                ~> name of the new stream
AddTypedColumns aggregate(groupBy(device_id, location, date),   // key: one output row per device, location and day
    total_kwh       = sum(kwh),                                  // value: sum of all kWh of that day
    avg_temperature = avg(temperature),                          // value: average
    avg_humidity    = avg(humidity),
    readings        = count()) ~> DailyTotals                    // value: number of rows. The new stream is DailyTotals
DailyTotals derive(total_kwh = round(total_kwh, 3),              // derive overwrites a column with the same name
        avg_temperature = round(avg_temperature, 2),
        avg_humidity    = round(avg_humidity, 2)) ~> RoundDaily
RoundDaily sort(asc(device_id, true), asc(date, true)) ~> SortDaily   // true = nulls last
SortDaily sink(... partitionFileNames:['daily_energy_by_device.json'],   // one file with this name in the run folder gold/by-timestamp/<run>/
    partitionBy('hash', 1)) ~> GoldDaily                                 // one partition = one file
```

`AddTypedColumns` is the clean stream. Its columns: `device_id`, `timestamp` (text), `temperature`, `humidity`, `kwh`, `location`, `event_time` (a real timestamp) and `date` (`YYYY-MM-DD`).

**Sort and limit pattern: `latest_readings.json`.** `sort(desc(timestamp, true), ...)`, then `limit(200)`, then a `select` of the six output columns. Find it in the file.

## Step 13 — Build `energy_by_location.json`

Group the daily totals by location. Expected output: 5 records `{location, total_kwh, devices, avg_kwh_per_day}`. `total_kwh` and `avg_kwh_per_day` have 3 decimals. `avg_kwh_per_day` = total kWh / number of different days. Start from `DailyTotals`: it comes before the rounding, so your sums stay exact.

```text
DailyTotals aggregate(groupBy(<<TODO: which column is the key?>>),
    total_kwh = sum(total_kwh),
    devices   = <<TODO: count the different device_id values; hint: countDistinct(device_id)>>,
    days      = <<TODO: count the different dates; hint: countDistinct(date)>>) ~> LocationTotals
LocationTotals derive(avg_kwh_per_day = <<TODO: total_kwh divided by days, rounded to 3 decimals>>,
    total_kwh = round(total_kwh, 3)) ~> RoundLocation
RoundLocation select(mapColumn(location, total_kwh, devices, avg_kwh_per_day),
    skipDuplicateMapInputs: true, skipDuplicateMapOutputs: true) ~> LocationColumns
LocationColumns sink(allowSchemaDrift: true, validateSchema: false, partitionFileNames:['energy_by_location.json'],
    umask: 0022, preCommands: [], postCommands: [], skipDuplicateMapInputs: true, skipDuplicateMapOutputs: true,
    partitionBy('hash', 1)) ~> GoldLocation
```

**How to work:**

1. Paste the block into `energy_etl.dfs` (before the `// 9. SINKS` comment). Fill the gaps. Copy the sink block unchanged.
2. Register the output in `terraform/modules/data-factory/main.tf`, in the `locals` block at the top. Add `LocationTotals`, `RoundLocation` and `LocationColumns` to `transformations`. Add `GoldLocation` to `gold_sinks`. Without this, Terraform does not know the new sink.
3. Optional: test in Studio (**Author → Data flows → `df_energy_etl`**, **Data flow debug** on, **Data preview**, then switch debug off). The **Code `{ }`** view shows the script. The file in the repository is the truth.
4. Commit (`feat(data-factory): add gold file by location`) and push to `main`. Run the manual **terraform** workflow with **apply** ticked.
5. Upload `energy_readings.csv` again (Step 6) and wait for the green run.

## Step 14 — Check your result

Portal → storage account → **Storage browser → Blob containers → `gold` → `latest`**. `energy_by_location.json` must exist. Open it (**Edit** or download): 5 records. Compare `total_kwh` with the expected values. Rounding can differ in the last digit: accept a difference up to 0.01.

| location | total_kwh | devices |
|---|---|---|
| Cafeteria | 7821.387 | 1 |
| Lab | 10296.995 | 1 |
| Office-A | 7246.373 | 1 |
| Server-Room | 19586.318 | 1 |
| Workshop | 7186.407 | 1 |

The full expected file is in your Apps repository: `https://github.com/<github-user>/CC2026_<LastName>_<FirstName>_Apps/blob/main/docs/p2/sample-data/gold/energy_by_location.json`. CLI alternative: `az storage blob download --auth-mode login --account-name "$STORAGE" --container-name gold --name latest/energy_by_location.json --file /tmp/energy_by_location.json`

## Step 15 — Next: Apps challenge

The backend reads **only `gold/latest/`** (settings `STORAGE_ACCOUNT_URL`, `GOLD_CONTAINER=gold`). Your instructor gives you the PR number of the Apps repository. In your Apps repository, on `main`, run:

```bash
gh pr diff <PR-number> --repo agi1clj/CC2026_DS_Applications | git apply
git add -A && git commit -m "feat(p2): add the challenge brief and sample data"
```

Then open `docs/p2/challenge.md` and follow it.

## Limits
- Every upload is a full refresh. Production appends or merges (for example with Delta or Iceberg).
- The data flow has no unit tests. The AWS Python script has them.
- A Spark data flow for a 32 MB file is a teaching choice. A small script would be faster and cheaper.
- The webhook URL is stored in the Terraform state and in the Logic App definition. We accept this limit. This course has no Key Vault.

## Cost

One data flow run costs about €0.3. Ten test runs cost about €3 on top of P1. Idle resources cost cents.

- Each upload starts one run. **Wait for the run to end before the next upload.**
- **The expensive trap is the Data Factory Studio debug session.** It keeps a Spark cluster running for the whole session (default time to live: 60 minutes, about €2 per hour). Switch *Data flow debug* on only when you test. Set the debug **time to live to 15 minutes**. Switch it off when you finish. Check **Monitor** and **Cost Management → Cost analysis** after each lab.
- **Delete nothing until the final evaluation.** P3 and the final project use the same infrastructure.

## Troubleshooting

Rows marked "Not verified" come from documentation, not from a tested run.

| Symptom | Fix |
|---|---|
| `MissingSubscriptionRegistration` or `SubscriptionNotRegistered` for `Microsoft.EventGrid`, `Microsoft.DataFactory` or `Microsoft.Logic` | Re-run `bootstrap.sh`, or run `az provider register --namespace Microsoft.EventGrid --wait` |
| Upload works, no pipeline run | Upload to `raw/<name>.csv` in container `bronze`. Check *Manage → Triggers*: status *Started*. Wait 1–2 minutes |
| `403 AuthorizationPermissionMismatch`, or "not authorized to perform this operation using this permission" in the portal | Do Step 5. Wait 5 minutes. Portal: use the Entra user account method. CLI: `--auth-mode login`, never `--account-key` |
| No Teams card (curl shows 202, or pipeline succeeded) | Power Automate → My flows → run history. Check `TEAMS_WEBHOOK_URL` and Portal → Logic App → *Runs history* |
| Run *Failed* with a schema error on a good file | The CSV header differs from the six column names. Compare with `head -1 data/energy_readings.csv` |
| Red card: `Too many rejected rows` | More than 10% of the rows were rejected. Read `silver/rejected/rejected_rows.csv`. Fix the file or the rules. `gold/latest/` was not changed |
| `Copy to latest` fails with `403` | Data Factory role not active yet. Wait 5 minutes and upload again |
| `RequestDisallowedByAzure`, `RequestDisallowedByPolicy` or `LocationNotAvailableForResourceType` | Region policy of Azure for Students. Portal → Policy → Assignments → *Allowed resource deployment regions*. Pick an allowed region, set `AZURE_LOCATION`, re-run bootstrap. We did not check Data Factory and Logic App availability in each region. Not verified |
| `... cores quota ... exceeded` or `Operation cannot be completed without additional quota` | Low vCore quota. Ask your instructor. Try later or use another region. Not verified |

## Bonus (optional)

Add a third gold file grouped by time (hour of day, weekday or month). Use `hour(event_time)`, `dayOfWeek(event_time)` or `month(event_time)` in a `derive`, then an `aggregate`.
