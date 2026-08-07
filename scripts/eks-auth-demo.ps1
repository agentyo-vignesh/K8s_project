<#
.SYNOPSIS
    Teaching demo: how a laptop authenticates to an EKS cluster.

.DESCRIPTION
    Seven steps proving that your AWS IAM credentials ARE your Kubernetes
    credentials - there is no Kubernetes password anywhere.

    Run it in front of a class. It pauses between steps so people can read the
    output; pass -NoPause to run it straight through.

    ASCII only, deliberately. Windows PowerShell 5.1 reads a .ps1 without a BOM
    using the system ANSI codepage, so a stray em dash or arrow corrupts string
    parsing and silently eats whole arguments.

.EXAMPLE
    ./scripts/eks-auth-demo.ps1
    ./scripts/eks-auth-demo.ps1 -Cluster ai-interview -Region ap-south-1
    ./scripts/eks-auth-demo.ps1 -NoPause
#>
[CmdletBinding()]
param(
    [string]$Cluster = "ai-interview",
    [string]$Region  = "ap-south-1",
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([int]$N, [string]$Title, [string]$Point)
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    Write-Host " $N. $Title" -ForegroundColor Cyan
    if ($Point) { Write-Host "    $Point" -ForegroundColor DarkGray }
    Write-Host ("=" * 78) -ForegroundColor DarkGray
}

function Wait-Step {
    if (-not $NoPause) { Read-Host "`n  [Enter] to continue" | Out-Null }
}

# -----------------------------------------------------------------------------
Write-Step 1 "kubeconfig - is there a password in it?" "Answer: no. Only a command to run."

$exec = kubectl config view --minify -o jsonpath='{.users[0].user.exec}' | ConvertFrom-Json
Write-Host "  command : $($exec.command)"
Write-Host "  args    : $($exec.args -join ' ')"
Write-Host ""
Write-Host "  kubectl runs that command on EVERY call to get a fresh token." -ForegroundColor Yellow
Wait-Step

# -----------------------------------------------------------------------------
Write-Step 2 "Who am I - AWS side?"

aws sts get-caller-identity --output json
Wait-Step

# -----------------------------------------------------------------------------
Write-Step 3 "Who am I - Kubernetes side?" "Same ARN. Kubernetes has no separate user for you."

kubectl auth whoami
Wait-Step

# -----------------------------------------------------------------------------
Write-Step 4 "The token - and what is actually inside it"

$token = (aws eks get-token --cluster-name $Cluster --region $Region --output json | ConvertFrom-Json).status.token

Write-Host "  prefix : $($token.Substring(0, [Math]::Min(45, $token.Length)))..."
Write-Host "  length : $($token.Length) chars"
Write-Host ""
Write-Host "  Not a JWT. Decode the base64 after 'k8s-aws-v1.' :" -ForegroundColor Yellow

# base64url -> base64, then pad to a multiple of 4
$b64 = $token.Substring(11).Replace('-', '+').Replace('_', '/')
while ($b64.Length % 4 -ne 0) { $b64 += '=' }
$url = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))

($url -split '&') | ForEach-Object {
    $line = if ($_.Length -gt 92) { $_.Substring(0, 92) + "..." } else { $_ }
    Write-Host "    $line"
}

Write-Host ""
Write-Host "  It is a PRE-SIGNED STS GetCallerIdentity URL." -ForegroundColor Yellow
Write-Host "  X-Amz-Expires=60     -> valid 60 seconds only." -ForegroundColor Yellow
Write-Host "  x-k8s-aws-id signed  -> bound to THIS cluster; it cannot be replayed" -ForegroundColor Yellow
Write-Host "                          against another one." -ForegroundColor Yellow
Write-Host ""
Write-Host "  EKS does not know your password. It replays this URL to STS, and" -ForegroundColor Yellow
Write-Host "  STS answers with your identity." -ForegroundColor Yellow
Wait-Step

# -----------------------------------------------------------------------------
Write-Step 5 "Where the IAM to Kubernetes mapping lives" "Note the node role: nodes authenticate exactly the way you do."

aws eks list-access-entries --cluster-name $Cluster --region $Region --output json

$me = (aws sts get-caller-identity --query Arn --output text)
Write-Host "`n  Access policies attached to $me" -ForegroundColor DarkGray
aws eks list-associated-access-policies --cluster-name $Cluster --region $Region `
    --principal-arn $me `
    --query "associatedAccessPolicies[].{Policy:policyArn,Scope:accessScope.type}" --output table
Wait-Step

# -----------------------------------------------------------------------------
Write-Step 6 "Authorization - what am I allowed to do?" "Groups is only system:authenticated. Admin comes from the access policy above."

$canI = kubectl auth can-i '*' '*' --all-namespaces
Write-Host "  kubectl auth can-i '*' '*' --all-namespaces  ->  $canI"
Wait-Step

# -----------------------------------------------------------------------------
Write-Step 7 "THE PROOF - break AWS credentials, leave kubeconfig untouched"

$saved    = $env:AWS_PROFILE
$hadValue = Test-Path Env:AWS_PROFILE

try {
    $env:AWS_PROFILE = "does-not-exist-$(Get-Random)"
    Write-Host "  AWS_PROFILE now points at a profile that does not exist."
    Write-Host "  kubeconfig is UNCHANGED. Running: kubectl get nodes`n" -ForegroundColor DarkGray

    # Expected to fail. The redirect has to happen in cmd, not PowerShell:
    # Windows PowerShell 5.1 turns a native command's stderr into
    # NativeCommandError objects for BOTH `2>&1` and `2>file`, which buries the
    # real message under a script trace. Letting cmd merge the streams means
    # PowerShell only ever sees stdout.
    $ErrorActionPreference = "Continue"
    $failure = & cmd /c "kubectl get nodes 2>&1"
    $failure | Where-Object { $_.Trim() } | Select-Object -First 3 |
        ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
}
finally {
    $ErrorActionPreference = "Stop"
    if ($hadValue) { $env:AWS_PROFILE = $saved } else { Remove-Item Env:AWS_PROFILE -ErrorAction SilentlyContinue }
}

Write-Host "`n  Credentials restored. Proving it works again:`n" -ForegroundColor DarkGray
kubectl get nodes

Write-Host ""
Write-Host ("=" * 78) -ForegroundColor DarkGray
Write-Host " Conclusion" -ForegroundColor Green
Write-Host ("=" * 78) -ForegroundColor DarkGray
Write-Host @"
  Same kubeconfig. Same cluster. Only the AWS credentials changed, and kubectl
  stopped working.

  -> Your Kubernetes access IS your AWS access.
  -> Stealing ~/.kube/config gains an attacker nothing. It holds no secret,
     only a command that reads YOUR ~/.aws/credentials.
  -> Disable the IAM user in AWS and cluster access dies immediately, with no
     change made inside the cluster.

  IRSA runs the same bridge in the opposite direction:
     IRSA    : Kubernetes identity -> AWS permissions    (pod -> AWS API)
     kubectl : AWS identity        -> Kubernetes perms   (you -> K8s API)

  See docs/RBAC_VS_IRSA.md
"@
