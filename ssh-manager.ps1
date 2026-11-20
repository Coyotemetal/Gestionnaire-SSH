#Requires -Version 5.1
# ==============================================================================
#   SSH MANAGER  -  interface terminal pour gérer et lancer vos connexions SSH
#   Lancé par script.bat. Les VMs sont rangées par dossier dans vms.txt :
#
#       [Lab perso]
#       Proxmox|192.168.10.250|root
#
#       [Lab Ecole]
#       Linux-lab|192.168.10.92|admin
# ==============================================================================

# ----------------------------- CONFIGURATION ---------------------------------
$Config = @{
    Fichier       = Join-Path $PSScriptRoot 'vms.txt'
    UserDefaut    = 'root'
    DossierDefaut = 'Mes VMs'   # dossier des VMs d'un ancien vms.txt (sans dossiers)
    Ouverture     = 'fenetre'   # 'fenetre' = nouvelle fenêtre | 'onglet' = nouvel onglet
    PingTimeout   = 1000        # délai max d'un ping (ms)
    AutoPing      = 15          # ping automatique toutes les X secondes (0 = désactivé)
}
# -----------------------------------------------------------------------------

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding  = [Text.Encoding]::UTF8 } catch {}
$Host.UI.RawUI.WindowTitle = 'SSH Manager'

# ------------------------------- Couleurs ------------------------------------
$E = [char]27
function Fg($r, $g, $b) { "$E[38;2;$r;$g;${b}m" }
function Bg($r, $g, $b) { "$E[48;2;$r;$g;${b}m" }

$C = @{
    Text    = Fg 205 214 244
    Sub     = Fg 127 132 156
    Dim     = Fg 88  91  112
    Blue    = Fg 137 180 250
    Mauve   = Fg 203 166 247
    Green   = Fg 166 227 161
    Red     = Fg 243 139 168
    Yellow  = Fg 249 226 175
    Peach   = Fg 250 179 135
    SelBg   = Bg 49  50  68
    KeyBg   = Bg 69  71  90
    Bold    = "$E[1m"
    NoBold  = "$E[22m"
    FgOff   = "$E[39m"
    BgOff   = "$E[49m"
    Reset   = "$E[0m"
}
$Spinner = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
$AnsiRe  = [regex]"$([char]27)\[[0-9;]*[A-Za-z]"

# ------------------------------ Utilitaires ----------------------------------
function VLen([string]$s) { $AnsiRe.Replace($s, '').Length }

function PadV([string]$s, [int]$w) {
    $l = VLen $s
    if ($l -lt $w) { return $s + (' ' * ($w - $l)) }
    return $s
}

function Fit([string]$s, [int]$w) {
    if ($w -le 0) { return '' }
    if ($s.Length -gt $w) {
        if ($w -eq 1) { return '…' }
        return $s.Substring(0, $w - 1) + '…'
    }
    return $s.PadRight($w)
}

function Gradient([string]$t, $c1, $c2) {
    $n = $t.Length; $out = ''
    for ($i = 0; $i -lt $n; $i++) {
        $f = if ($n -gt 1) { $i / ($n - 1) } else { 0 }
        $r = [int]($c1[0] + ($c2[0] - $c1[0]) * $f)
        $g = [int]($c1[1] + ($c2[1] - $c1[1]) * $f)
        $b = [int]($c1[2] + ($c2[2] - $c1[2]) * $f)
        $out += (Fg $r $g $b) + $t[$i]
    }
    return $out + $C.FgOff
}

function Key([string]$k, [string]$label) {
    "$($C.KeyBg)$($C.Text) $k $($C.BgOff)$($C.Sub) $label$($C.FgOff)"
}

# --------------------------------- État --------------------------------------
$State = @{
    Folders   = New-Object System.Collections.ArrayList
    View      = 'folders'     # 'folders' = liste des dossiers | 'vms' = contenu d'un dossier
    Cur       = $null         # dossier ouvert
    FSel      = 0             # sélection dans la liste des dossiers
    FOffset   = 0
    Sel       = 0             # sélection dans la liste des VMs
    Offset    = 0
    Msg       = ''
    MsgColor  = ''
    MsgTime   = [datetime]::MinValue
    Prompt    = $null
    LastPing  = [datetime]::MinValue
    Spin      = 0
    PrevCount = 0
    LastW     = 0
    LastH     = 0
    Quit      = $false
}
$WT_OK  = [bool](Get-Command wt  -ErrorAction SilentlyContinue)
$SSH_OK = [bool](Get-Command ssh -ErrorAction SilentlyContinue)

function New-VM($nom, $ip, $user) {
    [pscustomobject]@{ Nom = $nom; IP = $ip; User = $user; Status = '?'; Ms = $null; Task = $null; Pinger = $null }
}

function New-Folder($nom) {
    [pscustomobject]@{ Nom = $nom; VMs = (New-Object System.Collections.ArrayList) }
}

function Get-AllVMs { foreach ($f in $State.Folders) { foreach ($v in $f.VMs) { $v } } }

