#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# No real account is used. Auth tests use a temporary loopback listener;
# streaming-audio tests use a muted audio engine. No tests read Keychain.
test_build=".build.noindex/tests"
mkdir -p "$test_build"
swift_flags=(-swift-version 6 -parse-as-library -O)

run_test() {
  local name="$1"
  shift
  swiftc "${swift_flags[@]}" "$@" "Tests/${name}.swift" -o "$test_build/$name"
  "$test_build/$name"
}

run_test ChatGPTAuthTests ChatGPTAuth.swift
run_test ChatGPTClientTests ChatGPTAuth.swift ChatGPTClient.swift
run_test CredentialIsolationTests ChatGPTAuth.swift ChatGPTClient.swift ElevenLabsVoice.swift PCMStreamingAudio.swift
run_test ElevenLabsVoiceRequestTests ElevenLabsVoice.swift PCMStreamingAudio.swift
run_test PCMStreamingAudioTests ElevenLabsVoice.swift PCMStreamingAudio.swift
run_test CapriPersonaTests CapriPersona.swift
run_test CapriReplyQualityTests CapriReplyQuality.swift
run_test IdleAnimationTests IdleAnimationDirector.swift
run_test RightCommandTests SummonShortcut.swift
run_test WindowInteractionTests WindowInteraction.swift
