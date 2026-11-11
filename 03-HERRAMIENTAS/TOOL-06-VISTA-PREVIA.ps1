[CmdletBinding()]
param(
    [string]$VolumeLabel = '06',
    [switch]$VerificarInterfaz
)

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'TOOL-06-ORGANIZAR-ORIGENES.ps1'
$logRoot = Split-Path -Parent $PSScriptRoot
if (-not $logRoot) { $logRoot = $PSScriptRoot }
$logDir = Join-Path $logRoot 'logs'
$planPath = Join-Path $logDir ('organizador_plan_vista_' + [guid]::NewGuid().ToString('N') + '.csv')
$powerShell = Join-Path $PSHOME 'powershell.exe'

if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "No se encontro el organizador: $scriptPath"
}

Add-Type -AssemblyName System.Windows.Forms
$volumes = @(Get-CimInstance Win32_LogicalDisk | Where-Object {
    $_.VolumeName -eq $VolumeLabel -and $_.DeviceID -match '^[A-Z]:$'
})
if ($volumes.Count -ne 1) {
    $message = if ($volumes.Count -eq 0) {
        "No se encontro el disco llamado '$VolumeLabel'. Conectalo y vuelve a abrir el CMD."
    } else {
        "Hay varios discos llamados '$VolumeLabel'. Cambia el nombre de uno antes de continuar."
    }
    Write-Host $message -ForegroundColor Red
    if (-not $VerificarInterfaz) {
        [void][System.Windows.Forms.MessageBox]::Show($message, 'Organizador de origenes', 'OK', 'Warning')
    }
    exit 2
}
$targetVolume = $volumes[0]
$rootPath = $targetVolume.DeviceID + '\'
Write-Host "Disco seleccionado: $rootPath (nombre: $VolumeLabel)" -ForegroundColor Cyan
Write-Host 'Preparando la vista previa de los cambios...' -ForegroundColor Cyan
& $powerShell -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Root $rootPath -PlanCsv $planPath
if ($LASTEXITCODE -ne 0) { throw "El analisis fallo (codigo $LASTEXITCODE). No se aplicaron cambios." }

$plan = @()
if (Test-Path -LiteralPath $planPath -PathType Leaf) {
    $plan = @(Import-Csv -LiteralPath $planPath)
}
$movibles = @($plan | Where-Object { $_.Estado -eq 'MOVER' })
$sinMover = @($plan | Where-Object { $_.Estado -ne 'MOVER' })

Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = "Organizador de origenes - disco $VolumeLabel ($rootPath)"
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1220, 720)
$form.MinimumSize = New-Object System.Drawing.Size(900, 500)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'
$layout.RowCount = 3
$layout.ColumnCount = 1
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 70)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 50)))
$form.Controls.Add($layout)

$header = New-Object System.Windows.Forms.Label
$header.Dock = 'Top'
$header.Height = 70
$header.Padding = New-Object System.Windows.Forms.Padding(14, 12, 14, 4)
$header.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$header.Text = "DISCO $VolumeLabel ($rootPath): $($movibles.Count) movimientos   |   $($sinMover.Count) sin mover`r`nRevisa las rutas de origen y destino antes de continuar."
$layout.Controls.Add($header, 0, 0)

$footer = New-Object System.Windows.Forms.Panel
$footer.Dock = 'Bottom'
$footer.Height = 50
$layout.Controls.Add($footer, 0, 2)

$note = New-Object System.Windows.Forms.Label
$note.AutoSize = $true
$note.Location = New-Object System.Drawing.Point(14, 17)
$note.Text = 'Al cerrar esta ventana, el CMD pedira la palabra APLICAR.'
$footer.Controls.Add($note)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = 'Cerrar vista previa'
$closeButton.Size = New-Object System.Drawing.Size(150, 30)
$closeButton.Anchor = 'Top,Right'
$closeButton.Location = New-Object System.Drawing.Point(($form.ClientSize.Width - 170), 10)
$closeButton.Add_Click({ $form.Close() })
$footer.Controls.Add($closeButton)
$footer.Add_Resize({ $closeButton.Left = $footer.ClientSize.Width - $closeButton.Width - 16 })

$table = New-Object System.Data.DataTable
foreach ($name in @('Dia', 'Tipo', 'Proyecto', 'Camara', 'Estado', 'Origen', 'Destino')) {
    [void]$table.Columns.Add($name, [string])
}
foreach ($item in $plan) {
    [void]$table.Rows.Add([object[]]@($item.Dia, $item.Tipo, $item.Proyecto, $item.Camara, $item.Estado, $item.Origen, $item.Destino))
}

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.MultiSelect = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.RowHeadersVisible = $false
$grid.AutoSizeColumnsMode = 'None'
$grid.AutoGenerateColumns = $false
$grid.BindingContext = New-Object System.Windows.Forms.BindingContext
foreach ($name in @('Dia', 'Tipo', 'Proyecto', 'Camara', 'Estado', 'Origen', 'Destino')) {
    $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $column.Name = $name
    $column.HeaderText = $name
    $column.DataPropertyName = $name
    [void]$grid.Columns.Add($column)
}
$grid.DataSource = $table
$grid.Columns['Dia'].Width = 95
$grid.Columns['Tipo'].Width = 110
$grid.Columns['Proyecto'].Width = 205
$grid.Columns['Camara'].Width = 100
$grid.Columns['Estado'].Width = 100
$grid.Columns['Origen'].Width = 300
$grid.Columns['Destino'].Width = 300
foreach ($row in $grid.Rows) {
    $tipo = [string]$row.Cells['Tipo'].Value
    $estado = [string]$row.Cells['Estado'].Value
    if ($estado -ne 'MOVER') { $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::MistyRose }
    elseif ($tipo -eq 'NUEVO') { $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::Honeydew }
    elseif ($tipo -eq 'REZAGADO') { $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::AliceBlue }
}
$layout.Controls.Add($grid, 0, 1)

if ($VerificarInterfaz) {
    Write-Host "Interfaz preparada: $($grid.Rows.Count) filas; $($movibles.Count) movimientos."
    $form.Dispose()
    return
}

[void]$form.ShowDialog()
$form.Dispose()

if ($movibles.Count -eq 0) {
    Write-Host 'No hay elementos para mover.' -ForegroundColor Green
    return
}

Write-Host ''
$respuesta = Read-Host "Para mover los $($movibles.Count) elementos, escribe APLICAR (cualquier otra cosa cancela)"
if ($respuesta.Trim() -ne 'APLICAR') {
    Write-Host 'Cancelado: no se movio nada.' -ForegroundColor Yellow
    return
}

$currentVolume = @(Get-CimInstance Win32_LogicalDisk | Where-Object {
    $_.DeviceID -eq $targetVolume.DeviceID -and $_.VolumeName -eq $VolumeLabel -and
    $_.VolumeSerialNumber -eq $targetVolume.VolumeSerialNumber
})
if ($currentVolume.Count -ne 1) {
    throw "El disco '$VolumeLabel' cambio desde la vista previa. Abre de nuevo el CMD antes de aplicar."
}
Write-Host 'Ejecutando el organizador...' -ForegroundColor Cyan
& $powerShell -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Root $rootPath -Aplicar
if ($LASTEXITCODE -ne 0) { throw "La ejecucion termino con codigo $LASTEXITCODE. Revisa el registro de movimientos." }