function Find-Folder([string]$nom) {
    foreach ($f in $State.Folders) { if ($f.Nom -eq $nom) { return $f } }
    return $null
}

function Set-Msg([string]$text, [string]$color) {
    $State.Msg = $text; $State.MsgColor = $color; $State.MsgTime = Get-Date
}

# ------------------------------ Fichier vms.txt -------------------------------
function Load-Data {
    $State.Folders.Clear()
    if (-not (Test-Path -LiteralPath $Config.Fichier)) { return }
    $cur = $null
    foreach ($raw in [IO.File]::ReadAllLines($Config.Fichier, [Text.Encoding]::UTF8)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -match '^\[(.+)\]$') {
            $nom = $Matches[1].Trim()
            $cur = Find-Folder $nom
            if (-not $cur) { $cur = New-Folder $nom; [void]$State.Folders.Add($cur) }
            continue
        }
        $p = $line.Split('|')
        if ($p.Count -ge 2 -and $p[0].Trim() -and $p[1].Trim()) {
            if (-not $cur) {
                $cur = Find-Folder $Config.DossierDefaut
                if (-not $cur) { $cur = New-Folder $Config.DossierDefaut; [void]$State.Folders.Add($cur) }
            }
            $u = if ($p.Count -ge 3 -and $p[2].Trim()) { $p[2].Trim() } else { $Config.UserDefaut }
            [void]$cur.VMs.Add((New-VM $p[0].Trim() $p[1].Trim() $u))
        }
    }
}

function Save-Data {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($f in $State.Folders) {
        if ($lines.Count) { $lines.Add('') }
        $lines.Add("[$($f.Nom)]")
        foreach ($v in $f.VMs) { $lines.Add("$($v.Nom)|$($v.IP)|$($v.User)") }
    }
    [IO.File]::WriteAllLines($Config.Fichier, $lines.ToArray(), (New-Object Text.UTF8Encoding $false))
}

# ---------------------------------- Ping -------------------------------------
function Start-Ping($vm) {
    if ($vm.Pinger) { try { $vm.Pinger.Dispose() } catch {} }
    $vm.Status = '...'; $vm.Ms = $null
    try {
        $vm.Pinger = New-Object System.Net.NetworkInformation.Ping
        $vm.Task   = $vm.Pinger.SendPingAsync($vm.IP, $Config.PingTimeout)
    } catch {
        $vm.Status = 'DOWN'; $vm.Task = $null
    }
}

function Start-PingAll {
    foreach ($vm in @(Get-AllVMs)) { Start-Ping $vm }
    $State.LastPing = Get-Date
}

function Update-Pings {
    $changed = $false
    foreach ($vm in @(Get-AllVMs)) {
        if ($vm.Task -and $vm.Task.IsCompleted) {
            if ($vm.Task.Status -eq 'RanToCompletion' -and $vm.Task.Result.Status -eq 'Success') {
                $vm.Status = 'UP'; $vm.Ms = $vm.Task.Result.RoundtripTime
            } else {
                $vm.Status = 'DOWN'; $vm.Ms = $null
            }
            $vm.Task = $null; $changed = $true
        }
    }
    return $changed
}

function Test-Pinging($vms) { @($vms | Where-Object { $_.Status -eq '...' }).Count -gt 0 }

# --------------------------------- Rendu -------------------------------------
function Get-W { [Math]::Max(60, [Math]::Min(86, [Console]::WindowWidth - 4)) }

function Out-Frame($lines) {
    $ww = [Console]::WindowWidth; $wh = [Console]::WindowHeight
    if ($ww -ne $State.LastW -or $wh -ne $State.LastH) {
        [Console]::Clear(); $State.LastW = $ww; $State.LastH = $wh; $State.PrevCount = 0
    }
    $max = [Math]::Min($lines.Count, $wh - 1)
    $sb = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $max; $i++) {
        [void]$sb.Append("$E[$($i + 1);1H$($C.Reset)")
        [void]$sb.Append((PadV ('  ' + $lines[$i]) ($ww - 1)))
        [void]$sb.Append($C.Reset)
    }
    for ($i = $max; $i -lt $State.PrevCount; $i++) {
        [void]$sb.Append("$E[$($i + 1);1H" + (' ' * ($ww - 1)))
    }
    $State.PrevCount = $max
    [Console]::Write($sb.ToString())
}

