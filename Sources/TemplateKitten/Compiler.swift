import Foundation
import NIO

enum CompiledNode: UInt8 {
    case none = 0x00
    case tag = 0x01
    case literal = 0x02
    case list = 0x03
    case contextValue = 0x04
}

enum Constants {
    static let quote: UInt8 = 0x22
    static let less: UInt8 = 0x3c
    static let equal: UInt8 = 0x3d
    static let greater: UInt8 = 0x3e
    static let forwardSlash: UInt8 = 0x2f
}

enum TemplateError: Error {
    case internalCompilerError
}

public enum TemplateValue {
    case staticString(StaticString)
    case string(String)
    case null
}

fileprivate func equal(lhs: StaticString, rhs: StaticString) -> Bool {
    if lhs.utf8CodeUnitCount != rhs.utf8CodeUnitCount {
        return false
    }
    
    return memcmp(lhs.utf8Start, rhs.utf8Start, lhs.utf8CodeUnitCount) == 0
}

public struct TemplateContext {
    var keys = [StaticString]()
    var values = [TemplateValue]()
    
    public init() {}
    
    public subscript(key: StaticString) -> TemplateValue {
        get {
            if let index = keys.firstIndex(where: { equal(lhs: $0, rhs: key) }) {
                return values[index]
            }
            
            return .null
        }
        set {
            if let index = keys.firstIndex(where: { equal(lhs: $0, rhs: key) }) {
                values[index] = newValue
            } else {
                keys.append(key)
                values.append(newValue)
            }
        }
    }
}

fileprivate extension ByteBuffer {
    mutating func withSlice(run: (UnsafeRawBufferPointer) throws -> ()) throws {
        guard let length = self.readInteger(as: UInt32.self) else {
            throw TemplateError.internalCompilerError
        }
        
        let size = Int(length)
        
        try self.readWithUnsafeReadableBytes { buffer in
            let buffer = UnsafeRawBufferPointer(start: buffer.baseAddress, count: size)
            try run(buffer)
            return size
        }
    }
}

public struct CompiledTemplate {
    private var _template: ByteBuffer
    
    init(template: ByteBuffer) {
        self._template = template
    }
    
    private struct ByteBufferSlicePosition {
        let offset: Int
        let length: Int
    }
    
    private static func getString(from template: inout ByteBuffer) throws -> String {
        guard
            let length = template.readInteger(as: UInt32.self),
            let data = template.readString(length: Int(length))
        else {
            throw TemplateError.internalCompilerError
        }
        
        return data
    }
    
    private static func compileNextNode(template: inout ByteBuffer, into output: inout ByteBuffer) throws {
        while let byte = template.readInteger(as: UInt8.self) {
            guard let node = CompiledNode(rawValue: byte) else {
                throw TemplateError.internalCompilerError
            }
            
            switch node {
            case .none:
                return
            case .literal:
                try template.withSlice { buffer in
                    output.writeBytes(buffer)
                }
            case .tag:
                let offset = template.readerIndex
                try template.withSlice { tag in
                    output.writeInteger(Constants.less)
                    output.writeBytes(tag)
                }

                guard let modifierCount = template.readInteger(as: UInt8.self) else {
                    throw TemplateError.internalCompilerError
                }
                
                for _ in 0..<modifierCount {
                    try template.withSlice { key in
                        output.writeBytes(key)
                    }
                    
                    output.writeInteger(Constants.equal)
                    output.writeInteger(Constants.quote)
                    
                    try template.withSlice { value in
                        output.writeBytes(value)
                    }
                    
                    output.writeInteger(Constants.quote)
                }
                    
                output.writeInteger(Constants.greater)
                
                try compileNextNode(template: &template, into: &output)
                
                output.writeInteger(Constants.less)
                output.writeInteger(Constants.forwardSlash)
                let newOffset = template.readerIndex
                template.moveReaderIndex(to: offset)
                try template.withSlice { tag in
                    output.writeBytes(tag)
                }
                template.moveReaderIndex(to: newOffset)
                output.writeInteger(Constants.greater)
            case .list:
                guard let nodeCount = template.readInteger(as: UInt8.self) else {
                    throw TemplateError.internalCompilerError
                }
            
                for _ in 0..<nodeCount {
                    try compileNextNode(template: &template, into: &output)
                }
            case .contextValue:
                guard let pathCount = template.readInteger(as: UInt8.self) else {
                    throw TemplateError.internalCompilerError
                }
                
            }
        }
    }
    
    public static func render(template: inout CompiledTemplate, output: inout ByteBuffer, in context: TemplateContext = .init()) throws {
        template._template.moveReaderIndex(to: 0)
        
        try compileNextNode(template: &template._template, into: &output)
    }
}

public struct TemplateCompiler {
    var buffer: ByteBuffer
    
    init() {
        buffer = ByteBufferAllocator().buffer(capacity: 4_096)
    }
    
    private mutating func compile(_ modifier: Modifier) {
        switch modifier {
        case .attribute(let name, let value):
            compileString(name)
            compileString(value)
        }
    }
    
    private mutating func compileString(_ string: String) {
        buffer.writeInteger(UInt32(string.utf8.count))
        buffer.writeString(string)
    }
    
    private mutating func compile(_ node: TemplateNode) {
        switch node {
        case .none:
        buffer.writeInteger(CompiledNode.none.rawValue)
        case .tag(let name, let content, let modifiers):
            let data = Data(bytes: name.utf8Start, count: name.utf8CodeUnitCount)
            let name = String(data: data, encoding: .utf8)!
            
            buffer.writeInteger(CompiledNode.tag.rawValue)
            compileString(name)
            buffer.writeInteger(UInt8(modifiers.count))
            
            for modifier in modifiers {
                compile(modifier)
            }
            
            compile(content)
        case .literal(let literal):
            buffer.writeInteger(CompiledNode.literal.rawValue)
            compileString(literal)
        case .list(let nodes):
            buffer.writeInteger(CompiledNode.list.rawValue)
            buffer.writeInteger(UInt8(nodes.count))
            
            for node in nodes {
                compile(node)
            }
        case .lazy(let render):
            compile(render())
        case .contextValue(let path):
            buffer.writeInteger(CompiledNode.contextValue.rawValue)
            buffer.writeInteger(UInt8(path.count))
            
            for key in path {
                compileString(key)
            }
        }
    }
    
    public static func compile<T: Template>(_ type: T.Type) -> CompiledTemplate {
        var compiler = TemplateCompiler()
        compiler.compile(TemplateNode(from: T()))
        return CompiledTemplate(template: compiler.buffer)
    }
    
    public static func compile(_ root: Root) -> CompiledTemplate {
        var compiler = TemplateCompiler()
        compiler.compile(root.node)
        return CompiledTemplate(template: compiler.buffer)
    }
}
//
//struct TemplateRenderer {
//    static func updateString(_ string: inout String, forNode node: TemplateNode) {
//        switch node {
//        case .none:
//            return
//        case .tag(let name, let content, let modifiers):
//            let data = Data(bytes: name.utf8Start, count: name.utf8CodeUnitCount)
//            let name = String(data: data, encoding: .utf8)!
//            let modifierString = modifiers.string
//            string += "<\(name)\(modifierString)>"
//            updateString(&string, forNode: content)
//            string += "</\(name)>"
//        case .literal(let literal):
//            string += literal
//        case .list(let nodes):
//            for node in nodes {
//                updateString(&string, forNode: node)
//            }
//        case .
//        case .lazy(let render):
//            updateString(&string, forNode: render())
//        }
//    }
//}
//
