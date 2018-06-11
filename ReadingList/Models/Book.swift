import Foundation
import CoreData

@objc(Book)
class Book: NSManagedObject {
    @NSManaged var readState: BookReadState
    @NSManaged var startedReading: Date?
    @NSManaged var finishedReading: Date?

    @NSManaged var isbn13: String?
    @NSManaged var googleBooksId: String?

    @NSManaged var title: String
    @NSManaged private(set) var authors: NSOrderedSet
    @NSManaged private(set) var authorDisplay: String // Denormalised attribute to reduce required fetches
    @NSManaged private(set) var authorSort: String // Calculated sort helper

    @NSManaged var pageCount: NSNumber?
    @NSManaged var publicationDate: Date?
    @NSManaged var bookDescription: String?
    @NSManaged var coverImage: Data?
    @NSManaged var notes: String?
    @NSManaged var currentPage: NSNumber?
    @NSManaged var sort: NSNumber?

    @NSManaged var subjects: Set<Subject>
    @NSManaged private(set) var lists: Set<List>

    // Raw value of a BookKey option set. Represents the keys which have been modified locally but
    // not uploaded to a remote store.
    @NSManaged private var keysPendingRemoteUpdate: Int32
    var modifiedKeysPendingRemoteUpdate: BookKey {
        get { return BookKey(rawValue: keysPendingRemoteUpdate) }
        set { keysPendingRemoteUpdate = newValue.rawValue }
    }

    static let pendingRemoteUpdatesPredicate = NSPredicate(format: "%K != 0", #keyPath(Book.keysPendingRemoteUpdate))

    convenience init(context: NSManagedObjectContext, readState: BookReadState) {
        self.init(context: context)
        self.readState = readState
        if readState == .reading {
            startedReading = Date()
        }
        if readState == .finished {
            startedReading = Date()
            finishedReading = Date()
        }
    }

    override func willSave() {
        super.willSave()

        // The sort manipulation should be in a method which allows setting of dates
        if readState == .toRead && sort == nil {
            let maxSort = Book.maxSort(fromContext: managedObjectContext!) ?? 0
            self.sort = (maxSort + 1).nsNumber
        }

        // Sort is not (yet) supported for non To Read books
        if readState != .toRead && sort != nil {
            self.sort = nil
        }

        // Update the modified keys record
        let currentModifiedKeys = BookKey.union(changedValues().keys.compactMap { BookKey.from(coreDataKey: $0) })
        if modifiedKeysPendingRemoteUpdate != currentModifiedKeys {
            modifiedKeysPendingRemoteUpdate = currentModifiedKeys
        }
    }

    override func prepareForDeletion() {
        super.prepareForDeletion()
        for orphanedSubject in subjects.filter({ $0.books.count == 1 }) {
            orphanedSubject.delete()
            print("orphaned subject \(orphanedSubject.name) deleted.")
        }
    }
}

struct BookKey: OptionSet {
    let rawValue: Int32

    static let title = BookKey(rawValue: 1 << 0)
    static let authors = BookKey(rawValue: 1 << 1)
    static let cover = BookKey(rawValue: 1 << 2)
    static let googleBooksId = BookKey(rawValue: 1 << 3)
    static let isbn13 = BookKey(rawValue: 1 << 4)
    static let pageCount = BookKey(rawValue: 1 << 5)
    static let publicationDate = BookKey(rawValue: 1 << 6)
    static let bookDescription = BookKey(rawValue: 1 << 7)
    static let coverImage = BookKey(rawValue: 1 << 8)
    static let notes = BookKey(rawValue: 1 << 9)
    static let currentPage = BookKey(rawValue: 1 << 10)
    static let sort = BookKey(rawValue: 1 << 11)
    static let startedReading = BookKey(rawValue: 1 << 12)
    static let finishedReading = BookKey(rawValue: 1 << 13)

    static func from(coreDataKey: String) -> BookKey? { //swiftlint:disable:this cyclomatic_complexity
        switch coreDataKey {
        case #keyPath(Book.title): return .title
        case #keyPath(Book.authors): return .authors
        case #keyPath(Book.coverImage): return .cover
        case #keyPath(Book.googleBooksId): return .googleBooksId
        case #keyPath(Book.isbn13): return .isbn13
        case #keyPath(Book.pageCount): return .pageCount
        case #keyPath(Book.publicationDate): return .publicationDate
        case #keyPath(Book.bookDescription): return .bookDescription
        case #keyPath(Book.notes): return .notes
        case #keyPath(Book.currentPage): return .currentPage
        case #keyPath(Book.sort): return .sort
        case #keyPath(Book.startedReading): return .startedReading
        case #keyPath(Book.finishedReading): return .finishedReading
        default: return nil
        }
    }

    static func union(_ keys: [BookKey]) -> BookKey {
        var key = BookKey(rawValue: 0)
        keys.forEach { key.formUnion($0) }
        return key
    }
}

extension Book {

