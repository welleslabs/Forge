# Forge

**Set up, run, and present Trend Vision One security demos from one macOS app.**

Forge is a native SwiftUI demo launcher for solutions engineers and lab users. It brings environment setup, per-product credentials, lab guides, live scan controls, AI Guard attack demonstrations, and console output into one place.

Use it to demonstrate how security applies across an AI application's lifecycle: inspect source code and dependencies, audit container images, red-team a local language model, and compare model behavior with runtime guardrails enabled and disabled.

## Start here

1. [Install and launch Forge](#install-and-launch-forge).
2. [Configure your projects folder and credentials](#first-time-configuration).
3. [Set up the environment](#set-up-the-environment).
4. [Run a demo](#how-to-run-the-demos).
5. [Review results](#results-and-local-files) and [clean up](#reset-and-teardown).

More help: [Mock versus Live](#mock-versus-live) · [Command-line workflows](#command-line-workflows) · [Troubleshooting](#troubleshooting) · [Lab guides](#lab-guides) · [Development](#development)

## What is included?

| Feature | Current availability | What it does |
| --- | --- | --- |
| AI Scanner | Runnable; real tmas scan | Red-teams a local Ollama model for prompt attacks, data leakage, and unsafe output. |
| AI Guard | Runnable; hosted guardrails API | Demonstrates prompt and response inspection, with an unprotected local-model comparison. |
| Code Security | Runnable; Mock or Live | Scans a sample application's source and dependencies. Live results upload as a Directory artifact. |
| Container Security | Runnable; Mock or Live | Scans the sample application's container image. Live results upload as a container image artifact. |
| Cloud Risk Management | Coming-soon app preview | A catalog preview; supporting standalone lab scripts remain in the repository. |
| AI Detection and Response | Coming-soon app preview | A catalog preview without a runnable app workflow. |
| Data Security Posture | Coming-soon app preview | A catalog preview without a runnable app workflow. |

The repository also retains standalone AI Secure Access and AI Risk Insights labs. These are not active product pages in the current app. See [Additional standalone labs](#additional-standalone-labs).

### How the pieces fit together

- **Forge** orchestrates scripts and presents their output.
- **Ollama** serves the shared local model used by AI Scanner and AI Guard.
- **tmas** performs real AI, source, and container scans.
- **Trend Vision One** supplies hosted AI Guard decisions and receives supported live scan results.
- **Colima + Docker CLI**, or an existing reachable Docker daemon, supports the live container build.
- **SwiftTerm** provides the embedded terminal for interactive scans.

AI Scanner and AI Guard reuse one local model environment. Code Security and Container Security share one scan environment, sample application, and API-key setting.

## Install and launch Forge

### Requirements

| Requirement | Details |
| --- | --- |
| Operating system | macOS 14 Sonoma or later for the SwiftUI application. |
| Build tools | Swift 5.9 or later and Apple's command-line developer tools. |
| Git | Needed to clone and update this repository. |
| Python | Python 3 for the Python-backed lab scripts. |
| Disk space | Allow about 6 GB for the shared model and tooling; container images and build caches need additional space. |
| Network | Required for initial downloads and live Trend Vision One operations. |
| Vision One access | Required for AI Scanner, hosted AI Guard, and live artifact scans, with permissions appropriate to each product. |

The macOS scripts include architecture handling for Apple Silicon and Intel. Available model choices and execution speed depend on the machine.

### Build from source

Install Apple's command-line tools if they are not already installed:

```bash
xcode-select --install
```

Then clone and build:

```bash
git clone https://github.com/welleslabs/Forge.git
cd Forge
bash build-app.sh
open Forge.app
```

The build script resolves Swift dependencies, builds the release executable, generates the icon, assembles `Forge.app`, and attempts ad-hoc signing. It also attempts to copy the app to `~/Desktop/Forge.app`.

**Rebuilding replaces the generated app in the checkout and the Desktop copy.** Keep the repository folder: the app bundle does not include the lab scripts or Word guides.

If macOS blocks the locally built app, review the message in **System Settings → Privacy & Security** and use the system's per-app approval flow after verifying the source.

### Update an existing checkout

From your Forge checkout, first inspect any local changes:

```bash
git status
git pull --ff-only
bash build-app.sh
open Forge.app
```

Close the running app before replacing it. If Git reports local changes or a divergent branch, resolve that state before updating; these commands do not discard your work.

## First-time configuration

Open **Settings** from the sidebar or press **⌘,**.

### 1. Choose the projects folder

Select the **repository root**: the folder containing `AI Scanner`, `AI Guard`, `Code & Container Security`, and `Sources`.

For a normal clone, select your `Forge` folder. Automatic detection checks older Desktop folder names, so a fresh clone elsewhere usually needs this explicit selection.

Do not select `Forge.app`, its `Contents` directory, or an individual lab subfolder.

### 2. Select the Trend Vision One region

Choose the region where your tenant and API keys belong. The region is shared by live scans and the **View in Vision One** links.

A key from another region can fail authorization. Use the region associated with your tenant rather than the region geographically closest to your Mac.

### 3. Set a demo label

Choose a short label to distinguish your uploads from other presenters in a shared tenant. Forge sanitizes the label to letters and numbers, up to 20 characters. A blank label uses a machine-derived default.

### 4. Enter product credentials

Create or obtain keys through **Trend Vision One → Administration → API Keys**, with the appropriate product permissions.

| Setting | Used for | Required permissions / preparation |
| --- | --- | --- |
| AI Scanner → Vision One API Key | Real AI scans through tmas | Role must include **Run AI scan**. |
| AI Guard → Vision One API Key | Hosted prompt and response inspection | AI Guard permissions; configure the relevant AI Guard policy in your tenant before presenting. |
| Code Security / Container Security → Vision One API Key | Live source and image scans | Code Security and Container Security artifact/image scanning permissions. Entering the shared key in either product configures both. |

Settings are persisted locally through macOS UserDefaults. Some execution paths also stage credential files on disk; this implementation does not use Keychain for these settings. Do not include real keys in source code, screenshots, exported console text, or support attachments.

A separate ngrok account is **not required** for the current AI Scanner or hosted AI Guard app workflows.

## Mock versus Live

The **Lab data mode** setting controls supported hybrid labs; it is not a global offline switch.

| Workflow | Mock setting | Live setting |
| --- | --- | --- |
| AI Scanner | Still performs a real tmas AI scan | Performs a real tmas AI scan |
| AI Guard with protection enabled | Uses hosted AI Guard | Uses hosted AI Guard |
| AI Guard with protection disabled | Calls the local model without guardrails | Calls the local model without guardrails |
| Code Security | Local dependency/source analysis using seeded data | Real tmas source scan and upload, with fallback if unavailable |
| Container Security | Local Dockerfile hardening analysis | Real image scan and upload, with fallback if unavailable |

A container Mock run does not perform a real image-layer malware or vulnerability scan.

For the Code/Container labs, inspect console messages before describing a result as live. If a live operation is unavailable or fails, the scripts can fall back to Mock. The image workflow can also fall back to a public image when the local demo image is unavailable.

## Set up the environment

1. Open **Environment**.
2. Under **Include in setup**, select the products you intend to present.
3. Review **Will install**.
4. Click **Set Up Environment** and monitor the console.
5. Confirm setup and status checks complete before starting a demo.

| Environment | Selected by | What setup prepares |
| --- | --- | --- |
| Local LLM Lab | AI Scanner / AI Guard | Ollama, a demo model, and tmas when needed for AI Scanner. |
| Code & Container Scan Lab | Code Security / Container Security | Seeded sample application; in Live mode, tmas, a container runtime when needed, and the demo image. |

Setup detects existing tools and reuses shared components. Initial model and image downloads can take time. For live Code/Container scans, select **Live** before running setup so it provisions the live scan environment.

The AI Scanner setup expects the macOS tmas download from your tenant's **AI Application Security → AI Scanner → Set Up** flow when it needs the console-delivered CLI. Leave the downloaded ZIP in `~/Downloads` and rerun setup if prompted.

The model setup deliberately prepares a permissive demonstration target. Its startup script binds Ollama to `0.0.0.0:11434` with permissive origins, so network reachability can extend beyond localhost depending on your firewall. Run this on a controlled demo machine/network and stop it when finished.

## How to run the demos

### AI Scanner

**Purpose:** demonstrate pre-deployment red-teaming against a real local LLM.

1. Add the AI Scanner key and correct tenant region in Settings.
2. Set up the Local LLM Lab through Environment.
3. Open **AI Scanner**.
4. Open **Lab Guide** for the detailed walkthrough.
5. Choose **Guided selector** or **tmas wizard**.
6. Start **Run** and review the embedded console.
7. Review the uploaded scan in your tenant's **AI Application Security → AI Scanner** area.

#### Guided selector

- **Fast** runs the curated data-leak battery against a target loaded with synthetic demo data. Use it for a focused live presentation.
- **Full** runs that battery first, followed by the full built-in objective/technique matrix. Run it before a meeting when you need a broader report.
- Where the selector offers individual controls, choose the attack objectives, techniques, and optional modifiers you need.

Preset timing and severity counts shown in the interface are demo expectations, not guaranteed outcomes. Hardware, model selection, CLI behavior, and judging affect the result.

#### tmas wizard

The embedded terminal supports **arrow keys** to move, **Space** to toggle, and **Enter** to confirm.

Use the values shown in the app:

| Wizard input | Value |
| --- | --- |
| Model group name | Copy the generated model-group name displayed in Forge. |
| Target endpoint | `http://localhost:11434/v1` |
| Target API key | `ollama` — the local endpoint's placeholder, not your Vision One key. |

Keep wizard selections modest for a live presentation. The guided path controls concurrency; the interactive wizard uses the CLI's own behavior.

### AI Guard

**Purpose:** compare an unprotected local model with hosted prompt and response guardrails.

1. Add the AI Guard key and configure your tenant's AI Guard policy.
2. Set up the shared local model through Environment.
3. Open **AI Guard** and its Lab Guide.
4. Disable AI Guard for an unprotected baseline.
5. Run a selected Attack Library item and inspect the model reply.
6. Enable AI Guard and run a comparable attack.
7. Read the returned action and reason in the console. Use **Run All** for a sequential walkthrough.

The library covers prompt injection, sensitive-information disclosure, improper-output-handling examples, and system-prompt leakage. Prompts can change between runs. The local model is given a fictional enterprise context containing synthetic records and secrets.

With hosted protection enabled, Forge inspects the prompt; permitted traffic can proceed to the local model, and its reply is inspected before display. The app withholds replies when output inspection returns Block or Redact.

**Interpret the result:** Allow, Alert, Block, and Redact depend on the real service response and policy. A permitted prompt can still lead to a blocked response. An inspection failure is shown as unknown; the current output path can display the reply unguarded in that case. Treat this as demonstration behavior, not a fail-closed production gateway.

The normal app workflow uses the hosted API. The retained `AI Guard/guard-lab.sh` script is a separate proxy-based workflow with its own tmguard setup and policy-ID requirements; it is not required for the hosted app demonstration.

### Code Security

**Purpose:** show source/dependency findings before an application ships.

1. Choose **Mock** or **Live** in Settings.
2. For Live, add the shared Code/Container key and confirm the region.
3. Set up the Code & Container Scan Lab.
4. Open **Code Security**.
5. Click **Scan Code & Dependencies**.
6. Inspect the console summary.
7. For a successful live upload, open **Vision One → Code Security → CI/CD Artifacts**.

A live source scan is uploaded as a **Directory** artifact. Mock mode checks the seeded source and dependencies locally. Use **Reset Lab** to restore the demo application and clear local mock findings.

### Container Security

**Purpose:** demonstrate findings in the built image of the same sample application.

1. Set the desired data mode and shared Code/Container credentials.
2. Run environment setup; in Live mode, confirm the runtime and image are ready.
3. Open **Container Security**.
4. Click **Audit Container Image**.
5. Read the console to confirm whether it scanned the local image, a public fallback image, or Mock data.
6. For a successful live upload, open **Vision One → Cloud Security → Container Security → Log → Container Image Scanning**.

The live image path builds `forge-app:latest`, exports it with `docker save`, and scans the archive with tmas. The export is cached while the image is unchanged. Live scans request vulnerability, malware, and secret inspection by default.

The sample image intentionally contains vulnerable components and an EICAR test file for demonstration. Keep it confined to the lab.

Code and image scans create different artifact types. Seeing both entries in Vision One is expected. **Reset Lab** restores the local sample and clears cached scan exports; it leaves installed tools and the built image in place.

## Results and local files

| Location | Contents |
| --- | --- |
| Forge console | Process output, scan progress, guardrail decisions, and local-model replies. |
| Vision One | Uploaded live AI/source/image scan results and relevant product activity. Mock results are not equivalent to tenant findings. |
| `~/.trend-lab/` | Shared runtime state, selected model metadata, logs, and per-lab working data. |
| `~/.trend-lab/labs/code-container/` | Seeded app/data, mock findings, and cached image exports. |
| `~/.tmas/.env` | Staged tmas API-key configuration when written by the workflow. |
| `AI Scanner/debug/` | Scanner diagnostic/report artifacts when produced by a run. |

Use the console's **Copy** control to capture output, **Clear** to clear the display, and **Stop** to cancel a running operation. Console size controls expand the reading area.

Review copied output and diagnostic files before sharing them: they can contain prompts, synthetic records, paths, and service responses. Clearing the display does not delete saved files or tenant results.

## Reset and teardown

### Reset one lab

Use **Reset Lab** on Code Security or Container Security. Both refer to the same lab, so resetting either affects their shared local sample data.

### Quick Teardown

Open **Environment → Teardown → Quick Teardown**.

This stops shared lab services and removes runtime/lab state for the components recorded as set up, while keeping the model and installed tools for reuse. The shared LLM teardown deletes `~/.trend-lab`, so preserve any local results you need first.

AI Scanner and AI Guard share Ollama: stopping it affects both demos.

### Full Teardown

Use **Full Teardown — remove model, tools & configs** only when you want the broader cleanup.

**The shared LLM cleanup deletes the entire `~/.ollama` directory, including Ollama models used outside Forge.** It also attempts to uninstall Homebrew Ollama, remove tmas, and delete lab/config directories. The app invokes the script's noninteractive full-cleanup path after its own confirmation.

The container cleanup removes the lab image and state; its full path also stops Colima. It does not uninstall every container tool or remove every unrelated image.

Local cleanup does not revoke tenant API keys or delete uploaded Vision One findings. Handle those separately in the relevant console. Do not assume full teardown clears every persisted app preference; inspect Settings afterward.

## Command-line workflows

Run these commands from the repository root. Shell scripts do not inherit values saved in Forge's Settings; provide required environment variables separately or use the script's configuration prompts.

### Shared local model and AI Scanner

```bash
bash "AI Scanner/lab.sh" setup
bash "AI Scanner/lab.sh" status
bash "AI Scanner/lab.sh" scan
bash "AI Scanner/lab.sh" teardown
```

Use `bash "AI Scanner/lab.sh" help` for script options. For guided CLI execution, `FORGE_SCAN_MODE=guided` and the `FORGE_SCAN_*` variables configure the selection; the app is the easier way to generate it consistently.

### Code and container scans with Mock data

```bash
bash "Code & Container Security/lab.sh" setup
bash "Code & Container Security/lab.sh" status
bash "Code & Container Security/lab.sh" scan-code
bash "Code & Container Security/lab.sh" scan-image
bash "Code & Container Security/lab.sh" reset
bash "Code & Container Security/lab.sh" teardown
```

For standalone Live runs, set `TREND_LAB_MODE=live`, `V1_REGION`, and `CCS_API_KEY` in your shell environment before setup and scanning. Optional `FORGE_DEMO_ID` distinguishes uploads. Never place a real key in committed files.

## Additional standalone labs

These retained scripts provide supplemental workflows outside the current app catalog. They need Python 3 and keep state under `~/.trend-lab/labs/` by default.

| Lab | Commands after `setup` | Notes |
| --- | --- | --- |
| Cloud Risk Management | `assess`, `attack-path`, `remediate`, `status`, `reset`, `teardown` | Assessment can attempt Live with `TREND_LAB_MODE=live` and `V1_API_KEY`; failures fall back to seeded data. Attack-path and remediation remain mock narrative operations. |
| AI Secure Access | `replay`, `shadow-report`, `status`, `reset`, `teardown` | Replays seeded traffic through a local policy engine; it does not deploy a production access gateway. |
| AI Risk Insights | `report`, `status`, `reset`, `teardown` | Aggregates available sibling-lab outputs and local signals using the lab's scoring configuration. |

Example sequence:

```bash
bash "Cloud Risk Management/lab.sh" setup
bash "Cloud Risk Management/lab.sh" assess
bash "Cloud Risk Management/lab.sh" attack-path
bash "Cloud Risk Management/lab.sh" remediate

bash "AI Secure Access/lab.sh" setup
bash "AI Secure Access/lab.sh" replay
bash "AI Secure Access/lab.sh" shadow-report

bash "AI Risk Insights/lab.sh" setup
bash "AI Risk Insights/lab.sh" report
```

For these script-only labs, `TREND_LAB_HOME` can override their default state root. This override is not consistently used by the app's shared-model workflow, which uses `~/.trend-lab`.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| App cannot find a script or guide | Set Projects Folder to the repository root. Keep the full checkout alongside the separately built app. |
| `swift` or compiler unavailable | Install/select Apple's developer tools and verify `swift --version`. The app requires Swift 5.9+ and macOS 14+. |
| SwiftTerm / Metal build error | The package intentionally uses SwiftTerm 1.11.x, below 1.12.0. Preserve the declared version range and resolve dependencies again. |
| tmas missing during AI Scanner setup | Download the macOS CLI ZIP through your tenant's AI Scanner setup flow, leave it in Downloads, and rerun setup. Follow the exact setup error if the download is not found. |
| Model is not running | Reopen Environment, select AI Scanner or AI Guard, and rerun setup/status. Check `~/.trend-lab/ollama.log`. |
| Port 11434 is occupied | Run `lsof -nP -iTCP:11434 -sTCP:LISTEN` to identify the listener. Resolve the conflict before rerunning setup. |
| API authorization fails / HTTP 403 | Check key validity, tenant region, product permissions, and policy configuration. For AI Guard, distinguish a structured policy Block from an authentication failure. |
| Live Code/Container scan shows no tenant finding | Read the console for fallback messages. Confirm Live mode, the shared product key, successful upload, and the correct artifact location. |
| Container run scans a public image | The local runtime, build, or export was unavailable. Start a reachable Docker daemon or rerun Live environment setup, then check the console. |
| Full AI scan takes a long time | Full includes a much larger matrix. Use Fast for a focused live walkthrough; run Full ahead of the presentation. |
| Wizard keys do not respond | Click into the embedded terminal, then use arrows, Space, and Enter. Use Guided selector if you do not need the interactive CLI. |
| Guard permits an example attack | Verify the tenant policy, read prompt and response verdicts separately, and review product activity. A demo category does not guarantee a Block. |
| Another operation cannot start | Stop or finish the current process first. Forge serializes foreground work. |
| A preview has no Run button | Coming-soon entries do not have active app phases. Use only the runnable products listed above. |

## Lab guides

Open guides from their product pages or use the repository links below. These are Word documents; download them to read in Word or another compatible application.

- [AI Scanner guide](AI%20Scanner/Trend%20Vision%20One%20-%20AI%20Scanner%20Demo%20Lab.docx)
- [AI Guard guide](AI%20Guard/Trend%20Vision%20One%20-%20AI%20Guard%20Demo%20Lab.docx)
- [Code & Container Security guide](Code%20%26%20Container%20Security/Trend%20Vision%20One%20-%20Code%20%26%20Container%20Security%20Demo%20Lab.docx)
- [Cloud Risk Management guide](Cloud%20Risk%20Management/Trend%20Vision%20One%20-%20Cloud%20Risk%20Management%20Demo%20Lab.docx)
- [AI Secure Access guide](AI%20Secure%20Access/Trend%20Vision%20One%20-%20AI%20Secure%20Access%20Demo%20Lab.docx)
- [AI Risk Insights guide](AI%20Risk%20Insights/Trend%20Vision%20One%20-%20AI%20Risk%20Insights%20Demo%20Lab.docx)

The active app catalog and executable scripts define what is runnable. Retained guides can describe separate proxy or standalone workflows.

## Development

```bash
swift build
swift run TrendDemoLauncher
```

| Path | Responsibility |
| --- | --- |
| `Package.swift` | Swift executable target and SwiftTerm dependency range. |
| `Sources/TrendDemoLauncher/ProjectData.swift` | Product catalog, credentials, phases, and shared environment definitions. |
| `Sources/TrendDemoLauncher/DemoRunner.swift` | Process execution, environment orchestration, and AI Guard requests. |
| `Sources/TrendDemoLauncher/CredentialManager.swift` | Subprocess environment and credential staging. |
| `Sources/TrendDemoLauncher/AppSettings.swift` | Persisted settings and typed accessors. |
| `Sources/TrendDemoLauncher/DemoShowcaseView.swift` | Scanner presets and attack-library controls. |
| `Sources/TrendDemoLauncher/Theme.swift` | Appearance tokens and font scaling. |
| `AI Scanner/`, `AI Guard/`, `Code & Container Security/` | Active demo scripts, sample assets, and guides. |
| `build-app.sh` | Release build, app assembly, icon generation, and signing. |

Use Settings to choose System, Light, or Dark appearance. Use the app's View menu to adjust interface font size.

When adding a product, define its runnable phases and environment requirements in the catalog, connect its script entry point, and update this README to match the resulting behavior.
