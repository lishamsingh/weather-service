# Weather Service Plan (.NET 10 + Azure Container Apps, free setup)

Prepared for a Mac mini (M1) using VS Code, GitHub Free and Azure free tiers.

## 1. Goal

A .NET 10 backend with two weather endpoints and a console job. The job calls the scheduled endpoint **Monday to Friday at 4:30 PM Central US time**. Everything lives in one public GitHub repo, is built by GitHub Actions, and runs on Azure Container Apps as containers.

## 2. Decisions and defaults

| Topic | Decision |
| --- | --- |
| Weather provider | WeatherAPI.com (free account and API key) |
| Units and fields | Fahrenheit. Temperature, feels-like, conditions, humidity, wind, location name, local time |
| Scheduled result | Logged as structured output (viewable in Azure logs) |
| Fixed zip code | `10001` placeholder, set through config (change anytime) |
| API exposure | Public ingress |
| Security | Manual endpoint: `X-Api-Key` header. Scheduled endpoint: Entra app role `JobExecute` held by the job's managed identity |
| Azure scripting | `az` CLI scripts, region Central US |
| Code style | Minimal APIs, OpenAPI in Development only, xUnit tests, no caching |
| Repo | Public. No secrets in code |
| Project names | `Weather.Api`, `Weather.Job`, `Weather.Contracts` |

## 3. Repo layout

```
weather-service/
├── global.json
├── Directory.Build.props
├── WeatherService.slnx
├── .dockerignore  .gitignore
├── src/
│   ├── Weather.Api/        (Dockerfile)
│   ├── Weather.Job/        (Dockerfile)
│   └── Weather.Contracts/
├── tests/
│   ├── Weather.Api.Tests/
│   └── Weather.Job.Tests/
├── infra/                  (az CLI scripts)
├── .github/workflows/      (CI/CD)
├── docker-compose.yml
└── .env.example            (no real secrets)
```

## 4. API (Weather.Api)

- `GET /api/weather/{zipCode}`: today's weather for any 5-digit US zip. Protected by the API key.
- `POST /api/weather/scheduled`: weather for the configured zip. Requires the `JobExecute` role.
- `GET /health`: used by Container Apps probes.
- `IWeatherProvider` with `WeatherApiProvider` through `HttpClientFactory`. The key comes from the `WeatherApi__Key` environment variable.

## 5. Job (Weather.Job)

- Gets a token with `DefaultAzureCredential`, calls the scheduled endpoint, logs the result.
- Exits non-zero on failure so Azure marks the run failed. Retries transient failures.
- **Schedule:** Container Apps cron is UTC only, so use `30 21,22 * * 1-5`. The app checks the time in `America/Chicago` and exits quietly unless it is the 4 PM hour there (`Job:RunAtCentralHour`, default 16). This handles daylight saving automatically.

## 6. Docker

- Multi-stage, non-root images: `sdk:10.0` to build, then `aspnet:10.0` (API) or `runtime:10.0` (job).
- Build context is the repo root. Tags: git SHA and `latest`.
- Published to ghcr.io as public images (free, no pull credentials needed).
- Apple Silicon note: local builds are arm64. Azure runs linux/amd64, and GitHub Actions builds the amd64 images.

## 7. CI/CD (GitHub Actions)

1. Restore, build and test on every push and pull request.
2. On `main`: build both images and push to ghcr.io.
3. Log in to Azure with OIDC (no stored passwords).
4. Update the Container App and the Job to the new image tag.

## 8. Azure resources (Consumption plan)

- Resource group and Container Apps environment (Central US).
- Container App `ca-weather-api`: public ingress, scale to zero.
- Container Apps Job `caj-weather-daily`: schedule trigger, managed identity.
- Entra app registration with the `JobExecute` app role, assigned to the job's identity.
- Weather key and API key stored as Container Apps secrets.
- Budget alert (for example $1) as a safety net.

## 9. Cost expectation

- **GitHub:** $0 (public repo, unlimited Actions minutes, free ghcr.io images).
- **Azure Container Apps:** monthly free grant of 180,000 vCPU-seconds, 360,000 GiB-seconds and 2 million requests. Jobs incur no usage charges when not running. One short run per weekday plus occasional manual calls should fit well inside the grant.
- **Unconfirmed:** Log Analytics ingestion. Expected to be tiny. Verify together during setup.
- **WeatherAPI.com:** free tier.
- **Caveat:** Azure still requires a credit card at signup. The free trial credit is time-limited, and anything beyond the free grants is billed. Keep the budget alert on.

## 10. Local testing and `JobExecute`

Managed identity exists only on Azure. Locally, `DefaultAzureCredential` falls back to `az login` or a dev service principal, so the code stays the same. In Development, a switch can relax the role check for first tests.

## 11. Accounts checklist

- [ ] GitHub: two-factor authentication on, username noted
- [ ] Azure: subscription visible at portal.azure.com
- [ ] Azure: budget alert created (Cost Management + Billing, Budgets)
- [ ] WeatherAPI.com: account created, key saved in a password manager, browser test returns JSON

Never commit keys or passwords. Store them in a password manager, GitHub Secrets and Container Apps secrets.

## 12. Phases and checkpoints

| # | Phase | Checkpoint |
| --- | --- | --- |
| 1 | Install tools (Homebrew, git, gh, Azure CLI, .NET SDK, VS Code, Docker Desktop, extensions) | `dotnet --version` shows 10.x. `docker run hello-world` works. `az account show` shows Enabled. `gh auth status` logged in |
| 2 | Scaffold solution and projects | `dotnet build` succeeds |
| 3 | API code | `/health` returns 200. Manual endpoint returns weather |
| 4 | Job code | Local run calls the API and logs the result |
| 5 | Local testing, then `docker-compose` | Both containers work together |
| 6 | Dockerfiles | Both images build and run |
| 7 | GitHub repo and workflow | Images appear in ghcr.io |
| 8 | Azure setup | Environment, identity and app role created |
| 9 | Deploy API and Job | API reachable, job listed in Azure |
| 10 | Verify and monitor | Manual job start succeeds, logs visible, budget alert set |

## 13. Phase 1 commands (macOS, Apple M1)

```bash
# Homebrew (skip if already installed), then run the "Next steps" it prints
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Tools
brew install git gh azure-cli
brew install --cask dotnet-sdk visual-studio-code docker

# VS Code extensions
code --install-extension ms-dotnettools.csdevkit
code --install-extension ms-azuretools.vscode-docker
code --install-extension ms-azuretools.vscode-azurecontainerapps
code --install-extension ms-azuretools.vscode-azureresourcegroups
code --install-extension github.vscode-github-actions
code --install-extension humao.rest-client

# Sign in
gh auth login
az login

# Checkpoint
dotnet --version
docker --version
docker run --rm hello-world
az account show --query "{name:name, state:state}" -o table
gh auth status
git --version
```

Start Docker Desktop before the `docker run` check.

## 14. Working method

The assistant generates code and commands phase by phase (or as a zip for the scaffold). You run them in VS Code and paste back errors or checkpoint output. The assistant cannot run commands or access your accounts.

## 15. Next step

Finish the accounts checklist, run Phase 1, and send the checkpoint output. Then continue with Phase 2 (scaffold the solution).
