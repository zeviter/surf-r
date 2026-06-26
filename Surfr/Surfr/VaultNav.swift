import Foundation

/// The vault surface navigates as a **stack** (vault-spec WF-4/5/6/9). `list` is the implicit root
/// (empty stack); pushing opens a sub-screen. **Back and ESC each pop exactly one level** —
/// edit → detail → list → (caller closes the surface) → the tab you came from. Keeping the parent on
/// the stack is what makes an item opened *from Security Check* return *to Security Check*, not the
/// list. Pure + unit-tested; the view owns one `@State VaultNav`.
struct VaultNav: Equatable {
    enum Screen: Equatable {
        case securityCheck
        case detail(UUID)               // type-dispatched detail (login / note / address / payment)
        case editLogin(UUID?)           // nil = new
        case editNote(UUID?)
        case editAddress(UUID?)
        case editPayment(UUID?)
    }

    private(set) var stack: [Screen] = []

    /// The screen currently shown; `nil` = the list root.
    var current: Screen? { stack.last }
    var atRoot: Bool { stack.isEmpty }

    mutating func push(_ screen: Screen) { stack.append(screen) }

    /// Pop one level. Returns `false` when already at the root — the caller then closes the surface.
    @discardableResult mutating func pop() -> Bool {
        guard !stack.isEmpty else { return false }
        stack.removeLast()
        return true
    }

    mutating func reset() { stack.removeAll() }

    /// The item whose detail/edit is open (for surface-restore persistence), if any.
    var openItemID: UUID? {
        switch current {
        case .detail(let id): return id
        case .editLogin(let id), .editNote(let id), .editAddress(let id), .editPayment(let id): return id
        default: return nil
        }
    }
}
