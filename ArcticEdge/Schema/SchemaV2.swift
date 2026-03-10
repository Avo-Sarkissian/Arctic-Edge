// SchemaV2.swift
// ArcticEdge
//
// VersionedSchema migration plan: V1 (Phase 2 schema) -> V2 (Phase 3 schema).
// All new properties are Optional -- lightweight migration applies automatically.
// Do not add non-optional stored properties without a custom migration stage.

import SwiftData
import Foundation

enum SchemaV1: VersionedSchema {
    nonisolated(unsafe) static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [FrameRecord.self, RunRecord.self] }
}

enum SchemaV2: VersionedSchema {
    nonisolated(unsafe) static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [FrameRecord.self, RunRecord.self] }
}

enum ArcticEdgeMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self] }
    static let v1ToV2 = MigrationStage.lightweight(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self
    )
    static var stages: [MigrationStage] { [v1ToV2] }
}
