# Script de test pour valider le déploiement Azure Functions
# Teste tous les endpoints et fonctionnalités

param(
    [Parameter(Mandatory=$true)]
    [string]$FunctionAppUrl,
    
    [Parameter(Mandatory=$false)]
    [string]$TestUserId = "test-user-" + (Get-Date -Format "yyyyMMdd-HHmmss"),
    
    [Parameter(Mandatory=$false)]
    [switch]$Verbose = $false
)

Write-Host "🧪 Test de déploiement Azure Functions Translation" -ForegroundColor Green
Write-Host "🌐 URL: $FunctionAppUrl" -ForegroundColor Yellow
Write-Host "👤 User ID de test: $TestUserId" -ForegroundColor Yellow

# Configuration
$baseUrl = $FunctionAppUrl.TrimEnd('/')
if (-not $baseUrl.Contains('/api')) {
    $baseUrl = "$baseUrl/api"
}

$headers = @{
    'Content-Type' = 'application/json'
    'User-Agent' = 'Azure-Functions-Test-Script/1.0'
}

$testResults = @()

function Test-Endpoint {
    param(
        [string]$Name,
        [string]$Url,
        [string]$Method = "GET",
        [hashtable]$Body = $null,
        [hashtable]$ExpectedFields = @{},
        [int]$ExpectedStatusCode = 200
    )
    
    Write-Host "`n🔬 Test: $Name" -ForegroundColor Cyan
    Write-Host "   URL: $Url" -ForegroundColor Gray
    Write-Host "   Méthode: $Method" -ForegroundColor Gray
    
    try {
        $requestParams = @{
            Uri = $Url
            Method = $Method
            Headers = $headers
            TimeoutSec = 30
        }
        
        if ($Body) {
            $requestParams.Body = ($Body | ConvertTo-Json -Depth 10)
            if ($Verbose) {
                Write-Host "   Body: $($requestParams.Body)" -ForegroundColor Gray
            }
        }
        
        $response = Invoke-RestMethod @requestParams
        
        # Vérification du code de statut (approximatif car Invoke-RestMethod ne lève pas d'erreur pour 2xx)
        Write-Host "   ✅ Réponse reçue" -ForegroundColor Green
        
        if ($Verbose) {
            Write-Host "   Réponse: $($response | ConvertTo-Json -Depth 3)" -ForegroundColor Gray
        }
        
        # Vérification des champs attendus
        $fieldErrors = @()
        foreach ($field in $ExpectedFields.Keys) {
            $expectedValue = $ExpectedFields[$field]
            $actualValue = $response
            
            # Navigation dans les propriétés imbriquées (ex: "data.status")
            $fieldParts = $field.Split('.')
            foreach ($part in $fieldParts) {
                if ($actualValue -and $actualValue.PSObject.Properties[$part]) {
                    $actualValue = $actualValue.$part
                } else {
                    $actualValue = $null
                    break
                }
            }
            
            if ($expectedValue -eq "*") {
                # Vérifier seulement la présence
                if (-not $actualValue) {
                    $fieldErrors += "Champ '$field' manquant"
                }
            } elseif ($actualValue -ne $expectedValue) {
                $fieldErrors += "Champ '$field': attendu '$expectedValue', reçu '$actualValue'"
            }
        }
        
        if ($fieldErrors.Count -eq 0) {
            Write-Host "   ✅ Tous les champs validés" -ForegroundColor Green
            $global:testResults += @{ Name = $Name; Status = "PASS"; Error = $null; Response = $response }
            return $response
        } else {
            Write-Host "   ⚠️ Erreurs de validation:" -ForegroundColor Yellow
            foreach ($error in $fieldErrors) {
                Write-Host "     - $error" -ForegroundColor Yellow
            }
            $global:testResults += @{ Name = $Name; Status = "PARTIAL"; Error = ($fieldErrors -join "; "); Response = $response }
            return $response
        }
        
    } catch {
        $errorMsg = $_.Exception.Message
        Write-Host "   ❌ Erreur: $errorMsg" -ForegroundColor Red
        $global:testResults += @{ Name = $Name; Status = "FAIL"; Error = $errorMsg; Response = $null }
        return $null
    }
}

