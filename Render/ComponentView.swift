import Foundation
import UIKit

// MARK: - State protocol

/// There are two types of data that control a component: props and state.
/// props are simply the component proprieties,  set by the parent and they are fixed throughout the
/// lifetime of a component.
/// For data that is going to change, we have to use state.
public protocol StateType {
  /// Returns the initial state for this current state type.
  init()
}

/// Represent a empty state (for components that don't need a state).
public struct NilState: StateType {
  public init() { }
}

public enum RenderOption {
  /// The 'construct' method is called just once.
  /// This means that render will simply re-apply the existing configuration for the nodes
  /// and compute the new layout accordingly.
  ///  This is a very useful optimisation for components with a static view hierarchy.
  case preventViewHierarchyDiff

  /// Animates the layout changes.
  case animated(duration: TimeInterval,
                options: UIViewAnimationOptions,
                alongside: (() -> Void)?)

  case flexibleWidth
  case flexibleHeigth

  /// Use this if you wish to use the same bounds passed as argument in the previous invocation.
  case usePreviousBoundsAndOptions

  /// Internal use only.
  case __animated
}

// MARK: - ComponentView protocol

public protocol AnyComponentView: class {

  /// Internal use only.
  /// Used a store for nested component view refs.
  var childrenComponent: [String: AnyComponentView] { get set }

  /// Internal use only.
  var childrenComponentAutoIncrementKey: Int  { get set }

  func willRender()
  func didRender()
}

public protocol ComponentViewType: AnyComponentView {

  associatedtype StateType

  var state: StateType { get set }

  /// This will run 'construct' that generates a new virtual-tree for this component.
  /// The tree is then diffed against the current one and the changes are applied to current
  /// view hierarchy.
  /// The layout for the resulting view hierarchy is then re-computed.
  func render(in bounds: CGSize, options: [RenderOption])

  /// Asks the view to calculate and return the size that best fits the specified size.
  func sizeThatFits(_ size: CGSize) -> CGSize

  /// The natural size for the receiving view, considering only properties of the view itself.
  var intrinsicContentSize : CGSize { get }

  init()

  /// The 'construct' method is required.
  /// When called, it should examine the component properties and the state  and return a Node tree.
  /// This method is called every time 'render' is invoked.
  func construct(state: StateType, size: CGSize) -> NodeType
}

// MARK: - Implementation

/// Components let you split the UI into independent, reusable pieces, and think about each
/// piece in isolation.
/// A component represents a function that maps a state S to its representation.
/// The infrastructure below takes care of applying the minimal set of diffs whenever it is
/// necessary.
open class ComponentView<S: StateType>: UIView, ComponentViewType {

  public typealias StateType = S
  public typealias Construct = (S, CGSize) -> NodeType

  /// The state of the component. Call 'render' on this component after the new state is set.
  public var state: S = S()

  /// The component's default options.
  public var defaultOptions: [RenderOption] = []

  /// The reuse identifier of the root node for this component.
  public var reuseIdentifier: String {
    return root.identifier
  }

  /// Alternative to subclassing ComponentView.
  public var constructBlock: Construct?

  /// The (current) root node.
  private var root: NodeType = NilNode()

  /// The bounds used in the last invocation of 'render'.
  private var lastRenderParams: (CGSize, [RenderOption]) = (CGSize.max, [])

  /// The (current) view associated to the root node.
  private var rootView: UIView!
  private lazy var contentView: UIView = {
    return UIView()
  }()

  /// Wether the 'root' node has been constructed yet.
  private var initialized: Bool = false

  /// Store for the chilren component view.
  /// Keys in the store help identify which items have changed, are added, or are removed.
  /// Keys should be given to the elements inside the array to give the elements a stable identity
  public var childrenComponent: [String: AnyComponentView] = [:]

  /// Internal use only.
  public var childrenComponentAutoIncrementKey: Int = 0

  public required init() {
    super.init(frame: CGRect.zero)
    commonInit()
  }

