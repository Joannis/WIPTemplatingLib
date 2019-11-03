internal indirect enum TemplateNode: ContentRepresentable, _HTML {
    typealias ParentElement = Never
    
    case none
    case list([TemplateNode])
    case tag(name: StaticString, content: TemplateNode, modifiers: [Modifier])
    case lazy(() -> TemplateNode)
    case literal(String)
    case contextValue(StaticString)
    
    var node: TemplateNode { self }
    var html: TemplateNode { self }
    
    init<Content: _HTML>(from content: Content) {
        switch content {
        case let node as TemplateNode:
            self = node
        case let content as ContentRepresentable:
            self = content.node
        default:
            self.init(from: content.html)
        }
    }
}

//public struct TemplateString: ExpressibleByStringInterpolation {
//    public init(stringLiteral value: String) {
//
//    }
//
//    public init(stringInterpolation: StringInterpolation) {
//
//    }
//}

extension Never: HTML {
    public var html: Never { fatalError() }
}

protocol ContentRepresentable {
    var node: TemplateNode { get }
}

public protocol _HTML {
    associatedtype Content: _HTML
    associatedtype ParentElement
    
    var html: Content { get }
}

public protocol HTML: _HTML where ParentElement == Body, Content: HTML {}
public protocol Template: _HTML where ParentElement == Never {
    init()
}
internal protocol HeadElement: _HTML where ParentElement == Head {}
internal protocol BodyTag: _NativeHTMLElement where Content == AnyBodyTag, BaseTag == Self {
    var node: TemplateNode { get }
    static var tag: StaticString { get }
    
    init(node: TemplateNode)
}
public protocol AttributedHTML: HTML {
    associatedtype BaseTag: AttributedHTML
    
    func attribute(key: String, value: String) -> Modified<BaseTag>
}
public protocol _NativeHTMLElement: AttributedHTML {
    init()
    init(@TemplateBuilder<Body> build: () -> ListContent<Body>)
    init<Element: HTML>(@TemplateBuilder<Body> build: () -> Element)
}

extension BodyTag {
    public func attribute(key: String, value: String) -> Modified<BaseTag> {
        return Modified<BaseTag>(
            tag: Self.tag,
            modifiers: [
                .attribute(name: key, value: value)
            ],
            baseNode: node
        )
    }
}

extension BodyTag {
    @inlinable
    public init() {
        self.init(node: .none)
    }
    
    @inlinable
    public init(
        @TemplateBuilder<Body> build: () -> ListContent<Body>
    ) {
        self.init(node: TemplateNode(from: build()))
    }
    
    @inlinable
    public init<Element: HTML>(
        @TemplateBuilder<Body> build: () -> Element
    ) {
        self.init(node: TemplateNode(from: build()))
    }
    
    public var html: Content { AnyBodyTag(Self.tag, content: node, modifiers: []) }
}

public struct AnyHTML: ContentRepresentable, HTML {
    let node: TemplateNode
    
    init(node: TemplateNode) {
        self.node = node
    }
    
    init() {
        self.node = .none
    }
    
    public init<Content: _HTML>(content: Content) {
        if let node = content as? TemplateNode {
            self.node = node
        } else if let content = content as? ContentRepresentable {
            self.node = content.node
        } else {
            self.node = AnyHTML(content: content.html).node
        }
    }
    
    public var html: Never { fatalError() }
}

public struct ListContent<ParentElement>: ContentRepresentable, _HTML {
    let node: TemplateNode
    
    init(list: [TemplateNode]) {
        self.node = .list(list)
    }
    
    public init<C: _HTML>(@TemplateBuilder<ParentElement> build: () -> C) {
        self.node = TemplateNode(from: build())
    }
    
    public var html: Self { self }
}

public struct ConditionalHTML<
    True: _HTML, False: _HTML
>: ContentRepresentable, _HTML where True.ParentElement == False.ParentElement {
    public typealias ParentElement = True.ParentElement
    
    enum Condition {
        case trueCase(True)
        case falseCase(False)
    }
    
    let condition: Condition
    
    var node: TemplateNode {
        return html.node
    }
    
    public var html: AnyHTML { AnyHTML(node: node) }
}

public struct OptionalContent<Content: _HTML>: ContentRepresentable, _HTML {
    public typealias ParentElement = Content.ParentElement
    
    let content: Content?
    
    var node: TemplateNode {
        if let content = content {
            return TemplateNode(from: content)
        }
        
        return .none
    }
    
    public var html: Never { fatalError() }
}

extension Optional: _HTML where Wrapped: _HTML {
    public typealias ParentElement = Wrapped.ParentElement
    
    public var html: OptionalContent<Wrapped> {
        OptionalContent(content: self)
    }
}

@_functionBuilder
public struct TemplateBuilder<Context> {
    public static func buildBlock() -> AnyHTML {
        return AnyHTML(node: .none)
    }
    
    public static func buildBlock<Content: _HTML>(
        _ content: Content
    ) -> Content where Content.ParentElement == Context {
        return content
    }
    
    public static func buildBlock<
        C0: _HTML, C1: _HTML
    >(
        _ c0: C0, _ c1: C1
    ) -> ListContent<Context> where C0.ParentElement == Context, C1.ParentElement == Context {
        return ListContent(list: [
            .init(from: c0),
            .init(from: c1),
        ])
    }
    
    public static func buildBlock<
        C0: _HTML, C1: _HTML, C2: _HTML
    >(
        _ c0: C0, _ c1: C1, _ c2: C2
    ) -> ListContent<Context> where C0.ParentElement == Context, C1.ParentElement == Context, C2.ParentElement == Context {
        return ListContent(list: [
            .init(from: c0),
            .init(from: c1),
            .init(from: c2),
        ])
    }
    
