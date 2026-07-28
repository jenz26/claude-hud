# claude-hud-widget.ps1  -  widget HUD delle sessioni Claude Code
#
# Finestra senza cornice, sempre in primo piano, ancorata a un angolo.
# Legge i file di stato scritti dagli hook in ~/.claude/hud/ e li ridisegna
# ogni secondo. Non usa un terminale: qui non c'e' niente da ridisegnare a
# caratteri, quindi non esiste il problema dei fotogrammi accavallati.
#
# Formato di ogni file di stato, una riga sola, cinque campi separati da '|':
#   stato|timestamp|colore|progetto|titolo
# Lo scrive claude-hud.sh, che resta l'hook e non va toccato.
#
# Si lancia dal Desktop con "Claude HUD.cmd".
#   trascina col tasto sinistro   sposta la finestra (non c'e' barra del titolo)
#   tasto destro                  chiude il widget

# ------------------------------------------------------------------ TARATURA
$Anchor    = 'BottomRight'   # TopLeft | TopRight | BottomLeft | BottomRight
$MarginX   = 16              # distanza dal bordo verticale dello schermo
$MarginY   = 16              # distanza dal bordo orizzontale dello schermo
$Width     = 340             # larghezza della finestra; l'altezza si adatta
$FontSize  = 11
$ProjWidth = 96              # larghezza della colonna del progetto
$BackAlpha = 220             # 0 trasparente, 255 opaco

# Segnali acustici, per accorgersi che una sessione ha finito senza guardare.
# Ogni voce accetta: un suono di Windows (Asterisk, Beep, Exclamation, Hand,
# Question), il percorso di un .wav, oppure '' per restare muti.
# I .wav di sistema stanno in C:\Windows\Media (ding.wav, chimes.wav, notify.wav).
$SoundDone    = 'Asterisk'   # turno concluso
$SoundWaiting = 'Question'   # aspetta un permesso o un input
$SoundError   = 'Hand'       # errore
# ---------------------------------------------------------------------------

$HudDir       = Join-Path $env:USERPROFILE '.claude\hud'
$ProjectsDir  = Join-Path $env:USERPROFILE '.claude\projects'
$StaleAfter   = 300          # secondi di silenzio prima che "running" viri a grigio
$OrphanAfter  = 1800         # dopo mezz'ora il file di stato viene rimosso

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Una sola istanza: due widget sovrapposti sarebbero identici e indistinguibili.
# $mutex sembra inutilizzato e l'analizzatore lo segnala, ma la variabile va
# tenuta: se il Mutex viene raccolto dal garbage collector il blocco cade e una
# seconda istanza puo' partire.
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeHudWidget', [ref]$created)
if (-not $created) { exit 0 }

# Partenza pulita: via i file delle sessioni morte. Quelle vive si riscrivono
# al primo hook, quindi possono mancare per qualche secondo.
if (Test-Path $HudDir) {
  Get-ChildItem -Path $HudDir -File -Force | Remove-Item -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------ colori
function Get-Brush([int]$a, [int]$r, [int]$g, [int]$b) {
  New-Object System.Windows.Media.SolidColorBrush (
    [System.Windows.Media.Color]::FromArgb($a, $r, $g, $b))
}

function Get-HexBrush([string]$hex) {
  try {
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    New-Object System.Windows.Media.SolidColorBrush $c
  } catch {
    Get-Brush 255 102 102 102
  }
}

# Stessi significati dei pallini di claude-hud.sh.
function Get-StateBrush([string]$state) {
  switch ($state) {
    'running' { Get-Brush 255 229 192 123 }   # giallo  - turno in corso
    'done'    { Get-Brush 255 152 195 121 }   # verde   - turno concluso
    'error'   { Get-Brush 255 224 108 117 }   # rosso   - errore
    'waiting' { Get-Brush 255  97 175 239 }   # blu     - aspetta input
    default   { Get-Brush 255  92  99 112 }   # grigio  - idle o fermo
  }
}

# ------------------------------------------------------------------ finestra
$win = New-Object System.Windows.Window
$win.Title              = 'Claude HUD'   # non si vede, serve a ritrovarla
$win.WindowStyle        = 'None'
$win.AllowsTransparency = $true
$win.Background         = [System.Windows.Media.Brushes]::Transparent
$win.Topmost            = $true
$win.ShowInTaskbar      = $false
$win.ResizeMode         = 'NoResize'
$win.SizeToContent      = 'Height'
$win.Width              = $Width

$border = New-Object System.Windows.Controls.Border
$border.Background   = Get-Brush $BackAlpha 24 24 28
$border.CornerRadius = New-Object System.Windows.CornerRadius 8
$border.Padding      = New-Object System.Windows.Thickness 10, 8, 10, 8
$win.Content = $border

$stack = New-Object System.Windows.Controls.StackPanel
$border.Child = $stack

# Senza barra del titolo servono due gesti espliciti, altrimenti la finestra
# non si puo' ne' spostare ne' chiudere.
$win.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch { } })
$win.Add_MouseRightButtonUp({ $win.Close() })

