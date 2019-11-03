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

fileprivate extension UnsafeByteBuffer {
    mutating func parseSlice() throws -> UnsafeByteBuffer {
        guard
            let length = readInteger(as: UInt32.self),
            let slice = readUnsafeSlice(length: Int(length))
        else {
            throw TemplateError.internalCompilerError
        }
        
        return slice
    }
}

extension ByteBuffer {
    mutating func writeBytes(_ buffer: UnsafeByteBuffer) {
        buffer.withUnsafeReadableBytes { buffer in
            self.writeBytes(buffer)
        }
    }
}

public struct CompiledTemplate {
    private var _template: UnsafeByteBuffer
    
    init(template: UnsafeByteBuffer) {
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
    
    private static func compileNextNode(template: inout UnsafeByteBuffer, into output: inout ByteBuffer) throws {
        while let byte = template.readInteger(as: UInt8.self) {
            guard let node = CompiledNode(rawValue: byte) else {
                throw TemplateError.internalCompilerError
            }
            
            switch node {
            case .none:
                return
            case .literal:
                let buffer = try template.parseSlice()
                output.writeBytes(buffer)
            case .tag:
                let offset = template.readerIndex
                let tag = try template.parseSlice()
                output.writeInteger(Constants.less)
                output.writeBytes(tag)

                guard let modifierCount = template.readInteger(as: UInt8.self) else {
                    throw TemplateError.internalCompilerError
                }
                
                for _ in 0..<modifierCount {
                    let key = try template.parseSlice()
                    let value = try template.parseSlice()
                    
                    output.writeBytes(key)
                    output.writeInteger(Constants.equal)
                    output.writeInteger(Constants.quote)
                    output.writeBytes(value)
                    output.writeInteger(Constants.quote)
                }
                    
                output.writeInteger(Constants.greater)
                
                try compileNextNode(template: &template, into: &output)
                
                output.writeInteger(Constants.less)
                output.writeInteger(Constants.forwardSlash)
                output.writeBytes(tag)
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
        
        let size = compiler.buffer.readableBytes
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
        
        compiler.buffer.withUnsafeReadableBytes { buffer in
            _ = memcpy(pointer, buffer.baseAddress, size)
        }
        
        let buffer = UnsafeByteBuffer(pointer: pointer, size: size)
        return CompiledTemplate(template: buffer)
    }
    
    public static func compile(_ root: Root) -> CompiledTemplate {
        var compiler = TemplateCompiler()
        compiler.compile(root.node)
        
        let size = compiler.buffer.readableBytes
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
        
        compiler.buffer.withUnsafeReadableBytes { buffer in
            _ = memcpy(pointer, buffer.baseAddress, size)
        }
        
        let buffer = UnsafeByteBuffer(pointer: pointer, size: size)
        return CompiledTemplate(template: buffer)
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
