//
//  DebugLog.swift
//  little-chef
//

import Foundation

#if DEBUG
@inline(__always)
func dprint(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    Swift.print(items.map { "\($0)" }.joined(separator: separator), terminator: terminator)
}
#else
@inline(__always)
func dprint(_ items: Any..., separator: String = " ", terminator: String = "\n") {}
#endif
