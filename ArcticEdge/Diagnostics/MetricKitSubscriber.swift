// MetricKitSubscriber.swift
// ArcticEdge
//
// Receives MXMetricPayload and MXDiagnosticPayload from MetricKit.
// Each payload is JSON-serialized and appended as a JSONL line to:
//   <Documents>/MetricKit/metrics-YYYY-MM-DD.jsonl
//
// MetricKit delivers payloads at most once per 24 hours on device.
// In Simulator, payloads never arrive — the log file is never created.
//
// MXMetricManagerSubscriber requires NSObject conformance for ObjC protocol.
// nonisolated on delegate methods: MetricKit delivers on an arbitrary queue;
// all file I/O inside appendPayload is synchronous and self-contained.

import MetricKit
import Foundation

final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {

    override init() {
        super.init()
        MXMetricManager.shared.add(self)
    }

    deinit {
        MXMetricManager.shared.remove(self)
    }

    // MARK: - MXMetricManagerSubscriber

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            appendPayload(payload.jsonRepresentation(), label: "metric")
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            appendPayload(payload.jsonRepresentation(), label: "diagnostic")
        }
    }

    // MARK: - Private

    private nonisolated func appendPayload(_ data: Data, label: String) {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent("MetricKit", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let dateStr = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let file = dir.appendingPathComponent("metrics-\(dateStr).jsonl")

        // Wrap payload in a simple envelope: {"type":"...","ts":"...","payload":{...}}
        var envelope: [String: Any] = [
            "type": label,
            "ts": ISO8601DateFormatter().string(from: Date())
        ]
        if let json = try? JSONSerialization.jsonObject(with: data) {
            envelope["payload"] = json
        }
        guard let lineData = try? JSONSerialization.data(withJSONObject: envelope),
              var lineStr = String(data: lineData, encoding: .utf8) else { return }
        lineStr += "\n"

        if fm.fileExists(atPath: file.path) {
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                if let append = lineStr.data(using: .utf8) { handle.write(append) }
                try? handle.close()
            }
        } else {
            try? lineStr.data(using: .utf8)?.write(to: file, options: .atomic)
        }
    }
}
