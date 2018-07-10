import Foundation
import UIKit

class BookTableViewCell: UITableViewCell {
    @IBOutlet private weak var titleLabel: UILabel!
    @IBOutlet private weak var authorsLabel: UILabel!
    @IBOutlet private weak var bookCover: UIImageView!
    @IBOutlet private weak var readTimeLabel: UILabel!

    private var coverImageRequest: HTTP.Request?

    func resetUI() {
        titleLabel.text = nil
        authorsLabel.text = nil
        readTimeLabel.text = nil
        bookCover.image = nil
    }

    override func awakeFromNib() {
        super.awakeFromNib()
        initialise(withTheme: UserSettings.theme.value)
        resetUI()
    }

    func initialise(withTheme theme: Theme) {
        backgroundColor = theme.cellBackgroundColor
        selectedBackgroundColor = theme.selectedCellBackgroundColor
        titleLabel.textColor = theme.titleTextColor
        authorsLabel.textColor = theme.subtitleTextColor
        readTimeLabel?.textColor = theme.subtitleTextColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()

        // Cancel any pending cover data request task
        coverImageRequest?.cancel()
        coverImageRequest = nil

        resetUI()
    }

    func configureFrom(_ book: Book, includeReadDates: Bool = true) {
        titleLabel.text = book.title
        authorsLabel.text = Author.authorDisplay(book.authorDisplay)
        bookCover.image = UIImage(optionalData: book.coverImage) ?? #imageLiteral(resourceName: "CoverPlaceholder")
        if includeReadDates {
            switch book.readState {
            case .reading: readTimeLabel.text = book.startedReading!.toPrettyString()
            case .finished: readTimeLabel.text = book.finishedReading!.toPrettyString()
            default: readTimeLabel.text = nil
            }
        }

        #if DEBUG
            if DebugSettings.showSortNumber {
                titleLabel.text =  "(\(book.sort?.intValue.string ?? "none")) \(book.title)"
            }
        #endif
    }

    func configureFrom(_ searchResult: GoogleBooks.SearchResult) {
        titleLabel.text = searchResult.title
        authorsLabel.text = searchResult.authors.joined(separator: ", ")

        guard let coverURL = searchResult.thumbnailCoverUrl else { bookCover.image = #imageLiteral(resourceName: "CoverPlaceholder"); return }
        coverImageRequest = HTTP.Request.get(url: coverURL).data { [weak self] result in
            // Cancellations appear to be reported as errors. Ideally we would detect non-cancellation
            // errors (e.g. 404), and show the placeholder in those cases. For now, just make the image blank.
            guard result.isSuccess, let data = result.value else { self?.bookCover.image = nil; return }
            self?.bookCover.image = UIImage(data: data)
        }
    }
}