# En-tête : titre (+ dossier ouvert) et compteurs UP / DOWN
function Add-Header($L, [int]$W) {
    $inner = $W - 2
    if ($State.View -eq 'vms' -and $State.Cur) { $vms = @($State.Cur.VMs) } else { $vms = @(Get-AllVMs) }
    $up   = @($vms | Where-Object { $_.Status -eq 'UP' }).Count
    $down = @($vms | Where-Object { $_.Status -eq 'DOWN' }).Count

    $left = '  ' + $C.Mauve + '◆' + $C.FgOff + '   ' + $C.Bold +
            (Gradient 'S S H   M A N A G E R' @(137,180,250) @(203,166,247)) + $C.NoBold
    if ($State.View -eq 'vms' -and $State.Cur) {
        $left += $C.Dim + '   ›   ' + $C.FgOff + $C.Bold + $C.Text + (Fit $State.Cur.Nom 22).TrimEnd() + $C.NoBold + $C.FgOff
    }
    $right = $C.Green + "▲ $up" + $C.FgOff + '   ' + $C.Red + "▼ $down" + $C.FgOff +
             $C.Dim + '   │   ' + $C.FgOff + $C.Sub + (Get-Date -Format 'HH:mm') + $C.FgOff + '  '
    $mid = [Math]::Max(1, $inner - (VLen $left) - (VLen $right))

    $L.Add($C.Dim + '╭' + ('─' * $inner) + '╮' + $C.FgOff)
    $L.Add($C.Dim + '│' + $C.FgOff + $left + (' ' * $mid) + $right + $C.Dim + '│' + $C.FgOff)
    $L.Add($C.Dim + '╰' + ('─' * $inner) + '╯' + $C.FgOff)
}

function Get-StatusCell($vm) {
    switch ($vm.Status) {
        'UP'   { return $C.Green + '●' + ' UP'.PadRight(8) + $C.FgOff }
        'DOWN' { return $C.Red   + '●' + ' DOWN'.PadRight(8) + $C.FgOff }
        '...'  { return $C.Yellow + $Spinner[$State.Spin % $Spinner.Count] + ' ···'.PadRight(8) + $C.FgOff }
        default { return $C.Dim  + '◌' + ' —'.PadRight(8) + $C.FgOff }
    }
}

# Pied de page commun : ligne de ping, raccourcis, message
function Add-Footer($L, [int]$W, [string[]]$keyLines, [string]$extra) {
    $L.Add($C.Dim + ('─' * $W) + $C.FgOff)

    if (Test-Pinging @(Get-AllVMs)) {
        $info = $C.Yellow + $Spinner[$State.Spin % $Spinner.Count] + ' Ping en cours…' + $C.FgOff
    } elseif ($State.LastPing -gt [datetime]::MinValue) {
        $ago  = [int]((Get-Date) - $State.LastPing).TotalSeconds
        $info = $C.Dim + "Dernier ping il y a $ago s" + $C.FgOff
        if ($Config.AutoPing -gt 0) {
            $next = [Math]::Max(0, $Config.AutoPing - $ago)
            $info += $C.Dim + "  ·  prochain dans $next s" + $C.FgOff
        }
    } else { $info = '' }
    if ($extra) { $info += $C.Dim + "  ·  $extra" + $C.FgOff }
    $L.Add('  ' + $info)
    $L.Add('')

    foreach ($kl in $keyLines) { $L.Add($kl) }
    $L.Add('')

    if ($State.Prompt) {
        $L.Add($C.Yellow + '? ' + $C.FgOff + $C.Text + $State.Prompt + $C.FgOff + '   ' +
               (Key 'O' 'Oui') + '  ' + (Key 'N' 'Non'))
    } elseif ($State.Msg -and ((Get-Date) - $State.MsgTime).TotalSeconds -lt 5) {
        $L.Add($State.MsgColor + (Fit $State.Msg $W).TrimEnd() + $C.FgOff)
    } else {
        $L.Add('')
    }
}

