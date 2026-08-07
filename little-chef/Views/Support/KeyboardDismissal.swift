//
//  KeyboardDismissal.swift
//  little-chef
//
//  One reliable way to put the keyboard away.
//

import SwiftUI
import UIKit

/// Resigns whatever is first responder, wherever it lives.
///
/// `@FocusState` can only clear focus it owns. Once the keyboard belongs to a field in a sheet,
/// a `List` row, a `TextEditor`, or a search bar the current view knows nothing about, setting a
/// local focus flag to `false` does nothing at all — which is why the keyboard sat there covering
/// half the screen after the user had visibly moved on. Asking UIKit to resign first responder
/// is the one call that works from anywhere.
@MainActor
func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

extension View {

    /// Dismisses the keyboard when this view is tapped anywhere that isn't a control.
    ///
    /// Controls keep working: a tap gesture on a container is the outermost recognizer, so
    /// buttons, rows and text fields inside it get first refusal on the touch and this only
    /// fires for taps nothing else claimed. `contentShape` is what makes the empty gaps between
    /// them tappable at all — without it there is nothing to hit.
    ///
    /// Best-effort rather than the whole answer: a tap inside a scroll view can be claimed by
    /// the scroll view instead. `scrollDismissesKeyboard(.interactively)` — swipe down over the
    /// content to push the keyboard away — covers what this can't.
    func dismissesKeyboardOnTap() -> some View {
        contentShape(Rectangle())
            .onTapGesture { dismissKeyboard() }
    }
}
