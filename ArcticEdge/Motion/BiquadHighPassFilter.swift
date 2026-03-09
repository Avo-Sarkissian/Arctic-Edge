// BiquadHighPassFilter.swift
// ArcticEdge
//
// vDSP.Biquad wrapper implementing a second-order high-pass IIR filter
// using Audio EQ Cookbook coefficient formulas.
//
// NOT Sendable: this type is stateful (the vDSP filter holds internal delay state).
// Safe to use only from within the actor that exclusively owns an instance.
// The nonisolated(unsafe) annotation on the stored property opts out of the project-wide
// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor setting; the owning actor provides isolation.

import Accelerate

// kFilterCutoffHz is a starting hypothesis calibrated from biomechanical requirements:
// preserve carving vibrations above 2Hz, reject posture drift below 0.5Hz.
// The geometric mean of those thresholds (approximately 1.0Hz) is the single cutoff
// for this second-order biquad. Calibrate against real ski data before treating as settled.
public nonisolated let kFilterCutoffHz: Double = 1.0

final class BiquadHighPassFilter {
    // nonisolated(unsafe) exempts this property from SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
    // Thread safety is guaranteed by the MotionManager actor that exclusively owns this instance.
    nonisolated(unsafe) private var filter: vDSP.Biquad<Double>

    // cutoffHz: filter cutoff frequency in Hz
    // sampleRate: samples per second (100.0 for 100Hz)
    // Q: resonance / quality factor (0.707 for Butterworth maximally flat response)
    nonisolated init(cutoffHz: Double = kFilterCutoffHz, sampleRate: Double, Q: Double = 0.707) {
        let omega = 2.0 * .pi * cutoffHz / sampleRate
        let alpha = sin(omega) / (2.0 * Q)
        let cosOmega = cos(omega)

        // Audio EQ Cookbook second-order HPF coefficients:
        let b0 = (1.0 + cosOmega) / 2.0
        let b1 = -(1.0 + cosOmega)
        let b2 = (1.0 + cosOmega) / 2.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosOmega
        let a2 = 1.0 - alpha

        // vDSP.Biquad coefficient array order: [b0/a0, b1/a0, b2/a0, a1/a0, a2/a0]
        let coefficients = [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
        // Force-unwrap is safe: coefficient array is the correct length with finite values.
        self.filter = vDSP.Biquad(
            coefficients: coefficients,
            channelCount: 1,
            sectionCount: 1,
            ofType: Double.self
        )!
    }

    // Apply filter to a single sample by wrapping in array.
    // vDSP.Biquad maintains internal delay state between calls.
    nonisolated func apply(_ sample: Double) -> Double {
        return filter.apply(input: [sample])[0]
    }
}
