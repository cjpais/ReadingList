import Foundation
import CoreData
import UIKit
import CloudKit

class SyncCoordinator {
    let viewContext: NSManagedObjectContext
    let syncContext: NSManagedObjectContext

    let upstreamChangeProcessors: [UpstreamChangeProcessor]
    let downstreamChangeProcessors: [DownstreamChangeProcessor]
    let remote = BookCloudKitRemote()

    private var contextSaveNotificationObservers = [NSObjectProtocol]()

    init(container: NSPersistentContainer, upstreamChangeProcessors: [UpstreamChangeProcessor], downstreamChangeProcessors: [DownstreamChangeProcessor]) {
        viewContext = container.viewContext
        viewContext.name = "ViewContext"

        syncContext = container.newBackgroundContext()
        syncContext.name = "SyncContext"
        syncContext.mergePolicy = NSMergePolicy.mergeByPropertyStoreTrump // FUTURE: Add a custom merge policy

        self.upstreamChangeProcessors = upstreamChangeProcessors
        self.downstreamChangeProcessors = downstreamChangeProcessors
    }

    /**
     
     */
    func start() {
        setupQueryGenerations()
        startContextNotificationObserving()

        if !remote.isInitialised {
            remote.initialise {
                self.processPendingChanges()
            }
        } else {
            processPendingChanges()
        }
    }

    /**
     
    */
    func stop() {
        stopContextNotificationObserving()
    }

    private func setupQueryGenerations() {
        let token = NSQueryGenerationToken.current
        viewContext.perform {
            try! self.viewContext.setQueryGenerationFrom(token)
            self.viewContext.refreshAllObjects()
        }
        syncContext.perform {
            try! self.syncContext.setQueryGenerationFrom(token)
            self.syncContext.refreshAllObjects()
        }
    }

    /**
     Registers Save observers on both the viewContext and the syncContext, handling them by merging the save from
     one context to the other, and also calling `processChangedLocalObjects(_)` on the updated or inserted objects.
    */
    private func startContextNotificationObserving() {
        guard contextSaveNotificationObservers.isEmpty else { print("Observers already registered"); return }

        func registerForMergeOnSave(from sourceContext: NSManagedObjectContext, to destinationContext: NSManagedObjectContext) {
            let observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave, object: sourceContext, queue: nil) { [weak self] note in
                print("Merging save from \(String(sourceContext.name!)) to \(String(destinationContext.name!))")
                destinationContext.performMergeChanges(from: note)

                // Take the new or modified objects, mapped to the syncContext, and process the
                guard let coordinator = self else { return }
                coordinator.syncContext.perform {
                    // We unpack the notification here, to make sure it's retained until this point.
                    let updates = note.updatedObjects?.map { $0.inContext(coordinator.syncContext) } ?? []
                    let inserts = note.insertedObjects?.map { $0.inContext(coordinator.syncContext) } ?? []
                    coordinator.processLocalChanges(updates + inserts)
                }
            }
            contextSaveNotificationObservers.append(observer)
        }

        registerForMergeOnSave(from: syncContext, to: viewContext)
        registerForMergeOnSave(from: viewContext, to: syncContext)
    }

    private func stopContextNotificationObserving() {
        guard contextSaveNotificationObservers.count == 2 else { print("Unexpected count of observers: \(contextSaveNotificationObservers.count)"); return }

        contextSaveNotificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        contextSaveNotificationObservers.removeAll()
    }

    private func object(_ object: NSManagedObject, matches fetchRequest: NSFetchRequest<NSFetchRequestResult>) -> Bool {
        // Entity name comparison is done since the NSEntityDescription is not necessarily present until a fetch has been peformed
        return object.entity.name == fetchRequest.entityName && fetchRequest.predicate!.evaluate(with: object)
    }

    private func processLocalChanges(_ objects: [NSManagedObject]) {
        for changeProcessor in upstreamChangeProcessors {
            let matching = objects.filter {
                object($0, matches: changeProcessor.unprocessedChangedObjectsRequest)
            }
            guard !matching.isEmpty else { continue }
            changeProcessor.processLocalChanges(matching, context: syncContext, remote: remote)
        }
    }

    func processPendingChanges() {
        processOutstandingRemoteChanges()
        processOutstandingLocalChanges()
    }

    private func processOutstandingLocalChanges() {
        syncContext.perform {
            for changeProcessor in self.upstreamChangeProcessors {
                let fetchRequest = changeProcessor.unprocessedChangedObjectsRequest
                fetchRequest.returnsObjectsAsFaults = false
                let results = try! self.syncContext.fetch(fetchRequest) as! [NSManagedObject]
                if !results.isEmpty {
                    changeProcessor.processLocalChanges(results, context: self.syncContext, remote: self.remote)
                }
            }
        }
    }

    func processOutstandingRemoteChanges(applicationCallback: ((UIBackgroundFetchResult) -> Void)? = nil) {
        syncContext.perform {
            let changeToken: CKServerChangeToken?
            if let cachedChangeToken = ChangeToken.get(fromContext: self.syncContext, for: self.remote.bookZoneID) {
                changeToken = (NSKeyedUnarchiver.unarchiveObject(with: cachedChangeToken.changeToken) as! CKServerChangeToken)
            } else {
                changeToken = nil
            }

            self.remote.fetchRecordChanges(changeToken: changeToken) { changeToken, records, deletedRecordIDs in
                guard !records.isEmpty || !deletedRecordIDs.isEmpty else { return }
                for changeProcessor in self.downstreamChangeProcessors {
                    changeProcessor.processRemoteChanges(from: self.remote.bookZoneID, changedRecords: records,
                                                         deletedRecordIDs: deletedRecordIDs, newChangeToken: changeToken,
                                                         context: self.syncContext, completion: nil)
                }
            }
        }
    }
}