# ---- Écran 1 : liste des dossiers ----
function Render-Folders {
    $W  = Get-W
    $nw = $W - 36
    $L  = New-Object 'System.Collections.Generic.List[string]'

    $L.Add('')
    Add-Header $L $W
    $L.Add('')

    $L.Add($C.Sub + '    ' + 'DOSSIER'.PadRight($nw) + 'VMS'.PadRight(10) + 'ÉTAT' + $C.FgOff)
    $L.Add($C.Dim + ('─' * $W) + $C.FgOff)

    $n = $State.Folders.Count
    $rowsAvail = [Math]::Max(3, [Console]::WindowHeight - 17)

    if ($n -eq 0) {
        $L.Add('')
        $L.Add('  ' + $C.Sub + 'Aucun dossier pour le moment.' + $C.FgOff)
        $L.Add('  ' + $C.Sub + 'Appuie sur ' + $C.FgOff + (Key 'A' 'pour en créer un  (ex : Lab perso, Lab Ecole).'))
        $L.Add('')
    } else {
        if ($State.FSel -ge $n) { $State.FSel = $n - 1 }
        if ($State.FSel -lt $State.FOffset) { $State.FOffset = $State.FSel }
        if ($State.FSel -ge $State.FOffset + $rowsAvail) { $State.FOffset = $State.FSel - $rowsAvail + 1 }
        $end = [Math]::Min($n, $State.FOffset + $rowsAvail)

        for ($i = $State.FOffset; $i -lt $end; $i++) {
            $f    = $State.Folders[$i]
            $sel  = ($i -eq $State.FSel)
            $vms  = @($f.VMs)
            $up   = @($vms | Where-Object { $_.Status -eq 'UP' }).Count
            $down = @($vms | Where-Object { $_.Status -eq 'DOWN' }).Count
            $cnt  = if ($vms.Count -le 1) { "$($vms.Count) VM" } else { "$($vms.Count) VMs" }

            if ($vms.Count -eq 0) {
                $etat = $C.Dim + 'vide' + $C.FgOff
            } elseif (Test-Pinging $vms) {
                $etat = $C.Yellow + $Spinner[$State.Spin % $Spinner.Count] + ' ···' + $C.FgOff
            } else {
                $gc = if ($up)   { $C.Green } else { $C.Dim }
                $rc = if ($down) { $C.Red }   else { $C.Dim }
                $etat = $gc + "▲ $up" + $C.FgOff + '    ' + $rc + "▼ $down" + $C.FgOff
            }

            if ($sel) {
                $mark = $C.SelBg + $C.Blue + '▌ ' + $C.FgOff
                $icon = $C.Blue + '▸ ' + $C.FgOff
                $name = $C.Bold + $C.Text + (Fit $f.Nom ($nw - 1)) + ' ' + $C.NoBold + $C.FgOff
            } else {
                $mark = '  '
                $icon = $C.Mauve + '▸ ' + $C.FgOff
                $name = $C.Text + (Fit $f.Nom ($nw - 1)) + ' ' + $C.FgOff
            }
            $row = $mark + $icon + $name + $C.Sub + $cnt.PadRight(10) + $C.FgOff + $etat
            $row = PadV $row $W
            if ($sel) { $row += $C.BgOff }
            $L.Add($row)
        }
    }

    $extra = if ($n -gt $rowsAvail) { "$($State.FSel + 1)/$n" } else { '' }
    $keys = @(
        ((Key '↑↓' 'Naviguer') + '    ' + (Key '↵' 'Ouvrir') + '    ' + (Key 'P' 'Ping')),
        ((Key 'A' 'Nouveau dossier') + '    ' + (Key 'E' 'Renommer') + '    ' + (Key 'D' 'Supprimer') + '    ' + (Key 'Q' 'Quitter'))
    )
    Add-Footer $L $W $keys $extra
    Out-Frame $L
}

# ---- Écran 2 : VMs du dossier ouvert ----
function Render-VMs {
    $W   = Get-W
    $nw  = $W - 50
    $L   = New-Object 'System.Collections.Generic.List[string]'
    $vms = $State.Cur.VMs

    $L.Add('')
    Add-Header $L $W
    $L.Add('')

    $head = '  ' + 'STATUT'.PadRight(9) + ' ' + 'NOM'.PadRight($nw) + 'UTILISATEUR'.PadRight(13) +
            'ADRESSE'.PadRight(17) + 'LATENCE'
    $L.Add($C.Sub + $head + $C.FgOff)
    $L.Add($C.Dim + ('─' * $W) + $C.FgOff)

    $n = $vms.Count
    $rowsAvail = [Math]::Max(3, [Console]::WindowHeight - 17)

    if ($n -eq 0) {
        $L.Add('')
        $L.Add('  ' + $C.Sub + 'Ce dossier est vide.' + $C.FgOff)
        $L.Add('  ' + $C.Sub + 'Appuie sur ' + $C.FgOff + (Key 'A' 'pour ajouter une VM.'))
        $L.Add('')
    } else {
        if ($State.Sel -ge $n) { $State.Sel = $n - 1 }
        if ($State.Sel -lt $State.Offset) { $State.Offset = $State.Sel }
        if ($State.Sel -ge $State.Offset + $rowsAvail) { $State.Offset = $State.Sel - $rowsAvail + 1 }
        $end = [Math]::Min($n, $State.Offset + $rowsAvail)

        for ($i = $State.Offset; $i -lt $end; $i++) {
            $vm  = $vms[$i]
            $sel = ($i -eq $State.Sel)
            $lat = if ($vm.Status -eq 'UP') { if ($vm.Ms -lt 1) { '<1 ms' } else { "$($vm.Ms) ms" } } else { '—' }

            if ($sel) {
                $mark = $C.SelBg + $C.Blue + '▌ ' + $C.FgOff
                $name = $C.Bold + $C.Text + (Fit $vm.Nom ($nw - 1)) + ' ' + $C.NoBold
            } else {
                $mark = '  '
                $name = $C.Text + (Fit $vm.Nom ($nw - 1)) + ' '
            }
            $row  = $mark + (Get-StatusCell $vm) + ' ' + $name
            $row += $C.Mauve + (Fit $vm.User 12) + ' '
            $row += $C.Peach + (Fit $vm.IP 16) + ' '
            $row += $C.Sub + $lat + $C.FgOff
            $row  = PadV $row $W
            if ($sel) { $row += $C.BgOff }
            $L.Add($row)
        }
    }

    $extra = if ($n -gt $rowsAvail) { "$($State.Sel + 1)/$n" } else { '' }
    $keys = @(
        ((Key '↑↓' 'Naviguer') + '    ' + (Key '↵' 'Connecter') + '    ' + (Key 'P' 'Ping') + '    ' + (Key 'Échap' 'Retour')),
        ((Key 'A' 'Ajouter') + '   ' + (Key 'E' 'Modifier') + '   ' + (Key 'M' 'Déplacer') + '   ' + (Key 'D' 'Supprimer') + '   ' + (Key 'Q' 'Quitter'))
    )
    Add-Footer $L $W $keys $extra
    Out-Frame $L
}