    public static func buildIf<Content: _HTML>(_ content: Content?) -> Content? where Content.ParentElement == Context { content }
    
    public static func buildEither<
        True: _HTML,
        False: _HTML
    >(first: True) -> ConditionalHTML<True, False> where ConditionalHTML<True, False>.ParentElement == Context {
        return ConditionalHTML<True, False>(condition: .trueCase(first))
    }
    
    public static func buildEither<
        True: _HTML,
        False: _HTML
    >(second: False) -> ConditionalHTML<True, False> where ConditionalHTML<True, False>.ParentElement == Context {
        return ConditionalHTML<True, False>(condition: .falseCase(second))
    }
}

public struct Head: _HTML {
    public typealias ParentElement = Root
    
    let node: TemplateNode
    
    public init() {
        self.node = .none
    }
    
    public init(@TemplateBuilder<Head> build: () -> ListContent<Head>) {
        self.node = TemplateNode(from: build())
    }
    
    public init<Element: _HTML>(@TemplateBuilder<Head> build: () -> Element) where Element.ParentElement == Head {
        self.node = TemplateNode(from: build())
    }
    
    public var html: AnyHTML {
        AnyHTML(node: .tag(name: "head", content: node, modifiers: []))
    }
}

public struct Title: HeadElement {
    public typealias ParentElement = Head
    
    let title: TemplateNode
    
//    public init(_ title: String) {
//        self.title = .literal(title)
//    }
    
    public init(_ string: String) {
        title = .literal(string)
    }
    
    public var html: AnyHTML {
        AnyHTML(node: .tag(name: "title", content: title, modifiers: []))
    }
}

extension String: HTML {
    public typealias Content = AnyHTML
    
    public var html: AnyHTML {
        AnyHTML(node: .literal(self))
    }
}

public struct Body: _HTML {
    public typealias ParentElement = Root
    
    let node: TemplateNode
    
    public init() {
        self.node = .none
    }
    
    public init(@TemplateBuilder<Body> build: () -> ListContent<Body>) {
        self.node = TemplateNode(from: build())
    }
    
    public init<Element: HTML>(@TemplateBuilder<Body> build: () -> Element) {
        self.node = TemplateNode(from: build())
    }
    
    public var html: AnyHTML {
        AnyHTML(node: .tag(name: "body", content: node, modifiers: []))
    }
}

public struct P: BodyTag {
    public typealias BaseTag = P
    
    static var tag: StaticString = "p"
    let node: TemplateNode
}

extension P {
    public init(text: String) {
        self.node = .literal(text)
    }
}

public struct A: BodyTag {
    public typealias BaseTag = A
    
    static var tag: StaticString = "a"
    let node: TemplateNode
}

public protocol URIStringRepresentable {
    func makeURIString() -> String
}

extension String: URIStringRepresentable {
    @inlinable
    public func makeURIString() -> String { self }
}

public struct AnyBodyTag: HTML {
    let name: StaticString
    let content: TemplateNode
    let modifiers: [Modifier]
    
    init(_ name: StaticString, content: TemplateNode, modifiers: [Modifier]) {
        self.name = name
        self.content = content
        self.modifiers = modifiers
    }
    
    public init(
        _ name: StaticString,
        @TemplateBuilder<Body> build: () -> ListContent<Body>
    ) {
        self.name = name
        self.content = TemplateNode(from: build())
        self.modifiers = []
    }
    
    public init<Element: HTML>(
        _ name: StaticString,
        @TemplateBuilder<Body> build: () -> Element
    ) {
        self.name = name
        self.content = TemplateNode(from: build())
        self.modifiers = []
    }
    
    public var html: AnyHTML {
        AnyHTML(node: .tag(name: name, content: content, modifiers: modifiers))
    }
}

internal enum Modifier {
    case attribute(name: String, value: String)
}


extension Array where Element == Modifier {
    var string: String {
        var string = ""
        
        for element in self {
            if case .attribute(let name, let value) = element {
                string += " \(name)=\"\(value)\""
            }
        }
        
        return string
    }
}

public struct Modified<BaseTag: AttributedHTML>: AttributedHTML {
    public typealias Content = AnyBodyTag
    public typealias ParentElement = BaseTag.ParentElement

    let tag: StaticString
    let modifiers: [Modifier]
    let baseNode: TemplateNode
    
    var node: TemplateNode {
        .tag(name: tag, content: baseNode, modifiers: modifiers)
    }
    
    public var html: Content { AnyBodyTag(tag, content: node, modifiers: modifiers) }
    
    public func attribute(key: String, value: String) -> Modified<BaseTag> {
        var modifiers = self.modifiers
        modifiers.append(
            .attribute(name: key, value: value)
        )
        
        return Modified(
            tag: tag,
            modifiers: modifiers,
            baseNode: baseNode
        )
    }
}

extension AttributedHTML where BaseTag == A {
    public func href<URI: URIStringRepresentable>(_ href: URI) -> Modified<BaseTag> {
        attribute(key: "href", value: href.makeURIString())
    }
}

public struct Root {
    let node: TemplateNode
    
    init(node: TemplateNode) {
        self.node = node
    }
    
    public var html: AnyHTML {
        AnyHTML(node: node)
    }
    
    public init<Content: _HTML>(@TemplateBuilder<Root> content: @escaping () -> Content) where Content.ParentElement == Root {
        node = .lazy({ TemplateNode(from: content()) })
    }
}