# Test 1: Health Check
Write-Host "`n🏥 === TESTS DE SANTÉ ===" -ForegroundColor Magenta
$healthResponse = Test-Endpoint -Name "Health Check" -Url "$baseUrl/health" -ExpectedFields @{
    "success" = $true
    "data.status" = "*"
}

# Test 2: Langues supportées
Write-Host "`n🌍 === TESTS DE CONFIGURATION ===" -ForegroundColor Magenta
$languagesResponse = Test-Endpoint -Name "Langues supportées" -Url "$baseUrl/languages" -ExpectedFields @{
    "success" = $true
    "data.languages" = "*"
    "data.count" = "*"
}

# Test 3: Formats supportés
$formatsResponse = Test-Endpoint -Name "Formats supportés" -Url "$baseUrl/formats" -ExpectedFields @{
    "success" = $true
    "data.formats" = "*"
    "data.count" = "*"
}

# Test 4: Traduction (fichier de test simple)
Write-Host "`n📄 === TESTS DE TRADUCTION ===" -ForegroundColor Magenta

# Création d'un fichier de test simple (texte encodé en base64)
$testContent = "Hello, this is a test document for translation."
$testContentBytes = [System.Text.Encoding]::UTF8.GetBytes($testContent)
$testContentBase64 = [System.Convert]::ToBase64String($testContentBytes)

$translationBody = @{
    file_content = $testContentBase64
    file_name = "test-document.txt"
    target_language = "fr"
    user_id = $TestUserId
}

$startResponse = Test-Endpoint -Name "Démarrage traduction" -Url "$baseUrl/start_translation" -Method "POST" -Body $translationBody -ExpectedFields @{
    "success" = $true
    "data.translation_id" = "*"
    "data.status" = "*"
}

$translationId = $null
if ($startResponse -and $startResponse.success -and $startResponse.data.translation_id) {
    $translationId = $startResponse.data.translation_id
    Write-Host "   🆔 ID de traduction: $translationId" -ForegroundColor Green
    
    # Test 5: Vérification du statut
    Start-Sleep -Seconds 2  # Attendre un peu avant de vérifier
    
    $statusResponse = Test-Endpoint -Name "Vérification statut" -Url "$baseUrl/check_status/$translationId" -ExpectedFields @{
        "success" = $true
        "data.translation_id" = $translationId
        "data.status" = "*"
    }
    
    if ($statusResponse -and $statusResponse.success) {
        $currentStatus = $statusResponse.data.status
        Write-Host "   📊 Statut actuel: $currentStatus" -ForegroundColor Green
        
        # Si la traduction est en cours, attendre un peu plus
        if ($currentStatus -eq "InProgress" -or $currentStatus -eq "Pending") {
            Write-Host "   ⏳ Traduction en cours, attente de 30 secondes..." -ForegroundColor Yellow
            Start-Sleep -Seconds 30
            
            # Nouvelle vérification
            $statusResponse2 = Test-Endpoint -Name "Vérification statut (2)" -Url "$baseUrl/check_status/$translationId" -ExpectedFields @{
                "success" = $true
                "data.translation_id" = $translationId
            }
            
            if ($statusResponse2) {
                $finalStatus = $statusResponse2.data.status
                Write-Host "   📊 Statut final: $finalStatus" -ForegroundColor Green
                
                # Test du résultat si terminé
                if ($finalStatus -eq "Succeeded" -or $finalStatus -eq "Failed") {
                    Test-Endpoint -Name "Récupération résultat" -Url "$baseUrl/get_result/$translationId" -ExpectedFields @{
                        "success" = $true
                        "data.translation_id" = $translationId
                        "data.status" = $finalStatus
                    }
                }
            }
        }
    }
    
    # Test 6: Annulation (sur une nouvelle traduction pour éviter de perturber le test précédent)
    Write-Host "`n🛑 Test d'annulation..." -ForegroundColor Cyan
    $cancelBody = @{
        file_content = $testContentBase64
        file_name = "test-cancel.txt"
        target_language = "es"
        user_id = $TestUserId
    }
    
    $cancelStartResponse = Test-Endpoint -Name "Démarrage traduction (à annuler)" -Url "$baseUrl/start_translation" -Method "POST" -Body $cancelBody -ExpectedFields @{
        "success" = $true
        "data.translation_id" = "*"
    }
    
    if ($cancelStartResponse -and $cancelStartResponse.data.translation_id) {
        $cancelTranslationId = $cancelStartResponse.data.translation_id
        
        # Attendre un peu puis annuler
        Start-Sleep -Seconds 2
        Test-Endpoint -Name "Annulation traduction" -Url "$baseUrl/cancel_translation/$cancelTranslationId" -Method "DELETE" -ExpectedFields @{
            "success" = $true
        }
    }
}

