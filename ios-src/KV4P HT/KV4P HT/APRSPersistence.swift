import CoreData
import CryptoKit
import Foundation

// Core Data-backed store for the APRS RX/TX pipeline. Two entities:
//
//  - Frame: durable packet ingest. Every AX.25 frame in or out is persisted
//    here with its raw bytes, a content hash, and minimal parsed identity.
//    This is the dedupe and re-ack source of truth; it survives restarts.
//  - Entry: user-visible APRS history (messages, positions, weather...),
//    including outgoing-message ACK state. Capped presentation data, separate
//    from packet-level evidence.
//
// The model is built in code rather than a .xcdatamodeld so changes are
// reviewable in plain Swift. Additive attribute changes migrate via Core
// Data's inferred lightweight migration; renames or semantic changes need an
// explicit new model version.
final class APRSPersistence {

    static let frameEntity = "Frame"
    static let entryEntity = "Entry"

    private let container: NSPersistentContainer
    private var context: NSManagedObjectContext { container.viewContext }

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "APRS", managedObjectModel: Self.makeModel())
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }
        container.persistentStoreDescriptions.first?.shouldMigrateStoreAutomatically = true
        container.persistentStoreDescriptions.first?.shouldInferMappingModelAutomatically = true
        container.loadPersistentStores { _, error in
            if let error { print("APRS store failed to load: \(error)") }
        }
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    // MARK: - Model

    private static func makeModel() -> NSManagedObjectModel {
        func attr(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = optional
            return a
        }
        func index(_ entity: NSEntityDescription, _ properties: [String]) -> NSFetchIndexDescription {
            NSFetchIndexDescription(name: entity.name! + "_" + properties.joined(separator: "_"),
                                    elements: properties.map { name in
                NSFetchIndexElementDescription(
                    property: entity.propertiesByName[name]!, collationType: .binary)
            })
        }

        let frame = NSEntityDescription()
        frame.name = frameEntity
        frame.managedObjectClassName = "NSManagedObject"
        frame.properties = [
            attr("id", .UUIDAttributeType),
            attr("timestamp", .dateAttributeType),
            attr("direction", .stringAttributeType),        // "in" / "out"
            attr("frameHash", .stringAttributeType),        // SHA-256 of raw FCS-free bytes
            attr("rawBytes", .binaryDataAttributeType),
            attr("source", .stringAttributeType),
            attr("destination", .stringAttributeType),
            attr("payload", .binaryDataAttributeType),
            attr("kind", .stringAttributeType, optional: true),
            attr("msgNum", .stringAttributeType, optional: true),
        ]
        frame.indexes = [
            index(frame, ["frameHash"]),
            index(frame, ["timestamp"]),
            index(frame, ["source", "timestamp"]),
        ]

        let entry = NSEntityDescription()
        entry.name = entryEntity
        entry.managedObjectClassName = "NSManagedObject"
        entry.properties = [
            attr("id", .UUIDAttributeType),
            attr("fromCallsign", .stringAttributeType),
            attr("toCallsign", .stringAttributeType),
            attr("kind", .stringAttributeType),
            attr("text", .stringAttributeType),
            attr("timestamp", .dateAttributeType),
            attr("lat", .doubleAttributeType, optional: true),
            attr("lon", .doubleAttributeType, optional: true),
            attr("symbolTable", .stringAttributeType, optional: true),
            attr("symbolCode", .stringAttributeType, optional: true),
            attr("objName", .stringAttributeType, optional: true),
            attr("msgNum", .stringAttributeType, optional: true),
            attr("wasAcknowledged", .booleanAttributeType),
            attr("isOutgoing", .booleanAttributeType),
            attr("weatherData", .binaryDataAttributeType, optional: true),
            attr("frameHash", .stringAttributeType, optional: true),
        ]
        entry.indexes = [
            index(entry, ["timestamp"]),
            index(entry, ["msgNum"]),
        ]

        let model = NSManagedObjectModel()
        model.entities = [frame, entry]
        return model
    }

    static func frameHash(of raw: Data) -> String {
        SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    }

    private func save() {
        guard context.hasChanges else { return }
        do { try context.save() } catch {
            context.rollback()
            print("APRS store save failed: \(error)")
        }
    }

    // MARK: - Frames

    func insertFrame(direction: String, raw: Data, frameHash: String,
                     source: String, destination: String, payload: Data,
                     kind: String?, msgNum: String?, timestamp: Date) {
        let f = NSEntityDescription.insertNewObject(forEntityName: Self.frameEntity, into: context)
        f.setValue(UUID(), forKey: "id")
        f.setValue(timestamp, forKey: "timestamp")
        f.setValue(direction, forKey: "direction")
        f.setValue(frameHash, forKey: "frameHash")
        f.setValue(raw, forKey: "rawBytes")
        f.setValue(source, forKey: "source")
        f.setValue(destination, forKey: "destination")
        f.setValue(payload, forKey: "payload")
        f.setValue(kind, forKey: "kind")
        f.setValue(msgNum, forKey: "msgNum")
        save()
    }

    // True if an incoming frame with the same source and identical payload was
    // persisted within the window. Matching on (source, payload) rather than
    // frameHash alone also catches digipeated copies, whose path bytes (and
    // therefore raw-frame hash) change at each hop.
    func recentIncomingFrameExists(source: String, payload: Data, since: Date) -> Bool {
        let req = NSFetchRequest<NSManagedObject>(entityName: Self.frameEntity)
        req.predicate = NSPredicate(
            format: "direction == %@ AND source == %@ AND payload == %@ AND timestamp >= %@",
            "in", source, payload as NSData, since as NSDate)
        req.fetchLimit = 1
        return ((try? context.count(for: req)) ?? 0) > 0
    }

    func pruneFrames(olderThan cutoff: Date) {
        let req = NSFetchRequest<NSManagedObject>(entityName: Self.frameEntity)
        req.predicate = NSPredicate(format: "timestamp < %@", cutoff as NSDate)
        guard let stale = try? context.fetch(req), !stale.isEmpty else { return }
        stale.forEach(context.delete)
        save()
    }

    // MARK: - Entries

    func loadEntries(max: Int) -> [APRSEntry] {
        let req = NSFetchRequest<NSManagedObject>(entityName: Self.entryEntity)
        req.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        req.fetchLimit = max
        guard let rows = try? context.fetch(req) else { return [] }
        return rows.reversed().compactMap { row in
            guard let id = row.value(forKey: "id") as? UUID,
                  let kindRaw = row.value(forKey: "kind") as? String,
                  let kind = APRSPacketKind(rawValue: kindRaw),
                  let timestamp = row.value(forKey: "timestamp") as? Date
            else { return nil }
            var e = APRSEntry(
                fromCallsign: row.value(forKey: "fromCallsign") as? String ?? "",
                toCallsign: row.value(forKey: "toCallsign") as? String ?? "",
                kind: kind,
                text: row.value(forKey: "text") as? String ?? "",
                timestamp: timestamp,
                lat: row.value(forKey: "lat") as? Double,
                lon: row.value(forKey: "lon") as? Double,
                symbolTable: row.value(forKey: "symbolTable") as? String,
                symbolCode: row.value(forKey: "symbolCode") as? String,
                objName: row.value(forKey: "objName") as? String,
                msgNum: row.value(forKey: "msgNum") as? String)
            e.id = id
            e.wasAcknowledged = row.value(forKey: "wasAcknowledged") as? Bool ?? false
            e.isOutgoing = row.value(forKey: "isOutgoing") as? Bool ?? false
            if let wxData = row.value(forKey: "weatherData") as? Data {
                e.weather = try? JSONDecoder().decode(APRSWeather.self, from: wxData)
            }
            return e
        }
    }

    func insertEntry(_ entry: APRSEntry, frameHash: String?) {
        let row = NSEntityDescription.insertNewObject(forEntityName: Self.entryEntity, into: context)
        row.setValue(entry.id, forKey: "id")
        row.setValue(entry.fromCallsign, forKey: "fromCallsign")
        row.setValue(entry.toCallsign, forKey: "toCallsign")
        row.setValue(entry.kind.rawValue, forKey: "kind")
        row.setValue(entry.text, forKey: "text")
        row.setValue(entry.timestamp, forKey: "timestamp")
        row.setValue(entry.lat, forKey: "lat")
        row.setValue(entry.lon, forKey: "lon")
        row.setValue(entry.symbolTable, forKey: "symbolTable")
        row.setValue(entry.symbolCode, forKey: "symbolCode")
        row.setValue(entry.objName, forKey: "objName")
        row.setValue(entry.msgNum, forKey: "msgNum")
        row.setValue(entry.wasAcknowledged, forKey: "wasAcknowledged")
        row.setValue(entry.isOutgoing, forKey: "isOutgoing")
        row.setValue(entry.weather.flatMap { try? JSONEncoder().encode($0) }, forKey: "weatherData")
        row.setValue(frameHash, forKey: "frameHash")
        save()
    }

    func markEntryAcknowledged(id: UUID) {
        guard let row = fetchEntry(id: id) else { return }
        row.setValue(true, forKey: "wasAcknowledged")
        save()
    }

    func trimEntries(max: Int) {
        let req = NSFetchRequest<NSManagedObject>(entityName: Self.entryEntity)
        req.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        req.fetchOffset = max
        guard let overflow = try? context.fetch(req), !overflow.isEmpty else { return }
        overflow.forEach(context.delete)
        save()
    }

    func deleteAllEntries() {
        let req = NSFetchRequest<NSManagedObject>(entityName: Self.entryEntity)
        guard let rows = try? context.fetch(req) else { return }
        rows.forEach(context.delete)
        save()
    }

    private func fetchEntry(id: UUID) -> NSManagedObject? {
        let req = NSFetchRequest<NSManagedObject>(entityName: Self.entryEntity)
        req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        req.fetchLimit = 1
        return (try? context.fetch(req))?.first
    }

    // MARK: - Legacy migration

    // One-shot import of the pre-Core Data UserDefaults JSON blob.
    func migrateLegacyEntries(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode([APRSEntry].self, from: data) else { return }
        for entry in decoded { insertEntry(entry, frameHash: nil) }
    }
}
