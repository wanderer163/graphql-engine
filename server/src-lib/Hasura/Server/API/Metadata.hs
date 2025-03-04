{-# LANGUAGE ViewPatterns #-}

-- | The RQL metadata query ('/v1/metadata')
module Hasura.Server.API.Metadata
  ( RQLMetadata,
    RQLMetadataV1 (..),
    runMetadataQuery,
  )
where

import Control.Lens (_Just)
import Control.Monad.Trans.Control (MonadBaseControl)
import Data.Aeson
import Data.Aeson.Casing
import Data.Aeson.Types qualified as A
import Data.Environment qualified as Env
import Data.Has (Has)
import Data.Text qualified as T
import Data.Text.Extended qualified as T
import GHC.Generics.Extended (constrName)
import Hasura.Base.Error
import Hasura.EncJSON
import Hasura.Logging qualified as L
import Hasura.Metadata.Class
import Hasura.Prelude hiding (first)
import Hasura.RQL.DDL.Action
import Hasura.RQL.DDL.ApiLimit
import Hasura.RQL.DDL.ComputedField
import Hasura.RQL.DDL.CustomTypes
import Hasura.RQL.DDL.DataConnector
import Hasura.RQL.DDL.Endpoint
import Hasura.RQL.DDL.EventTrigger
import Hasura.RQL.DDL.GraphqlSchemaIntrospection
import Hasura.RQL.DDL.InheritedRoles
import Hasura.RQL.DDL.Metadata
import Hasura.RQL.DDL.Network
import Hasura.RQL.DDL.Permission
import Hasura.RQL.DDL.QueryCollection
import Hasura.RQL.DDL.QueryTags
import Hasura.RQL.DDL.Relationship
import Hasura.RQL.DDL.Relationship.Rename
import Hasura.RQL.DDL.RemoteRelationship
import Hasura.RQL.DDL.RemoteSchema
import Hasura.RQL.DDL.ScheduledTrigger
import Hasura.RQL.DDL.Schema
import Hasura.RQL.DDL.Schema.Source
import Hasura.RQL.DDL.SourceKinds
import Hasura.RQL.DDL.Webhook.Transform.Validation
import Hasura.RQL.Types.Action
import Hasura.RQL.Types.Allowlist
import Hasura.RQL.Types.ApiLimit
import Hasura.RQL.Types.Common
import Hasura.RQL.Types.CustomTypes
import Hasura.RQL.Types.Endpoint
import Hasura.RQL.Types.EventTrigger
import Hasura.RQL.Types.Eventing.Backend
import Hasura.RQL.Types.GraphqlSchemaIntrospection
import Hasura.RQL.Types.Metadata (GetCatalogState, SetCatalogState, emptyMetadataDefaults)
import Hasura.RQL.Types.Metadata.Backend
import Hasura.RQL.Types.Network
import Hasura.RQL.Types.Permission
import Hasura.RQL.Types.QueryCollection
import Hasura.RQL.Types.RemoteSchema
import Hasura.RQL.Types.Roles
import Hasura.RQL.Types.Run
import Hasura.RQL.Types.ScheduledTrigger
import Hasura.RQL.Types.SchemaCache
import Hasura.RQL.Types.SchemaCache.Build
import Hasura.RQL.Types.Source
import Hasura.SQL.AnyBackend
import Hasura.SQL.Backend
import Hasura.Server.API.Backend
import Hasura.Server.API.Instances ()
import Hasura.Server.Types
import Hasura.Server.Utils (APIVersion (..))
import Hasura.Session
import Hasura.Tracing qualified as Tracing
import Network.HTTP.Client.Manager qualified as HTTP

data RQLMetadataV1
  = -- Sources
    RMAddSource !(AnyBackend AddSource)
  | RMDropSource DropSource
  | RMRenameSource !RenameSource
  | RMUpdateSource !(AnyBackend UpdateSource)
  | RMListSourceKinds !ListSourceKinds
  | RMGetSourceKindCapabilities !GetSourceKindCapabilities
  | RMGetSourceTables !GetSourceTables
  | RMGetTableInfo !GetTableInfo
  | -- Tables
    RMTrackTable !(AnyBackend TrackTableV2)
  | RMUntrackTable !(AnyBackend UntrackTable)
  | RMSetTableCustomization !(AnyBackend SetTableCustomization)
  | RMSetApolloFederationConfig (AnyBackend SetApolloFederationConfig)
  | RMPgSetTableIsEnum !(AnyBackend SetTableIsEnum)
  | -- Tables permissions
    RMCreateInsertPermission !(AnyBackend (CreatePerm InsPerm))
  | RMCreateSelectPermission !(AnyBackend (CreatePerm SelPerm))
  | RMCreateUpdatePermission !(AnyBackend (CreatePerm UpdPerm))
  | RMCreateDeletePermission !(AnyBackend (CreatePerm DelPerm))
  | RMDropInsertPermission !(AnyBackend DropPerm)
  | RMDropSelectPermission !(AnyBackend DropPerm)
  | RMDropUpdatePermission !(AnyBackend DropPerm)
  | RMDropDeletePermission !(AnyBackend DropPerm)
  | RMSetPermissionComment !(AnyBackend SetPermComment)
  | -- Tables relationships
    RMCreateObjectRelationship !(AnyBackend CreateObjRel)
  | RMCreateArrayRelationship !(AnyBackend CreateArrRel)
  | RMDropRelationship !(AnyBackend DropRel)
  | RMSetRelationshipComment !(AnyBackend SetRelComment)
  | RMRenameRelationship !(AnyBackend RenameRel)
  | -- Tables remote relationships
    RMCreateRemoteRelationship !(AnyBackend CreateFromSourceRelationship)
  | RMUpdateRemoteRelationship !(AnyBackend CreateFromSourceRelationship)
  | RMDeleteRemoteRelationship !(AnyBackend DeleteFromSourceRelationship)
  | -- Functions
    RMTrackFunction !(AnyBackend TrackFunctionV2)
  | RMUntrackFunction !(AnyBackend UnTrackFunction)
  | RMSetFunctionCustomization (AnyBackend SetFunctionCustomization)
  | -- Functions permissions
    RMCreateFunctionPermission !(AnyBackend FunctionPermissionArgument)
  | RMDropFunctionPermission !(AnyBackend FunctionPermissionArgument)
  | -- Computed fields
    RMAddComputedField !(AnyBackend AddComputedField)
  | RMDropComputedField !(AnyBackend DropComputedField)
  | -- Tables event triggers
    RMCreateEventTrigger !(AnyBackend (Unvalidated1 CreateEventTriggerQuery))
  | RMDeleteEventTrigger !(AnyBackend DeleteEventTriggerQuery)
  | RMRedeliverEvent !(AnyBackend RedeliverEventQuery)
  | RMInvokeEventTrigger !(AnyBackend InvokeEventTriggerQuery)
  | RMCleanupEventTriggerLog !TriggerLogCleanupConfig
  | RMResumeEventTriggerCleanup !TriggerLogCleanupToggleConfig
  | RMPauseEventTriggerCleanup !TriggerLogCleanupToggleConfig
  | -- Remote schemas
    RMAddRemoteSchema !AddRemoteSchemaQuery
  | RMUpdateRemoteSchema !AddRemoteSchemaQuery
  | RMRemoveRemoteSchema !RemoteSchemaNameQuery
  | RMReloadRemoteSchema !RemoteSchemaNameQuery
  | RMIntrospectRemoteSchema !RemoteSchemaNameQuery
  | -- Remote schemas permissions
    RMAddRemoteSchemaPermissions !AddRemoteSchemaPermission
  | RMDropRemoteSchemaPermissions !DropRemoteSchemaPermissions
  | -- Remote Schema remote relationships
    RMCreateRemoteSchemaRemoteRelationship CreateRemoteSchemaRemoteRelationship
  | RMUpdateRemoteSchemaRemoteRelationship CreateRemoteSchemaRemoteRelationship
  | RMDeleteRemoteSchemaRemoteRelationship DeleteRemoteSchemaRemoteRelationship
  | -- Scheduled triggers
    RMCreateCronTrigger !(Unvalidated CreateCronTrigger)
  | RMDeleteCronTrigger !ScheduledTriggerName
  | RMCreateScheduledEvent !CreateScheduledEvent
  | RMDeleteScheduledEvent !DeleteScheduledEvent
  | RMGetScheduledEvents !GetScheduledEvents
  | RMGetEventInvocations !GetEventInvocations
  | RMGetCronTriggers
  | -- Actions
    RMCreateAction !(Unvalidated CreateAction)
  | RMDropAction !DropAction
  | RMUpdateAction !(Unvalidated UpdateAction)
  | RMCreateActionPermission !CreateActionPermission
  | RMDropActionPermission !DropActionPermission
  | -- Query collections, allow list related
    RMCreateQueryCollection !CreateCollection
  | RMRenameQueryCollection !RenameCollection
  | RMDropQueryCollection !DropCollection
  | RMAddQueryToCollection !AddQueryToCollection
  | RMDropQueryFromCollection !DropQueryFromCollection
  | RMAddCollectionToAllowlist !AllowlistEntry
  | RMDropCollectionFromAllowlist !DropCollectionFromAllowlist
  | RMUpdateScopeOfCollectionInAllowlist !UpdateScopeOfCollectionInAllowlist
  | -- Rest endpoints
    RMCreateRestEndpoint !CreateEndpoint
  | RMDropRestEndpoint !DropEndpoint
  | -- GraphQL Data Connectors
    RMDCAddAgent !DCAddAgent
  | RMDCDeleteAgent !DCDeleteAgent
  | -- Custom types
    RMSetCustomTypes !CustomTypes
  | -- Api limits
    RMSetApiLimits !ApiLimit
  | RMRemoveApiLimits
  | -- Metrics config
    RMSetMetricsConfig !MetricsConfig
  | RMRemoveMetricsConfig
  | -- Inherited roles
    RMAddInheritedRole !InheritedRole
  | RMDropInheritedRole !DropInheritedRole
  | -- Metadata management
    RMReplaceMetadata !ReplaceMetadata
  | RMExportMetadata !ExportMetadata
  | RMClearMetadata !ClearMetadata
  | RMReloadMetadata !ReloadMetadata
  | RMGetInconsistentMetadata !GetInconsistentMetadata
  | RMDropInconsistentMetadata !DropInconsistentMetadata
  | -- Introspection options
    RMSetGraphqlSchemaIntrospectionOptions !SetGraphqlIntrospectionOptions
  | -- Network
    RMAddHostToTLSAllowlist !AddHostToTLSAllowlist
  | RMDropHostFromTLSAllowlist !DropHostFromTLSAllowlist
  | -- QueryTags
    RMSetQueryTagsConfig !SetQueryTagsConfig
  | -- Debug
    RMDumpInternalState !DumpInternalState
  | RMGetCatalogState !GetCatalogState
  | RMSetCatalogState !SetCatalogState
  | RMTestWebhookTransform !(Unvalidated TestWebhookTransform)
  | -- Bulk metadata queries
    RMBulk [RQLMetadataRequest]
  deriving (Generic)

-- NOTE! If you add a new request type here that is read-only, make sure to
--       update queryModifiesMetadata

instance FromJSON RQLMetadataV1 where
  parseJSON = withObject "RQLMetadataV1" \o -> do
    queryType <- o .: "type"
    let args :: forall a. FromJSON a => A.Parser a
        args = o .: "args"
    case queryType of
      -- backend agnostic
      "rename_source" -> RMRenameSource <$> args
      "add_remote_schema" -> RMAddRemoteSchema <$> args
      "update_remote_schema" -> RMUpdateRemoteSchema <$> args
      "remove_remote_schema" -> RMRemoveRemoteSchema <$> args
      "reload_remote_schema" -> RMReloadRemoteSchema <$> args
      "introspect_remote_schema" -> RMIntrospectRemoteSchema <$> args
      "add_remote_schema_permissions" -> RMAddRemoteSchemaPermissions <$> args
      "drop_remote_schema_permissions" -> RMDropRemoteSchemaPermissions <$> args
      "create_remote_schema_remote_relationship" -> RMCreateRemoteSchemaRemoteRelationship <$> args
      "update_remote_schema_remote_relationship" -> RMUpdateRemoteSchemaRemoteRelationship <$> args
      "delete_remote_schema_remote_relationship" -> RMDeleteRemoteSchemaRemoteRelationship <$> args
      "cleanup_event_trigger_logs" -> RMCleanupEventTriggerLog <$> args
      "resume_event_trigger_cleanups" -> RMResumeEventTriggerCleanup <$> args
      "pause_event_trigger_cleanups" -> RMPauseEventTriggerCleanup <$> args
      "create_cron_trigger" -> RMCreateCronTrigger <$> args
      "delete_cron_trigger" -> RMDeleteCronTrigger <$> args
      "create_scheduled_event" -> RMCreateScheduledEvent <$> args
      "delete_scheduled_event" -> RMDeleteScheduledEvent <$> args
      "get_scheduled_events" -> RMGetScheduledEvents <$> args
      "get_event_invocations" -> RMGetEventInvocations <$> args
      "get_cron_triggers" -> pure RMGetCronTriggers
      "create_action" -> RMCreateAction <$> args
      "drop_action" -> RMDropAction <$> args
      "update_action" -> RMUpdateAction <$> args
      "create_action_permission" -> RMCreateActionPermission <$> args
      "drop_action_permission" -> RMDropActionPermission <$> args
      "create_query_collection" -> RMCreateQueryCollection <$> args
      "rename_query_collection" -> RMRenameQueryCollection <$> args
      "drop_query_collection" -> RMDropQueryCollection <$> args
      "add_query_to_collection" -> RMAddQueryToCollection <$> args
      "drop_query_from_collection" -> RMDropQueryFromCollection <$> args
      "add_collection_to_allowlist" -> RMAddCollectionToAllowlist <$> args
      "drop_collection_from_allowlist" -> RMDropCollectionFromAllowlist <$> args
      "update_scope_of_collection_in_allowlist" -> RMUpdateScopeOfCollectionInAllowlist <$> args
      "create_rest_endpoint" -> RMCreateRestEndpoint <$> args
      "drop_rest_endpoint" -> RMDropRestEndpoint <$> args
      "dc_add_agent" -> RMDCAddAgent <$> args
      "dc_delete_agent" -> RMDCDeleteAgent <$> args
      "list_source_kinds" -> RMListSourceKinds <$> args
      "get_source_kind_capabilities" -> RMGetSourceKindCapabilities <$> args
      "get_source_tables" -> RMGetSourceTables <$> args
      "get_table_info" -> RMGetTableInfo <$> args
      "set_custom_types" -> RMSetCustomTypes <$> args
      "set_api_limits" -> RMSetApiLimits <$> args
      "remove_api_limits" -> pure RMRemoveApiLimits
      "set_metrics_config" -> RMSetMetricsConfig <$> args
      "remove_metrics_config" -> pure RMRemoveMetricsConfig
      "add_inherited_role" -> RMAddInheritedRole <$> args
      "drop_inherited_role" -> RMDropInheritedRole <$> args
      "replace_metadata" -> RMReplaceMetadata <$> args
      "export_metadata" -> RMExportMetadata <$> args
      "clear_metadata" -> RMClearMetadata <$> args
      "reload_metadata" -> RMReloadMetadata <$> args
      "get_inconsistent_metadata" -> RMGetInconsistentMetadata <$> args
      "drop_inconsistent_metadata" -> RMDropInconsistentMetadata <$> args
      "add_host_to_tls_allowlist" -> RMAddHostToTLSAllowlist <$> args
      "drop_host_from_tls_allowlist" -> RMDropHostFromTLSAllowlist <$> args
      "dump_internal_state" -> RMDumpInternalState <$> args
      "get_catalog_state" -> RMGetCatalogState <$> args
      "set_catalog_state" -> RMSetCatalogState <$> args
      "set_graphql_schema_introspection_options" -> RMSetGraphqlSchemaIntrospectionOptions <$> args
      "test_webhook_transform" -> RMTestWebhookTransform <$> args
      "set_query_tags" -> RMSetQueryTagsConfig <$> args
      "bulk" -> RMBulk <$> args
      -- Backend prefixed metadata actions:
      _ -> do
        -- 1) Parse the backend source kind and metadata command:
        (backendSourceKind, cmd) <- parseQueryType queryType
        dispatchAnyBackend @BackendAPI backendSourceKind \(backendSourceKind' :: BackendSourceKind b) -> do
          -- 2) Parse the args field:
          argValue <- args
          -- 2) Attempt to run all the backend specific command parsers against the source kind, cmd, and arg:
          -- NOTE: If parsers succeed then this will pick out the first successful one.
          command <- choice <$> sequenceA [p backendSourceKind' cmd argValue | p <- metadataV1CommandParsers @b]
          onNothing command $
            fail $
              "unknown metadata command \""
                <> T.unpack cmd
                <> "\" for backend "
                <> T.unpack (T.toTxt backendSourceKind')

-- | Parse the Metadata API action type returning a tuple of the
-- 'BackendSourceKind' and the action suffix.
--
-- For example: @"pg_add_source"@ parses as @(PostgresVanillaValue, "add_source")@
parseQueryType :: MonadFail m => Text -> m (AnyBackend BackendSourceKind, Text)
parseQueryType queryType =
  let (prefix, T.drop 1 -> cmd) = T.breakOn "_" queryType
   in (,cmd)
        <$> backendSourceKindFromText prefix
        `onNothing` fail
          ( "unknown metadata command \""
              <> T.unpack queryType
              <> "\"; \""
              <> T.unpack prefix
              <> "\" was not recognized as a valid backend name"
          )

data RQLMetadataV2
  = RMV2ReplaceMetadata !ReplaceMetadataV2
  | RMV2ExportMetadata !ExportMetadata
  deriving (Generic)

instance FromJSON RQLMetadataV2 where
  parseJSON =
    genericParseJSON $
      defaultOptions
        { constructorTagModifier = snakeCase . drop 4,
          sumEncoding = TaggedObject "type" "args"
        }

data RQLMetadataRequest
  = RMV1 !RQLMetadataV1
  | RMV2 !RQLMetadataV2

instance FromJSON RQLMetadataRequest where
  parseJSON = withObject "RQLMetadataRequest" $ \o -> do
    version <- o .:? "version" .!= VIVersion1
    let val = Object o
    case version of
      VIVersion1 -> RMV1 <$> parseJSON val
      VIVersion2 -> RMV2 <$> parseJSON val

-- | The payload for the @/v1/metadata@ endpoint. See:
--
-- https://hasura.io/docs/latest/graphql/core/api-reference/metadata-api/index/
data RQLMetadata = RQLMetadata
  { _rqlMetadataResourceVersion :: !(Maybe MetadataResourceVersion),
    _rqlMetadata :: !RQLMetadataRequest
  }

instance FromJSON RQLMetadata where
  parseJSON = withObject "RQLMetadata" $ \o -> do
    _rqlMetadataResourceVersion <- o .:? "resource_version"
    _rqlMetadata <- parseJSON $ Object o
    pure RQLMetadata {..}

runMetadataQuery ::
  ( MonadIO m,
    MonadBaseControl IO m,
    Tracing.MonadTrace m,
    MonadMetadataStorage m,
    MonadResolveSource m,
    MonadEventLogCleanup m
  ) =>
  Env.Environment ->
  L.Logger L.Hasura ->
  InstanceId ->
  UserInfo ->
  HTTP.Manager ->
  ServerConfigCtx ->
  RebuildableSchemaCache ->
  RQLMetadata ->
  m (EncJSON, RebuildableSchemaCache)
runMetadataQuery env logger instanceId userInfo httpManager serverConfigCtx schemaCache RQLMetadata {..} = do
  (metadata, currentResourceVersion) <- Tracing.trace "fetchMetadata" fetchMetadata
  let exportsMetadata = \case
        RMV1 (RMExportMetadata _) -> True
        RMV2 (RMV2ExportMetadata _) -> True
        _ -> False
      metadataDefaults =
        if (exportsMetadata _rqlMetadata)
          then emptyMetadataDefaults
          else _sccMetadataDefaults serverConfigCtx
  ((r, modMetadata), modSchemaCache, cacheInvalidations) <-
    runMetadataQueryM env currentResourceVersion _rqlMetadata
      & flip runReaderT logger
      & runMetadataT metadata metadataDefaults
      & runCacheRWT schemaCache
      & peelRun (RunCtx userInfo httpManager serverConfigCtx)
      & runExceptT
      & liftEitherM
  -- set modified metadata in storage
  if queryModifiesMetadata _rqlMetadata
    then case (_sccMaintenanceMode serverConfigCtx, _sccReadOnlyMode serverConfigCtx) of
      (MaintenanceModeDisabled, ReadOnlyModeDisabled) -> do
        -- set modified metadata in storage
        newResourceVersion <-
          Tracing.trace "setMetadata" $
            setMetadata (fromMaybe currentResourceVersion _rqlMetadataResourceVersion) modMetadata

        -- notify schema cache sync
        Tracing.trace "notifySchemaCacheSync" $
          notifySchemaCacheSync newResourceVersion instanceId cacheInvalidations
        (_, modSchemaCache', _) <-
          Tracing.trace "setMetadataResourceVersionInSchemaCache" $
            setMetadataResourceVersionInSchemaCache newResourceVersion
              & runCacheRWT modSchemaCache
              & peelRun (RunCtx userInfo httpManager serverConfigCtx)
              & runExceptT
              & liftEitherM

        pure (r, modSchemaCache')
      (MaintenanceModeEnabled (), ReadOnlyModeDisabled) ->
        throw500 "metadata cannot be modified in maintenance mode"
      (MaintenanceModeDisabled, ReadOnlyModeEnabled) ->
        throw400 NotSupported "metadata cannot be modified in read-only mode"
      (MaintenanceModeEnabled (), ReadOnlyModeEnabled) ->
        throw500 "metadata cannot be modified in maintenance mode"
    else pure (r, modSchemaCache)

queryModifiesMetadata :: RQLMetadataRequest -> Bool
queryModifiesMetadata = \case
  RMV1 q ->
    case q of
      RMRedeliverEvent _ -> False
      RMInvokeEventTrigger _ -> False
      RMGetInconsistentMetadata _ -> False
      RMIntrospectRemoteSchema _ -> False
      RMDumpInternalState _ -> False
      RMSetCatalogState _ -> False
      RMGetCatalogState _ -> False
      RMExportMetadata _ -> False
      RMGetEventInvocations _ -> False
      RMGetCronTriggers -> False
      RMGetScheduledEvents _ -> False
      RMCreateScheduledEvent _ -> False
      RMDeleteScheduledEvent _ -> False
      RMTestWebhookTransform _ -> False
      RMGetSourceKindCapabilities _ -> False
      RMListSourceKinds _ -> False
      RMGetSourceTables _ -> False
      RMGetTableInfo _ -> False
      RMBulk qs -> any queryModifiesMetadata qs
      -- We used to assume that the fallthrough was True,
      -- but it is better to be explicit here to warn when new constructors are added.
      RMAddSource _ -> True
      RMDropSource _ -> True
      RMRenameSource _ -> True
      RMUpdateSource _ -> True
      RMTrackTable _ -> True
      RMUntrackTable _ -> True
      RMSetTableCustomization _ -> True
      RMSetApolloFederationConfig _ -> True
      RMPgSetTableIsEnum _ -> True
      RMCreateInsertPermission _ -> True
      RMCreateSelectPermission _ -> True
      RMCreateUpdatePermission _ -> True
      RMCreateDeletePermission _ -> True
      RMDropInsertPermission _ -> True
      RMDropSelectPermission _ -> True
      RMDropUpdatePermission _ -> True
      RMDropDeletePermission _ -> True
      RMSetPermissionComment _ -> True
      RMCreateObjectRelationship _ -> True
      RMCreateArrayRelationship _ -> True
      RMDropRelationship _ -> True
      RMSetRelationshipComment _ -> True
      RMRenameRelationship _ -> True
      RMCreateRemoteRelationship _ -> True
      RMUpdateRemoteRelationship _ -> True
      RMDeleteRemoteRelationship _ -> True
      RMTrackFunction _ -> True
      RMUntrackFunction _ -> True
      RMSetFunctionCustomization _ -> True
      RMCreateFunctionPermission _ -> True
      RMDropFunctionPermission _ -> True
      RMAddComputedField _ -> True
      RMDropComputedField _ -> True
      RMCreateEventTrigger _ -> True
      RMDeleteEventTrigger _ -> True
      RMCleanupEventTriggerLog _ -> True
      RMResumeEventTriggerCleanup _ -> True
      RMPauseEventTriggerCleanup _ -> True
      RMAddRemoteSchema _ -> True
      RMUpdateRemoteSchema _ -> True
      RMRemoveRemoteSchema _ -> True
      RMReloadRemoteSchema _ -> True
      RMAddRemoteSchemaPermissions _ -> True
      RMDropRemoteSchemaPermissions _ -> True
      RMCreateRemoteSchemaRemoteRelationship _ -> True
      RMUpdateRemoteSchemaRemoteRelationship _ -> True
      RMDeleteRemoteSchemaRemoteRelationship _ -> True
      RMCreateCronTrigger _ -> True
      RMDeleteCronTrigger _ -> True
      RMCreateAction _ -> True
      RMDropAction _ -> True
      RMUpdateAction _ -> True
      RMCreateActionPermission _ -> True
      RMDropActionPermission _ -> True
      RMCreateQueryCollection _ -> True
      RMRenameQueryCollection _ -> True
      RMDropQueryCollection _ -> True
      RMAddQueryToCollection _ -> True
      RMDropQueryFromCollection _ -> True
      RMAddCollectionToAllowlist _ -> True
      RMDropCollectionFromAllowlist _ -> True
      RMUpdateScopeOfCollectionInAllowlist _ -> True
      RMCreateRestEndpoint _ -> True
      RMDropRestEndpoint _ -> True
      RMDCAddAgent _ -> True
      RMDCDeleteAgent _ -> True
      RMSetCustomTypes _ -> True
      RMSetApiLimits _ -> True
      RMRemoveApiLimits -> True
      RMSetMetricsConfig _ -> True
      RMRemoveMetricsConfig -> True
      RMAddInheritedRole _ -> True
      RMDropInheritedRole _ -> True
      RMReplaceMetadata _ -> True
      RMClearMetadata _ -> True
      RMReloadMetadata _ -> True
      RMDropInconsistentMetadata _ -> True
      RMSetGraphqlSchemaIntrospectionOptions _ -> True
      RMAddHostToTLSAllowlist _ -> True
      RMDropHostFromTLSAllowlist _ -> True
      RMSetQueryTagsConfig _ -> True
  RMV2 q ->
    case q of
      RMV2ExportMetadata _ -> False
      _ -> True

runMetadataQueryM ::
  ( MonadIO m,
    MonadBaseControl IO m,
    CacheRWM m,
    Tracing.MonadTrace m,
    UserInfoM m,
    HTTP.HasHttpManagerM m,
    MetadataM m,
    MonadMetadataStorageQueryAPI m,
    HasServerConfigCtx m,
    MonadReader r m,
    Has (L.Logger L.Hasura) r,
    MonadEventLogCleanup m
  ) =>
  Env.Environment ->
  MetadataResourceVersion ->
  RQLMetadataRequest ->
  m EncJSON
runMetadataQueryM env currentResourceVersion =
  withPathK "args" . \case
    -- NOTE: This is a good place to install tracing, since it's involved in
    -- the recursive case via "bulk":
    RMV1 q ->
      Tracing.trace ("v1 " <> T.pack (constrName q)) $
        runMetadataQueryV1M env currentResourceVersion q
    RMV2 q ->
      Tracing.trace ("v2 " <> T.pack (constrName q)) $
        runMetadataQueryV2M currentResourceVersion q

runMetadataQueryV1M ::
  forall m r.
  ( MonadIO m,
    MonadBaseControl IO m,
    CacheRWM m,
    Tracing.MonadTrace m,
    UserInfoM m,
    HTTP.HasHttpManagerM m,
    MetadataM m,
    MonadMetadataStorageQueryAPI m,
    HasServerConfigCtx m,
    MonadReader r m,
    Has (L.Logger L.Hasura) r,
    MonadEventLogCleanup m
  ) =>
  Env.Environment ->
  MetadataResourceVersion ->
  RQLMetadataV1 ->
  m EncJSON
runMetadataQueryV1M env currentResourceVersion = \case
  RMAddSource q -> dispatchMetadata runAddSource q
  RMDropSource q -> runDropSource q
  RMRenameSource q -> runRenameSource q
  RMUpdateSource q -> dispatchMetadata runUpdateSource q
  RMListSourceKinds q -> runListSourceKinds q
  RMGetSourceKindCapabilities q -> runGetSourceKindCapabilities q
  RMGetSourceTables q -> runGetSourceTables q
  RMGetTableInfo q -> runGetTableInfo q
  RMTrackTable q -> dispatchMetadata runTrackTableV2Q q
  RMUntrackTable q -> dispatchMetadataAndEventTrigger runUntrackTableQ q
  RMSetFunctionCustomization q -> dispatchMetadata runSetFunctionCustomization q
  RMSetTableCustomization q -> dispatchMetadata runSetTableCustomization q
  RMSetApolloFederationConfig q -> dispatchMetadata runSetApolloFederationConfig q
  RMPgSetTableIsEnum q -> dispatchMetadata runSetExistingTableIsEnumQ q
  RMCreateInsertPermission q -> dispatchMetadata runCreatePerm q
  RMCreateSelectPermission q -> dispatchMetadata runCreatePerm q
  RMCreateUpdatePermission q -> dispatchMetadata runCreatePerm q
  RMCreateDeletePermission q -> dispatchMetadata runCreatePerm q
  RMDropInsertPermission q -> dispatchMetadata (runDropPerm PTInsert) q
  RMDropSelectPermission q -> dispatchMetadata (runDropPerm PTSelect) q
  RMDropUpdatePermission q -> dispatchMetadata (runDropPerm PTUpdate) q
  RMDropDeletePermission q -> dispatchMetadata (runDropPerm PTDelete) q
  RMSetPermissionComment q -> dispatchMetadata runSetPermComment q
  RMCreateObjectRelationship q -> dispatchMetadata (runCreateRelationship ObjRel . unCreateObjRel) q
  RMCreateArrayRelationship q -> dispatchMetadata (runCreateRelationship ArrRel . unCreateArrRel) q
  RMDropRelationship q -> dispatchMetadata runDropRel q
  RMSetRelationshipComment q -> dispatchMetadata runSetRelComment q
  RMRenameRelationship q -> dispatchMetadata runRenameRel q
  RMCreateRemoteRelationship q -> dispatchMetadata runCreateRemoteRelationship q
  RMUpdateRemoteRelationship q -> dispatchMetadata runUpdateRemoteRelationship q
  RMDeleteRemoteRelationship q -> dispatchMetadata runDeleteRemoteRelationship q
  RMTrackFunction q -> dispatchMetadata runTrackFunctionV2 q
  RMUntrackFunction q -> dispatchMetadata runUntrackFunc q
  RMCreateFunctionPermission q -> dispatchMetadata runCreateFunctionPermission q
  RMDropFunctionPermission q -> dispatchMetadata runDropFunctionPermission q
  RMAddComputedField q -> dispatchMetadata runAddComputedField q
  RMDropComputedField q -> dispatchMetadata runDropComputedField q
  RMCreateEventTrigger q ->
    dispatchMetadataAndEventTrigger
      ( validateTransforms
          (unUnvalidate1 . cetqRequestTransform . _Just)
          (runCreateEventTriggerQuery . _unUnvalidate1)
      )
      q
  RMDeleteEventTrigger q -> dispatchMetadataAndEventTrigger runDeleteEventTriggerQuery q
  RMRedeliverEvent q -> dispatchEventTrigger runRedeliverEvent q
  RMInvokeEventTrigger q -> dispatchEventTrigger runInvokeEventTrigger q
  RMCleanupEventTriggerLog q -> runCleanupEventTriggerLog q
  RMResumeEventTriggerCleanup q -> runEventTriggerResumeCleanup q
  RMPauseEventTriggerCleanup q -> runEventTriggerPauseCleanup q
  RMAddRemoteSchema q -> runAddRemoteSchema env q
  RMUpdateRemoteSchema q -> runUpdateRemoteSchema env q
  RMRemoveRemoteSchema q -> runRemoveRemoteSchema q
  RMReloadRemoteSchema q -> runReloadRemoteSchema q
  RMIntrospectRemoteSchema q -> runIntrospectRemoteSchema q
  RMAddRemoteSchemaPermissions q -> runAddRemoteSchemaPermissions q
  RMDropRemoteSchemaPermissions q -> runDropRemoteSchemaPermissions q
  RMCreateRemoteSchemaRemoteRelationship q -> runCreateRemoteSchemaRemoteRelationship q
  RMUpdateRemoteSchemaRemoteRelationship q -> runUpdateRemoteSchemaRemoteRelationship q
  RMDeleteRemoteSchemaRemoteRelationship q -> runDeleteRemoteSchemaRemoteRelationship q
  RMCreateCronTrigger q ->
    validateTransforms
      (unUnvalidate . cctRequestTransform . _Just)
      (runCreateCronTrigger . _unUnvalidate)
      q
  RMDeleteCronTrigger q -> runDeleteCronTrigger q
  RMCreateScheduledEvent q -> runCreateScheduledEvent q
  RMDeleteScheduledEvent q -> runDeleteScheduledEvent q
  RMGetScheduledEvents q -> runGetScheduledEvents q
  RMGetEventInvocations q -> runGetEventInvocations q
  RMGetCronTriggers -> runGetCronTriggers
  RMCreateAction q ->
    validateTransforms
      (unUnvalidate . caDefinition . adRequestTransform . _Just)
      (runCreateAction . _unUnvalidate)
      q
  RMDropAction q -> runDropAction q
  RMUpdateAction q ->
    validateTransforms
      (unUnvalidate . uaDefinition . adRequestTransform . _Just)
      (runUpdateAction . _unUnvalidate)
      q
  RMCreateActionPermission q -> runCreateActionPermission q
  RMDropActionPermission q -> runDropActionPermission q
  RMCreateQueryCollection q -> runCreateCollection q
  RMRenameQueryCollection q -> runRenameCollection q
  RMDropQueryCollection q -> runDropCollection q
  RMAddQueryToCollection q -> runAddQueryToCollection q
  RMDropQueryFromCollection q -> runDropQueryFromCollection q
  RMAddCollectionToAllowlist q -> runAddCollectionToAllowlist q
  RMDropCollectionFromAllowlist q -> runDropCollectionFromAllowlist q
  RMUpdateScopeOfCollectionInAllowlist q -> runUpdateScopeOfCollectionInAllowlist q
  RMCreateRestEndpoint q -> runCreateEndpoint q
  RMDropRestEndpoint q -> runDropEndpoint q
  RMDCAddAgent q -> runAddDataConnectorAgent q
  RMDCDeleteAgent q -> runDeleteDataConnectorAgent q
  RMSetCustomTypes q -> runSetCustomTypes q
  RMSetApiLimits q -> runSetApiLimits q
  RMRemoveApiLimits -> runRemoveApiLimits
  RMSetMetricsConfig q -> runSetMetricsConfig q
  RMRemoveMetricsConfig -> runRemoveMetricsConfig
  RMAddInheritedRole q -> runAddInheritedRole q
  RMDropInheritedRole q -> runDropInheritedRole q
  RMReplaceMetadata q -> runReplaceMetadata q
  RMExportMetadata q -> runExportMetadata q
  RMClearMetadata q -> runClearMetadata q
  RMReloadMetadata q -> runReloadMetadata q
  RMGetInconsistentMetadata q -> runGetInconsistentMetadata q
  RMDropInconsistentMetadata q -> runDropInconsistentMetadata q
  RMSetGraphqlSchemaIntrospectionOptions q -> runSetGraphqlSchemaIntrospectionOptions q
  RMAddHostToTLSAllowlist q -> runAddHostToTLSAllowlist q
  RMDropHostFromTLSAllowlist q -> runDropHostFromTLSAllowlist q
  RMDumpInternalState q -> runDumpInternalState q
  RMGetCatalogState q -> runGetCatalogState q
  RMSetCatalogState q -> runSetCatalogState q
  RMTestWebhookTransform q ->
    validateTransforms
      (unUnvalidate . twtTransformer)
      (runTestWebhookTransform . _unUnvalidate)
      q
  RMSetQueryTagsConfig q -> runSetQueryTagsConfig q
  RMBulk q -> encJFromList <$> indexedMapM (runMetadataQueryM env currentResourceVersion) q
  where
    dispatchMetadata ::
      (forall b. BackendMetadata b => i b -> a) ->
      AnyBackend i ->
      a
    dispatchMetadata f x = dispatchAnyBackend @BackendMetadata x f

    dispatchEventTrigger :: (forall b. BackendEventTrigger b => i b -> a) -> AnyBackend i -> a
    dispatchEventTrigger f x = dispatchAnyBackend @BackendEventTrigger x f

    dispatchMetadataAndEventTrigger ::
      (forall b. (BackendMetadata b, BackendEventTrigger b) => i b -> a) ->
      AnyBackend i ->
      a
    dispatchMetadataAndEventTrigger f x = dispatchAnyBackendWithTwoConstraints @BackendMetadata @BackendEventTrigger x f

runMetadataQueryV2M ::
  ( MonadIO m,
    CacheRWM m,
    MonadBaseControl IO m,
    MetadataM m,
    MonadMetadataStorageQueryAPI m,
    MonadReader r m,
    Has (L.Logger L.Hasura) r,
    MonadEventLogCleanup m
  ) =>
  MetadataResourceVersion ->
  RQLMetadataV2 ->
  m EncJSON
runMetadataQueryV2M currentResourceVersion = \case
  RMV2ReplaceMetadata q -> runReplaceMetadataV2 q
  RMV2ExportMetadata q -> runExportMetadataV2 currentResourceVersion q
