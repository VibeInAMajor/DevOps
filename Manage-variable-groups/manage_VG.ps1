[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [string] $OrganizationUrl ,                   #https://dev.azure.com/{organization name}"

  [Parameter(Mandatory=$true)]
  [string] $ProjectName,                        # existing project name

  [Parameter(Mandatory=$false)]
  [string] $InputPath,                          # file.json OR folder with *.json; defaults to script directory

  [ValidateSet('Create','Update','Delete','Upsert')]
  [string] $Operation,                          # if missing, we’ll prompt with 1..4

  [switch] $UseSystemAccessToken,               # use $env:SYSTEM_ACCESSTOKEN (recommended in pipelines)
  [string] $Pat,                                # PAT if running locally (DON'T hardcode)
  [switch] $Force                               # skip delete confirmation
)
$OrganizationUrl = $OrganizationUrl.TrimEnd('/')
function Info($m){ Write-Output "[$(Get-Date -Format HH:mm:ss)] $m" }
function Fail($m){ throw $m }

# --- Interactive operation picker (only if user didn't pass -Operation) ---
if (-not $PSBoundParameters.ContainsKey('Operation') -or [string]::IsNullOrWhiteSpace($Operation)) {
  Write-Host ""
  Write-Host "Select operation:"
  Write-Host "  1) Create"
  Write-Host "  2) Update"
  Write-Host "  3) Delete"
  Write-Host "  4) Upsert (default)"
  $choice = Read-Host "Enter 1, 2, 3, or 4 [default: 4]"
  switch ($choice) {
    '1' { $Operation = 'Create' }
    '2' { $Operation = 'Update' }
    '3' { $Operation = 'Delete' }
    '4' { $Operation = 'Upsert' }
    default { $Operation = 'Upsert' }
  }
}
Info "Operation: $Operation"

# --- Auth header ---
$h = @{}
if ($UseSystemAccessToken) {
  $t = $env:SYSTEM_ACCESSTOKEN; if ([string]::IsNullOrWhiteSpace($t)) { Fail "SYSTEM_ACCESSTOKEN is empty. Enable 'Allow scripts to access the OAuth token'." }
  $h['Authorization'] = "Bearer $t"
} elseif ($Pat) {
  $pair = ":$Pat"; $b = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
  $h['Authorization'] = "Basic $b"
} else { Fail "Provide -UseSystemAccessToken or -Pat." }
$h['Content-Type'] = 'application/json'

# --- Resolve Project ID ---
$projListUri = ("{0}/_apis/projects?api-version=7.1" -f $OrganizationUrl)
Info "GET $projListUri"
try { $projList = Invoke-RestMethod -Method GET -Headers $h -Uri $projListUri } catch { Fail "List projects failed. $_" }
$project = $projList.value | Where-Object { $_.name -ieq $ProjectName } | Select-Object -First 1
if (!$project) { Fail "Project '$ProjectName' not found in '$OrganizationUrl'." }
$projectId = $project.id
Info "Project $ProjectName ($projectId) resolved."

# ---------- Helpers ----------
function NormalizeVariables([hashtable]$vars) {
  $out = @{}
  foreach ($k in $vars.Keys) {
    $v = $vars[$k]
    if ($v -is [string]) { $out[$k] = @{ value = $v } }
    else {
      $o = @{}
      if ($v.ContainsKey('value'))      { $o.value      = [string]$v.value }
      if ($v.ContainsKey('isSecret'))   { $o.isSecret   = [bool]$v.isSecret }
      if ($v.ContainsKey('isReadOnly')) { $o.isReadOnly = [bool]$v.isReadOnly }
      $out[$k] = $o
    }
  }
  return $out
}

# Project-scope GET by name (no scopeId needed)
function Get-VG-ByName([string]$name){
  $uri = ("{0}/{1}/_apis/distributedtask/variablegroups?api-version=7.2-preview.2&groupName={2}" -f $OrganizationUrl, $ProjectName, [uri]::EscapeDataString($name))
  Info "GET $uri"
  try { $r = Invoke-RestMethod -Method GET -Headers $h -Uri $uri }
  catch { Fail "Query variable group '$name' failed. $_" }

  # Treat empty/missing as not found; require a positive integer id and exact name match
  if ($null -ne $r.value -and $r.value.Count -gt 0) {
    $hit = $r.value | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if ($hit -and $hit.id -and ($hit.id -as [int]) -gt 0) {
      return [pscustomobject]@{
        Id   = [int]$hit.id
        Name = [string]$hit.name
      }
    }
  }
  return $null
}