# ------------------------------------------------------------------ righe
function New-Cell([string]$text, [double]$w, $brush, [int]$col) {
  $t = New-Object System.Windows.Controls.TextBlock
  $t.Text          = $text
  $t.FontFamily    = New-Object System.Windows.Media.FontFamily 'Consolas'
  $t.FontSize      = $FontSize
  $t.Foreground    = $brush
  $t.TextTrimming  = 'CharacterEllipsis'
  $t.VerticalAlignment = 'Center'
  if ($w -gt 0) { $t.Width = $w }
  [System.Windows.Controls.Grid]::SetColumn($t, $col)
  return $t
}

function New-Row($state, $color, $proj, $title) {
  $g = New-Object System.Windows.Controls.Grid
  $g.Margin = New-Object System.Windows.Thickness 0, 1, 0, 1
  foreach ($spec in @(6, $ProjWidth, -1, 14)) {
    $cd = New-Object System.Windows.Controls.ColumnDefinition
    if ($spec -lt 0) { $cd.Width = New-Object System.Windows.GridLength 1, 'Star' }
    else             { $cd.Width = New-Object System.Windows.GridLength $spec }
    $g.ColumnDefinitions.Add($cd)
  }

  # barretta col colore Peacock del progetto
  $bar = New-Object System.Windows.Shapes.Rectangle
  $bar.Width = 4; $bar.RadiusX = 2; $bar.RadiusY = 2
  $bar.Fill = Get-HexBrush $color
  $bar.HorizontalAlignment = 'Left'
  [System.Windows.Controls.Grid]::SetColumn($bar, 0)
  $g.Children.Add($bar) | Out-Null

  $g.Children.Add((New-Cell $proj  ($ProjWidth - 6) (Get-Brush 255 220 220 225) 1)) | Out-Null
  $g.Children.Add((New-Cell $title 0               (Get-Brush 255 150 150 158) 2)) | Out-Null

  $dot = New-Object System.Windows.Shapes.Ellipse
  $dot.Width = 8; $dot.Height = 8
  $dot.Fill = Get-StateBrush $state
  $dot.HorizontalAlignment = 'Right'
  $dot.VerticalAlignment   = 'Center'
  [System.Windows.Controls.Grid]::SetColumn($dot, 3)
  $g.Children.Add($dot) | Out-Null

  return $g
}