  required public init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    commonInit()
  }

  private func commonInit() {
    rootView = root.renderedView
    addSubview(contentView)
    let notification = Notification.Name("INJECTION_BUNDLE_NOTIFICATION")
    NotificationCenter.default.addObserver(forName: notification,
                                           object: nil,
                                           queue: nil) { [weak self] _ in
      self?.render(options: [.usePreviousBoundsAndOptions])
    }
  }

  /// The 'construct' method is required for subclasses.
  /// When called, it should examine the component properties and the state  and return a Node tree.
  /// This method is called every time 'render' is invoked.
  open func construct(state: S, size: CGSize = CGSize.undefined) -> NodeType {
    if let constructBlock = constructBlock {
      return constructBlock(state, size)
    } else {
      print("Subclasses should override this method.")
      return NilNode()
    }
  }

  /// This will run 'construct' that generates a new virtual-tree for this component.
  /// The tree is then diffed against the current one and the changes are applied to current
  /// view hierarchy.
  /// The layout for the resulting view hierarchy is then re-computed.
  public func render(in bounds: CGSize = CGSize.max, options: [RenderOption] = []) {
    assert(Thread.isMainThread)

    var argBounds = bounds
    var argOptions = options
    if RenderOption.contains(options, .usePreviousBoundsAndOptions) {
      argBounds = lastRenderParams.0
      argOptions = RenderOption.filter(options, .__animated)
    } else {
      lastRenderParams.0 = bounds
      lastRenderParams.1 = options
    }

    willRender()
    let startTime = CFAbsoluteTimeGetCurrent()

    let numberOfPasses = 2
    for idx in 0..<numberOfPasses {
      let passOptions = idx != 0 ? argOptions + [.preventViewHierarchyDiff] : argOptions
      __render(in: argBounds, options: passOptions)
    }

    debugRenderTime("\(type(of: self)).render", startTime: startTime)
    didRender()
  }

  // Internal render method.
  private func __render(in bounds: CGSize = CGSize.max, options: [RenderOption]) {
    var opts = defaultOptions + options

    // At the first execution of 'render' the view cannot be animated.
    if !initialized {
      opts = RenderOption.filter(opts, .__animated)
    }

    // Reconstructs the tree and computes the diff.
    if !initialized || !RenderOption.contains(opts, .preventViewHierarchyDiff) {
      self.childrenComponentAutoIncrementKey = 0
      root = construct(state: state, size: bounds)
      reconcile(new: root, size: bounds, view: rootView, parent: contentView)
      rootView = root.renderedView!
    }
    initialized = true

    func layout() {
      // Applies the configuration closures and recursively computes the layout.
      root.render(in: bounds)

      let preservingOrigin = false
      let yoga = rootView.yoga

      if RenderOption.contains(opts, [.flexibleWidth, .flexibleHeigth]) {
        yoga.applyLayout(preservingOrigin: preservingOrigin,
                         dimensionFlexibility: [.flexibleWidth, .flexibleHeigth])

      } else if RenderOption.contains(opts, .flexibleWidth) {
        yoga.applyLayout(preservingOrigin: preservingOrigin, dimensionFlexibility: .flexibleWidth)

      } else if RenderOption.contains(opts, .flexibleHeigth) {
        yoga.applyLayout(preservingOrigin: preservingOrigin, dimensionFlexibility: .flexibleHeigth)

      } else {
        yoga.applyLayout(preservingOrigin: false)
      }

      // Applies the frame to the host view.
      rootView.frame.normalize()
      contentView.frame.size = rootView.bounds.size

      contentView.frame.size.height += yoga.marginTop.normal + yoga.marginBottom.normal
      contentView.frame.size.width +=  yoga.marginLeft.normal + yoga.marginRight.normal
      frame = contentView.bounds
    }

    // Lays out the views with an animation.
    if let animation = RenderOption.first(opts, .__animated) {

      // Hides all of the newly created views.
      let newViews: [(UIView, CGFloat)] = views() { view in
        return view.isNewlyCreated && !RenderOption.contains(opts, .preventViewHierarchyDiff)
      }.map { view in
        let result = (view, view.alpha)
        view.alpha = 0
        return result
      }

      switch animation {
        case .animated(let duration, let options, let alongside):
          UIView.animate(withDuration: duration, delay: 0, options: options, animations: {
            layout()
            alongside?()
          }) { _ in
            UIView.animate(withDuration: duration/2) {
              for (view, alpha) in newViews {
                view.alpha = alpha
              }
            }
          }
        default: break
      }
    // Lays out the views.
    } else {
      layout()
    }
  }

  open func willRender() {
    // Forwards the 'willRender' method to all of the children compoennts.
    for (_, child) in childrenComponent {
      child.willRender()
    }
  }

  open func didRender() {
    // Forwards the 'didRender' method to all of the children compoennts.
    for (_, child) in childrenComponent {
      child.didRender()
    }
  }

  /// Returns all views (descending recursively through the view hierarchy) that matches the
  /// condition passed as argument.
  public func views(root: UIView? = nil, matching: (UIView) -> Bool) -> [UIView] {
    guard let view: UIView = root ?? rootView else {
      return []
    }
    var result: [UIView] = matching(view) ? [view] : []
    for subview in view.subviews where subview.hasNode {
      result.append(contentsOf: views(root: subview, matching: matching))
    }
    return result
  }

  open override func sizeThatFits(_ size: CGSize) -> CGSize {
    assert(Thread.isMainThread)
    render(in: size)
    return rootView.yoga.intrinsicSize
  }

  open override var intrinsicContentSize : CGSize {
    assert(Thread.isMainThread)
    return sizeThatFits(CGSize.max)
  }

  /// Reconciliation algorithm for the view hierarchy.
  private func reconcile(new: NodeType, size: CGSize, view: UIView?, parent: UIView) {
    assert(Thread.isMainThread)

    // The candidate view is a good match for reuse.
    if let view = view, view.hasNode && view.tag == new.identifier.hashValue {
      new.build(with: view)
      view.isNewlyCreated = false
    // The view for this node needs to be created.
    } else {
      view?.removeFromSuperview()
      new.build(with: nil)
      new.renderedView!.isNewlyCreated = true
      parent.insertSubview(new.renderedView!, at: new.index)
    }
    // Gets all of the existing subviews.
    var oldSubviews = view?.subviews.filter { view in
      return view.hasNode
    }

    for subnode in new.children {
      // Look for a candidate view matching the node.
      let candidateView = oldSubviews?.filter { view in
        return view.tag == subnode.identifier.hashValue
      }.first
      // Pops the candidate view from the collection.
      oldSubviews = oldSubviews?.filter {
        view in view !== candidateView
      }
      // Recursively reconcile the subnode.
      reconcile(new: subnode, size: size, view: candidateView, parent: new.renderedView!)
    }

    // Remove all of the obsolete old views that couldn't be recycled.
    for view in oldSubviews ?? [] {
      view.removeFromSuperview()
    }
  }
}

