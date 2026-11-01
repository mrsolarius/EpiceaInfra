# ========================================
# Remplace le bloc de la simulation dans le fichier hosts de Windows (lancé en administrateur)
# Appelé par scripts/simulation/sim-hosts.sh ; un BlockFile vide retire le bloc.
# Erreurs écrites dans LogFile : la fenêtre élevée se ferme avant qu'on puisse les lire.
# ========================================
param(
    [Parameter(Mandatory)][string]$BlockFile,
    [Parameter(Mandatory)][string]$LogFile,
    [string]$HostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
)
$ErrorActionPreference = 'Stop'
$begin = '# >>> epicea-sim (make sim-host)'
$end = '# <<< epicea-sim'

try {
    # Lignes hors de l'ancien bloc
    $kept = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    foreach ($line in [IO.File]::ReadAllLines($HostsFile)) {
        if ($line -eq $begin) { $inBlock = $true; continue }
        if ($line -eq $end) { $inBlock = $false; continue }
        if (-not $inBlock) { $kept.Add($line) }
    }
    while ($kept.Count -gt 0 -and $kept[$kept.Count - 1] -eq '') { $kept.RemoveAt($kept.Count - 1) }

    $block = @([IO.File]::ReadAllLines($BlockFile) | Where-Object { $_ -ne '' })
    if ($block.Count -gt 0) { $kept.Add(''); $kept.Add($begin); $kept.AddRange([string[]]$block); $kept.Add($end) }

    # Le fichier hosts peut être verrouillé un instant (antivirus, client DNS) : quelques essais
    for ($i = 1; ; $i++) {
        try { [IO.File]::WriteAllLines($HostsFile, $kept); break }
        catch { if ($i -ge 5) { throw }; Start-Sleep -Milliseconds 500 }
    }
    ipconfig /flushdns | Out-Null
    "OK $($block.Count) lignes" | Out-File -FilePath $LogFile -Encoding utf8
}
catch {
    "ERREUR $_" | Out-File -FilePath $LogFile -Encoding utf8
    exit 1
}