# Test 7: Tests d'erreur
Write-Host "`n❌ === TESTS DE GESTION D'ERREUR ===" -ForegroundColor Magenta

# Test avec données invalides
$invalidBody = @{
    file_content = "invalid-base64"
    file_name = ""
    target_language = "invalid"
    user_id = ""
}

try {
    Invoke-RestMethod -Uri "$baseUrl/start_translation" -Method "POST" -Headers $headers -Body ($invalidBody | ConvertTo-Json) -TimeoutSec 30
    Write-Host "   ⚠️ Erreur attendue non reçue" -ForegroundColor Yellow
    $global:testResults += @{ Name = "Test données invalides"; Status = "PARTIAL"; Error = "Erreur attendue non reçue"; Response = $null }
} catch {
    Write-Host "   ✅ Erreur correctement gérée: $($_.Exception.Message)" -ForegroundColor Green
    $global:testResults += @{ Name = "Test données invalides"; Status = "PASS"; Error = $null; Response = $null }
}

# Test avec ID inexistant
try {
    Invoke-RestMethod -Uri "$baseUrl/check_status/inexistent-id" -Method "GET" -Headers $headers -TimeoutSec 30
    Write-Host "   ⚠️ Erreur attendue non reçue pour ID inexistant" -ForegroundColor Yellow
    $global:testResults += @{ Name = "Test ID inexistant"; Status = "PARTIAL"; Error = "Erreur attendue non reçue"; Response = $null }
} catch {
    Write-Host "   ✅ Erreur correctement gérée pour ID inexistant: $($_.Exception.Message)" -ForegroundColor Green
    $global:testResults += @{ Name = "Test ID inexistant"; Status = "PASS"; Error = $null; Response = $null }
}

# Test 8: Performance
Write-Host "`n⚡ === TESTS DE PERFORMANCE ===" -ForegroundColor Magenta

Write-Host "   🏃‍♂️ Test de latence..." -ForegroundColor Cyan
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    Invoke-RestMethod -Uri "$baseUrl/health" -Method "GET" -Headers $headers -TimeoutSec 10
    $stopwatch.Stop()
    $latency = $stopwatch.ElapsedMilliseconds
    
    if ($latency -lt 5000) {  # Moins de 5 secondes
        Write-Host "   ✅ Latence acceptable: ${latency}ms" -ForegroundColor Green
        $global:testResults += @{ Name = "Test latence"; Status = "PASS"; Error = $null; Response = $latency }
    } else {
        Write-Host "   ⚠️ Latence élevée: ${latency}ms" -ForegroundColor Yellow
        $global:testResults += @{ Name = "Test latence"; Status = "PARTIAL"; Error = "Latence élevée: ${latency}ms"; Response = $latency }
    }
} catch {
    $stopwatch.Stop()
    Write-Host "   ❌ Timeout ou erreur de latence" -ForegroundColor Red
    $global:testResults += @{ Name = "Test latence"; Status = "FAIL"; Error = "Timeout"; Response = $null }
}

# Résumé des résultats
Write-Host "`n📊 === RÉSUMÉ DES TESTS ===" -ForegroundColor Magenta

$passCount = ($testResults | Where-Object { $_.Status -eq "PASS" }).Count
$partialCount = ($testResults | Where-Object { $_.Status -eq "PARTIAL" }).Count
$failCount = ($testResults | Where-Object { $_.Status -eq "FAIL" }).Count
$totalCount = $testResults.Count

Write-Host "`n📈 Statistiques:" -ForegroundColor Cyan
Write-Host "   ✅ Réussis: $passCount" -ForegroundColor Green
Write-Host "   ⚠️ Partiels: $partialCount" -ForegroundColor Yellow
Write-Host "   ❌ Échecs: $failCount" -ForegroundColor Red
Write-Host "   📊 Total: $totalCount" -ForegroundColor White