# Project-scope: list all variable groups
function Get-AllVGs {
  $uri = ("{0}/{1}/_apis/distributedtask/variablegroups?api-version=7.2-preview.2" -f $OrganizationUrl, $ProjectName)
  Info ("GET {0}" -f $uri)
  try {
    $resp = Invoke-RestMethod -Method GET -Headers $h -Uri $uri
    return @($resp.value | Where-Object { $_.id -and $_.name } | Sort-Object id)
  } catch {
    Fail "Failed to list variable groups. $_"
  }
}

# Pretty print: "ID  group name"
function Show-VG-List([object[]]$groups) {
  if (-not $groups -or $groups.Count -eq 0) {
    Write-Output "No variable groups found in project '$ProjectName'."
    return
  }
  Write-Output ""
  Write-Output "ID  GroupName"
  foreach ($g in $groups) {
    Write-Output ("{0}  {1}" -f $g.id, $g.name)
  }
  Write-Output ""
}


# Add body (org-scope 7.2-preview.2)
function Build-CreateBody([hashtable]$p) {
  if (-not $p.name)      { Fail "Payload missing 'name'." }
  if (-not $p.type)      { $p.type = "Vsts" }
  if (-not $p.variables) { $p.variables = @{} }
  $vars = NormalizeVariables $p.variables

  [pscustomobject]@{
    description = $p.description
    name        = [string]$p.name
    type        = [string]$p.type
    variables   = $vars
    variableGroupProjectReferences = @(
      [pscustomobject]@{
        description      = $p.description
        name             = [string]$p.name
        projectReference = [pscustomobject]@{ id = $projectId; name = $ProjectName }
      }
    )
  } | ConvertTo-Json -Depth 30
}

# Full object for Update (org-scope PUT 7.1)
function Build-UpdateBody([hashtable]$p, [int]$id) {
  if (-not $p.type)      { $p.type = "Vsts" }
  if (-not $p.variables) { $p.variables = @{} }
  $vars = NormalizeVariables $p.variables

  [pscustomobject]@{
    id          = $id
    description = $p.description
    name        = [string]$p.name
    type        = [string]$p.type
    variables   = $vars
    variableGroupProjectReferences = @(
      [pscustomobject]@{
        description      = $p.description
        name             = [string]$p.name
        projectReference = [pscustomobject]@{ id = $projectId; name = $ProjectName }
      }
    )
  } | ConvertTo-Json -Depth 30
}

# ======================= OPERATION DISPATCH =======================

if ($Operation -eq 'Delete') {
  $all = Get-AllVGs
  Show-VG-List -groups $all
  if (-not $all -or $all.Count -eq 0) { Write-Output "Nothing to delete."; return }

  $raw = Read-Host "Enter one or more IDs to delete (e.g. 11 12,13-15)"
  $ids = Parse-Ids $raw
  if (-not $ids -or $ids.Count -eq 0) { Write-Output "No valid IDs provided. Aborting delete."; return }

  # Found vs not found
  $byId = @{}; foreach ($g in $all) { $byId[[int]$g.id] = $g }
  $toDelete = @(); foreach ($id in $ids) { if ($byId.ContainsKey($id)) { $toDelete += $byId[$id] } }
  $notFound = @(); foreach ($id in $ids) { if (-not $byId.ContainsKey($id)) { $notFound += $id } }

  if ($toDelete.Count -eq 0) { Write-Output "None of the specified IDs exist in project '$ProjectName'. Aborting."; return }

  Write-Output "`nWill delete:"
  Write-Output "ID  GroupName"
  foreach ($g in ($toDelete | Sort-Object id)) { "{0}  {1}" -f $g.id, $g.name | Write-Output }
  if ($notFound.Count -gt 0) { Write-Output "`nNot found (skipped): $($notFound -join ', ')" }
  Write-Output ""

  if (-not $Force) {
    $ans = Read-Host ("Delete {0} variable group(s)? [y/N]" -f $toDelete.Count)
    if ($ans -notin @('y','Y','yes','YES')) { Write-Output "Delete cancelled."; return }
  }

  foreach ($g in $toDelete) {
    $vgId = [int]$g.id
    $uri  = ("{0}/_apis/distributedtask/variablegroups/{1}?projectIds={2}&api-version=7.1" -f $OrganizationUrl.TrimEnd('/'), $vgId, $projectId)
    Info ("DELETE {0}" -f $uri)
    try {
      Invoke-RestMethod -Method DELETE -Headers $h -Uri $uri
      Write-Output ("Deleted '{0}' (ID {1})." -f $g.name, $vgId)
    } catch {
      Write-Output ("Failed to delete '{0}' (ID {1}). Error: {2}" -f $g.name, $vgId, $_.Exception.Message)
    }
  }

  return
}