function Render-Main {
    if ($State.View -eq 'vms' -and $State.Cur) { Render-VMs } else { Render-Folders }
}

# ------------------------------ Formulaires ----------------------------------
function Add-CardTop($L, [int]$inner, [string]$title) {
    $L.Add($C.Dim + '╭─ ' + $C.FgOff + $C.Bold + $C.Blue + $title + $C.NoBold + $C.FgOff + ' ' +
           $C.Dim + ('─' * [Math]::Max(1, $inner - 3 - $title.Length)) + '╮' + $C.FgOff)
}

function Render-Form([string]$title, [string[]]$labels, [string[]]$vals, [int]$active, [string]$err) {
    $W     = Get-W
    $CW    = [Math]::Min($W, 66)
    $inner = $CW - 2
    $FW    = $inner - 22
    $L     = New-Object 'System.Collections.Generic.List[string]'

    $L.Add('')
    Add-Header $L $W
    $L.Add('')

    Add-CardTop $L $inner $title
    $side  = $C.Dim + '│' + $C.FgOff
    $empty = $side + (' ' * $inner) + $side
    $L.Add($empty)

    $cursorX = 0
    for ($i = 0; $i -lt $labels.Count; $i++) {
        $v = $vals[$i]
        $disp = if ($v.Length -gt $FW - 1) { '…' + $v.Substring($v.Length - ($FW - 2)) } else { $v }
        if ($i -eq $active) {
            $lab = $C.Blue + $C.Bold + $labels[$i].PadRight(14) + $C.NoBold + '› ' + $C.FgOff
            $box = $C.KeyBg + $C.Text + ' ' + $disp.PadRight($FW) + ' ' + $C.BgOff + $C.FgOff
            $cursorX = 2 + 1 + 2 + 14 + 2 + 1 + $disp.Length
        } else {
            $lab = $C.Sub + $labels[$i].PadRight(14) + $C.Dim + '› ' + $C.FgOff
            $box = $C.SelBg + $C.Text + ' ' + $disp.PadRight($FW) + ' ' + $C.BgOff + $C.FgOff
        }
        $L.Add($side + (PadV ('  ' + $lab + $box) $inner) + $side)
        $L.Add($empty)
    }

    if ($err) { $msg = '  ' + $C.Red + '✗ ' + $err + $C.FgOff }
    elseif ($labels.Count -gt 1) { $msg = '  ' + (Key '↵' 'Valider') + '   ' + (Key '↑↓' 'Champ') + '   ' + (Key 'Échap' 'Annuler') }
    else { $msg = '  ' + (Key '↵' 'Valider') + '   ' + (Key 'Échap' 'Annuler') }
    $L.Add($side + (PadV $msg $inner) + $side)
    $L.Add($empty)
    $L.Add($C.Dim + '╰' + ('─' * $inner) + '╯' + $C.FgOff)

    Out-Frame $L
    return @{ X = $cursorX; Y = 7 + ($active * 2) }
}

function Show-Form([string]$title, [string[]]$labels, [string[]]$values, [int]$focus = 0, [string]$err = '') {
    $vals = [string[]]$values.Clone()
    $i = $focus
    [Console]::CursorVisible = $true
    try {
        while ($true) {
            $pos = Render-Form $title $labels $vals $i $err
            [Console]::SetCursorPosition($pos.X, $pos.Y)
            $k = [Console]::ReadKey($true)
            $err = ''
            if ($k.Key -eq 'Escape') { return $null }
            elseif ($k.Key -eq 'Enter' -or ($k.Key -eq 'Tab' -and -not ($k.Modifiers -band [ConsoleModifiers]::Shift))) {
                if ($i -lt $labels.Count - 1) { $i++ }
                elseif ($k.Key -eq 'Enter') { return ,$vals }
                else { $i = 0 }
            }
            elseif ($k.Key -eq 'DownArrow') { if ($i -lt $labels.Count - 1) { $i++ } }
            elseif ($k.Key -eq 'UpArrow' -or $k.Key -eq 'Tab') { if ($i -gt 0) { $i-- } }
            elseif ($k.Key -eq 'Backspace') {
                if ($vals[$i].Length -gt 0) { $vals[$i] = $vals[$i].Substring(0, $vals[$i].Length - 1) }
            }
            elseif (-not [char]::IsControl($k.KeyChar)) { $vals[$i] += $k.KeyChar }
        }
    } finally {
        [Console]::CursorVisible = $false
    }
}

