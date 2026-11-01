# P2 — Data Pipeline Walkthrough (Azure)

P2 adds an ETL pipeline (extract, transform, load) to your P1 infrastructure. You upload a CSV file with energy readings. Azure cleans it and writes the results. Teams tells you if it worked.

```text
upload CSV -> bronze/raw/ -> storage event -> Data Factory pipeline -> Mapping Data Flow
                                                  |                       |-> silver/ (clean Parquet)
                                                  |                       '-> gold/by-timestamp/<run>/ (history) -> Copy -> gold/latest/
                                                  '-> Logic App -> Teams card (SUCCEEDED / FAILED)
```

New terms: **Data Factory** runs the pipeline. A **Mapping Data Flow** transforms data on Spark and is a text script. **Parquet** is a typed binary table format. **Event Grid** sends a *BlobCreated* event that starts the pipeline. A **Logic App** posts the Teams card. A **Teams Workflow webhook** is a URL: a POST to it shows a card.

| Zone | Container | Content |
|---|---|---|
| bronze | `bronze` | Raw upload. You never change it |
| silver | `silver` | Clean, typed Parquet: `energy_readings/` |
| gold | `gold` | Small JSON files. Every run writes `by-timestamp/<yyyyMMddTHHmmssZ>/<file>.json` (history, never deleted). Then it copies them to `latest/`. The backend reads **only `gold/latest/`** |

### Medallion in one minute

The same reading travels through three layers. Each layer answers one question.

| Layer | Question it answers | One reading in this layer |
|---|---|---|
| Bronze | What did we receive? | `device-001,2025-11-01T00:00:00Z,20.81,57.53,0.0575,Office-A`: text, exactly as uploaded, bad rows included |
| Silver | Which rows can we trust? | The same reading with real types: `timestamp` is a timestamp, `kwh` is a number, one row per `device_id` + `timestamp`. Stored as Parquet in `silver/energy_readings/` |
| Gold | What does the dashboard ask? | 288 silver readings of one day become 1 record: `{"device_id":"device-001","location":"Office-A","date":"2025-11-01","total_kwh":18.419,"avg_temperature":21.09,"avg_humidity":55.02,"readings":288}` |

You never change bronze. Each layer is rebuilt from the layer before it, so uploading again is safe. Only the pipeline reads silver. The backend reads only gold.

## What is provided and what you build

| Part | Who |
|---|---|
| Storage, Data Factory, trigger, pipeline, Teams notification, roles, silver (clean Parquet) | **Provided** (Terraform) |
| Gold file `daily_energy_by_device.json` | **Provided**: the worked example |
| Gold files `energy_by_location.json` and `latest_readings.json` | **You build them** (Lab 2) |
| A third gold file of your own and an extra data-quality rule | Optional bonus |

- **Lab 1** (Steps 1 to 11): deploy, upload the CSV, see the green Teams card, then the red card.
- **Lab 2** (Steps 12 to 15): write the two gold files. **Next** (Step 16): the Apps challenge.

Use the P1 placeholders (`<LastName>_<FirstName>`, `<github-user>`). Time: about 60 minutes. **Do not edit the Data Factory portal.** It is for watching only. Terraform overwrites portal edits.

---

# Lab 1 — Deploy and run the pipeline

## Step 1 — Get the P2 code into your Infra repository

Your repository shares no history with the course repository, so pass `--allow-unrelated-histories`.

```bash
cd CC2026_<LastName>_<FirstName>_Infra
git remote add upstream https://github.com/agi1clj/CC2026_DS_Infra.git   # once
git fetch upstream
git pull upstream feature/p2-data-pipeline --allow-unrelated-histories --no-rebase
```

Fix merge conflicts. Do not push yet.

## Step 2 — Run bootstrap again

P2 needs three more providers (`Microsoft.DataFactory`, `Microsoft.EventGrid`, `Microsoft.Logic`) and two more roles.

```bash
az login
./bootstrap/bootstrap.sh --check
./bootstrap/bootstrap.sh
```

Re-running is safe. Run it again whenever Azure or GitHub asks for it.

## Step 3 — Create the Teams webhook

The old "Incoming Webhook" connector is retired. Use a **Workflow** (Power Automate).

1. In Teams, open a channel (a private channel in your own team is fine). Click **More options (…) → Workflows**.
2. Pick **Send webhook alerts to a channel**. Name it `cc2026-p2`. Select team and channel. Click **Add workflow**.
3. Copy the **webhook URL**. Find it later in **Power Automate → My flows → your flow → trigger**.

