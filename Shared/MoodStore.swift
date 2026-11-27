import CoreData
import Foundation

actor MoodStore {
    private let url: URL?
    private var context: NSManagedObjectContext?

    init(url: URL? = nil) { self.url = url }

    static func location(testing: Bool) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent(testing ? "MoodCal-UITest" : "MoodCal", isDirectory: true)
            .appendingPathComponent("Mood.sqlite")
    }

    private static func entity(_ name: String, _ fields: [(String, NSAttributeType)], unique: String) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = fields.map { name, type in
            let field = NSAttributeDescription()
            field.name = name
            field.attributeType = type
            field.isOptional = false
            return field
        }
        entity.uniquenessConstraints = [[unique]]
        return entity
    }

    private func open() throws -> NSManagedObjectContext {
        if let context { return context }
        let model = NSManagedObjectModel()
        let record = Self.entity("Record", [("uuid", .stringAttributeType), ("dayKey", .stringAttributeType),
                                            ("payload", .binaryDataAttributeType)], unique: "uuid")
        if let day = record.propertiesByName["dayKey"] {
            record.indexes = [NSFetchIndexDescription(name: "recordDay", elements: [
                NSFetchIndexElementDescription(property: day, collationType: .binary)
            ])]
        }
        model.entities = [record, Self.entity("Preference", [("key", .stringAttributeType), ("payload", .binaryDataAttributeType)], unique: "key")]
        model.versionIdentifiers = [AnyHashable("MoodCal.v1")]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        if let url {
            var folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: [
                NSMigratePersistentStoresAutomaticallyOption: true,
                NSInferMappingModelAutomaticallyOption: true,
                NSPersistentStoreFileProtectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ])
        } else {
            try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil, options: nil)
        }
        let newContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        newContext.persistentStoreCoordinator = coordinator
        context = newContext
        return newContext
    }

    private static func fetch(_ name: String, in context: NSManagedObjectContext, predicate: NSPredicate? = nil) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: name)
        request.predicate = predicate
        return try context.fetch(request)
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, _ object: NSManagedObject) throws -> Value {
        guard let data = object.value(forKey: "payload") as? Data else { throw MoodFailure.invalid }
        return try JSONDecoder().decode(type, from: data)
    }

    func load() throws -> MoodHistory {
        let context = try open()
        return try context.performAndWait {
            defer { context.reset() }
            let entries = try Self.fetch("Record", in: context).map { try Self.decode(MoodEntry.self, $0) }
            let preferences = try Self.fetch("Preference", in: context).first.map { try Self.decode(Preferences.self, $0) } ?? Preferences()
            guard entries.allSatisfy(\.valid), preferences.valid else { throw MoodFailure.invalid }
            return MoodHistory(entries: entries, preferences: preferences)
        }
    }

    func save(from old: MoodHistory, to new: MoodHistory) throws {
        let context = try open()
        try context.performAndWait {
            defer { context.reset() }
            let before = Dictionary(uniqueKeysWithValues: old.entries.map { ($0.id, $0) })
            let after = Set(new.entries.map(\.id))
            let encoder = JSONEncoder()
            do {
                for entry in old.entries where !after.contains(entry.id) {
                    for object in try Self.fetch("Record", in: context, predicate: NSPredicate(format: "uuid == %@", entry.id.uuidString)) {
                        context.delete(object)
                    }
                }
                for entry in new.entries where before[entry.id] != entry {
                    guard entry.valid else { throw MoodFailure.invalid }
                    let stored = before[entry.id] == nil ? nil : try Self.fetch("Record", in: context,
                        predicate: NSPredicate(format: "uuid == %@", entry.id.uuidString)).first
                    let object = stored ?? NSEntityDescription.insertNewObject(forEntityName: "Record", into: context)
                    object.setValue(entry.id.uuidString, forKey: "uuid")
                    object.setValue(entry.dayKey, forKey: "dayKey")
                    object.setValue(try encoder.encode(entry), forKey: "payload")
                }
                if old.preferences != new.preferences {
                    guard new.preferences.valid else { throw MoodFailure.invalid }
                    let object = try Self.fetch("Preference", in: context).first
                        ?? NSEntityDescription.insertNewObject(forEntityName: "Preference", into: context)
                    object.setValue("current", forKey: "key")
                    object.setValue(try encoder.encode(new.preferences), forKey: "payload")
                }
                if context.hasChanges { try context.save() }
            } catch {
                context.rollback()
                throw error
            }
        }
    }
}
