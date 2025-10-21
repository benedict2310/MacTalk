//
//  WhisperBridge.mm
//  MacTalk
//
//  Objective-C++ implementation wrapping whisper.cpp
//

#import "WhisperBridge.h"

#import <Accelerate/Accelerate.h>
#include <algorithm>
#include <string>
#include <vector>

// Include whisper.cpp headers
// NOTE: These paths assume whisper.cpp is added to the project
// Adjust include paths in Xcode build settings if needed
#include "whisper.h"
#include "ggml.h"

WTWhisperContextRef wt_whisper_init(const char * model_path) {
    if (!model_path) {
        NSLog(@"[WhisperBridge] NULL model path provided");
        return nullptr;
    }

    // Set up context parameters for Metal/GPU acceleration
    struct whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = true;        // Enable Metal backend
    cparams.gpu_device = 0;        // Use default GPU

    NSLog(@"[WhisperBridge] Initializing whisper context from: %s", model_path);

    struct whisper_context* ctx = whisper_init_from_file_with_params(model_path, cparams);

    if (!ctx) {
        NSLog(@"[WhisperBridge] Failed to initialize whisper context");
        return nullptr;
    }

    NSLog(@"[WhisperBridge] Whisper context initialized successfully");
    return (WTWhisperContextRef)ctx;
}

void wt_whisper_free(WTWhisperContextRef ctx) {
    if (ctx) {
        NSLog(@"[WhisperBridge] Freeing whisper context");
        whisper_free((struct whisper_context*)ctx);
    }
}

char * wt_whisper_transcribe(
    WTWhisperContextRef ctx,
    const float *samples,
    int numSamples,
    const char *lang,
    bool translate,
    bool noContext
) {
    if (!ctx || !samples || numSamples <= 0) {
        NSLog(@"[WhisperBridge] Invalid parameters: ctx=%p samples=%p numSamples=%d",
              ctx, samples, numSamples);
        return nullptr;
    }

    struct whisper_context* whisper_ctx = (struct whisper_context*)ctx;

    // Set up transcription parameters
    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);

    // Optimization settings
    params.n_threads = std::max(4, (int)[[NSProcessInfo processInfo] activeProcessorCount] - 2);
    params.n_max_text_ctx = 16384;

    // Disable verbose output
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;

    // Transcription options
    params.single_segment = false;
    params.translate = translate;
    params.no_context = noContext;

    // Language setting
    if (lang && strlen(lang) > 0) {
        params.language = lang;
    } else {
        params.language = "auto";  // Auto-detect
    }

    // Speed up processing
    params.speed_up = true;

    // Audio splitting
    params.audio_ctx = 0;  // Use default

    NSLog(@"[WhisperBridge] Starting transcription of %d samples (%.2f seconds)",
          numSamples, (float)numSamples / 16000.0f);

    // Run transcription
    int result = whisper_full(whisper_ctx, params, samples, numSamples);

    if (result != 0) {
        NSLog(@"[WhisperBridge] Transcription failed with code: %d", result);
        return nullptr;
    }

    // Collect transcript segments
    int n_segments = whisper_full_n_segments(whisper_ctx);
    NSLog(@"[WhisperBridge] Transcription complete: %d segments", n_segments);

    std::string transcript;
    transcript.reserve(1024);

    for (int i = 0; i < n_segments; ++i) {
        const char* segment_text = whisper_full_get_segment_text(whisper_ctx, i);
        if (segment_text) {
            transcript += segment_text;
            if (i != n_segments - 1) {
                transcript += " ";
            }
        }
    }

    // Allocate and return C string (caller must free)
    char* result_str = (char*)malloc(transcript.size() + 1);
    if (!result_str) {
        NSLog(@"[WhisperBridge] Failed to allocate result string");
        return nullptr;
    }

    memcpy(result_str, transcript.c_str(), transcript.size() + 1);

    NSLog(@"[WhisperBridge] Returning transcript: %s",
          transcript.substr(0, 50).c_str());

    return result_str;
}