No template? Build a blank flow. Trigger: **When a Teams webhook request is received** (*Anyone*). Action: **Post card in a chat or channel** (as *Flow bot*, Adaptive Card = `triggerBody()?['attachments']?[0]?['content']`).

Test the URL. A card "hello from CC2026" must appear in the channel. `202 Accepted` means Power Automate got the request.

```bash
curl -i -X POST -H "Content-Type: application/json" \
  -d '{"type":"message","attachments":[{"contentType":"application/vnd.microsoft.card.adaptive","content":{"type":"AdaptiveCard","version":"1.4","$schema":"http://adaptivecards.io/schemas/adaptive-card.json","body":[{"type":"TextBlock","text":"hello from CC2026"}]}}]}' \
  "<webhook-url>"
```

The URL is a **secret**. Never commit it. Store it twice:

```bash
gh secret set TEAMS_WEBHOOK_URL --repo <github-user>/CC2026_<LastName>_<FirstName>_Infra   # paste the URL
echo 'teams_webhook_url = "<webhook-url>"' > terraform/environments/dev/teams.auto.tfvars   # git-ignored
```

Use `teams.auto.tfvars`, not `terraform.tfvars`. Bootstrap rewrites `terraform.tfvars` on every run. It never touches `teams.auto.tfvars`.

Your tenant may block Workflows. Ask your instructor or use a personal account. Without a URL the pipeline works but sends no card.

## Step 4 — Get the dataset

`data/` holds `energy_sample.csv` (1 day) and `energy_invalid.csv` (broken on purpose). Generate the full file (about 530 000 rows, 32 MB):

```bash
python3 scripts/generate_dataset.py --out data
head -3 data/energy_readings.csv
```

Columns: `device_id,timestamp,temperature,humidity,kwh,location`. About 1% of the rows are dirty. Silver removes them.

| Dirty row | Silver rule |
|---|---|
| Duplicate (`device_id` + `timestamp`) | Keep the first |
| `kwh` empty or negative | Remove |
| `humidity` below 0 or above 100 | Remove |
| `temperature` outside -40 to 60 (for example `-999`) | Remove |

## Step 5 — Deploy with the terraform workflow

Run `git push origin HEAD:main`. Open *Actions → terraform → Run workflow*. Untick **apply** to read the plan. Then run it with **apply** ticked.

The plan adds storage, Data Factory (pipeline `pl-energy-etl`, data flow, trigger), the Logic App and roles. It sets `STORAGE_ACCOUNT_URL` and `GOLD_CONTAINER` on the backend Web App.

If bootstrap printed `CI_CAN_ASSIGN_ROLES=false`, the workflow stops before apply. Apply once from your laptop:

```bash
cd terraform/environments/dev
terraform init -backend-config=backend.hcl
terraform apply      # review, then type yes
terraform output
cd ../../..
```

## Step 6 — Give yourself access to the data

Shared keys are off. Your login needs a data role. Use the **same terminal** for Steps 6 to 14 (`$STORAGE` is a shell variable).

```bash
cd terraform/environments/dev
terraform init -backend-config=backend.hcl   # skip if you did Step 5 locally
STORAGE=$(terraform output -raw storage_account_name)
cd ../../..
az role assignment create \
  --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --role "Storage Blob Data Contributor" \
  --scope "$(az storage account show --name "$STORAGE" --query id -o tsv)"
```

Wait 2–5 minutes.

## Step 7 — Upload the dataset and start the pipeline

```bash
az storage blob upload --auth-mode login --account-name "$STORAGE" \
  --container-name bronze --name raw/energy_readings.csv \
  --file data/energy_readings.csv --overwrite
```

The upload starts `pl-energy-etl`.

## Step 8 — Watch the run in Data Factory

Portal → Data Factory (`terraform output data_factory_name`) → **Launch studio → Monitor → Pipeline runs**. Expect *In progress*, then *Succeeded*. The first run needs about 5 minutes (Spark cold start). Do not start a second run.

## Step 9 — Check silver and gold

```bash
for c in silver/energy_readings/ gold/by-timestamp/ gold/latest/; do
  az storage blob list --auth-mode login --account-name "$STORAGE" --container-name "${c%%/*}" --prefix "${c#*/}" --output table
done
az storage blob download --auth-mode login --account-name "$STORAGE" --container-name gold \
  --name latest/daily_energy_by_device.json --file /tmp/daily_energy_by_device.json && head -c 400 /tmp/daily_energy_by_device.json
```

