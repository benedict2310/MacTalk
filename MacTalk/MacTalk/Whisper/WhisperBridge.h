//
//  WhisperBridge.h
//  MacTalk
//
//  Objective-C bridging header for whisper.cpp C API
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque pointer to whisper context
typedef void* WTWhisperContextRef;

/// Initialize whisper context from model file
/// @param model_path Path to the GGUF/GGML model file
/// @return Opaque context reference, or NULL on failure
WTWhisperContextRef _Nullable wt_whisper_init(const char * _Nonnull model_path);

/// Free whisper context and resources
/// @param ctx Context to free
void wt_whisper_free(WTWhisperContextRef _Nullable ctx);

/// Transcribe audio samples
/// @param ctx Whisper context
/// @param samples Float array of 16kHz mono audio samples
/// @param numSamples Number of samples in the array
/// @param lang Language code (e.g., "en", "es") or NULL for auto-detect
/// @param translate Whether to translate to English
/// @param noContext Whether to ignore previous context
/// @return Malloc'd UTF-8 string with transcript (caller must free), or NULL on error
char * _Nullable wt_whisper_transcribe(
    WTWhisperContextRef _Nonnull ctx,
    const float * _Nonnull samples,
    int numSamples,
    const char * _Nullable lang,
    bool translate,
    bool noContext
);

#ifdef __cplusplus
}
#endif
