import Foundation
import CoreData
import CloudKit
import os.log

class BookCloudKitRemote {
    let bookZoneName = "BookZone"

    private let userRecordNameKey = "CK_UserRecordName"

    private(set) var userRecordName: String!
    private(set) var bookZoneID: CKRecordZone.ID!

    var privateDB: CKDatabase {
        return CKContainer.default().privateCloudDatabase
    }

    var isInitialised: Bool {
        return bookZoneID != nil
    }

    func initialise(completion: @escaping (Error?) -> Void) {
        if let userRecordName = UserDefaults.standard.string(forKey: userRecordNameKey) {
            createZoneAndSubscription(userRecordName: userRecordName, completion: completion)
        } else {
            CKContainer.default().fetchUserRecordID { ckRecordID, error in
                if let error = error {
                    completion(error)
                } else {
                    UserDefaults.standard.set(ckRecordID!.recordName, forKey: self.userRecordNameKey)
                    self.createZoneAndSubscription(userRecordName: ckRecordID!.recordName, completion: completion)
                }
            }
        }
    }

    private func createZoneAndSubscription(userRecordName: String, completion: @escaping (Error?) -> Void) {
        self.userRecordName = userRecordName
        self.bookZoneID = CKRecordZone.ID(zoneName: bookZoneName, ownerName: userRecordName)

        // Ensure the book zone exists. We're not calling the error callback here, since the subsequent operation is
        // not cancelled if this one fails. If the zone fails to get created, then the second operation will fail too.
        let bookZone = CKRecordZone(zoneID: bookZoneID)
        let createZoneOperation = CKModifyRecordZonesOperation(recordZonesToSave: [bookZone], recordZoneIDsToDelete: nil)
        createZoneOperation.modifyRecordZonesCompletionBlock = { _, _, error in
            if let error = error {
                os_log("Book record zone creation failed: %{public}s", type: .error, error.localizedDescription)
            } else {
                os_log("Record zone created", type: .info)
            }
        }
        createZoneOperation.qualityOfService = .userInitiated
        privateDB.add(createZoneOperation)

        // Create a subscribe and to it
        let subscription = CKRecordZoneSubscription(zoneID: bookZone.zoneID, subscriptionID: "BookChanges")
        subscription.notificationInfo = CKSubscription.NotificationInfo(shouldSendContentAvailable: true)

        let modifySubscriptionOperation = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: nil)
        modifySubscriptionOperation.addDependency(createZoneOperation)
        modifySubscriptionOperation.qualityOfService = .userInitiated
        modifySubscriptionOperation.modifySubscriptionsCompletionBlock = { _, _, error in
            if let error = error {
                os_log("Book record zone subscription creation failed: %{public}s", type: .error, error.localizedDescription)
                completion(error)
            } else {
                os_log("Record zone subscription created", type: .info)
                completion(nil)
            }
        }
        privateDB.add(modifySubscriptionOperation)
    }

    func fetchRecordChanges(changeToken: CKServerChangeToken?, recordDeletion: @escaping (CKRecord.ID) -> Void,
                            recordChange: @escaping (CKRecord) -> Void, changeTokenUpdate: @escaping (CKServerChangeToken) -> Void,
                            completion: @escaping (CKServerChangeToken?, Error?, Bool) -> Void) {
        if changeToken == nil {
            os_log("Fetching record changes without change token", type: .info)
        } else {
            os_log("Fetching record changes with change token", type: .info)
        }

        let options = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        if let changeToken = changeToken {
            options.previousServerChangeToken = changeToken
        }

        var hasChanges = false
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [bookZoneID], configurationsByRecordZoneID: [bookZoneID: options])
        operation.qualityOfService = .userInitiated
        operation.recordChangedBlock = { record in
            recordChange(record)
            hasChanges = true
        }
        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            recordDeletion(recordID)
            hasChanges = true
        }
        operation.recordZoneChangeTokensUpdatedBlock = { _, changeToken, _ in
            os_log("Record fetch change token updated", type: .info)
            if let changeToken = changeToken { changeTokenUpdate(changeToken) }
            hasChanges = true
        }
        operation.recordZoneFetchCompletionBlock = { _, changeToken, _, _, error in
            os_log("Record fetch batch operation complete", type: .info)
            completion(changeToken, error, hasChanges)
        }
        privateDB.add(operation)
    }

    func upload(_ records: [CKRecord], completion: @escaping (Error?) -> Void) {
        let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        operation.qualityOfService = .userInitiated
        operation.modifyRecordsCompletionBlock = { _, _, error in
            completion(error)
        }
        CKContainer.default().privateCloudDatabase.add(operation)
    }

    func remove(_ recordIDs: [CKRecord.ID], completion: @escaping (Error?) -> Void) {
        let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: recordIDs)
        operation.qualityOfService = .userInitiated
        operation.modifyRecordsCompletionBlock = { _, _, error in
            completion(error)
        }
        CKContainer.default().privateCloudDatabase.add(operation)
    }
}