`by-timestamp/` has one folder per run, like `20261101T093000Z/`. `latest/` copies the newest run. The full dataset gives 1825 records in `daily_energy_by_device.json`.

## Step 10 — See the SUCCEEDED card in Teams

Teams shows **CC2026 P2 pipeline SUCCEEDED** with file name, run ID, rows written and a run link.

## Step 11 — Make a run fail on purpose

`energy_invalid.csv` has no `kwh` column. The data flow checks the source schema and stops.

```bash
az storage blob upload --auth-mode login --account-name "$STORAGE" \
  --container-name bronze --name raw/energy_invalid.csv \
  --file data/energy_invalid.csv --overwrite
```

Monitor shows *Failed*. Teams shows **CC2026 P2 pipeline FAILED** with the error. Silver and gold keep the last good run.

## Safe to repeat

- The **same file** again, even 3 times: safe. Silver is overwritten. Each run adds a `gold/by-timestamp/` folder. `gold/latest/` shows the newest run. Runs queue one at a time. You get 3 cards.
- A **different or small file** replaces silver and `gold/latest/`. History stays. Upload `energy_readings.csv` again to restore.
- Each upload costs about €0.3. Wait for the Teams card before the next upload.

---

# Lab 2 — Write the two gold files

## Step 12 — Study the finished example: `daily_energy_by_device`

The whole data flow is one file: `terraform/modules/data-factory/dataflow/energy_etl.dfs` (`//` starts a comment). Read it once. This block builds the provided gold file:

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

## Step 13 — Build `energy_by_location.json` and `latest_readings.json`

Expected output for the full dataset (same field names and rounding):

| File | Shape |
|---|---|
| `energy_by_location.json` | 5 records `{location, total_kwh, devices, avg_kwh_per_day}`. `total_kwh` and `avg_kwh_per_day` have 3 decimals. `avg_kwh_per_day` = total kWh / number of different days |
| `latest_readings.json` | 200 records `{device_id, timestamp, temperature, humidity, kwh, location}`: the newest clean readings, newest first. `timestamp` stays text, like `2026-10-31T23:55:00Z` |

Correct files: Apps repository, `docs/p2/sample-data/gold/`. Your sinks use the same dataset as `GoldDaily`, so the pipeline copies them to `gold/latest/` for you.

**`energy_by_location`: fill the gaps.** Start from `DailyTotals`. It comes before the rounding, so your sums stay exact.

```text
DailyTotals aggregate(groupBy(<<TODO: which column is the key?>>),
    total_kwh = sum(total_kwh),
    devices   = <<TODO: count the different device_id values; hint: countDistinct>>,
    days      = <<TODO: count the different dates>>) ~> LocationTotals
LocationTotals derive(avg_kwh_per_day = <<TODO: total_kwh divided by days, rounded to 3 decimals>>,
    total_kwh = round(total_kwh, 3)) ~> RoundLocation
RoundLocation select(mapColumn(location, total_kwh, devices, avg_kwh_per_day),
    skipDuplicateMapInputs: true, skipDuplicateMapOutputs: true) ~> LocationColumns
LocationColumns sink(allowSchemaDrift: true, validateSchema: false,
    partitionFileNames:['energy_by_location.json'],
    umask: 0022, preCommands: [], postCommands: [],
    skipDuplicateMapInputs: true, skipDuplicateMapOutputs: true,
    partitionBy('hash', 1)) ~> GoldLocation
```

**`latest_readings`: hint.** Start from `AddTypedColumns`. Use three steps:

1. `sort(desc(timestamp, true), desc(device_id, true))`. ISO 8601 text sorts correctly.
2. `limit(200)`.
3. `select(mapColumn(...))` with only the six output columns (not `event_time` and `date`).

Finish with a sink like the one above. Use `partitionFileNames:['latest_readings.json']` and the name `GoldLatest`.

**How to work:**

1. Portal → Data Factory → **Launch studio → Author → Data flows → `df_energy_etl`**.
2. Turn on **Data flow debug** (costs money, see Cost). Add your transformations. Check **Data preview**.
3. Open the **Code `{ }`** view and copy your new lines.
4. Paste them into `terraform/modules/data-factory/dataflow/energy_etl.dfs`.
5. In `terraform/modules/data-factory/main.tf`, add the new stream names to `local.transformations`. Add `GoldLocation` and `GoldLatest` to `local.gold_sinks`.
6. Commit, push to `main` and run the **terraform** workflow with **apply** ticked:

   ```bash
   git commit -am "feat(data-factory): add gold files by location and latest readings"
   git push origin HEAD:main
   ```