# ---- Create/Update/Upsert: now we resolve input path & show logs ----
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($InputPath)) { $InputPath = $scriptDir; Info "No -InputPath provided; defaulting to: $InputPath" }

if (-not (Test-Path -LiteralPath $InputPath)) { Fail "InputPath not found: $InputPath" }
$files = (Get-Item -LiteralPath $InputPath) -is [IO.DirectoryInfo] ? (Get-ChildItem -Path $InputPath -Filter *.json) : ,(Get-Item -LiteralPath $InputPath)
if ($files.Count -eq 0) { Fail "No JSON files found in $InputPath" }
Info ("Found {0} JSON file(s) in {1}." -f $files.Count, $InputPath)

foreach ($f in $files) {
  Info ("Processing file {0} …" -f $f.FullName)
  try { $payload = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable }
  catch { Fail "Parse JSON failed: $f. $_" }

  $name = $payload.name; if (-not $name) { Fail "Missing 'name' in $($f.Name)" }

  switch ($Operation) {
    'Create' {
      $existing = Get-VG-ByName -name $name
      if ($existing -and ($existing.Id -as [int]) -gt 0) { Fail "Variable group '$name' already exists (ID $($existing.Id)). Use -Operation Update/Upsert." }
      $body = Build-CreateBody -p $payload
      $uri  = ("{0}/_apis/distributedtask/variablegroups?api-version=7.2-preview.2" -f $OrganizationUrl)
      Info ("POST {0}" -f $uri)
      try {
        $created = Invoke-RestMethod -Method POST -Headers $h -Uri $uri -Body $body
        Write-Output ("Created variable group '{0}' (ID {1})" -f $name, $created.id)
      } catch { Fail ("Create failed for '{0}'. URL: {1}. {2}" -f $name, $uri, $_) }
    }

    'Update' {
      $existing = Get-VG-ByName -name $name
      if (-not $existing) { Fail "Variable group '$name' not found. Use -Operation Create/Upsert." }
      $vgId = [int]$existing.Id
      $body = Build-UpdateBody -p $payload -id $vgId
      $uri  = ("{0}/_apis/distributedtask/variablegroups/{1}?api-version=7.1" -f $OrganizationUrl, $vgId)
      Info ("PUT {0}" -f $uri)
      try {
        $updated = Invoke-RestMethod -Method PUT -Headers $h -Uri $uri -Body $body
        Write-Output ("Updated variable group '{0}' (ID {1})" -f $name, $updated.id)
      } catch { Fail ("Update failed for '{0}' (ID {1}). URL: {2}. {3}" -f $name, $vgId, $uri, $_) }
    }

    'Upsert' {
      $existing = Get-VG-ByName -name $name
      if ($existing) {
        $vgId = [int]$existing.Id
        $body = Build-UpdateBody -p $payload -id $vgId
        $uri  = ("{0}/_apis/distributedtask/variablegroups/{1}?api-version=7.1" -f $OrganizationUrl, $vgId)
        Info ("PUT {0}" -f $uri)
        try {
          $updated = Invoke-RestMethod -Method PUT -Headers $h -Uri $uri -Body $body
          Write-Output ("Updated variable group '{0}' (ID {1})" -f $name, $updated.id)
        } catch { Fail ("Update failed for '{0}' (ID {1}). URL: {2}. {3}" -f $name, $vgId, $uri, $_) }
      } else {
        $body = Build-CreateBody -p $payload
        $uri  = ("{0}/_apis/distributedtask/variablegroups?api-version=7.2-preview.2" -f $OrganizationUrl)
        Info ("POST {0}" -f $uri)
        try {
          $created = Invoke-RestMethod -Method POST -Headers $h -Uri $uri -Body $body
          Write-Output ("Created variable group '{0}' (ID {1})" -f $name, $created.id)
        } catch { Fail ("Create failed for '{0}'. URL: {1}. {2}" -f $name, $uri, $_) }
      }
    }
  }
}

Write-Output "Done."
