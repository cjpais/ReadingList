import Foundation
import ReadingList_Foundation
import UIKit
import CoreData

protocol OrganizeTableViewDataSourceCommon: UITableViewEmptyDetectingDataSource, NSFetchedResultsControllerDelegate {
    var sortManager: SortManager<List> { get }
    var resultsController: NSFetchedResultsController<List> { get }

    func updateData(animate: Bool)
}

extension OrganizeTableViewDataSourceCommon {
    func canMoveRow(at indexPath: IndexPath) -> Bool {
        guard ListSortOrder.selectedSort == .custom else { return false }
        return resultsController.sections![0].numberOfObjects > 1
    }

    func moveRow(at sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard ListSortOrder.selectedSort == .custom else {
            assertionFailure()
            return
        }

        // We need to disable the change detection while we handle the move (since the cells are already in the right location,
        // because of the move, and we don't want to attempt to re-animate the move). Grab a reference to the results controller
        // delegate object to hold locally while the delegate is set to nil for the duration of the operation.
        let delegateReference = resultsController.delegate
        resultsController.delegate = nil

        sortManager.move(objectAt: sourceIndexPath, to: destinationIndexPath)
        try! resultsController.performFetch()
        PersistentStoreManager.container.viewContext.saveAndLogIfErrored()

        // Delay slightly so that the UI update doesn't interfere with the animation of the row reorder completing.
        // This is quite ugly code, but leads to a less ugly UI.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [unowned self] in
            self.updateData(animate: false)
        }

        resultsController.delegate = delegateReference
    }
}

final class OrganizeTableViewDataSource: EmptyDetectingTableDiffableDataSource<String, NSManagedObjectID>, OrganizeTableViewDataSourceCommon {
    let sortManager: SortManager<List>
    let resultsController: NSFetchedResultsController<List>
    var changeMediator: ResultsControllerSnapshotGenerator<OrganizeTableViewDataSource>!

    init(tableView: UITableView, resultsController: NSFetchedResultsController<List>) {
        self.resultsController = resultsController
        self.sortManager = SortManager(tableView) {
            resultsController.object(at: $0)
        }

        super.init(tableView: tableView) { _, indexPath, _ in
            let cell = tableView.dequeueReusableCell(withIdentifier: "ListCell", for: indexPath)
            cell.configure(from: resultsController.object(at: indexPath))
            return cell
        }
        changeMediator = ResultsControllerSnapshotGenerator { [unowned self] in
            self.snapshot()
        }
        changeMediator.delegate = self

        resultsController.delegate = changeMediator.controllerDelegate
    }

    func updateData(animate: Bool) {
        apply(resultsController.snapshot(), animatingDifferences: animate)
    }

    final override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return canMoveRow(at: indexPath)
    }

    final override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        moveRow(at: sourceIndexPath, to: destinationIndexPath)
    }

    final override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }
}

extension OrganizeTableViewDataSource: ResultsControllerSnapshotGeneratorDelegate {
    typealias SectionType = String

    func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>, didChangeProducingSnapshot snapshot: NSDiffableDataSourceSnapshot<String, NSManagedObjectID>, withChangedObjects changedObjects: [NSManagedObjectID]) {
        apply(snapshot, animatingDifferences: true)
    }
}
