"""
Azure Functions App pour la traduction de documents
Remplace la fonction durable par des fonctions HTTP simples
"""

import azure.functions as func
import json
import logging
import os
from typing import Dict, Any
from datetime import datetime, timezone

# Configuration du logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Création de l'application Azure Functions
app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

# Import des handlers après l'initialisation de l'app
from shared.services.translation_handler import TranslationHandler
from shared.services.status_handler import StatusHandler
from shared.utils.response_helper import create_response, create_error_response
from shared.services.blob_service import BlobService
from shared.services.translation_service import TranslationService
from shared.services.graph_service import GraphService
from shared.config import Config

onedrive_upload_enabled = Config.ONEDRIVE_UPLOAD_ENABLED

# Initialisation des handlers
translation_handler = TranslationHandler()
status_handler = StatusHandler()
blob_service = BlobService()
graph_service = GraphService()
translation_service = TranslationService()

@app.route(route="start_translation", methods=["POST"])
def start_translation(req: func.HttpRequest) -> func.HttpResponse:
    logger.info("🚀 Démarrage d'une nouvelle traduction")

    try:
        if not req.get_body():
            return create_error_response("Corps de requête manquant", 400)

        try:
            data = req.get_json()
        except ValueError as e:
            return create_error_response(f"JSON invalide: {str(e)}", 400)

        required_fields = ["blob_name", "target_language", "user_id"]
        for field in required_fields:
            if field not in data:
                return create_error_response(f"Paramètre manquant: {field}", 400)

        blob_name = data["blob_name"]
        target_language = data["target_language"]
        user_id = data["user_id"]

        # 1. Vérifier l’existence du blob
        blob_service = BlobService()
        if not blob_service.check_blob_exists(blob_name):
            return create_error_response(f"Fichier '{blob_name}' non trouvé", 404)

        # 2. Construire les URLs SAS
        blob_urls = blob_service.prepare_translation_urls(blob_name, target_language)
        source_url = blob_urls["source_url"]
        target_url = blob_urls["target_url"]

        # 3. Démarrer la traduction
        translation_service = TranslationService()
        translation_id = translation_service.start_translation(
            source_url=source_url,
            target_url=target_url,
            target_language=target_language
        )

        result = {
            "success": True,
            "translation_id": translation_id,
            "message": f"Traduction démarrée avec succès pour {blob_name}",
            "status": "En cours",
            "target_language": target_language,
            "estimated_time": "2-5 minutes"
        }
        return create_response(result, 202)

    except Exception as e:
        logger.error(f"❌ Erreur traduction: {str(e)}")
        return create_error_response(f"Erreur lors de la traduction: {str(e)}", 500)


@app.route(route="check_status/{translation_id}", methods=["GET"])
def check_translation_status(req: func.HttpRequest) -> func.HttpResponse:
    translation_id = req.route_params.get('translation_id')
    if not translation_id:
        return create_error_response("ID de traduction manquant", 400)
    logger.info(f"🔍 Vérification du statut pour: {translation_id}")
    try:
        result = status_handler.check_status(translation_id)
        if result['success']:
            return create_response(result['data'], 200)
        else:
            return create_error_response(result['message'], 404)
    except Exception as e:
        logger.error(f"❌ Erreur inattendue: {str(e)}")
        return create_error_response(f"Erreur interne: {str(e)}", 500)


@app.route(route="get_result", methods=["GET"])
def get_translation_result(req: func.HttpRequest) -> func.HttpResponse:
    """
    Récupère l'URL SAS du document traduit (stateless).
    Requiert les paramètres : ?blob_name=xxx&target_language=fr
    """
    blob_name = req.params.get('blob_name')
    target_language = req.params.get('target_language')
    user_id = req.params.get('user_id')  # Pour OneDrive optionnel

    if not blob_name or not target_language:
        return create_error_response("Paramètres manquants : blob_name, target_language", 400)

    try:
        # Génère le nom du blob de sortie
        file_base, file_ext = blob_name.rsplit('.', 1)
        output_blob_name = f"{file_base}-{target_language}.{file_ext}"

        # Génère l'URL SAS
        download_url = blob_service.get_translated_file_url(output_blob_name)
        if not download_url:
            return create_error_response("Fichier traduit introuvable", 404)

        result = {
            "download_url": download_url
        }

        # (Optionnel) Upload vers OneDrive
        if user_id:
            file_content = blob_service.download_translated_file(output_blob_name)
            onedrive_url = graph_service.upload_to_onedrive(file_content, output_blob_name, user_id)
            result["onedrive_url"] = onedrive_url

        return create_response(result, 200)

    except Exception as e:
        logger.error(f"❌ Erreur lors de la récupération du résultat: {str(e)}")
        return create_error_response(f"Erreur interne: {str(e)}", 500)


@app.route(route="health", methods=["GET"])
def health_check(req: func.HttpRequest) -> func.HttpResponse:
    """
    Point de santé pour vérifier que les fonctions sont opérationnelles
    """
    try:
        # Vérification des variables d'environnement critiques
        required_vars = [
            'TRANSLATOR_KEY',
            'TRANSLATOR_ENDPOINT',
            'AZURE_ACCOUNT_NAME',
            'AZURE_ACCOUNT_KEY'
        ]
        
        missing_vars = [var for var in required_vars if not os.getenv(var)]
        
        if missing_vars:
            return create_error_response(
                f"Variables d'environnement manquantes: {', '.join(missing_vars)}", 
                503
            )
        if onedrive_upload_enabled:
            od_available = "available"
        else:
            od_available = "not configured"
        health_data = {
            "status": "healthy",
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "services": {
                "translator": "available",
                "blob_storage": "available",
                "onedrive": od_available
            }
        }
        
        return create_response(health_data, 200)
        
    except Exception as e:
        logger.error(f"❌ Erreur du health check: {str(e)}")
        return create_error_response(f"Service unhealthy: {str(e)}", 503)


@app.route(route="languages", methods=["GET"])
def get_supported_languages(req: func.HttpRequest) -> func.HttpResponse:
    """
    Retourne la liste des langues supportées
    """
    try:
        from shared.models.schemas import SupportedLanguages
        
        languages = SupportedLanguages.get_all_languages()
        
        return create_response({
            "languages": languages,
            "count": len(languages)
        }, 200)
        
    except Exception as e:
        logger.error(f"❌ Erreur lors de la récupération des langues: {str(e)}")
        return create_error_response(f"Erreur interne: {str(e)}", 500)


@app.route(route="formats", methods=["GET"])
def get_supported_formats(req: func.HttpRequest) -> func.HttpResponse:
    """
    Retourne la liste des formats de fichiers supportés
    """
    try:
        from shared.models.schemas import FileFormats
        
        formats = FileFormats.get_all_formats()
        
        return create_response({
            "formats": formats,
            "count": len(formats)
        }, 200)
        
    except Exception as e:
        logger.error(f"❌ Erreur lors de la récupération des formats: {str(e)}")
        return create_error_response(f"Erreur interne: {str(e)}", 500)
