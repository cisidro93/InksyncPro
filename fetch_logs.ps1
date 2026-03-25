$ProgressPreference = 'SilentlyContinue'
$runs = Invoke-RestMethod -Uri "https://api.github.com/repos/cisidro93/InksyncPro/actions/runs" -Headers @{"Accept"="application/vnd.github.v3+json"}
$latestId = $runs.workflow_runs[0].id
$jobs = Invoke-RestMethod -Uri "https://api.github.com/repos/cisidro93/InksyncPro/actions/runs/$latestId/jobs" -Headers @{"Accept"="application/vnd.github.v3+json"}
$jobId = $jobs.jobs[0].id

# Try to fetch logs
try {
    # If the job is completed, we can get logs directly
    Invoke-WebRequest -Uri "https://api.github.com/repos/cisidro93/InksyncPro/actions/jobs/$jobId/logs" -OutFile "C:\Users\chris\.gemini\antigravity\scratch\InksyncPro\logs.zip"
    Expand-Archive -Path "C:\Users\chris\.gemini\antigravity\scratch\InksyncPro\logs.zip" -DestinationPath "C:\Users\chris\.gemini\antigravity\scratch\InksyncPro\gh_logs" -Force
} catch {
    Write-Host "Logs not available or not completed yet. Error: $_"
}