Write-Host "`n📋 Détails des tests:" -ForegroundColor Cyan
foreach ($result in $testResults) {
    $status = switch ($result.Status) {
        "PASS" { "✅" }
        "PARTIAL" { "⚠️" }
        "FAIL" { "❌" }
        default { "❓" }
    }
    
    $errorText = if ($result.Error) { " - $($result.Error)" } else { "" }
    Write-Host "   $status $($result.Name)$errorText" -ForegroundColor White
}

# Évaluation globale
Write-Host "`n🎯 === ÉVALUATION GLOBALE ===" -ForegroundColor Magenta

$successRate = [math]::Round(($passCount / $totalCount) * 100, 1)

if ($failCount -eq 0 -and $partialCount -le 2) {
    Write-Host "🎉 DÉPLOIEMENT RÉUSSI!" -ForegroundColor Green
    Write-Host "   Taux de réussite: $successRate%" -ForegroundColor Green
    Write-Host "   Le service est opérationnel et prêt à être utilisé." -ForegroundColor Green
    $exitCode = 0
} elseif ($failCount -eq 0) {
    Write-Host "✅ DÉPLOIEMENT ACCEPTABLE" -ForegroundColor Yellow
    Write-Host "   Taux de réussite: $successRate%" -ForegroundColor Yellow
    Write-Host "   Le service fonctionne avec quelques avertissements mineurs." -ForegroundColor Yellow
    $exitCode = 0
} elseif ($failCount -le 2 -and $passCount -ge ($totalCount / 2)) {
    Write-Host "⚠️ DÉPLOIEMENT PARTIEL" -ForegroundColor Yellow
    Write-Host "   Taux de réussite: $successRate%" -ForegroundColor Yellow
    Write-Host "   Le service fonctionne mais nécessite des corrections." -ForegroundColor Yellow
    $exitCode = 1
} else {
    Write-Host "❌ DÉPLOIEMENT PROBLÉMATIQUE" -ForegroundColor Red
    Write-Host "   Taux de réussite: $successRate%" -ForegroundColor Red
    Write-Host "   Le service nécessite des corrections importantes." -ForegroundColor Red
    $exitCode = 2
}

# Recommandations
Write-Host "`n💡 === RECOMMANDATIONS ===" -ForegroundColor Magenta

if ($failCount -gt 0) {
    Write-Host "🔧 Actions recommandées:" -ForegroundColor Cyan
    Write-Host "   1. Vérifiez les logs dans Application Insights" -ForegroundColor White
    Write-Host "   2. Validez les variables d'environnement dans le portail Azure" -ForegroundColor White
    Write-Host "   3. Testez manuellement les endpoints qui ont échoué" -ForegroundColor White
    Write-Host "   4. Vérifiez les permissions Azure Storage et Translator" -ForegroundColor White
}

if ($partialCount -gt 0) {
    Write-Host "📝 Améliorations suggérées:" -ForegroundColor Cyan
    Write-Host "   1. Optimisez les temps de réponse si nécessaire" -ForegroundColor White
    Write-Host "   2. Configurez OneDrive si souhaité" -ForegroundColor White
    Write-Host "   3. Ajustez les paramètres de configuration" -ForegroundColor White
}

Write-Host "`n🔗 Liens utiles:" -ForegroundColor Cyan
Write-Host "   📊 Application Insights: https://portal.azure.com" -ForegroundColor White
Write-Host "   ⚙️ Configuration Function App: https://portal.azure.com" -ForegroundColor White
Write-Host "   📚 Documentation: https://docs.microsoft.com/azure/azure-functions/" -ForegroundColor White

# Génération d'un rapport JSON
$reportPath = "test-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$report = @{
    timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    function_app_url = $FunctionAppUrl
    test_user_id = $TestUserId
    summary = @{
        total_tests = $totalCount
        passed = $passCount
        partial = $partialCount
        failed = $failCount
        success_rate = $successRate
    }
    tests = $testResults
    recommendation = switch ($exitCode) {
        0 { "DEPLOY_SUCCESS" }
        1 { "DEPLOY_PARTIAL" }
        2 { "DEPLOY_FAILED" }
    }
}

$report | ConvertTo-Json -Depth 10 | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host "`n📄 Rapport détaillé sauvegardé: $reportPath" -ForegroundColor Cyan

Write-Host "`n🏁 Test terminé avec le code de sortie: $exitCode" -ForegroundColor White
exit $exitCode