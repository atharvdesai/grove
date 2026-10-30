import SwiftUI

/// `@State` without the macro.
///
/// From the macOS 27 SDK, `@State` resolves to a macro whose plugin ships only
/// with full Xcode, so a Command Line Tools build fails with "plugin for module
/// 'SwiftUIMacros' not found" — and every view after it with a cascade of
/// "self is immutable". Naming the property wrapper through an alias reaches
/// `SwiftUI.State` itself, which needs no plugin, and keeps Grove buildable
/// with `xcode-select --install` alone.
///
/// Use `@ViewState` wherever `@State` would go. The backing storage is still
/// `State<Value>`, so `_name = State(initialValue:)` in an init is unchanged.
typealias ViewState<Value> = SwiftUI.State<Value>