# Liste de choix dans une carte (↑↓ + Entrée)  ->  index choisi, ou -1
function Show-Picker([string]$title, [string[]]$items) {
    $sel = 0
    while ($true) {
        $W     = Get-W
        $CW    = [Math]::Min($W, 66)
        $inner = $CW - 2
        $L     = New-Object 'System.Collections.Generic.List[string]'
        $L.Add('')
        Add-Header $L $W
        $L.Add('')
        Add-CardTop $L $inner $title
        $side  = $C.Dim + '│' + $C.FgOff
        $empty = $side + (' ' * $inner) + $side
        $L.Add($empty)
        for ($i = 0; $i -lt $items.Count; $i++) {
            if ($i -eq $sel) {
                $row = $C.SelBg + $C.Blue + '  ▌ ' + '▸ ' + $C.Bold + $C.Text + (Fit $items[$i] ($inner - 10)) + $C.NoBold + $C.FgOff
                $row = (PadV $row $inner) + $C.BgOff
            } else {
                $row = PadV ('    ' + $C.Mauve + '▸ ' + $C.Text + (Fit $items[$i] ($inner - 10)) + $C.FgOff) $inner
            }
            $L.Add($side + $row + $side)
        }
        $L.Add($empty)
        $L.Add($side + (PadV ('  ' + (Key '↑↓' 'Choisir') + '   ' + (Key '↵' 'Valider') + '   ' + (Key 'Échap' 'Annuler')) $inner) + $side)
        $L.Add($empty)
        $L.Add($C.Dim + '╰' + ('─' * $inner) + '╯' + $C.FgOff)
        Out-Frame $L

        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
            'UpArrow'   { $sel = ($sel - 1 + $items.Count) % $items.Count }
            'DownArrow' { $sel = ($sel + 1) % $items.Count }
            'Enter'     { return $sel }
            'Escape'    { return -1 }
        }
    }
}

function Confirm-Action([string]$text) {
    $State.Prompt = $text
    Render-Main
    $k = [Console]::ReadKey($true)
    $State.Prompt = $null
    return ('o','O','y','Y' -contains [string]$k.KeyChar)
}

