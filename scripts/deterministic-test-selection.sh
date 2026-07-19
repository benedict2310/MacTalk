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
  MacTalkTests/VerifiedArtifactReaderTests
  MacTalkTests/VerifiedCoreMLByteAssetTests
  MacTalkTests/ParakeetStoreFileLockTests
  MacTalkTests/ParakeetSourceSnapshotTests
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

append_deterministic_test_selection() {
  local class_name
  for class_name in "${DETERMINISTIC_TEST_CLASSES[@]}"; do
    printf '%s\n' "-only-testing:$class_name"
  done
}
