# BAW App Deploy

Installs a workflow app package (`.zip`, process and/or case) on an IBM Business Automation Workflow server and copies the environment variables from the current default snapshot to the new one.

## Usage

1. Put the package `.zip` in this folder.
2. Run:

```powershell
$env:PASSWORD = '<password>'              # optional, otherwise you are prompted
.\deploy.ps1                              # deploys the newest zip in this folder
.\deploy.ps1 -File ".\MyApp_1.0.zip"      # deploys a specific package
.\deploy.ps1 -Config .\acc.yaml           # uses another environment's config
.\deploy.ps1 -DryRun                      # shows what would be deployed, changes nothing
```

Server, user and install settings are in [config.yaml](config.yaml).

If script execution is blocked:

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1
```
