// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Built off the main thread. Flat ownership avoids recursive view construction;
/// NSOutlineView asks only for the children and cells it needs to display.
final class CommandBarJSONDocument {
    struct Node {
        let parent: Int?
        let key: String
        let value: String
        let container: Bool
        var children: [Int]
        let summary: String
    }
    let nodes: [Node]

    init(text: String) throws {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        var result: [Node] = []
        func append(_ value: Any, key: String, parent: Int?) -> Int {
            let id = result.count
            let dictionary = value as? [String: Any]
            let array = value as? [Any]
            let description: String
            if let dictionary { description = "{ \(dictionary.count) }" }
            else if let array { description = "[ \(array.count) ]" }
            else if let string = value as? String { description = "\"\(string)\"" }
            else if value is NSNull { description = "null" }
            else if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) {
                description = String(decoding: data, as: UTF8.self)
            } else { description = String(describing: value) }
            result.append(Node(parent: parent, key: key, value: description,
                               container: dictionary != nil || array != nil, children: [],
                               summary: String(description.prefix(500)) + (description.count > 500 ? " …" : "")))
            var children: [Int] = []
            if let dictionary {
                children = dictionary.keys.sorted().map { append(dictionary[$0]!, key: $0, parent: id) }
            } else if let array {
                children = array.enumerated().map { append($0.element, key: "[\($0.offset)]", parent: id) }
            }
            result[id].children = children
            return id
        }
        _ = append(object, key: "$", parent: nil)
        nodes = result
    }

    func matches(_ query: String, cancelled: () -> Bool = { false }) -> [Int] {
        guard !query.isEmpty else { return [] }
        var matches: [Int] = []
        for index in nodes.indices {
            if cancelled() { return [] }
            let node = nodes[index]
            if node.key.localizedCaseInsensitiveContains(query) || node.value.localizedCaseInsensitiveContains(query) {
                matches.append(index)
            }
        }
        return matches
    }

    func ancestors(of index: Int) -> [Int] {
        var result: [Int] = []
        var parent = nodes[index].parent
        while let id = parent { result.append(id); parent = nodes[id].parent }
        return result.reversed()
    }
}
