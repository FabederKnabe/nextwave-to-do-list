# pipeline-toast.psm1
#
# Geteilte Pipeline-Toast-Hilfsfunktion fuer record-call.ps1 und
# process-recording.ps1. Alle Toasts nutzen denselben UniqueIdentifier
# 'nw-call-pipeline', damit aufeinanderfolgende Aufrufe denselben Toast
# ersetzen statt zu stapeln. Immer -Silent.
#
# ProgressBar optional:
#   - default (Value 0..1 + ValueDisplay)
#   - -Indeterminate (Marquee-Balken)
#   - -NoProgress (reiner Text-Toast)

function Send-PipelineToast {
  param(
    [string]$Title = 'nextWAVE Pipeline',
    [string]$Status,
    [double]$ProgressValue = -1,
    [string]$ValueDisplay = '',
    [switch]$Indeterminate,
    [switch]$NoProgress
  )
  if (-not (Get-Module -ListAvailable -Name BurntToast)) { return }
  try {
    Import-Module BurntToast -ErrorAction Stop
    $btParams = @{
      Text             = @($Title, $Status)
      UniqueIdentifier = 'nw-call-pipeline'
      Silent           = $true
    }
    if (-not $NoProgress) {
      if ($Indeterminate) {
        $pb = New-BTProgressBar -Status $Status -Indeterminate
      } else {
        $val  = if ($ProgressValue -ge 0) { $ProgressValue } else { 0.0 }
        $disp = if ($ValueDisplay) { $ValueDisplay } else { '{0:P0}' -f $val }
        $pb = New-BTProgressBar -Status $Status -Value $val -ValueDisplay $disp
      }
      $btParams['ProgressBar'] = $pb
    }
    New-BurntToastNotification @btParams
  } catch { }
}

Export-ModuleMember -Function Send-PipelineToast
