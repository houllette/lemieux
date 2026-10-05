param([Parameter(ValueFromRemainingArguments=$true)][string[]]$LmxArguments)
# lmx on Windows is experimental. bin/lmx.cmd runs this script.
# What the person's commands inherit is the environment they started lmx
# with, not the VM's (Lmx.CLI, "What the commands lmx starts inherit"): before
# anything here or in the release script changes it, record PATH and the
# value of each variable they set that those set for the VM.
$env:LMX_PARENT_PATH = $env:PATH
$LmxNames = @('BINDIR', 'ROOTDIR', 'EMU', 'PROGNAME', 'ERL_CRASH_DUMP', 'ELIXIR_ERL_OPTIONS') +
  @(Get-ChildItem Env: | Where-Object { $_.Name -like 'RELEASE_*' } | ForEach-Object { $_.Name })
foreach ($LmxName in $LmxNames) {
  $LmxValue = [Environment]::GetEnvironmentVariable($LmxName)
  if ($null -ne $LmxValue) { [Environment]::SetEnvironmentVariable("LMX_PARENT__$LmxName", $LmxValue) }
}
$env:LMX_RELEASE_ROOT = Split-Path -Parent $PSScriptRoot
$env:LMX_ARGV_FILE = [IO.Path]::GetTempFileName()
$env:RELEASE_DISTRIBUTION = 'none'
# The VM writes erl_crash.dump into the current directory, which is the
# person's project, and a dump holds provider keys and transcript text. Keep
# dumps in the state directory instead; the person's commands do not inherit
# this (recorded above).
if (-not $env:ERL_CRASH_DUMP) {
  $LmxState = if ($env:LMX_HOME) { $env:LMX_HOME } else { Join-Path $HOME '.lmx' }
  $LmxCrash = Join-Path $LmxState 'crash'
  New-Item -ItemType Directory -Force -Path $LmxCrash -ErrorAction SilentlyContinue | Out-Null
  if (Test-Path -PathType Container $LmxCrash) { $env:ERL_CRASH_DUMP = Join-Path $LmxCrash 'erl_crash.dump' }
}
try {
  $text = if ($LmxArguments.Count) { ($LmxArguments -join "`0") + "`0" } else { '' }
  [IO.File]::WriteAllBytes($env:LMX_ARGV_FILE, [Text.Encoding]::UTF8.GetBytes($text))
  & "$PSScriptRoot/lmx-release.bat" eval 'Application.ensure_all_started(:lmx); Lmx.Boot.main()'
  exit $LASTEXITCODE
} finally {
  Remove-Item -ErrorAction SilentlyContinue $env:LMX_ARGV_FILE
}
