import NIO
import XCTest
import TemplateKitten

@available(OSX 10.15.0, *)
public struct Article: HTML {
    public var html: some HTML {
        P {
            A {
                "Google"
            }.href("https://google.com")
            "No"
        }
    }
}

@available(OSX 10.15.0, *)
final class TemplateKittenTests: XCTestCase {
    func testExample() throws {
        let template = Root {
            Head {
                Title("Hello, Vapor!")
            }
            Body {
                Article()
                "Hello, world!"
            }
        }
        
        var compiled = try TemplateCompiler.compile(template)
        var context = TemplateContext()
        context["title"] = .staticString("Vapor")
        var output = ByteBufferAllocator().buffer(capacity: 4_096)
        output.reserveCapacity(10_000)
        measure {
            for _ in 0..<10_000 {
                _ = try! CompiledTemplate.render(template: &compiled, output: &output, in: context)
            }
        }
    }

    static var allTests = [
        ("testExample", testExample),
    ]
}
