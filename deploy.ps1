# Script de déploiement Azure Functions pour la traduction
# Remplace le déploiement conteneur par un déploiement Function App

param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory=$true)]
    [string]$FunctionAppName,
    
    [Parameter(Mandatory=$false)]
    [string]$StorageAccountName = "",
    
    [Parameter(Mandatory=$false)]
    [string]$Location = "France Central",
    
    [Parameter(Mandatory=$false)]
    [switch]$CreateResources = $false
)

Write-Host "🚀 Déploiement Azure Functions pour la traduction de documents" -ForegroundColor Green
Write-Host "📁 Resource Group: $ResourceGroupName" -ForegroundColor Yellow
Write-Host "⚡ Function App: $FunctionAppName" -ForegroundColor Yellow

# Vérification des outils requis
Write-Host "`n🔧 Vérification des outils..." -ForegroundColor Cyan

# Azure CLI
try {
    $azVersion = az --version | Select-String "azure-cli" | ForEach-Object { $_.Line.Split()[1] }
    Write-Host "✅ Azure CLI: $azVersion" -ForegroundColor Green
} catch {
    Write-Host "❌ Azure CLI non trouvé. Installez-le depuis https://aka.ms/installazurecliwindows" -ForegroundColor Red
    exit 1
}

# Azure Functions Core Tools
try {
    $funcVersion = func --version
    Write-Host "✅ Azure Functions Core Tools: $funcVersion" -ForegroundColor Green
} catch {
    Write-Host "❌ Azure Functions Core Tools non trouvé. Installez avec: npm install -g azure-functions-core-tools@4 --unsafe-perm true" -ForegroundColor Red
    exit 1
}

# Python
try {
    $pythonVersion = python --version
    Write-Host "✅ Python: $pythonVersion" -ForegroundColor Green
} catch {
    Write-Host "❌ Python non trouvé. Installez Python 3.9+ depuis https://python.org" -ForegroundColor Red
    exit 1
}

# Connexion Azure
Write-Host "`n🔐 Vérification de la connexion Azure..." -ForegroundColor Cyan
$account = az account show --query "user.name" -o tsv 2>$null
if (-not $account) {
    Write-Host "🔑 Connexion à Azure..." -ForegroundColor Yellow
    az login
    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ Échec de la connexion Azure" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "✅ Connecté en tant que: $account" -ForegroundColor Green
}