// MARK: - Utilities

func debugRenderTime(_ label: String, startTime: CFAbsoluteTime, threshold: CFAbsoluteTime = 16) {
  let timeElapsed = (CFAbsoluteTimeGetCurrent() - startTime)*1000

  // - Note: 60fps means you need to render a frame every ~16ms to not drop any frames.
  // This is even more important when used inside a cell.
  if timeElapsed > threshold  {
    print(String(format: "\(label) (%2f) ms.", arguments: [timeElapsed]))
  }
}

// MARK: Equatable Options

extension RenderOption: Equatable {

  /** Strips the param out of the enum type. */
  public var kind: Int {
    switch self {
    case .preventViewHierarchyDiff: return 1 << 0
    case .animated(_), .__animated: return 1 << 1
    case .usePreviousBoundsAndOptions: return 1 << 2
    case .flexibleWidth: return 1 << 3
    case .flexibleHeigth: return 1 << 4
    }
  }

  /** Makes sure the enum is comparable. */
  public static func ==(lhs: RenderOption, rhs: RenderOption) -> Bool {
    return lhs.kind == rhs.kind
  }

  public static func filter(_ options: [RenderOption], _ option: RenderOption) -> [RenderOption] {
    return options.filter { opt in
      return opt == option
    }
  }

  public static func contains(_ options: [RenderOption], _ option: RenderOption) -> Bool {
    return RenderOption.filter(options, option).count > 0
  }

  public static func contains(_ options: [RenderOption], _ subset: [RenderOption]) -> Bool {
    return subset.map({ RenderOption.contains(options, $0) }).reduce(true, { $0 && $1 })
  }

  public static func first(_ options: [RenderOption], _ option: RenderOption) -> RenderOption? {
    return RenderOption.filter(options, option).first
  }
}

// MARK: Equatable Options

public class NilStateComponentView: ComponentView<NilState> { }