7. Upload `energy_readings.csv` again (Step 7). After the green card, your files are in `gold/latest/`.

## Step 14 — Check your result

Set `APPS_REPO` to your Apps repository folder. Then compare:

```bash
APPS_REPO=../CC2026_<LastName>_<FirstName>_Apps
mkdir -p out
for f in energy_by_location latest_readings; do
  az storage blob download --auth-mode login --account-name "$STORAGE" \
    --container-name gold --name "latest/$f.json" --file "out/$f.json" --overwrite
  diff <(jq -S -s 'flatten' "out/$f.json") <(jq -S -s 'flatten' "$APPS_REPO/docs/p2/sample-data/gold/latest/$f.json") && echo "$f OK"
done
```

`... OK` means equal. A difference in the last decimal means a missing rounding step.

## Step 15 — Change a cleaning rule (and optional bonus)

The cleaning rules are in the stream `CleanRows`. Change the temperature limit `60` to `30`. Push, run the workflow, upload again and compare row counts in Monitor. Change it back.

**Bonus (optional):**

- A third gold file by hour of day (24 records), weekday (7) or month (12). Use `hour(event_time)`, `dayOfWeek(event_time)` or `month(event_time)` in a `derive`, then an `aggregate`.
- One more rule in `CleanRows`, like `kwh <= 5`. Upload a CSV with one bad row as `raw/bad_row.csv`. Show in Monitor that silver misses it.

## Step 16 — Next: Apps challenge

The backend reads **only `gold/latest/`** (settings `STORAGE_ACCOUNT_URL`, `GOLD_CONTAINER=gold`). Follow `docs/p2/challenge.md` in the Apps repository.

---

## Cost

One data flow run costs about €0.3. Ten test runs cost about €3 on top of P1. Idle resources cost cents.

- Each upload starts one run. **Wait for the Teams card before the next upload.**
- **The expensive trap is the Data Factory Studio debug session.** It keeps a Spark cluster running. The default time to live is 60 minutes. Follow these rules:
  1. Switch *Data flow debug* on only when you test.
  2. Set the debug **time to live to 15 minutes**.
  3. Switch it off when you finish.
  4. Check **Monitor** and **Cost Management → Cost analysis** (filter on your resource group) after each lab.
- Do not upload the big file in a loop. **Delete nothing until the final evaluation.** P3 and the final project use the same infrastructure.

## Troubleshooting

Rows marked "Not verified" come from documentation, not from a tested run.

| Symptom | Fix |
|---|---|
| `MissingSubscriptionRegistration` or `SubscriptionNotRegistered` for `Microsoft.EventGrid`, `Microsoft.DataFactory` or `Microsoft.Logic` | Re-run `bootstrap.sh`, or run `az provider register --namespace Microsoft.EventGrid --wait` |
| Workflow stops: plan creates role assignments | `CI_CAN_ASSIGN_ROLES=false`. Run `terraform apply` locally (Step 5) |
| Upload works, no pipeline run | Upload to `raw/<name>.csv` in container `bronze`. Check *Manage → Triggers*: status *Started*. Wait 1–2 minutes |
| `403 AuthorizationPermissionMismatch` | Do Step 6. Wait 5 minutes. Use `--auth-mode login`, never `--account-key` |
| curl shows 202, no Teams message | Power Automate → My flows → run history. The flow must post to a channel |
| Pipeline succeeded, no card | Check `TEAMS_WEBHOOK_URL`. Portal → Logic App → *Runs history* |
| Run *Failed* with a schema error on a good file | The CSV header differs from the six column names. Compare with `head -1 data/energy_readings.csv` |
| `Copy to latest` fails with `403` | Data Factory role not active yet. Wait 5 minutes and upload again |
| `RequestDisallowedByPolicy`, `LocationNotAvailableForResourceType` | Azure for Students limits regions and types. Re-run bootstrap with an allowed region (`AZURE_LOCATION=...`). Else ask your instructor. Not verified |
| `... cores quota ... exceeded` or `Operation cannot be completed without additional quota` | Low vCore quota. Ask your instructor. Try later or use another region. Not verified |
| `StorageAccountAlreadyTaken` | Name not unique. Change `project_name` or ask your instructor. Not verified |
