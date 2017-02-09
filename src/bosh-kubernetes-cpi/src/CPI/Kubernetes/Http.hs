{-# LANGUAGE InstanceSigs      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}

module CPI.Kubernetes.Http(
    createPod
  , getPod
  , hasPod
  , deletePod
  , createSecret
  , listSecret
  , updateSecret
  , createService
  , deleteService
  , listService
  , createPersistentVolumeClaim
  , getPersistentVolumeClaim
  , hasPersistentVolumeClaim
  , deletePersistentVolumeClaim
) where


import qualified CPI.Base                       as Base
import CPI.Kubernetes.Config

import           Control.Lens
import           Control.Monad.Catch
import           Data.Maybe
import           Data.ByteString
import           Data.Semigroup
import Data.Aeson
import           Control.Monad.Except
import           Control.Monad.Reader
import           Control.Monad.Log
import           Data.Text                      (Text)
import qualified Data.Text                      as Text
import qualified Data.Text.Encoding             as Text.Encoding
import qualified Data.Text.IO                   as Text.IO
import Data.ByteString.Lazy (toStrict)
import qualified Servant.Common.BaseUrl         as Url
import qualified Servant.Common.Req             as Servant
import qualified Kubernetes.Api.ApivApi         as Kube
import qualified Kubernetes.Model.V1.Pod        as Pod
import qualified Kubernetes.Model.V1.PersistentVolumeClaim        as PersistentVolumeClaim
import qualified Kubernetes.Model.V1.Service    as Service
import qualified Kubernetes.Model.V1.ServiceList    as ServiceList
import qualified Kubernetes.Model.V1.Secret     as Secret
import qualified Kubernetes.Model.V1.SecretList     as SecretList
import qualified Kubernetes.Model.V1.DeleteOptions as DeleteOptions
import qualified Kubernetes.Model.V1.ObjectMeta as ObjectMeta
import qualified Kubernetes.Model.Unversioned.Status as Status
import           Network.HTTP.Client
import qualified Network.HTTP.Types.Status as Http
import           Network.HTTP.Client.TLS
import           System.IO
import Data.IORef

type NamespacedF model =
        Text
     -> Manager
     -> Url.BaseUrl
     -> Servant.ClientM model

namespacedF :: (MonadIO m, MonadThrow m, MonadReader Config m, MonadLog Text m) =>
             NamespacedF model
          -> m model
namespacedF f = do
  config <- ask
  result <- let
    baseUrl = apiEndpoint config
    tlsSettings = Base.tlsSettings baseUrl (credentials config)
    kubeNamespace = namespace config
    in do
      manager <- liftIO $ newManager $ (mkManagerSettings tlsSettings Nothing)
                                        {
                                            managerModifyResponse = logResponse
                                          , managerModifyRequest = \req -> do
                                              Text.IO.hPutStrLn stderr (Text.pack (show req))
                                              return req
                                        }
      liftIO $ runExceptT $ f kubeNamespace manager baseUrl
  either throwM return result


logResponse :: Response BodyReader -> IO (Response BodyReader)
logResponse res = do
  let constBodyReader :: [ByteString] -> IO BodyReader
      constBodyReader input = do
        iinput <- newIORef input
        return $ atomicModifyIORef iinput $ \input' ->
              case input' of
                  [] -> ([], empty)
                  x:xs -> (xs, x)
  body <- brConsume $ responseBody res
  response <- showResponse res body
  Text.IO.hPutStrLn stderr response
  reader <- constBodyReader body
  return res {
    responseBody = reader
  }

showResponse :: Response BodyReader -> [ByteString] -> IO Text
showResponse res body =
  return $ Text.unlines
    [
      "Response {"
    , "  responseStatus     = " <> Text.pack (show (responseStatus res))
    , "  responseVersion    = " <> Text.pack (show (responseVersion res))
    , "  responseHeaders    = " <> Text.pack (show (responseHeaders res))
    , "  responseBody       = " <> Text.Encoding.decodeUtf8 (Data.ByteString.concat body)
    , "}"
    ]

namespacedGetter :: (MonadIO m, MonadCatch m, MonadReader Config m, MonadLog Text m) =>
             NamespacedF model
          -> m (Maybe model)
namespacedGetter f = do
  result <- try(namespacedF f)
  return $ case result of
    Right model -> Just model
    Left Servant.FailureResponse {
      Servant.responseStatus = Http.Status {
        Http.statusCode = 404
      },
      Servant.responseContentType = _,
      Servant.responseBody = _
    } -> Nothing
    Left servantError -> throwM servantError

createPod :: (MonadIO m, MonadThrow m, MonadReader Config m, MonadLog Text m) =>
     Pod.Pod
  -> m Pod.Pod
createPod pod = do
  logMessage $ "Creating pod '" <> (Text.Encoding.decodeUtf8.toStrict.encode) pod <> "'"
  namespacedF $ \namespace -> Kube.createNamespacedPod namespace Nothing pod

getPod :: (MonadIO m, MonadCatch m, MonadReader Config m, MonadLog Text m) =>
     Text
  -> m (Maybe Pod.Pod)
getPod name = do
  logMessage $ "Looking up pod '" <> name <> "'"
  namespacedGetter $ \namespace -> Kube.readNamespacedPod namespace name Nothing Nothing Nothing

hasPod :: (MonadIO m, MonadCatch m, MonadReader Config m, MonadLog Text m) =>
     Text
  -> m Bool
hasPod name = do
  result <- getPod name
  return $ isJust result

deletePod :: (MonadIO m, MonadCatch m, MonadReader Config m, MonadLog Text m) =>
    Text
  -> m Pod.Pod
deletePod name = do
  logMessage $ "Deleting pod '" <> name <> "'"
  namespacedF $ \namespace -> Kube.deleteNamespacedPod namespace name Nothing (DeleteOptions.mkDeleteOptions 0)

createSecret :: (MonadIO m, MonadThrow m, MonadReader Config m, MonadLog Text m) =>
     Secret.Secret
  -> m Secret.Secret
createSecret secret = do
  logMessage $ "Creating secret '" <> (Text.Encoding.decodeUtf8.toStrict.encode) secret <> "'"
  namespacedF $ \namespace -> Kube.createNamespacedSecret namespace Nothing secret

listSecret :: (MonadIO m, MonadThrow m, MonadReader Config m, MonadLog Text m) =>
     Text
  -> m SecretList.SecretList
listSecret labelSelector = namespacedF $ \namespace -> Kube.listNamespacedSecret namespace Nothing (Just labelSelector) Nothing Nothing Nothing Nothing

updateSecret :: (MonadIO m, MonadThrow m, MonadReader Config m, MonadLog Text m) =>
       Secret.Secret
    -> m Secret.Secret
updateSecret secret = do
  logMessage $ "Updating secret '" <> (Text.Encoding.decodeUtf8.toStrict.encode) secret <> "'"
  namespacedF $ \namespace -> Kube.replaceNamespacedSecret namespace (secret ^. Secret.metadata._Just.ObjectMeta.name._Just) Nothing secret

createService :: (MonadIO m, MonadThrow m, MonadReader Config m, MonadLog Text m) =>
     Service.Service
  -> m Service.Service
createService service = do
  logMessage $ "Creating service '" <> (Text.Encoding.decodeUtf8.toStrict.encode) service <> "'"
  namespacedF $ \namespace -> Kube.createNamespacedService namespace Nothing service

listService :: (MonadIO m, MonadCatch m, MonadReader Config m, MonadLog Text m) =>
     Text
  -> m ServiceList.ServiceList
listService labelSelector = namespacedF $ \namespace -> Kube.listNamespacedService namespace Nothing (Just labelSelector) Nothing Nothing Nothing Nothing

deleteService :: (MonadIO m, MonadCatch m, MonadReader Config m, MonadLog Text m) =>
     Text
  -> m Status.Status
deleteService name = do
  logMessage $ "Deleting service '" <> name <> "'"
  namespacedF $ \namespace -> Kube.deleteNamespacedService namespace name Nothing

createPersistentVolumeClaim :: (MonadIO m, MonadCatch m, MonadReader Config m, MonadLog Text m) =>
     PersistentVolumeClaim.PersistentVolumeClaim
  -> m PersistentVolumeClaim.PersistentVolumeClaim
createPersistentVolumeClaim claim = do
  logMessage $ "Creating persistent volume claim '" <> (Text.Encoding.decodeUtf8.toStrict.encode) claim <> "'"
  namespacedF $ \namespace -> Kube.createNamespacedPersistentVolumeClaim namespace Nothing claim

getPersistentVolumeClaim :: (MonadIO m, MonadCatch m, MonadReader Config m, MonadLog Text m) =>
     Text
  -> m (Maybe PersistentVolumeClaim.PersistentVolumeClaim)
getPersistentVolumeClaim name = do
  logMessage $ "Looking up persistent volume claim '" <> name <> "'"
  namespacedGetter $ \namespace -> Kube.readNamespacedPersistentVolumeClaim namespace name Nothing Nothing Nothing

hasPersistentVolumeClaim :: (MonadIO m, MonadCatch m, MonadReader Config m, MonadLog Text m) =>
     Text
  -> m Bool
hasPersistentVolumeClaim name = do
  result <- getPersistentVolumeClaim name
  return $ isJust result

deletePersistentVolumeClaim :: (MonadIO m, MonadCatch m, MonadReader Config m, MonadLog Text m) =>
     Text
  -> m Status.Status
deletePersistentVolumeClaim name = do
  logMessage $ "Deleting persistent volume claim '" <> name <> "'"
  namespacedF $ \namespace -> Kube.deleteNamespacedPersistentVolumeClaim namespace name Nothing (DeleteOptions.mkDeleteOptions 0)