# ---------------------------- Validation saisies -----------------------------
function Test-Saisie([string]$nom, [string]$ip, [string]$user, $exclude) {
    if (-not $nom)                { return @{ Err = 'Le nom est obligatoire.'; Field = 0 } }
    if ($nom -match '[|;&"]')     { return @{ Err = 'Le nom ne peut pas contenir | ; & ou ".'; Field = 0 } }
    if (-not $ip)                 { return @{ Err = "L'adresse IP est obligatoire."; Field = 1 } }
    if ($ip -match '[\s|;&"]')    { return @{ Err = "L'adresse ne peut pas contenir d'espace ni | ; & `"."; Field = 1 } }
    if (-not $user)               { return @{ Err = "L'utilisateur est obligatoire."; Field = 2 } }
    if ($user -match '[\s|;&"@]') { return @{ Err = "L'utilisateur ne peut pas contenir d'espace ni | ; & `" @."; Field = 2 } }
    foreach ($v in $State.Cur.VMs) {
        if ($v -ne $exclude -and $v.IP -eq $ip -and $v.User -eq $user) {
            return @{ Err = "Déjà dans ce dossier sous le nom « $($v.Nom) »."; Field = 1 }
        }
    }
    return $null
}

function Test-NomDossier([string]$nom, $exclude) {
    if (-not $nom)              { return 'Le nom du dossier est obligatoire.' }
    if ($nom -match '[\[\]|]')  { return 'Le nom ne peut pas contenir [ ] ou |.' }
    foreach ($f in $State.Folders) {
        if ($f -ne $exclude -and $f.Nom -eq $nom) { return "Le dossier « $nom » existe déjà." }
    }
    return $null
}

# --------------------------- Actions : dossiers -------------------------------
function Add-Folder {
    $vals = @(''); $err = ''
    while ($true) {
        $r = Show-Form 'Nouveau dossier' @('Nom') $vals 0 $err
        if ($null -eq $r) { return }
        $nom = $r[0].Trim()
        $err = Test-NomDossier $nom $null
        if ($err) { $vals = @($nom); continue }
        $f = New-Folder $nom
        [void]$State.Folders.Add($f)
        $State.FSel = $State.Folders.Count - 1
        Save-Data
        Set-Msg "✓ Dossier « $nom » créé." $C.Green
        return
    }
}

function Rename-Folder {
    if ($State.Folders.Count -eq 0) { return }
    $f = $State.Folders[$State.FSel]
    $vals = @($f.Nom); $err = ''
    while ($true) {
        $r = Show-Form "Renommer « $($f.Nom) »" @('Nom') $vals 0 $err
        if ($null -eq $r) { return }
        $nom = $r[0].Trim()
        $err = Test-NomDossier $nom $f
        if ($err) { $vals = @($nom); continue }
        $f.Nom = $nom
        Save-Data
        Set-Msg "✓ Dossier renommé en « $nom »." $C.Green
        return
    }
}

function Remove-Folder {
    if ($State.Folders.Count -eq 0) { return }
    $f = $State.Folders[$State.FSel]
    $n = $f.VMs.Count
    $q = if ($n -gt 0) { "Supprimer le dossier « $($f.Nom) » et ses $n VM(s) ?" } else { "Supprimer le dossier « $($f.Nom) » ?" }
    if (Confirm-Action $q) {
        $State.Folders.RemoveAt($State.FSel)
        if ($State.FSel -ge $State.Folders.Count) { $State.FSel = [Math]::Max(0, $State.Folders.Count - 1) }
        Save-Data
        Set-Msg "✓ Dossier « $($f.Nom) » supprimé." $C.Green
    }
}

function Open-Folder {
    if ($State.Folders.Count -eq 0) { return }
    $State.Cur = $State.Folders[$State.FSel]
    $State.View = 'vms'; $State.Sel = 0; $State.Offset = 0
}

function Close-Folder {
    $State.View = 'folders'; $State.Cur = $null
}

# ----------------------------- Actions : VMs ----------------------------------
function Add-VM {
    $labels = @('Nom', 'Adresse IP', 'Utilisateur')
    $vals = @('', '', $Config.UserDefaut); $focus = 0; $err = ''
    while ($true) {
        $r = Show-Form "Nouvelle VM  ·  $($State.Cur.Nom)" $labels $vals $focus $err
        if ($null -eq $r) { return }
        $r = @($r | ForEach-Object { $_.Trim() })
        $chk = Test-Saisie $r[0] $r[1] $r[2] $null
        if ($chk) { $vals = $r; $focus = $chk.Field; $err = $chk.Err; continue }
        $vm = New-VM $r[0] $r[1] $r[2]
        [void]$State.Cur.VMs.Add($vm)
        Save-Data
        $State.Sel = $State.Cur.VMs.Count - 1
        Start-Ping $vm
        Set-Msg "✓ VM « $($vm.Nom) » ajoutée." $C.Green
        return
    }
}

function Edit-VM {
    if ($State.Cur.VMs.Count -eq 0) { return }
    $vm = $State.Cur.VMs[$State.Sel]
    $labels = @('Nom', 'Adresse IP', 'Utilisateur')
    $vals = @($vm.Nom, $vm.IP, $vm.User); $focus = 0; $err = ''
    while ($true) {
        $r = Show-Form "Modifier « $($vm.Nom) »" $labels $vals $focus $err
        if ($null -eq $r) { return }
        $r = @($r | ForEach-Object { $_.Trim() })
        $chk = Test-Saisie $r[0] $r[1] $r[2] $vm
        if ($chk) { $vals = $r; $focus = $chk.Field; $err = $chk.Err; continue }
        $ipChanged = ($vm.IP -ne $r[1])
        $vm.Nom = $r[0]; $vm.IP = $r[1]; $vm.User = $r[2]
        Save-Data
        if ($ipChanged) { Start-Ping $vm }
        Set-Msg "✓ VM « $($vm.Nom) » modifiée." $C.Green
        return
    }
}

function Move-VM {
    if ($State.Cur.VMs.Count -eq 0) { return }
    $others = @($State.Folders | Where-Object { $_ -ne $State.Cur })
    if ($others.Count -eq 0) { Set-Msg '✗ Crée d''abord un autre dossier pour pouvoir y déplacer la VM.' $C.Red; return }
    $vm  = $State.Cur.VMs[$State.Sel]
    $idx = Show-Picker "Déplacer « $($vm.Nom) » vers" ([string[]]@($others | ForEach-Object { $_.Nom }))
    if ($idx -lt 0) { return }
    $dest = $others[$idx]
    foreach ($v in $dest.VMs) {
        if ($v.IP -eq $vm.IP -and $v.User -eq $vm.User) {
            Set-Msg "✗ « $($dest.Nom) » contient déjà $($vm.User)@$($vm.IP) ($($v.Nom))." $C.Red; return
        }
    }
    $State.Cur.VMs.RemoveAt($State.Sel)
    [void]$dest.VMs.Add($vm)
    if ($State.Sel -ge $State.Cur.VMs.Count) { $State.Sel = [Math]::Max(0, $State.Cur.VMs.Count - 1) }
    Save-Data
    Set-Msg "✓ « $($vm.Nom) » déplacée vers « $($dest.Nom) »." $C.Green
}

function Remove-VM {
    if ($State.Cur.VMs.Count -eq 0) { return }
    $vm = $State.Cur.VMs[$State.Sel]
    if (Confirm-Action "Supprimer « $($vm.Nom) » ($($vm.User)@$($vm.IP)) ?") {
        $State.Cur.VMs.RemoveAt($State.Sel)
        if ($State.Sel -ge $State.Cur.VMs.Count) { $State.Sel = [Math]::Max(0, $State.Cur.VMs.Count - 1) }
        Save-Data
        Set-Msg "✓ VM « $($vm.Nom) » supprimée." $C.Green
    }
}

function Connect-VM {
    if ($State.Cur.VMs.Count -eq 0) { return }
    if (-not $SSH_OK) { Set-Msg '✗ Client OpenSSH introuvable (Paramètres › Applications › Fonctionnalités facultatives)' $C.Red; return }
    $vm = $State.Cur.VMs[$State.Sel]
    if ($vm.Status -eq 'DOWN') {
        if (-not (Confirm-Action "« $($vm.Nom) » ne répond pas au ping. Se connecter quand même ?")) { return }
    }
    $target = "$($vm.User)@$($vm.IP)"
    if ($WT_OK) {
        $w = if ($Config.Ouverture -eq 'onglet') { '0' } else { 'new' }
        Start-Process wt -ArgumentList "-w $w new-tab --title `"$($vm.Nom)`" --suppressApplicationTitle ssh $target"
    } else {
        Start-Process cmd -ArgumentList "/c title $($vm.Nom)& ssh $target& if errorlevel 1 pause"
    }
    Set-Msg "✓ Session « $($vm.Nom) » ouverte  ($target)" $C.Green
}

# ------------------------------- Clavier -------------------------------------
function Invoke-KeyFolders($k) {
    $n = $State.Folders.Count
    switch ($k.Key) {
        'UpArrow'    { if ($n) { $State.FSel = ($State.FSel - 1 + $n) % $n }; return }
        'DownArrow'  { if ($n) { $State.FSel = ($State.FSel + 1) % $n }; return }
        'Home'       { $State.FSel = 0; return }
        'End'        { $State.FSel = [Math]::Max(0, $n - 1); return }
        'Enter'      { Open-Folder; return }
        'RightArrow' { Open-Folder; return }
        'Escape'     { $State.Quit = $true; return }
        'Insert'     { Add-Folder; return }
        'Delete'     { Remove-Folder; return }
        'F2'         { Rename-Folder; return }
        'F5'         { Start-PingAll; return }
    }
    switch ([string]$k.KeyChar) {
        { $_ -in 'a','A','+' }     { Add-Folder; return }
        { $_ -in 'e','E','r','R' } { Rename-Folder; return }
        { $_ -in 'd','D' }         { Remove-Folder; return }
        { $_ -in 'p','P' }         { Start-PingAll; return }
        { $_ -in 'q','Q', [string][char]3 } { $State.Quit = $true; return }
    }
}

function Invoke-KeyVMs($k) {
    $n = $State.Cur.VMs.Count
    switch ($k.Key) {
        'UpArrow'   { if ($n) { $State.Sel = ($State.Sel - 1 + $n) % $n }; return }
        'DownArrow' { if ($n) { $State.Sel = ($State.Sel + 1) % $n }; return }
        'Home'      { $State.Sel = 0; return }
        'End'       { $State.Sel = [Math]::Max(0, $n - 1); return }
        'Enter'     { Connect-VM; return }
        'Escape'    { Close-Folder; return }
        'LeftArrow' { Close-Folder; return }
        'Backspace' { Close-Folder; return }
        'Insert'    { Add-VM; return }
        'Delete'    { Remove-VM; return }
        'F2'        { Edit-VM; return }
        'F5'        { Start-PingAll; return }
    }
    switch ([string]$k.KeyChar) {
        { $_ -in 'a','A','+' } { Add-VM; return }
        { $_ -in 'e','E' }     { Edit-VM; return }
        { $_ -in 'm','M' }     { Move-VM; return }
        { $_ -in 'd','D' }     { Remove-VM; return }
        { $_ -in 'p','P','r','R' } { Start-PingAll; return }
        { $_ -in 'q','Q', [string][char]3 } { $State.Quit = $true; return }
    }
}

function Invoke-Key($k) {
    if ($State.View -eq 'vms' -and $State.Cur) { Invoke-KeyVMs $k } else { Invoke-KeyFolders $k }
}

# ------------------------------ Boucle principale -----------------------------
if (-not (Test-Path -LiteralPath $Config.Fichier)) { [IO.File]::WriteAllText($Config.Fichier, '') }
Load-Data
if (-not $SSH_OK) { Set-Msg '✗ Client OpenSSH introuvable (Paramètres › Applications › Fonctionnalités facultatives)' $C.Red }
Start-PingAll

try { [Console]::TreatControlCAsInput = $true } catch {}
[Console]::CursorVisible = $false
[Console]::Clear()

try {
    $lastSec = -1
    while (-not $State.Quit) {
        $dirty = Update-Pings
        $pinging = Test-Pinging @(Get-AllVMs)
        if ($pinging) { $State.Spin++; $dirty = $true }

        $now = Get-Date
        if ($now.Second -ne $lastSec) { $lastSec = $now.Second; $dirty = $true }
        if ($Config.AutoPing -gt 0 -and -not $pinging -and
            ($now - $State.LastPing).TotalSeconds -ge $Config.AutoPing) {
            Start-PingAll; $dirty = $true
        }

        if ($dirty) { Render-Main }

        if ([Console]::KeyAvailable) {
            Invoke-Key ([Console]::ReadKey($true))
            Render-Main
        } else {
            Start-Sleep -Milliseconds 80
        }
    }
} finally {
    foreach ($vm in @(Get-AllVMs)) { if ($vm.Pinger) { try { $vm.Pinger.Dispose() } catch {} } }
    [Console]::Write($C.Reset)
    [Console]::Clear()
    [Console]::CursorVisible = $true
}