    func setAuthors(_ authors: [Author]) {
        self.authors = NSOrderedSet(array: authors)
        self.authorSort = Author.authorSort(authors)
        self.authorDisplay = Author.authorDisplay(authors)
    }

    // FUTURE: make a convenience init which takes a fetch result?
    func populate(fromFetchResult fetchResult: GoogleBooks.FetchResult) {
        googleBooksId = fetchResult.id
        title = fetchResult.title
        populateAuthors(fromStrings: fetchResult.authors)
        bookDescription = fetchResult.description
        subjects = Set(fetchResult.subjects.map { Subject.getOrCreate(inContext: self.managedObjectContext!, withName: $0) })
        coverImage = fetchResult.coverImage
        pageCount = fetchResult.pageCount?.nsNumber
        publicationDate = fetchResult.publishedDate
        isbn13 = fetchResult.isbn13
    }

    func populate(fromSearchResult searchResult: GoogleBooks.SearchResult, withCoverImage coverImage: Data? = nil) {
        googleBooksId = searchResult.id
        title = searchResult.title
        populateAuthors(fromStrings: searchResult.authors)
        isbn13 = searchResult.isbn13
        self.coverImage = coverImage
    }

    private func populateAuthors(fromStrings authors: [String]) {
        let authorNames: [(String?, String)] = authors.map {
            if let range = $0.range(of: " ", options: .backwards) {
                let firstNames = $0[..<range.upperBound].trimming()
                let lastName = $0[range.lowerBound...].trimming()

                return (firstNames: firstNames, lastName: lastName)
            } else {
                return (firstNames: nil, lastName: $0)
            }
        }
        // FUTURE: This is a bit brute force, deleting all existing authors. Could perhaps inspect for changes first.
        self.authors.map { $0 as! Author }.forEach { $0.delete() }
        self.setAuthors(authorNames.map { Author(context: self.managedObjectContext!, lastName: $0.1, firstNames: $0.0) })
    }

    static func get(fromContext context: NSManagedObjectContext, googleBooksId: String? = nil, isbn: String? = nil) -> Book? {
        // if both are nil, leave early
        guard googleBooksId != nil || isbn != nil else { return nil }

        // First try fetching by google books ID
        if let googleBooksId = googleBooksId {
            let googleBooksfetch = NSManagedObject.fetchRequest(Book.self, limit: 1)
            googleBooksfetch.predicate = NSPredicate(format: "%K == %@", #keyPath(Book.googleBooksId), googleBooksId)
            googleBooksfetch.returnsObjectsAsFaults = false
            if let result = (try! context.fetch(googleBooksfetch)).first { return result }
        }

        // then try fetching by ISBN
        if let isbn = isbn {
            let isbnFetch = NSManagedObject.fetchRequest(Book.self, limit: 1)
            isbnFetch.predicate = NSPredicate(format: "%K == %@", #keyPath(Book.isbn13), isbn)
            isbnFetch.returnsObjectsAsFaults = false
            return (try! context.fetch(isbnFetch)).first
        }

        return nil
    }

    static func maxSort(fromContext context: NSManagedObjectContext) -> Int32? {
        // FUTURE: Could use a fetch expression to just return the max value
        let fetchRequest = NSManagedObject.fetchRequest(Book.self, limit: 1)
        fetchRequest.predicate = NSPredicate(format: "%K == %ld", #keyPath(Book.readState), BookReadState.toRead.rawValue)
        fetchRequest.sortDescriptors = [NSSortDescriptor(\Book.sort, ascending: false)]
        fetchRequest.returnsObjectsAsFaults = false
        return (try! context.fetch(fetchRequest)).first?.sort?.int32
    }

    enum ValidationError: Error {
        case missingTitle
        case invalidIsbn
        case invalidReadDates
    }

    override func validateForUpdate() throws {
        try super.validateForUpdate()

        // FUTURE: these should be property validators, not in validateForUpdate
        if title.isEmptyOrWhitespace { throw ValidationError.missingTitle }
        if let isbn = isbn13, ISBN13(isbn) == nil { throw ValidationError.invalidIsbn }

        // FUTURE: Check read state with current page
        if readState == .toRead && (startedReading != nil || finishedReading != nil) { throw ValidationError.invalidReadDates }
        if readState == .reading && (startedReading == nil || finishedReading != nil) { throw ValidationError.invalidReadDates }
        if readState == .finished && (startedReading == nil || finishedReading == nil
            || startedReading!.startOfDay() > finishedReading!.startOfDay()) {
            throw ValidationError.invalidReadDates
        }
    }

    func startReading() {
        guard readState == .toRead else { print("Attempted to start a book in state \(readState)"); return }
        readState = .reading
        startedReading = Date()
    }

    func finishReading() {
        guard readState == .reading else { print("Attempted to finish a book in state \(readState)"); return }
        readState = .finished
        finishedReading = Date()
    }
}