# Création des ressources si demandé
if ($CreateResources) {
    Write-Host "`n🏗️ Création des ressources Azure..." -ForegroundColor Cyan
    
    # Génération du nom de storage si non fourni
    if (-not $StorageAccountName) {
        $StorageAccountName = $FunctionAppName.ToLower().Replace("-", "") + "storage"
        $StorageAccountName = $StorageAccountName.Substring(0, [Math]::Min(24, $StorageAccountName.Length))
    }
    
    # Création du Resource Group
    Write-Host "📁 Création du Resource Group..." -ForegroundColor Yellow
    az group create --name $ResourceGroupName --location $Location
    
    # Création du Storage Account
    Write-Host "💾 Création du Storage Account..." -ForegroundColor Yellow
    az storage account create `
        --name $StorageAccountName `
        --resource-group $ResourceGroupName `
        --location $Location `
        --sku Standard_LRS `
        --kind StorageV2
    
    # Création des conteneurs blob
    Write-Host "📦 Création des conteneurs blob..." -ForegroundColor Yellow
    $storageKey = az storage account keys list --resource-group $ResourceGroupName --account-name $StorageAccountName --query "[0].value" -o tsv
    
    az storage container create --name "doc-to-trad" --account-name $StorageAccountName --account-key $storageKey
    az storage container create --name "doc-trad" --account-name $StorageAccountName --account-key $storageKey
    
    # Création de l'Application Insights
    Write-Host "📊 Création d'Application Insights..." -ForegroundColor Yellow
    $appInsightsName = "$FunctionAppName-insights"
    az monitor app-insights component create `
        --app $appInsightsName `
        --location $Location `
        --resource-group $ResourceGroupName `
        --kind web `
        --application-type web
    
    # Création de la Function App
    Write-Host "⚡ Création de la Function App..." -ForegroundColor Yellow
    az functionapp create `
        --resource-group $ResourceGroupName `
        --consumption-plan-location $Location `
        --runtime python `
        --runtime-version 3.9 `
        --functions-version 4 `
        --name $FunctionAppName `
        --storage-account $StorageAccountName `
        --app-insights $appInsightsName `
        --disable-app-insights false
    
    Write-Host "✅ Ressources créées avec succès!" -ForegroundColor Green
} else {
    Write-Host "`n🔍 Vérification des ressources existantes..." -ForegroundColor Cyan
    
    # Vérification de l'existence de la Function App
    $functionApp = az functionapp show --name $FunctionAppName --resource-group $ResourceGroupName 2>$null
    if (-not $functionApp) {
        Write-Host "❌ Function App '$FunctionAppName' introuvable dans le groupe '$ResourceGroupName'" -ForegroundColor Red
        Write-Host "💡 Utilisez le paramètre -CreateResources pour créer les ressources" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "✅ Function App trouvée: $FunctionAppName" -ForegroundColor Green
}

# Configuration des variables d'environnement
Write-Host "`n⚙️ Configuration des variables d'environnement..." -ForegroundColor Cyan

# Lecture du fichier local.settings.json pour les valeurs par défaut
$localSettings = @{}
if (Test-Path "local.settings.json") {
    try {
        $localSettingsContent = Get-Content "local.settings.json" -Raw | ConvertFrom-Json
        $localSettings = $localSettingsContent.Values
        Write-Host "✅ Fichier local.settings.json lu" -ForegroundColor Green
    } catch {
        Write-Host "⚠️ Erreur lecture local.settings.json: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Variables d'environnement critiques
$criticalSettings = @{
    "TRANSLATOR_TEXT_SUBSCRIPTION_KEY" = "Clé de subscription Azure Translator"
    "TRANSLATOR_TEXT_ENDPOINT" = "Endpoint Azure Translator"
    "AZURE_ACCOUNT_NAME" = "Nom du compte de storage"
    "AZURE_ACCOUNT_KEY" = "Clé du compte de storage"
}

Write-Host "🔧 Configuration des paramètres critiques..." -ForegroundColor Yellow

foreach ($setting in $criticalSettings.GetEnumerator()) {
    $key = $setting.Key
    $description = $setting.Value
    $currentValue = ""
    
    # Vérifier si la valeur existe dans local.settings.json
    if ($localSettings.ContainsKey($key) -and $localSettings.$key -and $localSettings.$key -notlike "<*>") {
        $currentValue = $localSettings.$key
        Write-Host "📝 $description : Utilisation de la valeur du fichier local" -ForegroundColor Green
    } else {
        # Demander à l'utilisateur
        do {
            $currentValue = Read-Host "🔑 Entrez $description ($key)"
        } while (-not $currentValue)
    }
    
    # Configuration dans Azure
    az functionapp config appsettings set `
        --name $FunctionAppName `
        --resource-group $ResourceGroupName `
        --settings "$key=$currentValue" `
        --output none
}

# Configuration des paramètres optionnels
Write-Host "`n🔄 Configuration des paramètres optionnels..." -ForegroundColor Yellow

$optionalSettings = @{
    "INPUT_CONTAINER" = "doc-to-trad"
    "OUTPUT_CONTAINER" = "doc-trad"
    "MAX_FILE_SIZE_MB" = "100"
    "MAX_TRANSLATION_TIME_MINUTES" = "30"
    "CLEANUP_INTERVAL_HOURS" = "1"
    "ONEDRIVE_FOLDER" = "Translated Documents"
}

foreach ($setting in $optionalSettings.GetEnumerator()) {
    $key = $setting.Key
    $defaultValue = $setting.Value
    $value = $defaultValue
    
    if ($localSettings.ContainsKey($key) -and $localSettings.$key) {
        $value = $localSettings.$key
    }
    
    az functionapp config appsettings set `
        --name $FunctionAppName `
        --resource-group $ResourceGroupName `
        --settings "$key=$value" `
        --output none
}

# Configuration OneDrive (optionnel)
Write-Host "`n☁️ Configuration OneDrive (optionnel)..." -ForegroundColor Cyan
$configureOneDrive = Read-Host "Configurer l'intégration OneDrive? (y/N)"

if ($configureOneDrive -eq "y" -or $configureOneDrive -eq "Y") {
    $clientId = Read-Host "🔑 Client ID (Azure AD App)"
    $clientSecret = Read-Host "🔐 Client Secret" -AsSecureString
    $tenantId = Read-Host "🏢 Tenant ID"
    
    $clientSecretPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($clientSecret))
    
    az functionapp config appsettings set `
        --name $FunctionAppName `
        --resource-group $ResourceGroupName `
        --settings "CLIENT_ID=$clientId" "SECRET_ID=$clientSecretPlain" "TENANT_ID=$tenantId" `
        --output none
    
    Write-Host "✅ OneDrive configuré" -ForegroundColor Green
}

# Build et déploiement
Write-Host "`n🔨 Préparation du déploiement..." -ForegroundColor Cyan

# Vérification de la structure du projet
$requiredFiles = @("function_app.py", "requirements.txt", "host.json")
foreach ($file in $requiredFiles) {
    if (-not (Test-Path $file)) {
        Write-Host "❌ Fichier manquant: $file" -ForegroundColor Red
        exit 1
    }
}
Write-Host "✅ Structure du projet validée" -ForegroundColor Green

# Installation des dépendances Python (si nécessaire)
if (Test-Path "requirements.txt") {
    Write-Host "📦 Installation des dépendances Python..." -ForegroundColor Yellow
    python -m pip install -r requirements.txt --quiet
}

# Déploiement
Write-Host "`n🚀 Déploiement de la Function App..." -ForegroundColor Cyan
Write-Host "⏳ Cela peut prendre quelques minutes..." -ForegroundColor Yellow

func azure functionapp publish $FunctionAppName --python

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n✅ Déploiement réussi!" -ForegroundColor Green
    
    # Récupération de l'URL de la Function App
    $functionAppUrl = az functionapp show --name $FunctionAppName --resource-group $ResourceGroupName --query "defaultHostName" -o tsv
    
    Write-Host "`n🌐 URLs des endpoints:" -ForegroundColor Cyan
    Write-Host "   Health Check: https://$functionAppUrl/api/health" -ForegroundColor White
    Write-Host "   Start Translation: https://$functionAppUrl/api/start_translation" -ForegroundColor White
    Write-Host "   Check Status: https://$functionAppUrl/api/check_status/{translation_id}" -ForegroundColor White
    Write-Host "   Get Result: https://$functionAppUrl/api/get_result/{translation_id}" -ForegroundColor White
    Write-Host "   Languages: https://$functionAppUrl/api/languages" -ForegroundColor White
    Write-Host "   Formats: https://$functionAppUrl/api/formats" -ForegroundColor White
    
    # Test de santé
    Write-Host "`n🏥 Test de santé..." -ForegroundColor Cyan
    try {
        $healthResponse = Invoke-RestMethod -Uri "https://$functionAppUrl/api/health" -Method GET -TimeoutSec 30
        if ($healthResponse.success -and $healthResponse.data.status -eq "healthy") {
            Write-Host "✅ Service opérationnel!" -ForegroundColor Green
        } else {
            Write-Host "⚠️ Service déployé mais santé dégradée" -ForegroundColor Yellow
            Write-Host "   Vérifiez les logs dans le portail Azure" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "⚠️ Impossible de tester la santé - Le service peut encore démarrer" -ForegroundColor Yellow
        Write-Host "   Attendez quelques minutes et testez manuellement" -ForegroundColor Yellow
    }
    
    Write-Host "`n📋 Prochaines étapes:" -ForegroundColor Cyan
    Write-Host "   1. Testez les endpoints avec Postman ou curl" -ForegroundColor White
    Write-Host "   2. Configurez le monitoring dans Application Insights" -ForegroundColor White
    Write-Host "   3. Mettez à jour vos applications clientes avec les nouvelles URLs" -ForegroundColor White
    Write-Host "   4. Supprimez l'ancien conteneur si tout fonctionne" -ForegroundColor White
    
} else {
    Write-Host "`n❌ Échec du déploiement" -ForegroundColor Red
    Write-Host "   Vérifiez les logs ci-dessus pour plus de détails" -ForegroundColor Yellow
    exit 1
}

Write-Host "`n🎉 Migration de conteneur vers Azure Functions terminée!" -ForegroundColor Green