# P2 — Data Pipeline Walkthrough (Azure)

P2 adds an ETL pipeline to your P1 infrastructure. You upload a CSV file with energy readings. Azure cleans it and writes the results. Teams tells you if it worked.

```text
upload CSV -> bronze/raw/ -> storage event -> Data Factory pipeline -> Mapping Data Flow
                                                  |                       |-> silver/ (clean Parquet)
                                                  |                       '-> gold/by-timestamp/<run>/ (history) -> Copy -> gold/latest/
                                                  '-> Logic App -> Teams card (SUCCEEDED / FAILED)
```

| Zone | Container | Content |
|---|---|---|
| bronze | `bronze` | Raw upload. You never change it |
| silver | `silver` | Clean, typed Parquet: `energy_readings/` |
| gold | `gold` | Small JSON files. Every run writes `by-timestamp/<yyyyMMddTHHmmssZ>/<file>.json` (history, never deleted) and then copies the files to `latest/`. The backend reads **only `gold/latest/`** |

### Medallion in one minute

The same reading travels through three layers. Each layer answers one question.

| Layer | Question it answers | One reading in this layer |
|---|---|---|
| Bronze | What did we receive? | `device-001,2025-11-01T00:00:00Z,20.81,57.53,0.0575,Office-A`: text, exactly as uploaded, bad rows included |
| Silver | Which rows can we trust? | The same reading with real types: `timestamp` is a timestamp, `kwh` is a number, one row per `device_id` + `timestamp`. Stored as Parquet in `silver/energy_readings/` |
| Gold | What does the dashboard ask? | 288 silver readings of one day become 1 record: `{"device_id":"device-001","location":"Office-A","date":"2025-11-01","total_kwh":18.419,"avg_temperature":21.09,"avg_humidity":55.02,"readings":288}` |

- You never change bronze. If a cleaning rule is wrong, fix the rule and run again from bronze.
- Silver is large and clean. Only the pipeline reads it.
- Gold is small and shaped for one question. The backend reads only gold. 500,000 rows never go to the browser.
- Each layer is rebuilt from the layer before it. This is why uploading again is safe.

## What is provided and what you build

| Part | Who |
|---|---|
| Storage, Data Factory, trigger, pipeline, Teams notification, roles, silver (clean Parquet) | **Provided** (Terraform) |
| Gold file `daily_energy_by_device.json` | **Provided**: the worked example |
| Gold files `energy_by_location.json` and `latest_readings.json` | **You build them** (Lab 2) |
| A third gold file of your own (hour of day, weekday or month) and an extra data-quality rule | Optional bonus |

- **Lab 1** (Steps 1 to 11): deploy, upload the CSV, see the silver files and the green Teams card, then the red card.
- **Lab 2** (Steps 12 to 15): write the two gold files.
- **Next** (Step 16): the Apps challenge.

Use the same placeholders as in the P1 walkthrough (`<LastName>_<FirstName>`, `<github-user>`, `<initials>`).

**Time:** about 60 minutes. **Do not edit anything in the Data Factory portal.** The portal is for watching only. Terraform owns every resource and overwrites portal edits at the next apply.

---

# Lab 1 — Deploy and run the pipeline

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
az storage blob list --auth-mode login --account-name "$STORAGE" --container-name gold --prefix by-timestamp/ --output table
az storage blob list --auth-mode login --account-name "$STORAGE" --container-name gold --prefix latest/ --output table
az storage blob download --auth-mode login --account-name "$STORAGE" --container-name gold \
  --name latest/daily_energy_by_device.json --file /tmp/daily_energy_by_device.json && head -c 400 /tmp/daily_energy_by_device.json
```

`by-timestamp/` has one folder per run, for example `by-timestamp/20261101T093000Z/`. `latest/` has a copy of the newest run. Silver has only the data of the newest run. The full dataset gives 1825 records in `daily_energy_by_device.json`.

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

## Safe to repeat

- Uploading the **same file** again, even 3 times, is safe. Silver is overwritten. Each run adds a new folder under `gold/by-timestamp/`. `gold/latest/` shows the newest run. The runs wait in a queue and run one at a time. You get 3 Teams cards.
- Uploading a **different or small test file** replaces silver and `gold/latest/` with the data of that file. The history stays in `gold/by-timestamp/`. Upload the full `energy_readings.csv` again to restore the normal state.
- Each upload is one data flow run (about €0.3). Wait for the Teams card before you upload again.

---

# Lab 2 — Write the two gold files

Gold files are small summaries. The backend reads only gold, never the 500 000 silver rows.

## Step 12 — Study the finished example: `daily_energy_by_device`

The whole data flow is one text file: `terraform/modules/data-factory/dataflow/energy_etl.dfs`. Lines that start with `//` are comments. This block builds the provided gold file. Each line says what it does:

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

`AddTypedColumns` is the clean stream from the earlier steps. It has the columns `device_id`, `timestamp` (text), `temperature`, `humidity`, `kwh`, `location`, `event_time` (a real timestamp) and `date` (`YYYY-MM-DD`). Read the full file once.

## Step 13 — Build `energy_by_location.json` and `latest_readings.json`

**Expected output** for the full dataset. Use the same field names and the same rounding:

| File | Shape |
|---|---|
| `energy_by_location.json` | 5 records `{location, total_kwh, devices, avg_kwh_per_day}`. `total_kwh` and `avg_kwh_per_day` have 3 decimals. `avg_kwh_per_day` = total kWh / number of different days |
| `latest_readings.json` | 200 records `{device_id, timestamp, temperature, humidity, kwh, location}`: the newest clean readings, newest first. `timestamp` stays text, like `2026-10-31T23:55:00Z` |

