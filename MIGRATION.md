# Guide de Migration : Conteneur → Azure Functions

## 🎯 Objectif
Migrer votre service de traduction de documents d'**Azure Container Instance** vers **Azure Functions** pour réduire les coûts de 60-80% tout en conservant toutes les fonctionnalités.

## 📋 Checklist de préparation

### ✅ Avant de commencer
- [ ] Sauvegarder les configurations du conteneur actuel
- [ ] Noter les variables d'environnement utilisées
- [ ] Identifier les clients/applications qui utilisent le service
- [ ] Planifier une fenêtre de maintenance (1-2h recommandées)

### ✅ Outils requis
- [ ] [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli) installé et configuré
- [ ] [Azure Functions Core Tools](https://docs.microsoft.com/azure/azure-functions/functions-run-local) v4
- [ ] PowerShell 5.1+ ou PowerShell Core 7+
- [ ] Python 3.9+
- [ ] Accès administrateur à votre subscription Azure

## 🚀 Étapes de migration

### Étape 1: Récupération du code existant

```bash
# Si vous avez votre code conteneur actuel dans un repo Git
git clone <votre-repo-conteneur>
cd votre-projet-conteneur

# Ou récupérez les fichiers depuis votre conteneur si nécessaire
```

**📁 Copiez tous les artefacts fournis dans un nouveau dossier :**
- `function_app.py`
- `host.json`
- `requirements.txt` 
- `local.settings.json`
- `deploy.ps1`
- `test_deployment.ps1`
- Dossier `shared/` complet

### Étape 2: Configuration des paramètres

**📝 Éditez `local.settings.json` :**

```json
{
  "Values": {
    "AZURE_ACCOUNT_NAME": "COPIEZ depuis votre conteneur",
    "AZURE_ACCOUNT_KEY": "COPIEZ depuis votre conteneur", 
    "TRANSLATOR_TEXT_SUBSCRIPTION_KEY": "COPIEZ depuis votre conteneur",
    "TRANSLATOR_TEXT_ENDPOINT": "COPIEZ depuis votre conteneur",
    "CLIENT_ID": "COPIEZ si OneDrive configuré",
    "SECRET_ID": "COPIEZ si OneDrive configuré",
    "TENANT_ID": "COPIEZ si OneDrive configuré"
  }
}
```

**🔍 Pour retrouver vos paramètres actuels :**
```bash
# Si votre conteneur est encore en marche
az container show --name VOTRE_CONTENEUR --resource-group VOTRE_RG --query "containers[0].environmentVariables"

# Ou vérifiez dans le portail Azure > Container Instances > Configuration
```

### Étape 3: Test local (recommandé)

```bash
# Installation des dépendances
pip install -r requirements.txt

# Démarrage local
func start --python

# Test dans un autre terminal
curl http://localhost:7071/api/health
```

### Étape 4: Déploiement Azure Functions

**🎯 Option A - Déploiement complet (ressources neuves)**
```powershell
.\deploy.ps1 -ResourceGroupName "rg-translation-functions" -FunctionAppName "func-translation-v2" -CreateResources
```

**🔄 Option B - Déploiement dans un groupe existant**
```powershell
.\deploy.ps1 -ResourceGroupName "VOTRE_RG_EXISTANT" -FunctionAppName "NOUVEAU_NOM_FUNCTION"
```

### Étape 5: Validation du déploiement

```powershell
# Test automatisé complet
.\test_deployment.ps1 -FunctionAppUrl "https://votre-function-app.azurewebsites.net"
```

**✅ Vérifications manuelles :**
- Health check : `GET /api/health`
- Langues : `GET /api/languages` 
- Test de traduction simple avec un petit fichier texte

### Étape 6: Test en parallèle

**🔗 Mise à jour graduelle des clients :**

```javascript
// Avant (conteneur)
const oldBaseUrl = 'https://votre-conteneur.azurecontainerinstance.io';

// Après (Azure Functions) 
const newBaseUrl = 'https://votre-function-app.azurewebsites.net/api';

// Test A/B possible
const baseUrl = useNewService ? newBaseUrl : oldBaseUrl;
```

**📊 Comparaison des performances :**
- Testez avec les mêmes fichiers sur les deux services
- Comparez les temps de réponse
- Validez que les résultats de traduction sont identiques

### Étape 7: Mise en production

**🔄 Stratégies de basculement :**

**Option A - Basculement complet :**
```bash
# Mettez à jour toutes vos applications d'un coup
# Arrêtez l'ancien conteneur
az container stop --name VOTRE_CONTENEUR --resource-group VOTRE_RG
```

**Option B - Basculement progressif :**
```bash
# Redirigez 10% du trafic d'abord, puis augmentez graduellement
# Utilisez un load balancer ou API Gateway si disponible
```

### Étape 8: Nettoyage

**🧹 Une fois la migration validée (après 1 semaine) :**

```bash
# Suppression de l'ancien conteneur
az container delete --name VOTRE_CONTENEUR --resource-group VOTRE_RG --yes

# Suppression des ressources inutilisées si container dans un RG dédié
az group delete --name ANCIEN_RG_CONTENEUR --yes
```

## 📊 Validation des économies

### Comparaison des coûts

**💰 Avant (Container Instance) :**
```
Conteneur Always-On (Basic: 1 vCPU, 1.5GB RAM):
• €30-50/mois en continu
• Facturation 24h/24, même sans utilisation
```

**💰 Après (Azure Functions) :**
```
Consommation Functions:
• ~€5-15/mois pour usage modéré
• Facturation uniquement à l'exécution
• 1M exécutions gratuites/mois incluses
```

**📈 Exemple concret :**
- 100 traductions/jour × 30 jours = 3000 exécutions/mois
- Temps moyen par traduction : 2 minutes
- Coût Azure Functions : ~€8/mois vs Container : ~€40/mois
- **Économies : 80%**

## 🔧 Résolution de problèmes

### Problèmes courants et solutions

**❌ "Cannot find storage account"**
```bash
# Vérifiez les variables d'environnement
az functionapp config appsettings list --name VOTRE_FUNCTION --resource-group VOTRE_RG

# Mettez à jour si nécessaire
az functionapp config appsettings set --name VOTRE_FUNCTION --resource-group VOTRE_RG --settings "AZURE_ACCOUNT_NAME=correctvalue"
```

**❌ "Translator service unavailable"**
```bash
# Testez votre clé Translator directement
curl -X POST "https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&to=fr" \
  -H "Ocp-Apim-Subscription-Key: VOTRE_CLE" \
  -H "Content-Type: application/json" \
  -d '[{"Text":"Hello"}]'
```

**❌ "Function app cold start timeout"**
- Normal au premier appel après inactivité
- L'application se réchauffe après quelques requêtes
- Considérez Premium Plan si critique

**❌ "Translation stuck in InProgress"**
- Azure Translator peut prendre 5-15 minutes
- Vérifiez les logs Application Insights
- Le polling automatique gère les long processus

### Logs et monitoring

**📊 Application Insights :**
```bash
# Accès direct aux logs
# Portail Azure > Votre Function App > Application Insights > Logs

# Requête exemple pour les erreurs
exceptions
| where timestamp > ago(1h)
| project timestamp, message, details
```

**🔍 Debugging local :**
```bash
# Mode verbose
func start --python --verbose

# Variables d'environnement de debug
export AZURE_FUNCTIONS_ENVIRONMENT=Development
```

## 📋 Rollback (si nécessaire)

**🔄 Plan de retour en arrière :**

1. **Redémarrage de l'ancien conteneur :**
```bash
az container start --name VOTRE_ANCIEN_CONTENEUR --resource-group VOTRE_RG
```

2. **Restauration des URLs dans vos applications**

3. **Investigation du problème Functions :**
   - Vérifiez les logs Application Insights
   - Validez la configuration
   - Testez individuellement chaque endpoint

## ✅ Checklist post-migration

### Validation technique
- [ ] Tous les endpoints répondent correctement
- [ ] Les traductions produisent les mêmes résultats
- [ ] OneDrive fonctionne (si configuré)
- [ ] Les performances sont acceptables
- [ ] Le monitoring fonctionne

### Validation business
- [ ] Les applications clientes fonctionnent
- [ ] Les utilisateurs peuvent traduire normalement
- [ ] Aucune plainte d'utilisateurs
- [ ] Les coûts Azure reflètent les économies attendues

### Nettoyage
- [ ] Ancien conteneur arrêté/supprimé
- [ ] Documentation mise à jour
- [ ] Équipe informée des nouvelles URLs
- [ ] Monitoring configuré sur les nouvelles ressources

## 🎉 Félicitations !

Votre migration est terminée ! Vous devriez maintenant bénéficier de :
- **💰 Réduction des coûts de 60-80%**
- **🚀 Mise à l'échelle automatique**
- **📊 Meilleur monitoring**
- **🔧 Maintenance simplifiée**

---

**📞 Support :** En cas de problème, vérifiez d'abord les logs Application Insights, puis consultez la documentation Azure Functions.

**🔄 Améliorations futures :** Considérez l'ajout de Redis pour la gestion d'état en production haute charge.