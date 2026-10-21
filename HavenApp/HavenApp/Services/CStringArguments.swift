import Foundation

/// Calls `body` with C strings for `strings` that stay valid for the whole
/// call, for passing keys and payloads to the Go FFI.
///
/// Replaces `UnsafeMutablePointer(mutating: (s as NSString).utf8String)`,
/// whose pointer belongs to an autoreleased bridged NSString and is only
/// guaranteed while that object lives. It worked because the call sat in the
/// same expression; a refactor could hand Go (often a private key) a dangling
/// pointer. Here each pointer comes from `String.withCString`, scoped to `body`.
///
/// Go's exported functions take `*C.char`, which Swift imports as mutable, so
/// the pointers are mutable in type only. Go copies with `C.GoString` and
/// never writes through them.
func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>]) -> R) -> R {
    func nest(_ index: Int, _ pointers: [UnsafeMutablePointer<CChar>]) -> R {
        guard index < strings.count else { return body(pointers) }
        return strings[index].withCString { nest(index + 1, pointers + [UnsafeMutablePointer(mutating: $0)]) }
    }
    return nest(0, [])
}
