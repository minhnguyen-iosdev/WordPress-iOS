import UIKit
import WordPressShared

typealias ImmuTableRowControllerGenerator = (ImmuTableRow) -> UIViewController

protocol ImmuTablePresenter: class {
    func push(_ controllerGenerator: ImmuTableRowControllerGenerator) -> ImmuTableAction
    func present(_ controllerGenerator: ImmuTableRowControllerGenerator) -> ImmuTableAction
}

extension ImmuTablePresenter where Self: UIViewController {
    func push(_ controllerGenerator: @escaping ImmuTableRowControllerGenerator) -> ImmuTableAction {
        return {
            [unowned self] in
            let controller = controllerGenerator($0)
            self.navigationController?.pushViewController(controller, animated: true)
        }
    }

    func present(_ controllerGenerator: @escaping ImmuTableRowControllerGenerator) -> ImmuTableAction {
        return {
            [unowned self] in
            let controller = controllerGenerator($0)
            self.present(controller, animated: true, completion: nil)
        }
    }
}

extension ImmuTablePresenter {
    func prompt<T: UIViewController>(_ controllerGenerator: (ImmuTableRow) -> T) -> ImmuTableAction where T: Confirmable {
        return present({
            let controller = controllerGenerator($0)
            return PromptViewController(controller)
        })
    }
}

protocol ImmuTableController {
    var title: String { get }
    var immuTableRows: [ImmuTableRow.Type] { get }
    var noticeMessage: String? { get }
    func tableViewModelWithPresenter(_ presenter: ImmuTablePresenter) -> ImmuTable
    func refreshModel()
}

/// Generic view controller to present ImmuTable-based tables
///
/// Instead of subclassing the view controller, this is designed to be used from
/// a "controller" class that handles all the logic, and updates the view
/// controller, like you would update a view.
final class ImmuTableViewController: UITableViewController, ImmuTablePresenter {
    fileprivate lazy var handler: ImmuTableViewHandler = {
        return ImmuTableViewHandler(takeOver: self)
    }()

    fileprivate var noticeAnimator: NoticeAnimator!

    let controller: ImmuTableController

    // MARK: - Table View Controller

    init(controller: ImmuTableController) {
        self.controller = controller
        super.init(style: .grouped)

        title = controller.title
        registerRows(controller.immuTableRows)
        controller.refreshModel()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        noticeAnimator = NoticeAnimator(target: view)

        WPStyleGuide.configureColors(for: view, andTableView: tableView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        noticeAnimator.layout()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadModel()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ImmuTableViewController.loadModel),
            name: NSNotification.Name(rawValue: ImmuTableViewController.modelChangedNotification),
            object: nil)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        NotificationCenter.default.removeObserver(self,
                                                            name: NSNotification.Name(rawValue: ImmuTableViewController.modelChangedNotification),
                                                            object: nil)
    }

    // MARK: - Inputs

    /// Registers custom rows
    /// - seealso: ImmuTable.registerRows(_:tableView)
    func registerRows(_ rows: [ImmuTableRow.Type]) {
        ImmuTable.registerRows(rows, tableView: tableView)
    }

    func loadModel() {
        handler.viewModel = controller.tableViewModelWithPresenter(self)
        noticeMessage = controller.noticeMessage
    }

    var noticeMessage: String? = nil {
        didSet {
            guard noticeMessage != oldValue else { return }
            noticeAnimator.animateMessage(noticeMessage)
        }
    }

    // MARK: - Constants

    static let modelChangedNotification = "ImmuTableControllerChanged"
}
