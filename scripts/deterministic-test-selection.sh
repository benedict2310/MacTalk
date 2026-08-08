# Shared deterministic XCTest selection. Keep this list explicit: adding a class
# here is a reviewable declaration that it has no AppKit/window, TCC,
# hardware, provider/model, or real-network dependency.
DETERMINISTIC_TEST_CLASSES=(
  MacTalkTests/AppAudioSourceCoordinatorTests
  MacTalkTests/AppSettingsTests
  MacTalkTests/AudioCompositionTests
  MacTalkTests/AudioLevelMonitorTests
  MacTalkTests/AudioMixerTests
  MacTalkTests/ConcurrencyStressTests
  MacTalkTests/DeterministicHarnessTests
  MacTalkTests/EngineLifecycleCoordinatorTests
  MacTalkTests/ModelDownloadCoordinatorTests
  MacTalkTests/WhisperModelDownloadClientTests
  MacTalkTests/ModelCatalogTests
  MacTalkTests/ModelIntegrityTests
  MacTalkTests/ModelProvenanceTests
  MacTalkTests/ModelSecurityTests
  MacTalkTests/BoundedModelDownloadTransportTests
  MacTalkTests/ParakeetDownloadTransportTests
  MacTalkTests/ParakeetBootstrapTests
  MacTalkTests/ParakeetLegacyCompiledCleanerTests
  MacTalkTests/ParakeetSourceAvailabilityTests
  MacTalkTests/EngineSelectionLoaderTests
  MacTalkTests/VerifiedArtifactReaderTests
  MacTalkTests/VerifiedCoreMLByteAssetTests
  MacTalkTests/ParakeetStoreFileLockTests
  MacTalkTests/ParakeetCompiledWeightReuserTests
  MacTalkTests/ParakeetSourceArtifactMaterializerTests
  MacTalkTests/ParakeetSourceSnapshotTests
  MacTalkTests/ParakeetSourcePreparerTests
  MacTalkTests/VerifiedParakeetModelLoaderTests
  MacTalkTests/NotificationManagerTests
  MacTalkTests/OutputCoordinatorTests
  MacTalkTests/PermissionFlowCoordinatorTests
  MacTalkTests/PrivacyLoggingTests
  MacTalkTests/RecordingSessionCoordinatorTests
  MacTalkTests/StatusBarControllerTests
  MacTalkTests/ShortcutCoordinatorTests
  MacTalkTests/TranscriptionControllerTests
)

# Complete deterministic subset supported by the hosted macOS 15 TSan runtime.
# Run 31272883974 established that ParakeetStoreFileLockTests subprocess probes
# terminate with status 15, CoreML rejects the version-10 fixture used by
# VerifiedCoreMLByteAssetTests, and VerifiedParakeetModelLoaderTests stalls.
# Keep every other deterministic class here; ordinary macOS 26 lanes continue
# to run the broader selection above.
TSAN_SUPPORTED_TEST_CLASSES=(
  MacTalkTests/AppAudioSourceCoordinatorTests
  MacTalkTests/AppSettingsTests
  MacTalkTests/AudioCompositionTests
  MacTalkTests/AudioLevelMonitorTests
  MacTalkTests/AudioMixerTests
  MacTalkTests/ConcurrencyStressTests
  MacTalkTests/DeterministicHarnessTests
  MacTalkTests/EngineLifecycleCoordinatorTests
  MacTalkTests/ModelDownloadCoordinatorTests
  MacTalkTests/WhisperModelDownloadClientTests
  MacTalkTests/ModelCatalogTests
  MacTalkTests/ModelIntegrityTests
  MacTalkTests/ModelProvenanceTests
  MacTalkTests/ModelSecurityTests
  MacTalkTests/BoundedModelDownloadTransportTests
  MacTalkTests/ParakeetDownloadTransportTests
  MacTalkTests/ParakeetBootstrapTests
  MacTalkTests/ParakeetLegacyCompiledCleanerTests
  MacTalkTests/ParakeetSourceAvailabilityTests
  MacTalkTests/EngineSelectionLoaderTests
  MacTalkTests/VerifiedArtifactReaderTests
  MacTalkTests/ParakeetCompiledWeightReuserTests
  MacTalkTests/ParakeetSourceArtifactMaterializerTests
  MacTalkTests/ParakeetSourceSnapshotTests
  MacTalkTests/ParakeetSourcePreparerTests
  MacTalkTests/NotificationManagerTests
  MacTalkTests/OutputCoordinatorTests
  MacTalkTests/PermissionFlowCoordinatorTests
  MacTalkTests/PrivacyLoggingTests
  MacTalkTests/RecordingSessionCoordinatorTests
  MacTalkTests/StatusBarControllerTests
  MacTalkTests/ShortcutCoordinatorTests
  MacTalkTests/TranscriptionControllerTests
)

append_deterministic_test_selection() {
  local class_name
  for class_name in "${DETERMINISTIC_TEST_CLASSES[@]}"; do
    printf '%s\n' "-only-testing:$class_name"
  done
}

append_tsan_supported_test_selection() {
  local class_name
  for class_name in "${TSAN_SUPPORTED_TEST_CLASSES[@]}"; do
    printf '%s\n' "-only-testing:$class_name"
  done
}