The correct files are in the Apps repository: `docs/p2-sample-data/gold/`. Your sinks use the same dataset as `GoldDaily`, so they write to the run folder automatically. The pipeline then copies the run folder to `gold/latest/`: you do not write any copy code.

**`energy_by_location`: fill the gaps.** Start from the stream `DailyTotals`. It comes before the rounding, so your sums stay exact.

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

**`latest_readings`: hint.** Start from `AddTypedColumns`. You need three steps:
1. `sort(desc(timestamp, true), desc(device_id, true))`. The text timestamps sort correctly because they are ISO 8601.
2. `limit(200)`.
3. `select(mapColumn(...))` that keeps only the six output columns (not `event_time` and `date`).

Finish with a sink like the one above, with `partitionFileNames:['latest_readings.json']`.

**How to work (important):**

1. Data Factory Studio helps you build and test. Portal → your Data Factory → **Launch studio → Author → Data flows → `df_energy_etl`**. Turn on **Data flow debug**. It costs money while it runs, so turn it off when you finish. Add your transformation and check the numbers in **Data preview**.
2. Open the **Code `{ }`** view (or **Script**) and copy your new lines.
3. Paste them into `terraform/modules/data-factory/dataflow/energy_etl.dfs` in your repository.
4. In `terraform/modules/data-factory/main.tf`, add the new stream names to `local.transformations` and the new sink names (`GoldLocation`, `GoldLatest`) to `local.gold_sinks`.
5. Commit, push to `main` and run the **terraform** workflow:

   ```bash
   git commit -am "feat(data-factory): add gold files by location and latest readings"
   git push origin HEAD:main
   ```

6. Upload `energy_readings.csv` again (Step 7) and wait for the green Teams card. Your files appear in `gold/latest/` and in a new `gold/by-timestamp/<run>/` folder.

**Never keep a change only in the portal.** Terraform overwrites it at the next apply. The file in the repository is the truth.

## Step 14 — Check your result

Set `APPS_REPO` to the folder of your Apps repository, then compare:

```bash
APPS_REPO=../CC2026_<LastName>_<FirstName>_Apps
mkdir -p out
for f in energy_by_location latest_readings; do
  az storage blob download --auth-mode login --account-name "$STORAGE" \
    --container-name gold --name "latest/$f.json" --file "out/$f.json" --overwrite
  diff <(jq -S -s 'flatten' "out/$f.json") <(jq -S -s 'flatten' "$APPS_REPO/docs/p2-sample-data/gold/$f.json") && echo "$f OK"
done
```

`... OK` means that your file equals the expected file. `jq` accepts a JSON array and also one JSON object per line. A difference in the last decimal usually means that a rounding step is missing.

## Step 15 — Change a cleaning rule (and optional bonus)

All cleaning rules are in the stream `CleanRows`. Change the temperature limit from `60` to `30`, push, run the workflow, upload again and compare the row counts in Monitor. Change it back afterwards.

**Bonus (optional):**
- A third gold file of your own that groups by time: hour of day (24 records), weekday (7) or month (12). Use `hour(event_time)`, `dayOfWeek(event_time)` or `month(event_time)` in a `derive`, then an `aggregate`.
- One more data-quality rule in `CleanRows`, for example `kwh <= 5`. Make a small CSV with one bad row, upload it as `raw/bad_row.csv` and show in Monitor that the row is missing in silver.

## Step 16 — Next: Apps challenge

The backend has read access to the storage account and the settings `STORAGE_ACCOUNT_URL` and `GOLD_CONTAINER=gold`. It reads **only `gold/latest/`**. Go to the Apps repository and follow `docs/p2-challenge.md`. You read the gold files in the backend and show charts in the frontend.

---

## Cost

| Item | Cost |
|---|---|
| One data flow run (General Purpose, 8 cores in total, cold start included) | about €0.3 |
| About 10 test runs | about €3, on top of the P1 cost |
| Storage, Logic App, Data Factory when idle | cents per month |

- Each upload starts one run. **Wait for the Teams card before the next upload.**
- **The expensive trap is the Data Factory Studio debug session.** *Data flow debug* keeps a Spark cluster running for the whole session. The default time to live is 60 minutes. Follow these rules:
  1. Switch *Data flow debug* on only when you test.
  2. Set the debug **time to live to 15 minutes** in the debug settings.
  3. Switch *Data flow debug* off when you finish.
  4. Check **Monitor** and **Cost Management → Cost analysis** (filter on your resource group) after each lab.
- The pipeline uses the smallest data flow size (General Purpose, 8 cores in total). It uses no time to live and no own integration runtime, so nothing runs between the runs.

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
| `RequestDisallowedByPolicy` when Terraform creates the storage account, the Data Factory or the Logic App | Azure for Students policy allows only some regions or resource types. The new resources use your `location` variable, like P1 | Re-run `bootstrap.sh` with an allowed region (`AZURE_LOCATION=...`). If a resource type is blocked, tell your instructor. Not verified |
| `SubscriptionNotRegistered` or `MissingSubscriptionRegistration` for `Microsoft.EventGrid` when the trigger is created | Event Grid provider not registered | `az provider register --namespace Microsoft.EventGrid --wait`. Not verified |
| Data flow run fails: `... cores quota ... exceeded` or `Operation cannot be completed without additional quota` | Student subscriptions can have a low data flow (vCore) quota in a region | Ask your instructor. Try again later or use another allowed region. Not verified |
| Data Factory or Logic App creation fails with `LocationNotAvailableForResourceType` | The service is not offered in that region for your subscription | Choose another allowed region (re-run bootstrap). Not verified |
| Storage account creation fails with a name or `StorageAccountAlreadyTaken` error | Name not unique | Change `project_name` or ask your instructor. Not verified |
| Copy to latest fails with `403` | Data Factory role not active yet | Wait 5 minutes and upload again |
