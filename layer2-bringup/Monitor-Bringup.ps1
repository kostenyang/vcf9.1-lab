param(
  [string]$Inst='10.0.1.4',
  [string]$Sddc='450c646c-88c2-48b6-a485-8e8ab16f2659',
  [int]$IntervalSec=180,
  [string]$LogFile='E:\9.1\vcf9.1-lab\layer2-bringup\bringup-monitor.log'
)
[Net.ServicePointManager]::ServerCertificateValidationCallback={$true}
function Get-Tok {
  (Invoke-RestMethod -Method Post -Uri "https://$Inst/v1/tokens" -SkipCertificateCheck -ContentType 'application/json' -Body (@{username='admin@local';password='VMware1!VMware1!'}|ConvertTo-Json)).accessToken
}
while($true){
  $ts=(Get-Date).ToString('HH:mm')
  try{
    $t=Get-Tok
    $h=@{Authorization="Bearer $t"}
    $s=Invoke-RestMethod -Uri "https://$Inst/v1/sddcs/$Sddc" -Headers $h -SkipCertificateCheck
    $sub=$s.sddcSubTasks
    $done=@($sub | Where-Object{$_.status -match 'SUCCESS|COMPLETED'}).Count
    $tot=@($sub).Count
    $cur=@($sub | Where-Object{$_.status -eq 'IN_PROGRESS'} | ForEach-Object{$_.name})
    $fail=@($sub | Where-Object{$_.status -match 'FAIL|ERROR'})
    $line="[$ts] status=$($s.status) done=$done/$tot"
    if($cur){ $line += " | NOW: " + ($cur -join ' ; ') }
    if($fail){ $line += " | FAIL: " + (($fail|ForEach-Object{$_.name+'='+$_.status}) -join ' ; ') }
    Add-Content -Path $LogFile -Value $line
    if($s.status -match 'COMPLETED_WITH_SUCCESS|Completed|SUCCESS' -and $s.status -notmatch 'IN_PROGRESS'){
      Add-Content -Path $LogFile -Value "[$ts] *** BRING-UP FINISHED status=$($s.status) ***"
      break
    }
    if($s.status -match 'FAIL|ERROR'){
      Add-Content -Path $LogFile -Value "[$ts] *** BRING-UP FAILED status=$($s.status) ***"
      break
    }
  }catch{
    Add-Content -Path $LogFile -Value "[$ts] poll-error: $($_.Exception.Message)"
  }
  Start-Sleep -Seconds $IntervalSec
}