function Get-EpochNow {
  [int][math]::Floor(((Get-Date).ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds)
}

# ---------------------------------------------------------------- suoni
# Stato precedente di ogni sessione: il suono va legato al PASSAGGIO, non allo
# stato. Senza questo, una sessione ferma su "done" suonerebbe ogni secondo.
$script:PrevState = @{}
$script:WavCache  = @{}

function Invoke-HudSound([string]$spec) {
  if (-not $spec) { return }
  try {
    # I suoni di sistema seguono volume e schema audio di Windows, e Play()
    # torna subito: non si puo' bloccare il filo dell'interfaccia per un beep.
    if (@('Asterisk','Beep','Exclamation','Hand','Question') -contains $spec) {
      [System.Media.SystemSounds]::$spec.Play()
      return
    }
    if (Test-Path $spec) {
      $p = $script:WavCache[$spec]
      if (-not $p) {
        $p = New-Object System.Media.SoundPlayer $spec
        $p.Load()                     # una volta sola: Load e' sincrono
        $script:WavCache[$spec] = $p
      }
      $p.Play()
    }
  } catch { }
}

# ------------------------------------------------------------- nome della chat
# Claude Code scrive il nome della chat nel transcript della sessione, come riga
#   {"type":"ai-title","aiTitle":"...","sessionId":"..."}
# in ~/.claude/projects/<progetto>/<session-id>.jsonl.
#
# Quei file arrivano a decine di MB e NON si leggono interi. Attenzione: non si
# usa nemmeno "Get-Content -Tail". Ogni riga e' un evento JSON e puo' pesare
# decine di KB (allegati, output di tool): in un transcript reale l'ultimo
# megabyte conteneva 51 righe, e -Tail 120 doveva risalirne molti altri. Provato:
# bloccava per minuti. Qui si legge una finestra fissa di byte dal fondo, quindi
# il costo non dipende da quanto sono lunghe le righe.
$script:TitleCache = @{}
$script:LastSig    = $null   # righe disegnate l'ultima volta, per non ridisegnare a vuoto
$TailBytes = 1048576         # quanto leggere dal fondo del transcript

function Read-TranscriptTail([string]$path) {
  # FileShare ReadWrite: Claude Code sta scrivendo su questo file, non va bloccato
  $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
  try {
    $len  = $fs.Length
    $want = [Math]::Min($len, $TailBytes)
    [void]$fs.Seek($len - $want, 'Begin')
    $buf  = New-Object byte[] $want
    $read = $fs.Read($buf, 0, $want)
  } finally { $fs.Close() }
  return [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
}

function Find-SessionTranscript([string]$sid) {
  foreach ($d in (Get-ChildItem -Path $ProjectsDir -Directory -ErrorAction SilentlyContinue)) {
    $cand = Join-Path $d.FullName ($sid + '.jsonl')
    if (Test-Path $cand) { return $cand }
  }
  return $null
}

function Get-ChatName([string]$sid) {
  $c = $script:TitleCache[$sid]

  # gia' in cache e file non toccato: nessuna lettura
  if ($c -and (Test-Path $c.Path)) {
    $stamp = (Get-Item $c.Path).LastWriteTimeUtc.Ticks
    if ($stamp -eq $c.Stamp) { return $c.Title }
  } else {
    $c = $null
  }

  $path = if ($c) { $c.Path } else { Find-SessionTranscript $sid }
  if (-not $path) { return '' }      # transcript non ancora creato: riprovo dopo

  # Cerco l'ultima occorrenza nel testo grezzo e ritaglio solo quella riga:
  # spezzare l'intero megabyte costerebbe piu' della lettura stessa.
  $title = ''
  try {
    $text = Read-TranscriptTail $path
    $i = $text.LastIndexOf('"type":"ai-title"')
    if ($i -ge 0) {
      $a = $text.LastIndexOf("`n", $i) + 1
      $b = $text.IndexOf("`n", $i); if ($b -lt 0) { $b = $text.Length }
      # la prima riga del buffer puo' essere tagliata a meta': se non e' JSON
      # valido, ConvertFrom-Json fallisce e si ripiega sulla cache
      $t = ($text.Substring($a, $b - $a) | ConvertFrom-Json).aiTitle
      if ($t) { $title = $t }
    }
  } catch { }

  # niente titolo in questa lettura: tengo l'ultimo buono invece di far
  # lampeggiare la riga tornando a "(nuova sessione)"
  if (-not $title -and $c) { $title = $c.Title }

  $stamp = 0
  try { $stamp = (Get-Item $path).LastWriteTimeUtc.Ticks } catch { }
  $script:TitleCache[$sid] = @{ Path = $path; Stamp = $stamp; Title = $title }
  return $title
}

function Update-Rows {
  $now = Get-EpochNow
  $rows = @()
  $seen = @{}       # sessioni viste in questo giro
  $ring = ''        # suono da emettere alla fine del giro, uno solo

  if (Test-Path $HudDir) {
    foreach ($f in Get-ChildItem -Path $HudDir -File -Force -ErrorAction SilentlyContinue) {
      $line = ''
      try { $line = (Get-Content $f.FullName -TotalCount 1 -ErrorAction Stop) } catch { continue }
      if (-not $line) { continue }

      $p = $line -split '\|', 5
      if ($p.Count -lt 5) { continue }
      $state = $p[0]; $ts = $p[1]; $color = $p[2]; $proj = $p[3]; $title = $p[4]
      if (-not $state) { continue }

      # timestamp illeggibile: non cancello, lo lascio a video in grigio
      $age = -1
      if ($ts -match '^\d+$') {
        $age = $now - [int64]$ts
        if ($age -gt $OrphanAfter) {
          Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
          continue
        }
      }
      if ($state -eq 'running' -and $age -ge 0 -and $age -gt $StaleAfter) { $state = 'stale' }

      # Il nome della chat batte quello che scrive l'hook: descrive la sessione
      # invece dell'ultimo prompt, e c'e' anche quando l'hook non ha mai visto
      # un UserPromptSubmit, cioe' proprio nei casi che mostravano
      # "(nuova sessione)". Se manca, resta quello dell'hook.
      $chat = Get-ChatName $f.Name
      if ($chat) { $title = $chat }

      # Suono solo se lo stato e' CAMBIATO, e mai la prima volta che vedo una
      # sessione: al primo giro, o dopo un riavvio del widget, suonerebbero
      # tutte insieme senza che sia successo niente.
      $seen[$f.Name] = $true
      $prev = $script:PrevState[$f.Name]
      if ($prev -and $prev -ne $state) {
        switch ($state) {
          'error'   { $ring = 'error' }
          'waiting' { if ($ring -ne 'error') { $ring = 'waiting' } }
          'done'    { if (-not $ring)        { $ring = 'done'    } }
        }
      }
      $script:PrevState[$f.Name] = $state

      $rows += [pscustomobject]@{ State=$state; Color=$color; Proj=$proj; Title=$title }
    }
  }

  # Via lo stato delle sessioni sparite: se quella session-id ricomparisse,
  # verrebbe trattata come nuova invece che come un passaggio di stato.
  foreach ($k in @($script:PrevState.Keys)) {
    if (-not $seen.ContainsKey($k)) { $script:PrevState.Remove($k) }
  }

  # Un solo suono per giro anche se piu' sessioni cambiano insieme, e la
  # priorita' e' quella che richiede piu' attenzione.
  switch ($ring) {
    'error'   { Invoke-HudSound $SoundError }
    'waiting' { Invoke-HudSound $SoundWaiting }
    'done'    { Invoke-HudSound $SoundDone }
  }

  # Ricostruire gli elementi grafici a ogni secondo costava il 4% di un core
  # anche a schermo fermo. Se le righe sono identiche al giro precedente non
  # c'e' niente da ridisegnare, e nemmeno da riposizionare.
  $sig = ($rows | ForEach-Object { "$($_.State)|$($_.Color)|$($_.Proj)|$($_.Title)" }) -join "`n"
  if ($sig -eq $script:LastSig) { return }
  $script:LastSig = $sig

  $stack.Children.Clear()
  if ($rows.Count -eq 0) {
    $empty = New-Cell 'nessuna sessione attiva' 0 (Get-Brush 255 110 110 118) 0
    $stack.Children.Add($empty) | Out-Null
  } else {
    foreach ($r in ($rows | Sort-Object Proj, Title)) {
      $stack.Children.Add((New-Row $r.State $r.Color $r.Proj $r.Title)) | Out-Null
    }
  }

  # Senza questo, ActualHeight e' ancora quella di prima: WPF non ha rifatto il
  # layout e la finestra verrebbe piazzata usando l'altezza vecchia, staccandosi
  # dall'angolo appena il numero di righe cambia.
  $win.UpdateLayout()
  Set-Position
}

# L'altezza cambia a ogni sessione che entra o esce: ancorando in basso va
# ricalcolata ogni volta, altrimenti la finestra scivola fuori dallo schermo.
function Set-Position {
  $wa = [System.Windows.SystemParameters]::WorkArea
  $w  = $win.ActualWidth;  if ($w -le 0) { $w = $Width }
  $h  = $win.ActualHeight; if ($h -le 0) { $h = 40 }
  switch ($Anchor) {
    'TopLeft'    { $win.Left = $wa.Left + $MarginX;        $win.Top = $wa.Top + $MarginY }
    'TopRight'   { $win.Left = $wa.Right - $w - $MarginX;  $win.Top = $wa.Top + $MarginY }
    'BottomLeft' { $win.Left = $wa.Left + $MarginX;        $win.Top = $wa.Bottom - $h - $MarginY }
    default      { $win.Left = $wa.Right - $w - $MarginX;  $win.Top = $wa.Bottom - $h - $MarginY }
  }
}

# ------------------------------------------------------------------ avvio
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({ Update-Rows })

$win.Add_Loaded({ Update-Rows; $timer.Start() })
$win.Add_Closed({ $timer.Stop() })

# Rete di sicurezza: qualunque cosa cambi l'altezza, l'angolo resta l'angolo.
$win.Add_SizeChanged({ Set-Position })

$win.ShowDialog() | Out-Null
