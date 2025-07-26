"""
Service Microsoft Graph pour OneDrive
Adapté du code conteneur existant
"""

import logging
import requests
import base64
from typing import Dict, Any, Optional
from shared.config import Config

logger = logging.getLogger(__name__)


class GraphService:
    """Service pour l'intégration Microsoft Graph (OneDrive)"""

    def __init__(self):
        self.client_id = Config.CLIENT_ID
        self.client_secret = Config.CLIENT_SECRET
        self.tenant_id = Config.TENANT_ID
        self.onedrive_upload_enabled = Config.ONEDRIVE_UPLOAD_ENABLED
        self.onedrive_folder = Config.ONEDRIVE_FOLDER or "Translated Documents"

        # URLs Microsoft Graph
        self.token_url = f"https://login.microsoftonline.com/{self.tenant_id}/oauth2/v2.0/token"
        self.graph_base_url = "https://graph.microsoft.com/v1.0"

        # Cache du token (en production, utiliser Redis ou équivalent)
        self._access_token = None
        self._token_expires_at = None

        logger.info("✅ GraphService initialisé")

    def is_configured(self) -> bool:
        """Vérifie si le service Graph est configuré"""
        return Config.is_onedrive_enabled()

    def upload_to_onedrive(self, file_content: bytes, file_name: str, user_id: str) -> Dict[str, Any]:
        """
        Upload un fichier vers OneDrive
        """
        if not self.is_configured():
            return {
                "success": False,
                "error": "OneDrive non configuré"
            }
        if self.onedrive_upload_enabled is False:
            return {
                "success": True,
                "info": "Upload OneDrive désactivé"
            }
        try:
            logger.info(f"☁️ Upload vers OneDrive: {file_name} pour {user_id}")

            # Obtention du token d'accès
            access_token = self._get_access_token()
            if not access_token:
                return {
                    "success": False,
                    "error": "Impossible d'obtenir le token d'accès Microsoft Graph"
                }

            # Création du dossier si nécessaire
            folder_id = self._ensure_folder_exists(access_token, self.onedrive_folder)
            if not folder_id:
                return {
                    "success": False,
                    "error": "Impossible de créer/accéder au dossier OneDrive"
                }

            # Construction du nom de fichier unique
            unique_filename = self._get_unique_filename(file_name, user_id)

            # Upload du fichier
            upload_url = f"{self.graph_base_url}/me/drive/items/{folder_id}:/{unique_filename}:/content"
            logger.info(f"📤 URL d'upload: {upload_url}")

            headers = {
                'Authorization': f'Bearer {access_token}',
                'Content-Type': 'application/octet-stream'
            }

            response = requests.put(
                upload_url,
                headers=headers,
                data=file_content,
                timeout=60
            )

            if response.status_code in [200, 201]:
                file_info = response.json()
                onedrive_url = file_info.get('webUrl')

                logger.info(f"✅ Fichier uploadé vers OneDrive: {unique_filename}")
                return {
                    "success": True,
                    "onedrive_url": onedrive_url,
                    "file_id": file_info.get('id'),
                    "file_name": unique_filename
                }
            else:
                error_msg = f"Erreur HTTP {response.status_code}: {response.text}"
                logger.error(f"❌ Erreur upload OneDrive: {error_msg}")
                return {
                    "success": False,
                    "error": error_msg
                }

        except Exception as e:
            logger.error(f"❌ Erreur lors de l'upload OneDrive: {str(e)}")
            return {
                "success": False,
                "error": f"Erreur interne: {str(e)}"
            }

    def _get_access_token(self) -> Optional[str]:
        """Obtient un token d'accès Microsoft Graph"""
        try:
            # Vérifier si le token en cache est encore valide
            if self._access_token and self._token_expires_at:
                import time
                if time.time() < self._token_expires_at - 300:  # 5 min de marge
                    return self._access_token

            # Demande d'un nouveau token
            data = {
                'client_id': self.client_id,
                'client_secret': self.client_secret,
                'scope': 'https://graph.microsoft.com/.default',
                'grant_type': 'client_credentials'
            }

            response = requests.post(self.token_url, data=data, timeout=30)

            if response.status_code == 200:
                token_data = response.json()
                self._access_token = token_data.get('access_token')
                expires_in = token_data.get('expires_in', 3600)

                import time
                self._token_expires_at = time.time() + expires_in

                logger.info("✅ Token Microsoft Graph obtenu")
                return self._access_token
            else:
                logger.error(f"❌ Erreur obtention token: {response.status_code} - {response.text}")
                return None

        except Exception as e:
            logger.error(f"❌ Erreur lors de l'obtention du token: {str(e)}")
            return None

    def _ensure_folder_exists(self, access_token: str, folder_name: str) -> Optional[str]:
        """S'assure que le dossier existe sur OneDrive"""
        try:
            # Recherche du dossier existant
            search_url = f"{self.graph_base_url}/me/drive/root/children"
            headers = {'Authorization': f'Bearer {access_token}'}

            response = requests.get(search_url, headers=headers, timeout=30)

            if response.status_code == 200:
                items = response.json().get('value', [])
                for item in items:
                    if (item.get('name') == folder_name and 
                        item.get('folder') is not None):
                        logger.info(f"📁 Dossier existant trouvé: {folder_name}")
                        return item.get('id')

            # Création du dossier s'il n'existe pas
            create_url = f"{self.graph_base_url}/me/drive/root/children"
            
            folder_data = {
                "name": folder_name,
                "folder": {},
                "@microsoft.graph.conflictBehavior": "rename"
            }

            create_response = requests.post(
                create_url,
                headers={
                    'Authorization': f'Bearer {access_token}',
                    'Content-Type': 'application/json'
                },
                json=folder_data,
                timeout=30
            )

            if create_response.status_code in [200, 201]:
                folder_info = create_response.json()
                folder_id = folder_info.get('id')
                logger.info(f"✅ Dossier créé: {folder_name}")
                return folder_id
            else:
                logger.error(f"❌ Erreur création dossier: {create_response.status_code}")
                return None

        except Exception as e:
            logger.error(f"❌ Erreur gestion dossier: {str(e)}")
            return None

    def _get_unique_filename(self, file_name: str, user_id: str) -> str:
        """Génère un nom de fichier unique pour OneDrive"""
        from datetime import datetime
        
        # Extraction nom et extension
        if '.' in file_name:
            name, ext = file_name.rsplit('.', 1)
        else:
            name, ext = file_name, ''

        # Ajout timestamp et user_id
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        unique_name = f"{name}_{user_id}_{timestamp}"
        
        if ext:
            unique_name += f".{ext}"
            
        return unique_name

    def get_folder_contents(self, folder_name: Optional[str] = None) -> Dict[str, Any]:
        """Liste le contenu d'un dossier OneDrive"""
        if not self.is_configured():
            return {
                "success": False,
                "error": "OneDrive non configuré"
            }

        try:
            access_token = self._get_access_token()
            if not access_token:
                return {
                    "success": False,
                    "error": "Token d'accès indisponible"
                }

            # URL pour lister les fichiers
            if folder_name:
                folder_id = self._ensure_folder_exists(access_token, folder_name)
                if not folder_id:
                    return {
                        "success": False,
                        "error": f"Dossier '{folder_name}' introuvable"
                    }
                list_url = f"{self.graph_base_url}/me/drive/items/{folder_id}/children"
            else:
                list_url = f"{self.graph_base_url}/me/drive/root/children"

            headers = {'Authorization': f'Bearer {access_token}'}
            response = requests.get(list_url, headers=headers, timeout=30)

            if response.status_code == 200:
                items = response.json().get('value', [])
                files = []
                
                for item in items:
                    if 'file' in item:  # Ignorer les dossiers
                        files.append({
                            'name': item.get('name'),
                            'id': item.get('id'),
                            'size': item.get('size'),
                            'created': item.get('createdDateTime'),
                            'modified': item.get('lastModifiedDateTime'),
                            'download_url': item.get('@microsoft.graph.downloadUrl'),
                            'web_url': item.get('webUrl')
                        })

                return {
                    "success": True,
                    "files": files,
                    "count": len(files)
                }
            else:
                error_msg = f"Erreur HTTP {response.status_code}: {response.text}"
                return {
                    "success": False,
                    "error": error_msg
                }

        except Exception as e:
            logger.error(f"❌ Erreur liste OneDrive: {str(e)}")
            return {
                "success": False,
                "error": f"Erreur interne: {str(e)}"
            }

    def delete_file(self, file_id: str) -> Dict[str, Any]:
        """Supprime un fichier OneDrive"""
        if not self.is_configured():
            return {
                "success": False,
                "error": "OneDrive non configuré"
            }

        try:
            access_token = self._get_access_token()
            if not access_token:
                return {
                    "success": False,
                    "error": "Token d'accès indisponible"
                }

            delete_url = f"{self.graph_base_url}/me/drive/items/{file_id}"
            headers = {'Authorization': f'Bearer {access_token}'}

            response = requests.delete(delete_url, headers=headers, timeout=30)

            if response.status_code == 204:
                logger.info(f"✅ Fichier OneDrive supprimé: {file_id}")
                return {
                    "success": True,
                    "message": "Fichier supprimé avec succès"
                }
            else:
                error_msg = f"Erreur HTTP {response.status_code}: {response.text}"
                return {
                    "success": False,
                    "error": error_msg
                }

        except Exception as e:
            logger.error(f"❌ Erreur suppression OneDrive: {str(e)}")
            return {
                "success": False,
                "error": f"Erreur interne: {str(e)}"
            }